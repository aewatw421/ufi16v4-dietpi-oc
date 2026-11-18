#!/usr/bin/env bash
# Orchestrate the whole build: kernel -> disk -> DietPi -> kernel install ->
# board glue -> pack.
#
# Each stage is its own script so it can be re-run in isolation while debugging
# (or cancelled between stages on a CI runner with a short timeout).
set -euo pipefail

HERE="$(cd "$(dirname "${BASH_SOURCE[0]}")" && pwd)"

# Absolute paths, so every stage (and every sudo invocation) resolves them the
# same way regardless of its own working directory.
mkdir -p "${OUT_DIR:-$PWD/out}" "${MNT:-$PWD/mnt}"
export OUT_DIR="$(cd "${OUT_DIR:-$PWD/out}" && pwd)"
export MNT="$(cd "${MNT:-$PWD/mnt}" && pwd)"
export DISTRO="${DISTRO:-trixie}"
export IMG_SIZE_MB="${IMG_SIZE_MB:-4096}"

log() { printf '\n\033[1;35m### %s\033[0m\n' "$*"; }

log "Stage 0/5: kernel + overclock device tree"
"$HERE/build-kernel.sh"

log "Stage 1/5: disk image skeleton"
sudo -E "$HERE/10-make-disk.sh"

log "Stage 2/5: Debian bootstrap + DietPi-Installer"
sudo -E "$HERE/20-dietpi-installer.sh"

log "Stage 3/5: our kernel, modules, DTB, extlinux"
sudo -E "$HERE/30-install-kernel.sh"

log "Stage 4/5: board glue (USB gadget, modem, governor)"
sudo -E "$HERE/40-finalize.sh"

log "Stage 5/5: pack and compress"
sudo -E "$HERE/50-pack-image.sh"

log "All stages complete"
ls -lh "$OUT_DIR"/ufi16v4-dietpi-oc.img* | sed 's/^/    /'
