#!/usr/bin/env bash
#
# Copyright (c) 2017-2020 Intel Corporation
# Copyright (c) 2018 ARM Limited
#
# SPDX-License-Identifier: Apache-2.0
#

export KATA_RUNTIME=${KATA_RUNTIME:-kata-runtime}
export KATA_KSM_THROTTLER=${KATA_KSM_THROTTLER:-no}
export KATA_NEMU_DESTDIR=${KATA_NEMU_DESTDIR:-"/usr"}
export KATA_QEMU_DESTDIR=${KATA_QEMU_DESTDIR:-"/usr"}
export KATA_ETC_CONFIG_PATH="/etc/kata-containers/configuration.toml"

export kata_repo="github.com/kata-containers/kata-containers"
export kata_repo_dir="${GOPATH}/src/${kata_repo}"
export kata_default_branch="${kata_default_branch:-main}"


# Name of systemd service for the throttler
KATA_KSM_THROTTLER_JOB="kata-ksm-throttler"

# How long do we wait for docker to perform a task before we
# timeout with the presumption it has hung.
# Docker itself has a 10s timeout, so make our timeout longer
# than that. Measured in seconds by default (see timeout(1) for
# more formats).
export KATA_DOCKER_TIMEOUT=30

# Number of seconds to wait for a general network operation to complete.
export KATA_NET_TIMEOUT=30

# Ensure GOPATH set
if command -v go > /dev/null; then
	export GOPATH=${GOPATH:-$(go env GOPATH)}
else
	# if go isn't installed, set default location for GOPATH
	export GOPATH="${GOPATH:-$HOME/go}"
fi

tests_repo="${tests_repo:-github.com/kata-containers/tests}"
lib_script="${GOPATH}/src/${tests_repo}/lib/common.bash"
source "${lib_script}"

export KATA_OBS_REPO_BASE="http://download.opensuse.org/repositories/home:/katacontainers:/releases:/$(arch):/master"

# Jenkins master URL
jenkins_url="http://jenkins.katacontainers.io"
# Path where cached artifacts are found.
cached_artifacts_path="lastSuccessfulBuild/artifact/artifacts"

# If we fail for any reason a message will be displayed
die() {
	msg="$*"
	echo "ERROR: $msg" >&2
	exit 1
}

info() {
	echo -e "INFO: $*"
}

# Clone repo only if $kata_repo_dir is empty
# Otherwise, we assume $kata_repo is cloned and in correct branch, e.g. a PR or local change
clone_kata_repo() {
	if [ ! -d "${kata_repo_dir}" ]; then
		go get -d "${kata_repo}" || true
		pushd "${kata_repo_dir}"
		# Checkout to default branch
		git checkout "${kata_default_branch}"
		popd
	fi
}

function build_version() {
	github_project="$1"
	make_target="$2"
	version="$3"

	[ -z "${version}" ] && die "need version to build"

	project_dir="${GOPATH}/src/${github_project}"

	[ -d "${project_dir}" ] || go get -d "${github_project}" || true

	pushd "${project_dir}"

	if [ "$version" != "HEAD" ]; then
		info "Using ${github_project} version ${version}"
		git checkout -b "${version}" "${version}"
	fi

	info "Building ${github_project}"
	if [ ! -f Makefile ]; then
		if [ -f autogen.sh ]; then
			info "Run autogen.sh to generate Makefile"
			bash -f autogen.sh
		fi
	fi

	if [ -f Makefile ]; then
		make ${make_target}
	else
		# install locally (which is what "go get" does by default)
		go install ./...
	fi

	popd
}

function build() {
	github_project="$1"
	make_target="$2"
	version="${3:-"HEAD"}"

	build_version "${github_project}" "${make_target}" "${version}"
}

function build_and_install() {
	github_project="$1"
	make_target="$2"
	test_not_gopath_set="$3"
	tag="$4"

	build "${github_project}" "${make_target}" "${tag}"
	pushd "${GOPATH}/src/${github_project}"
	if [ "$test_not_gopath_set" = "true" ]; then
		info "Installing ${github_project} in No GO command or GOPATH not set mode"
		sudo -E PATH="$PATH" KATA_RUNTIME="${KATA_RUNTIME}" make install
		[ $? -ne 0 ] && die "Fail to install ${github_project} in No GO command or GOPATH not set mode"
	fi
	info "Installing ${github_project}"
	sudo -E PATH="$PATH" KATA_RUNTIME="${KATA_RUNTIME}" make install
	popd
}

function get_dep_from_yaml_db(){
	local versions_file="$1"
	local dependency="$2"

	[ ! -f "$versions_file" ] && die "cannot find $versions_file"

	"${GOPATH}/src/${tests_repo}/.ci/install_yq.sh" >&2

	result=$("${GOPATH}/bin/yq" r -X "$versions_file" "$dependency")
	[ "$result" = "null" ] && result=""
	echo "$result"
}

function get_version(){
	dependency="$1"
	versions_file="${kata_repo_dir}/versions.yaml"
	if [ ! -d "${kata_repo_dir}" ]; then
		mkdir -p "$(dirname ${kata_repo_dir})"
		git clone --quiet https://${kata_repo}.git "${kata_repo_dir}"
		( cd "${kata_repo_dir}" && git checkout "$kata_default_branch" >&2 )
	fi
	get_dep_from_yaml_db "${versions_file}" "${dependency}"
}

function get_test_version(){
	local dependency="$1"

	local db
	local cidir

	# directory of this script, not the caller
	local cidir=$(dirname "${BASH_SOURCE[0]}")

	db="${cidir}/../versions.yaml"

	get_dep_from_yaml_db "${db}" "${dependency}"
}

function waitForProcess(){
        wait_time="$1"
        sleep_time="$2"
        cmd="$3"
        while [ "$wait_time" -gt 0 ]; do
                if eval "$cmd"; then
                        return 0
                else
                        sleep "$sleep_time"
                        wait_time=$((wait_time-sleep_time))
                fi
        done
        return 1
}

kill_stale_process()
{
	clean_env
	extract_kata_env
	stale_process_union=( "${stale_process_union[@]}" "${PROXY_PATH}" "${HYPERVISOR_PATH}" "${SHIM_PATH}" )
	for stale_process in "${stale_process_union[@]}"; do
		[ -z "${stale_process}" ] && continue
		local pids=$(pgrep -d ' ' -f "${stale_process}")
		if [ -n "$pids" ]; then
			sudo kill -9 ${pids} || true
		fi
	done
}

delete_stale_docker_resource()
{
	sudo systemctl stop docker.service docker.socket

	# before removing stale docker dir, you should umount related resource
	for stale_docker_mount_point in "${stale_docker_mount_point_union[@]}"; do
		local mount_point_union=$(mount | grep "${stale_docker_mount_point}" | awk '{print $3}')
		if [ -n "${mount_point_union}" ]; then
			while IFS='$\n' read mount_point; do
				[ -n "$(grep "${mount_point}" "/proc/mounts")" ] && sudo umount -R "${mount_point}"
			done <<< "${mount_point_union}"
		fi
	done
	# remove stale docker dir
	for stale_docker_dir in "${stale_docker_dir_union[@]}"; do
		if [ -d "${stale_docker_dir}" ]; then
			sudo rm -rf "${stale_docker_dir}"
		fi
	done

	sudo systemctl disable docker.service docker.socket
	sudo rm -f /etc/systemd/system/{docker.service,docker.socket}
}

delete_stale_kata_resource()
{
	for stale_kata_dir in "${stale_kata_dir_union[@]}"; do
		if [ -d "${stale_kata_dir}" ]; then
			sudo rm -rf "${stale_kata_dir}"
		fi
	done
}

delete_kata_repo_registrations()
{
	case "$ID" in
		ubuntu)
			local apt_file="/etc/apt/sources.list.d/kata-containers.list"
			if [ -f "$apt_file" ]; then
				info "Removing Kata apt file [$apt_file]"
				sudo rm -f "$apt_file"
			fi

			sudo apt-key list | grep 'home:katacontainers' > /dev/null
			if [ $? -eq 0 ]; then
				# apt-key output format changed at ubuntu 16.10
				if [ "$VERSION_ID" \< "16.10" ]; then
					kata_uuid="$(sudo apt-key list | awk '$2=="home:katacontainers" {print prev} {prev=$2}')"
					kata_uuid="${kata_uuid##*/}"
				else
					kata_uuid="$(sudo apt-key list | awk '$4=="home:katacontainers" {print prev} {prev=$0}')"
				fi

				if [ -n "$kata_uuid" ]; then
					info "Removing Kata apt key [$kata_uuid]"
					sudo apt-key del "$kata_uuid"
				else
					die "Failed to parse apt-key output for [$ID][$VERSION_ID]"
				fi
			else
				info "No katacontainers key found - not removing"
			fi
			;;

		*) info "Do not know how to clean repos from distro [$ID]";;
	esac
}

delete_crio_stale_resource() {
	# stale cri-o related binary
	sudo rm -rf /usr/local/bin/crio
	sudo sh -c 'rm -rf /usr/local/libexec/crio/*'
	sudo rm -rf /usr/local/bin/crio-runc
	# stale cri-o related configuration
	sudo rm -rf /etc/crio/crio.conf
	sudo rm -rf /usr/local/share/oci-umount/oci-umount.d/crio-umount.conf
	sudo rm -rf /etc/crictl.yaml
	# stale cri-o systemd service file
	sudo rm -rf /etc/systemd/system/crio.service
}

delete_containerd_cri_stale_resource() {
	# stop containerd service
	sudo systemctl stop containerd
	# remove stale binaries
	containerd_cri_dir="github.com/containerd/cri"
	release_dir="${GOPATH}/src/${containerd_cri_dir}/_output/release-stage"
	binary_dir_union=( "/usr/local/bin" "/usr/local/sbin" )
	for binary_dir in ${binary_dir_union[@]}
	do
		for stale_binary in ${release_dir}/${binary_dir}/*
		do
			sudo rm -rf ${binary_dir}/$(basename ${stale_binary})
		done
	done
	# remove cluster directory
	sudo rm -rf /opt/containerd/
	# remove containerd home/run directory
	sudo rm -r /var/lib/containerd
	sudo rm -r /var/lib/containerd-test
	sudo rm -r /run/containerd
	sudo rm -r /run/containerd-test
	# remove configuration files
	sudo rm -f /etc/containerd/config.toml
	sudo rm -f /etc/crictl.yaml
	sudo rm -f /etc/systemd/system/containerd.service
}

gen_clean_arch() {
	# Set up some vars
	stale_process_union=( "docker-containerd-shim" )
	#docker supports different storage driver, such like overlay2, aufs, etc.
	docker_storage_driver=$(timeout ${KATA_DOCKER_TIMEOUT} docker info --format='{{.Driver}}')
	stale_docker_mount_point_union=( "/var/lib/docker/containers" "/var/lib/docker/${docker_storage_driver}" )
	stale_docker_dir_union=( "/var/lib/docker" )
	stale_kata_dir_union=( "/var/lib/vc" "/run/vc" "/usr/share/kata-containers" "/usr/share/defaults/kata-containers" )

	info "kill stale process"
	kill_stale_process
	info "delete stale docker resource under ${stale_docker_dir_union[@]}"
	delete_stale_docker_resource
	info "delete stale kata resource under ${stale_kata_dir_union[@]}"
	delete_stale_kata_resource
	info "Remove installed kata packages"
	${GOPATH}/src/${tests_repo}/cmd/kata-manager/kata-manager.sh remove-packages
	info "Remove installed cri-o related binaries and configuration"
	delete_crio_stale_resource
	info "Remove installed containerd-cri related binaries and configuration"
	delete_containerd_cri_stale_resource
	info "Remove installed kubernetes packages and configuration"
	if [ "$ID" == ubuntu ]; then
		sudo rm -rf /etc/systemd/system/kubelet.service.d
		sudo apt-get remove kubeadm kubelet kubectl docker.io docker-ce containerd.io docker-ce-cli -y
		sudo apt autoremove -y
	fi
	# Remove existing CNI configurations and binaries.
	sudo sh -c 'rm -rf /opt/cni/bin/*'
	sudo sh -c 'rm -rf /etc/cni'
	sudo sh -c 'rm -rf /var/lib/cni'

	info "Remove Kata package repo registrations"
	delete_kata_repo_registrations

	info "Clean GOCACHE"
	if command -v go > /dev/null; then
		GOCACHE=${GOCACHE:-$(go env GOCACHE)}
	else
		# if go isn't installed, try default dir
		GOCACHE=${GOCACHE:-$HOME/.cache/go-build}
	fi
	[ -d "$GOCACHE" ] && sudo rm -rf ${GOCACHE}/*

	info "Clean transient test data and logs which has been stored under ${KATA_TESTS_BASEDIR}"
	[ -d "${KATA_TESTS_BASEDIR}" ] && sudo rm -rf ${KATA_TESTS_BASEDIR}/*
}

check_git_version() {
	result="true"

        local required_version_major=$(echo "$1" | cut -d. -f1)
        local required_version_medium=$(echo "$1" | cut -d. -f2)
        local required_version_minor=$(echo "$1" | cut -d. -f3)

        local git_version=$(git version | cut -d' ' -f3)
        [ -n "${git_version}" ] || die "cannot determine git version, please ensure it is installed"

        local current_version_major=$(echo "${git_version}" | cut -d. -f1)
        local current_version_medium=$(echo "${git_version}" | cut -d. -f2)
        local current_version_minor=$(echo "${git_version}" | cut -d. -f3)

        [[ ${current_version_major} -lt ${required_version_major} ]] || \
        [[ ( ${current_version_major} -eq ${required_version_major} ) && ( ${current_version_medium} -lt ${required_version_medium} ) ]] || \
        [[ ( ${current_version_major} -eq ${required_version_major} ) && ( ${current_version_medium} -eq ${required_version_medium} ) && ( ${current_version_minor} -lt ${required_version_minor} ) ]] && \
        result="false"

	echo "${result}"
}

# Obtain a list of the files the PR changed.
# Returns the information in format "${filter}\t${file}".
get_pr_changed_file_details_full()
{
	# List of filters used to restrict the types of file changes.
	# See git-diff-tree(1) for further info.
	local filters=""

	# Added file
	filters+="A"

	# Copied file
	filters+="C"

	# Modified file
	filters+="M"

	# Renamed file
	filters+="R"

	# Unmerged (U) and Unknown (X) files. These particular filters
	# shouldn't be necessary but just in case...
	filters+="UX"

	git diff-tree \
		-r \
		--name-status \
		--diff-filter="${filters}" \
		"origin/${branch}" HEAD
}

# Obtain a list of the files the PR changed, ignoring vendor files.
# Returns the information in format "${filter}\t${file}".
get_pr_changed_file_details()
{
	get_pr_changed_file_details_full | grep -v "vendor/"
}


# Gets a list of files and/or directories to build a SHA-256 from their contents.
# Returns the SHA-256 hash if succeeded, otherwise an empty string.
sha256sum_from_files() {
	local files_in=${1:-}
	local files=""
	local shasum=""

	# Process the input files:
	#  - discard the files/directories that don't exist.
	#  - find the files if it is a directory
	for f in $files_in; do
		if [ -d "$f" ]; then
			files+=" $(find $f -type f)"
		elif [ -f "$f" ]; then
			files+=" $f"
		fi
	done
	# Return in case there is none input files.
	[ -n "$files" ] || return 0

	# Alphabetically sorting the files.
	files="$(echo $files | tr ' ' '\n' | LC_ALL=C sort -u)"
	# Concate the files and calculate a hash.
	shasum="$(cat $files | sha256sum -b)" || true
	if [ -n "$shasum" ];then
		# Return only the SHA field.
		echo $(awk '{ print $1 }' <<< $shasum)
	fi
}

# Calculate a SHA-256 from all the files used to build QEMU.
# Use this function to detect changes on build scripts which should force a
# local build of QEMU.
#
# Note: bear in mind it is not used a comprehensive list of files but only
# those that seems sufficient to detect changes. For example, this script is
# sourced by many others but it is not considered.
calc_qemu_files_sha256sum() {
	local pkg_dir="${kata_repo_dir}/tools/packaging"
	local files="${pkg_dir}/qemu \
		${pkg_dir}/static-build/qemu \
		${pkg_dir}/static-build/qemu.blacklist \
		${pkg_dir}/static-build/scripts \
		${pkg_dir}/scripts"

	sha256sum_from_files $files
}
