#!/usr/bin/env bash
# Shared helpers for stages that run commands inside the target rootfs.
#
# Stage 2 unmounts /dev, /proc and /sys before it hands the rootfs on, so stages
# 3 and 4 have to re-establish the bind mounts before calling chroot.
#
# Source this file, then use chroot_mounts_up / chroot_mounts_down.

chroot_mounts_up() {
	local root=$1 d
	[[ -d $root ]] || { echo "chroot_mounts_up: $root does not exist" >&2; return 1; }
	for d in dev dev/pts proc sys; do
		mkdir -p "$root/$d"
		mountpoint -q "$root/$d" && continue
		mount --bind "/$d" "$root/$d"
	done
}

chroot_mounts_down() {
	local root=$1 d
	for d in dev/pts dev proc sys; do
		umount -lf "$root/$d" 2>/dev/null || true
	done
}
