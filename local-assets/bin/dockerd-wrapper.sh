#!/usr/bin/env bash
set -Eeuo pipefail

workaround_apparmor_profile_reload() {
	local aa_profile_reloaded="$SNAP_COMMON/profile_reloaded"
	# https://github.com/docker/docker-snap/issues/4
	if [ ! -f "$aa_profile_reloaded" ]; then
		local aa_count
		if aa_count="$(grep -c 'docker-default (enforce)' /sys/kernel/security/apparmor/profiles)" && [ -n "$aa_count" ] && [ "$aa_count" -ge 1 ]; then
			export DOCKER_AA_RELOAD=1
			touch "$aa_profile_reloaded"
		fi
	fi
}

default_socket_group='docker'
workaround_lp1606510() {
	# ensure there's at least one member in the group.
	local getent_group_docker_snap
	if getent_group_docker_snap="$(getent group docker-snap | awk -F':' '{print $NF}')" && [ -n "$getent_group_docker_snap" ]; then
		default_socket_group='docker-snap'
	fi
}

yolo() {
	"$@" > /dev/null 2>&1 || :
}

force_umount() {
	yolo umount    "$@"
	yolo umount -f "$@"
	yolo umount -l "$@"
}

# check if enough interfaces is connected to run
# as minimum we want, docker-support, firewall-control, and home
check_connected_interfaces() {
  if ! snapctl is-connected docker-support || \
     ! snapctl is-connected firewall-control ||\
     ! snapctl is-connected home ; then
       exit -1
  fi
}

dir="$(mktemp -d)"
trap "force_umount --no-mtab '$dir'; rm -rf '$dir'" EXIT
# try mounting a few FS types to force the kernel to try loading modules
for t in aufs overlay zfs; do
	yolo mount --no-mtab -t "$t" /dev/null "$dir"
	force_umount --no-mtab "$dir"
done
# inside our snap, we can't "modprobe" for whatever reason (probably no access to the .ko files)
# so this forces the kernel itself to "modprobe" for these filesystems so that the modules we need are available to Docker
rm -rf "$dir"
trap - EXIT

# modify XDG_RUNTIME_DIR to be a snap writable dir underneath $SNAP_COMMON
# until LP #1656340 is fixed
export XDG_RUNTIME_DIR=$SNAP_COMMON/run

# use SNAP_DATA for most "data" bits
mkdir -p \
	"/run/docker" \
	"$SNAP_COMMON/var/lib/docker" \
	"$XDG_RUNTIME_DIR"

check_connected_interfaces

workaround_lp1606510

workaround_apparmor_profile_reload

# make sure we have up to date docker daemon config file
snapctl get -d docker.daemon | jq .[] > "${SNAP_DATA}/etc/docker/daemon.json"

exec "$@" \
	--group "$default_socket_group" \
	--exec-root="/run/docker" \
	--data-root="/var/lib/docker" \
	--pidfile="/run/docker/docker.pid" \
	--config-file="/etc/docker/daemon.json"
