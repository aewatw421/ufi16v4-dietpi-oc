#!/usr/bin/env bash
# Stage 5: unmount, fsck, shrink the rootfs, and compress the final image.
#
# Shrinking matters: the rootfs is sparse on creation, and everything after the
# last used block is dead weight in the download.
set -euo pipefail

HERE="$(cd "$(dirname "${BASH_SOURCE[0]}")/.." && pwd)"
OUT_DIR="${OUT_DIR:-$PWD/out}"; OUT_DIR="$(cd "$OUT_DIR" && pwd)"
MNT="${MNT:-$PWD/mnt}"
# Canonicalise to an absolute path: stages run from different working
# directories (and under sudo), so a relative default would resolve
# differently in each one and "mountpoint" checks would disagree.
mkdir -p "$MNT"
MNT="$(cd "$MNT" && pwd)"
WORK="$OUT_DIR/work"
IMG="$OUT_DIR/ufi16v4-dietpi-oc.img"

log() { printf '\n\033[1;36m==> %s\033[0m\n' "$*"; }
info() { printf '    %s\n' "$*"; }
die() { printf '\033[1;31m[x] %s\033[0m\n' "$*" >&2; exit 1; }
[[ $EUID -eq 0 ]] || die "run as root"

LOOP=$(cat "$WORK/loop.dev" 2>/dev/null || true)
ROOT_DEV=$(cat "$WORK/root.dev" 2>/dev/null || true)
[[ -b $ROOT_DEV ]] || die "no root device recorded; run stage 1 first"

log "Unmounting"
for d in dev/pts dev proc sys; do umount -lf "$MNT/$d" 2>/dev/null || true; done
umount -lf "$MNT" 2>/dev/null || true
sync

log "Filesystem check"
e2fsck -fy "$ROOT_DEV" 2>&1 | tail -3 | sed 's/^/    /'

log "Shrinking the rootfs to its contents"
# e2fsck above may have altered the fs; resize2fs needs it clean.
resize2fs -M "$ROOT_DEV" 2>&1 | tail -2 | sed 's/^/    /'
# The partition is larger than the fs now; the trailing space is just zeros in
# the sparse image, so there is nothing to reclaim beyond the file itself.

log "Recording rootfs extent"
# Read this before detaching the loop device, while the partition node exists.
# "lsblk -P" gives NAME="..." START="..." pairs, so column order cannot bite.
ROOT_START_SECTORS=$(lsblk -lnbo START "$ROOT_DEV" 2>/dev/null | tr -d " ")
ROOT_SIZE_SECTORS=$(lsblk -lnbo SECTORS "$ROOT_DEV" 2>/dev/null | tr -d " ")
info "rootfs starts at sector ${ROOT_START_SECTORS:-?}, ${ROOT_SIZE_SECTORS:-?} sectors long"

log "Detaching loop device"
losetup -d "$LOOP" 2>/dev/null || true

log "Trimming the image to the last partition"
# resize2fs -M shrank the filesystem, but the rootfs *partition* still spans to
# the end of the disk, so the file stays IMG_SIZE_MB and the tail is all zeros.
# Cut the file down to the end of the rootfs partition; a partition larger than
# its filesystem is fine, the kernel does not care. This shrinks what gets
# compressed (and eventually downloaded) without touching any partition data.
if [[ $ROOT_START_SECTORS && $ROOT_SIZE_SECTORS ]]; then
	NEW_BYTES=$(( (ROOT_START_SECTORS + ROOT_SIZE_SECTORS) * 512 ))
	info "shrinking image to $(( NEW_BYTES / 1048576 )) MiB (rootfs ends there)"
	truncate -s "$NEW_BYTES" "$IMG"
	# Truncating moved the end of the disk, so the backup GPT that lived at the
	# old last sector is gone. Regenerate both GPT copies for the new size; the
	# partition starts are unchanged, and rootfs still ends at the last usable
	# sector.
	node "$HERE/scripts/make-gpt.js" --output "$IMG" >/dev/null
	info "regenerated GPT for the trimmed size"
else
	info "could not determine the rootfs extent; keeping the full image size"
fi

log "Checking the result"
lsblk -lpo NAME,SIZE,PARTLABEL "$IMG" 2>/dev/null | sed 's/^/    /' || true

log "Compressing"
BASE="${IMG%.img}"
if command -v xz >/dev/null; then
	xz -T0 -9 -f -k --no-warn "$IMG" && info "created ${BASE}.img.xz"
else
	gzip -9 -kf "$IMG" && info "created ${BASE}.img.gz"
fi

log "Checksums"
( cd "$OUT_DIR" && sha256sum ufi16v4-dietpi-oc.img* > SHA256SUMS )
cat "$OUT_DIR/SHA256SUMS" | sed 's/^/    /'

log "Stage 5 done"
ls -lh "$OUT_DIR"/ufi16v4-dietpi-oc.img* | sed 's/^/    /'
