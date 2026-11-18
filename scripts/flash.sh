#!/usr/bin/env bash
# One-shot flasher for the UFI_16__V4 / UFI-001B / UFI-001C 4G stick.
#
# Handles both entry paths and picks one automatically:
#
#   fastboot  stock aboot (or lk2nd) still alive -> writes boot + rootfs only
#   edl       device in 9008 mode, or bricked    -> rewrites GPT and boot chain
#
# Nothing here touches modemst1/modemst2/fsg unless you pass --with-modem-data:
# those carry this unit's RF calibration and IMEI, and no download restores them.
#
# Usage:
#   ./flash.sh                      auto-detect mode, flash the bundled image
#   ./flash.sh --image FILE.img     explicit image
#   ./flash.sh --edl                force the EDL path
#   ./flash.sh --fastboot           force the fastboot path
#   ./flash.sh --backup DIR         back up calibration partitions first
#   ./flash.sh --dry-run            print commands, change nothing
#   ./flash.sh --with-modem-data    also write modemst1/2, fsg, fsc (dangerous)
set -euo pipefail

HERE="$(cd "$(dirname "${BASH_SOURCE[0]}")/.." && pwd)"

IMAGE=""
MODE="auto"
BACKUP_DIR=""
DRY_RUN=0
WITH_MODEM_DATA=0
ASSUME_YES=0

log()  { printf '\n\033[1;36m==> %s\033[0m\n' "$*"; }
info() { printf '    %s\n' "$*"; }
warn() { printf '\033[1;33m[!] %s\033[0m\n' "$*"; }
die()  { printf '\033[1;31m[x] %s\033[0m\n' "$*" >&2; exit 1; }
run()  { if (( DRY_RUN )); then echo "    \$ $*"; else "$@"; fi; }

usage() {
	sed -n '2,19p' "${BASH_SOURCE[0]}" | sed 's/^# \{0,1\}//'
	exit 0
}

while (( $# )); do
	case $1 in
		--image)           shift; IMAGE=$1;;
		--edl)             MODE=edl;;
		--fastboot)        MODE=fastboot;;
		--backup)          shift; BACKUP_DIR=$1;;
		--dry-run)         DRY_RUN=1;;
		--with-modem-data) WITH_MODEM_DATA=1;;
		-y|--yes)          ASSUME_YES=1;;
		-h|--help)         usage;;
		*) die "unknown option: $1 (try --help)";;
	esac
	shift
done

need_tool() { command -v "$1" >/dev/null || die "missing tool: $1${2:+ ($2)}"; }

detect_image() {
	[[ $IMAGE ]] && return
	local cand
	for cand in "$HERE/out/ufi16v4-dietpi-oc.img" \
	            "$HERE/ufi16v4-dietpi-oc.img" \
	            ./ufi16v4-dietpi-oc.img; do
		[[ -f $cand ]] && { IMAGE=$cand; return; }
	done
	die "no image found; pass --image FILE.img"
}

# lsblk rather than "partx -o LABEL": util-linux 2.38 dropped that column.
part_dev() { # <loop-or-disk> <label>
	lsblk -lnpo NAME,PARTLABEL "$1" 2>/dev/null \
		| awk -v l="$2" '$2==l{print $1; exit}'
}

detect_mode() {
	[[ $MODE != auto ]] && { echo "$MODE"; return; }
	if command -v fastboot >/dev/null && fastboot devices 2>/dev/null | grep -q .; then
		echo fastboot; return
	fi
	if command -v adb >/dev/null \
	   && adb devices 2>/dev/null | awk 'NR>1 && $2=="device"{f=1} END{exit !f}'; then
		echo fastboot; return
	fi
	if command -v lsusb >/dev/null && lsusb | grep -qi '05c6:9008'; then
		echo edl; return
	fi
	echo none
}

do_backup() {
	[[ $BACKUP_DIR ]] || return 0
	log "Backing up per-device partitions to $BACKUP_DIR"
	mkdir -p "$BACKUP_DIR"
	case $1 in
		fastboot)
			need_tool fastboot
			for p in fsc fsg modemst1 modemst2; do
				info "dump $p"
				run fastboot oem dump "$p" || warn "dump $p failed"
				run fastboot get_staged "$BACKUP_DIR/$p.bin" || warn "get_staged $p failed"
			done
			;;
		edl)
			need_tool edl
			for p in modemst1 modemst2 fsg fsc; do
				info "read $p"
				run edl r "$p" "$BACKUP_DIR/$p.bin" || warn "read $p failed"
			done
			;;
	esac
	info "saved to $BACKUP_DIR"
}

confirm() {
	(( ASSUME_YES )) && return 0
	echo
	warn "$1"
	read -r -p "    continue? [y/N] " a
	[[ ${a,,} == y* ]] || die "aborted"
}

flash_fastboot() {
	need_tool fastboot
	log "Flashing over fastboot"

	if command -v adb >/dev/null \
	   && adb devices 2>/dev/null | awk 'NR>1 && $2=="device"{f=1} END{exit !f}'; then
		info "device visible over adb, rebooting to bootloader"
		run adb reboot bootloader
		sleep 8
	fi

	fastboot devices | grep -q . \
		|| die "no fastboot device; hold the EDL button (GPIO37) while plugging in, then retry"

	confirm "This overwrites the boot and rootfs partitions. Modem calibration is kept."

	WORK=$(mktemp -d)
	trap 'rm -rf "$WORK"' RETURN

	log "Extracting boot and rootfs from $IMAGE"
	LOOP=$(sudo losetup -f --show -P "$IMAGE")
	info "loop device $LOOP"

	BOOT=$(part_dev "$LOOP" boot)
	ROOT=$(part_dev "$LOOP" rootfs)
	if [[ ! -b $BOOT || ! -b $ROOT ]]; then
		sudo losetup -d "$LOOP"
		die "image has no boot/rootfs partition; inspect with 'lsblk -p $LOOP'"
	fi

	sudo dd if="$BOOT" of="$WORK/boot.img" bs=4M status=none
	sudo dd if="$ROOT" of="$WORK/rootfs.img" bs=4M status=none
	sudo losetup -d "$LOOP"

	log "Writing boot (lk2nd) and rootfs"
	run fastboot flash boot   "$WORK/boot.img"
	run fastboot flash rootfs "$WORK/rootfs.img"
	run fastboot erase userdata || true
	run fastboot reboot

	log "Done"
	info "The stick boots DietPi; reach it at 192.168.68.1 over the USB NIC"
	info "or /dev/ttyACM0 for the serial console. Login: root / dietpi"
}

flash_edl() {
	need_tool edl
	log "Flashing over EDL (9008)"

	if ! lsusb 2>/dev/null | grep -qi '05c6:9008'; then
		warn "device is not in EDL mode"
		info "hold the EDL button (GPIO37) while plugging in USB, then retry"
		die "no EDL device"
	fi

	confirm "Full flash: GPT, SBL1, RPM, TZ, HYP, aboot, lk2nd, rootfs. Modem calibration is preserved unless --with-modem-data."

	WORK=$(mktemp -d)
	trap 'rm -rf "$WORK"' RETURN

	log "Splitting $IMAGE into named partition dumps"
	LOOP=$(sudo losetup -f --show -P "$IMAGE")
	info "loop device $LOOP"
	lsblk -lpo NAME,SIZE,PARTLABEL "$LOOP" | sed 's/^/    /'

	while read -r label; do
		[[ $label ]] || continue
		dev=$(part_dev "$LOOP" "$label")
		[[ -b $dev ]] || continue
		sz=$(sudo blockdev --getsize64 "$dev")
		(( sz == 0 )) && continue
		info "extract $label ($(( sz / 1024 / 1024 )) MiB)"
		sudo dd if="$dev" of="$WORK/$label.bin" bs=4M status=none
	done < <(lsblk -lnpo PARTLABEL "$LOOP" | awk 'NF')
	sudo losetup -d "$LOOP"

	# "edl w gpt" wants a partition-table blob. Our image carries one at offset
	# 0: protective MBR + primary header + 128 entry records = 34 sectors.
	sudo dd if="$IMAGE" of="$WORK/gpt_both0.bin" bs=512 count=34 status=none

	log "Writing partitions"
	run edl w gpt "$WORK/gpt_both0.bin"
	for p in sbl1 rpm tz hyp aboot boot devinfo; do
		if [[ ! -f $WORK/$p.bin ]]; then
			info "skip $p (empty)"
			continue
		fi
		run edl w "$p" "$WORK/$p.bin"
	done
	[[ -f $WORK/cdt.bin ]] && run edl w cdt "$WORK/cdt.bin"

	if (( WITH_MODEM_DATA )); then
		for p in modemst1 modemst2 fsg fsc; do
			[[ -f $WORK/$p.bin ]] && run edl w "$p" "$WORK/$p.bin"
		done
	else
		info "leaving modemst1/modemst2/fsg/fsc untouched"
	fi

	log "Writing rootfs (a few minutes on eMMC)"
	run edl w rootfs "$WORK/rootfs.bin"

	run edl reset
	log "Done"
}

detect_image
MODE=$(detect_mode)

log "UFI_16__V4 DietPi flasher"
info "image : $IMAGE"
info "mode  : $MODE"
(( DRY_RUN )) && info "dry run: nothing will be written"

case $MODE in
	none)
		warn "no device detected (no fastboot, no adb, no 05c6:9008)"
		info "1. EDL: hold the button on GPIO37, then plug in USB"
		info "2. or, from a booted system: adb reboot bootloader"
		die "nothing to flash"
		;;
	fastboot)
		need_tool sudo
		do_backup fastboot
		flash_fastboot
		;;
	edl)
		need_tool sudo
		do_backup edl
		flash_edl
		;;
esac
