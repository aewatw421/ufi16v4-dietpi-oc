#!/usr/bin/env bash
# One-shot flasher for the UFI_16__V4 / UFI-001B / UFI-001C 4G stick.
#
# Handles both entry paths and picks the right one automatically:
#
#   fastboot  stock aboot still alive -> flash only what we own (boot + rootfs)
#   edl       device in 9008 mode (or bricked) -> rewrite GPT + full boot chain
#
# Nothing here touches modemst1/modemst2/fsg unless you explicitly ask for it
# with --with-modem-data, because those partitions carry the per-device RF
# calibration and losing them kills the modem.
#
# Usage:
#   ./flash.sh                      # auto-detect, flash image
#   ./flash.sh --image FILE.img     # explicit image
#   ./flash.sh --edl                # force EDL path
#   ./flash.sh --fastboot           # force fastboot path
#   ./flash.sh --backup DIR         # back up modem/calibration partitions first
#   ./flash.sh --dry-run            # show what would be done
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

usage() { sed -n '2,26p' "${BASH_SOURCE[0]}" | sed 's/^# \{0,1\}//'; exit 0; }

while (( $# )); do
	case $1 in
		--image)   shift; IMAGE=$1;;
		--edl)     MODE=edl;;
		--fastboot) MODE=fastboot;;
		--backup)  shift; BACKUP_DIR=$1;;
		--dry-run) DRY_RUN=1;;
		--with-modem-data) WITH_MODEM_DATA=1;;
		-y|--yes)  ASSUME_YES=1;;
		-h|--help) usage;;
		*) die "unknown option: $1 (try --help)";;
	esac
	shift
done

# ---------------------------------------------------------------- prerequisites
need_tool() { command -v "$1" >/dev/null || die "missing tool: $1${2:+ ($2)}"; }

detect_image() {
	[[ $IMAGE ]] && return
	for cand in "$HERE"/out/ufi16v4-dietpi-oc.img \
	            "$HERE"/ufi16v4-dietpi-oc.img \
	            ./ufi16v4-dietpi-oc.img; do
		[[ -f $cand ]] && { IMAGE=$cand; return; }
	done
	die "no image found; pass --image FILE.img"
}

part_dev() { # <loop-or-disk> <label> -> partition node
	local disk=$1 label=$2
	blkid -t PARTLABEL="$label" -o device "$disk" 2>/dev/null | head -1 && return 0
	local nr
	nr=$(partx -g -o NR,LABEL "$disk" 2>/dev/null | awk -v l="$label" '$2==l{print $1; exit}')
	[[ $nr ]] && echo "${disk}p${nr}"
}

# ------------------------------------------------------------------ mode detect
detect_mode() {
	[[ $MODE != auto ]] && { echo "$MODE"; return; }
	if command -v fastboot >/dev/null && fastboot devices 2>/dev/null | grep -q .; then
		echo fastboot; return
	fi
	if command -v adb >/dev/null && adb devices 2>/dev/null | awk 'NR>1 && $2=="device"{f=1} END{exit !f}'; then
		echo fastboot; return           # reachable over adb -> reboot to bootloader
	fi
	# Qualcomm EDL: 05c6:9008
	if command -v lsusb >/dev/null && lsusb | grep -qi '05c6:9008'; then
		echo edl; return
	fi
	echo none
}

require_root() {
	(( EUID == 0 )) && return
	warn "not running as root; using sudo for privileged steps"
	command -v sudo >/dev/null || die "need root or sudo"
}

# ------------------------------------------------------------------- backup path
do_backup() {
	[[ $BACKUP_DIR ]] || return 0
	log "Backing up per-device partitions to $BACKUP_DIR"
	mkdir -p "$BACKUP_DIR"
	local m=$1
	case $m in
		fastboot)
			need_tool fastboot
			for p in fsc fsg modemst1 modemst2; do
				info "fastboot oem dump $p"
				run fastboot oem dump "$p" || warn "dump $p failed"
				run fastboot get_staged "$BACKUP_DIR/$p.bin" || warn "get_staged $p failed"
			done
			;;
		edl)
			need_tool edl
			for p in modemst1 modemst2 fsg fsc; do
				info "edl r $p"
				run edl r "$p" "$BACKUP_DIR/$p.bin" || warn "read $p failed"
			done
			;;
	esac
	info "saved to $BACKUP_DIR"
}

# --------------------------------------------------------------- fastboot path
flash_fastboot() {
	need_tool fastboot
	log "Flashing over fastboot"

	if command -v adb >/dev/null && adb devices 2>/dev/null | awk 'NR>1 && $2=="device"{f=1} END{exit !f}'; then
		info "device visible over adb, rebooting to bootloader"
		run adb reboot bootloader
		sleep 8
	fi

	fastboot devices | grep -q . || die "no fastboot device; put the stick in fastboot (EDL button = GPIO37) and retry"

	if (( ! ASSUME_YES )); then
		echo
		warn "This overwrites the rootfs partition and lk2nd. Modem calibration is kept."
		read -r -p "    continue? [y/N] " a
		[[ ${a,,} == y* ]] || die "aborted"
	fi

	# Stage the parts of the image we need, without touching GPT on this path:
	# the stock GPT is already the layout we want.
	WORK=$(mktemp -d)
	trap 'rm -rf "$WORK"' RETURN

	log "Extracting boot and rootfs from $IMAGE"
	LOOP=$(sudo losetup -f --show -P "$IMAGE")
	info "loop device $LOOP"

	BOOT=$(part_dev "$LOOP" boot)
	ROOT=$(part_dev "$LOOP" rootfs)
	[[ -b $BOOT ]] || { sudo losetup -d "$LOOP"; die "no boot partition in image"; }
	[[ -b $ROOT ]] || { sudo losetup -d "$LOOP"; die "no rootfs partition in image"; }

	sudo dd if="$BOOT" of="$WORK/boot.img" bs=4M status=none
	sudo dd if="$ROOT" of="$WORK/rootfs.img" bs=4M status=none
	sudo losetup -d "$LOOP"

	log "Writing boot (lk2nd) and rootfs"
	run fastboot flash boot   "$WORK/boot.img"
	run fastboot flash rootfs "$WORK/rootfs.img"
	run fastboot erase userdata || true
	run fastboot reboot

	log "Done"
	info "The stick boots DietPi; SSH appears on 192.168.68.1 (eth gadget) or the"
	info "saved WiFi/modem profile. Default login: root / dietpi"
}

# -------------------------------------------------------------------- edl path
flash_edl() {
	need_tool edl
	log "Flashing over EDL (9008)"

	if ! lsusb 2>/dev/null | grep -qi '05c6:9008'; then
		warn "device is not in EDL mode"
		info "hold the EDL/reset button (GPIO37) while plugging in USB, then retry"
		die "no EDL device"
	fi

	if (( ! ASSUME_YES )); then
		echo
		warn "Full flash: GPT, SBL1, RPM, TZ, HYP, aboot, lk2nd, rootfs."
		warn "Per-device modem calibration is preserved unless --with-modem-data."
		read -r -p "    continue? [y/N] " a
		[[ ${a,,} == y* ]] || die "aborted"
	fi

	WORK=$(mktemp -d)
	trap 'rm -rf "$WORK"' RETURN

	log "Splitting $IMAGE into named partition dumps"
	LOOP=$(sudo losetup -f --show -P "$IMAGE")
	info "loop device $LOOP"
	sudo partx -s "$LOOP" | sed 's/^/    /'

	for label in $(sudo partx -g -o LABEL "$LOOP" | grep -v '^$'); do
		dev=$(part_dev "$LOOP" "$label")
		[[ -b $dev ]] || continue
		sz=$(sudo blockdev --getsize64 "$dev")
		(( sz == 0 )) && continue
		info "extract $label ($(( sz / 1024 / 1024 )) MiB)"
		sudo dd if="$dev" of="$WORK/$label.bin" bs=4M status=none
	done
	sudo losetup -d "$LOOP"

	# EDL writes whole partitions by name; tiny ones are fine as raw files.
	# The GPT needs the raw sector blob, which lives at the start of the image.
	sudo dd if="$IMAGE" of="$WORK/gpt_both0.bin" bs=512 count=67 status=none

	log "Writing partitions"
	run edl w gpt              "$WORK/gpt_both0.bin"
	for p in sbl1 rpm tz hyp aboot boot devinfo; do
		[[ -f $WORK/$p.bin ]] || { info "skip $p (empty)"; continue; }
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

	log "Writing rootfs (this takes a few minutes on eMMC)"
	run edl w rootfs "$WORK/rootfs.bin"

	run edl reset
	log "Done"
}

# ------------------------------------------------------------------------ main
detect_image
MODE=$(detect_mode)

log "UFI_16__V4 DietPi flasher"
info "image : $IMAGE"
info "mode  : $MODE"
(( DRY_RUN )) && info "dry run: nothing will be written"

case $MODE in
	none)
		warn "no device detected (no fastboot, no adb, no 05c6:9008)"
		info "1. EDL button on UFI-001C is GPIO37: hold it, then plug USB"
		info "2. or: adb reboot bootloader"
		die "nothing to flash"
		;;
	fastboot)
		require_root
		do_backup fastboot
		flash_fastboot
		;;
	edl)
		require_root
		do_backup edl
		flash_edl
		;;
esac
