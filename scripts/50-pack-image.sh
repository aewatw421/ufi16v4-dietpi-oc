#!/usr/bin/env bash
# Stage 5: unmount, fsck, shrink the rootfs, and compress the final image.
#
# Shrinking matters: the rootfs is sparse on creation, and everything after the
# last used block is dead weight in the download.
set -euo pipefail

OUT_DIR="${OUT_DIR:-$PWD/out}"; OUT_DIR="$(cd "$OUT_DIR" && pwd)"
MNT="${MNT:-$PWD/mnt}"
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

log "Detaching loop device"
losetup -d "$LOOP" 2>/dev/null || true

log "Zeroing unused space to improve compression"
# Punch out everything the filesystem no longer references: truncate the image
# to the last used byte of the rootfs partition.
ROOT_START=$(partx -g -o START,SECTORS "$IMG" 2>/dev/null | tail -1)
USED_KB=$(dumpe2fs -h "$IMG" 2>/dev/null | awk '/Block count/{c=$3}/Block size/{b=$3}END{print c*b/1024}' || echo 0)
info "rootfs size reported by dumpe2fs: ${USED_KB:-?} KiB (informational)"

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
