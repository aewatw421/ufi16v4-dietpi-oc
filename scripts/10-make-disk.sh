#!/usr/bin/env bash
# Create the disk image skeleton: OpenStick GPT + boot firmware + lk2nd, and an
# empty ext4 rootfs partition mounted at $MNT for the next stage.
#
# The GPT is taken verbatim from OpenStick's base.zip so the partition LBAs match
# what the stock aboot expects:
#
#   cdt  sbl1  rpm  tz  hyp  sec  modemst1  modemst2  fsc  fsg  aboot
#   boot     64 MiB  @ 526336   lk2nd + fallback kernel/dtb/extlinux
#   devinfo   1 MiB  @ 657408
#   rootfs   rest    @ 659456
#
# Environment:
#   OUT_DIR     (default $PWD/out)
#   IMG_SIZE_MB (default 4096)
#   MNT         (default $PWD/mnt)
set -euo pipefail

HERE="$(cd "$(dirname "${BASH_SOURCE[0]}")/.." && pwd)"
OUT_DIR="${OUT_DIR:-$PWD/out}"; mkdir -p "$OUT_DIR"; OUT_DIR="$(cd "$OUT_DIR" && pwd)"
IMG_SIZE_MB="${IMG_SIZE_MB:-4096}"
MNT="${MNT:-$PWD/mnt}"
WORK="$OUT_DIR/work"
IMG="$OUT_DIR/ufi16v4-dietpi-oc.img"

log() { printf '\n\033[1;36m==> %s\033[0m\n' "$*"; }
info() { printf '    %s\n' "$*"; }
die() { printf '\033[1;31m[x] %s\033[0m\n' "$*" >&2; exit 1; }

[[ $EUID -eq 0 ]] || die "run as root"

log "Fetching OpenStick boot blobs"
mkdir -p "$WORK"
BASE_ZIP="$WORK/base.zip"
if [[ ! -f $BASE_ZIP ]]; then
	curl -fL --retry 5 --retry-delay 3 -o "$BASE_ZIP" \
		"${BASE_URL:-https://github.com/OpenStick/OpenStick/releases/download/v1}/base.zip"
fi
rm -rf "$WORK/base"; mkdir -p "$WORK/base"
if command -v bsdtar >/dev/null; then
	bsdtar -xf "$BASE_ZIP" -C "$WORK/base"
else
	unzip -oq "$BASE_ZIP" -d "$WORK/base"
fi
B="$WORK/base/base"; [[ -d $B ]] || B="$WORK/base"
for f in gpt_both0.bin sbl1.mbn rpm.mbn tz.mbn hyp.mbn aboot.bin sbc_1.0_8016.bin; do
	[[ -f $B/$f ]] || die "blob missing: $f"
done

log "Fetching lk2nd"
LK2ND_IMG="${LK2ND_IMG:-$OUT_DIR/lk2nd.img}"
if [[ ! -f $LK2ND_IMG ]]; then
	URL=$(curl -sSf https://api.github.com/repos/msm8916-mainline/lk2nd/releases/latest \
		| grep -oE '"browser_download_url":[[:space:]]*"[^"]*lk2nd-msm8916\.img"' \
		| head -1 | cut -d'"' -f4)
	[[ $URL ]] || die "cannot find lk2nd-msm8916.img in the latest lk2nd release"
	info "$URL"
	curl -fL --retry 5 -o "$LK2ND_IMG" "$URL"
fi

log "Creating ${IMG_SIZE_MB} MiB image"
rm -f "$IMG"
truncate -s "${IMG_SIZE_MB}M" "$IMG"

LOOP=$(losetup -f --show -P "$IMG")
info "loop: $LOOP"
cleanup_loop() { umount -lf "$MNT" 2>/dev/null || true; losetup -d "$LOOP" 2>/dev/null || true; }
trap cleanup_loop EXIT

dd if="$B/gpt_both0.bin" of="$LOOP" bs=512 conv=notrunc status=none
partprobe "$LOOP" 2>/dev/null || true
udevadm settle 2>/dev/null || sleep 1

partnr() { partx -g -o NR,LABEL "$LOOP" | awk -v l="$1" '$2==l{print $1; exit}'; }

log "Writing boot firmware"
write_part() { # <label> <file>
	local n; n=$(partnr "$1")
	[[ $n ]] || { info "skip $1"; return; }
	dd if="$2" of="${LOOP}p$n" bs=1M conv=notrunc status=none
	info "$1 <- $(basename "$2")"
}
write_part cdt   "$B/sbc_1.0_8016.bin"
write_part sbl1  "$B/sbl1.mbn"
write_part rpm   "$B/rpm.mbn"
write_part tz    "$B/tz.mbn"
write_part hyp   "$B/hyp.mbn"
write_part aboot "$B/aboot.bin"

log "Writing lk2nd to the boot partition"
BOOT_N=$(partnr boot); [[ $BOOT_N ]] || die "boot partition missing"
dd if="$LK2ND_IMG" of="${LOOP}p$BOOT_N" bs=1M conv=notrunc status=none
info "lk2nd <- $(basename "$LK2ND_IMG") ($(stat -c%s "$LK2ND_IMG") bytes)"

log "Formatting rootfs partition"
ROOT_N=$(partnr rootfs); [[ $ROOT_N ]] || die "rootfs partition missing"
ROOT_DEV="${LOOP}p$ROOT_N"
mkfs.ext4 -q -F -L rootfs -O ^metadata_csum_seed -E lazy_itable_init=0,lazy_journal_init=0 "$ROOT_DEV"
info "rootfs on $ROOT_DEV ($(blockdev --getsize64 "$ROOT_DEV" | awk '{printf "%.1f GiB", $1/1073741824}'))"

log "Mounting at $MNT"
mkdir -p "$MNT"
mount "$ROOT_DEV" "$MNT"

echo "$LOOP" > "$WORK/loop.dev"
echo "$ROOT_DEV" > "$WORK/root.dev"
log "Stage 1 done"
