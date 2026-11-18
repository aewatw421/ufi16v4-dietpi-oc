#!/usr/bin/env bash
# Stage 3: put our kernel, modules, device tree and lk2nd boot config into the
# rootfs that stage 2 just produced.
#
# lk2nd scans every ext2/3/4 partition for /extlinux/extlinux.conf and patches
# the DTB it loads, so the whole boot configuration lives inside the rootfs and
# the (small) boot partition only needs lk2nd itself.
#
# Environment:
#   MNT        mounted rootfs   (default $PWD/mnt)
#   OUT_DIR    kernel artifacts (default $PWD/out)
#   HOOK       also install the overclock A/B boot hook (default 1)
set -euo pipefail

HERE="$(cd "$(dirname "${BASH_SOURCE[0]}")/.." && pwd)"
MNT="${MNT:-$PWD/mnt}"
# Canonicalise to an absolute path: stages run from different working
# directories (and under sudo), so a relative default would resolve
# differently in each one and "mountpoint" checks would disagree.
mkdir -p "$MNT"
MNT="$(cd "$MNT" && pwd)"
OUT_DIR="${OUT_DIR:-$PWD/out}"; OUT_DIR="$(cd "$OUT_DIR" && pwd)"
HOOK="${HOOK:-1}"

log() { printf '\n\033[1;36m==> %s\033[0m\n' "$*"; }
info() { printf '    %s\n' "$*"; }
die() { printf '\033[1;31m[x] %s\033[0m\n' "$*" >&2; exit 1; }

[[ $EUID -eq 0 ]] || die "run as root"
mountpoint -q "$MNT" || die "$MNT is not a mountpoint"

OC_DTB="$OUT_DIR/msm8916-thwc-ufi001c-oc.dtb"
STOCK_DTB="$OUT_DIR/msm8916-thwc-ufi001c.dtb"
[[ -f $OC_DTB ]] || die "missing $OC_DTB"
[[ -f $OUT_DIR/Image.gz || -f $OUT_DIR/Image ]] || die "missing kernel image in $OUT_DIR"
[[ -d $OUT_DIR/modules/lib/modules ]] || die "missing modules tree in $OUT_DIR"

KVER=$(ls -1 "$OUT_DIR/modules/lib/modules" | head -1)
[[ $KVER ]] || die "cannot determine kernel version"
log "Installing kernel $KVER"

log "Kernel image and device trees"
install -d "$MNT/boot/extlinux" "$MNT/boot/dtbs/qcom"
if [[ -f $OUT_DIR/Image.gz ]]; then
	install -m644 "$OUT_DIR/Image.gz" "$MNT/boot/Image.gz"
else
	install -m644 "$OUT_DIR/Image" "$MNT/boot/Image"
fi
install -m644 "$OC_DTB" "$MNT/boot/msm8916-thwc-ufi001c-oc.dtb"
install -m644 "$OC_DTB" "$MNT/boot/dtbs/qcom/msm8916-thwc-ufi001c-oc.dtb"
if [[ -f $STOCK_DTB ]]; then
	install -m644 "$STOCK_DTB" "$MNT/boot/msm8916-thwc-ufi001c.dtb"
	install -m644 "$STOCK_DTB" "$MNT/boot/dtbs/qcom/msm8916-thwc-ufi001c.dtb"
fi

log "Modules"
install -d "$MNT/lib/modules/$KVER"
cp -a "$OUT_DIR/modules/lib/modules/$KVER/." "$MNT/lib/modules/$KVER/"
# Rebuild depmod metadata for the target rootfs with the target's own depmod.
chroot "$MNT" /usr/bin/env -i PATH=/usr/sbin:/usr/bin:/sbin:/bin \
	/bin/sh -c "depmod -a $KVER 2>/dev/null || true"

log "extlinux.conf"
# The first label is the default. /Image.gz and the DTB paths are absolute
# inside the rootfs, which is where lk2nd looks because it mounts it as root.
cat > "$MNT/boot/extlinux/extlinux.conf" <<CONF
DEFAULT oc
PROMPT 0
TIMEOUT 20

LABEL oc
    LINUX /boot/Image.gz
    FDT /boot/msm8916-thwc-ufi001c-oc.dtb
    APPEND root=PARTLABEL=rootfs rootwait rootfstype=ext4 rw console=tty0 loglevel=7 panic=10 no_console_suspend

LABEL stock
    LINUX /boot/Image.gz
    FDT /boot/msm8916-thwc-ufi001c.dtb
    APPEND root=PARTLABEL=rootfs rootwait rootfstype=ext4 rw console=tty0 loglevel=7 panic=10
CONF
mkdir -p "$MNT/extlinux"
cp "$MNT/boot/extlinux/extlinux.conf" "$MNT/extlinux/extlinux.conf"

if [[ $HOOK == 1 ]]; then
	log "Installing the overclock watchdog hook"
	# A 2 GHz A53 in a plastic shell is asking for trouble; this hook restores
	# the stock OPP ceiling automatically if the device fails to stay up.
	install -m755 "$HERE/scripts/oc-watchdog.sh" "$MNT/usr/local/sbin/oc-watchdog.sh"
	install -m644 "$HERE/scripts/oc-watchdog.service" \
		"$MNT/etc/systemd/system/oc-watchdog.service"
	chroot "$MNT" /usr/bin/env -i PATH=/usr/bin:/bin:/usr/sbin:/sbin \
		/bin/sh -c 'systemctl enable oc-watchdog.service >/dev/null 2>&1 || true'
fi

log "Sanity-checking the installed system"
# Catch the common ways stage 2 can end up "successful" but useless: no init,
# no shell, or a DietPi install that was skipped entirely.
for probe in /sbin/init /bin/sh /etc/os-release; do
	if [[ ! -e $MNT$probe ]]; then
		printf '\033[1;31m[x] missing %s in the rootfs\033[0m\n' "$probe" >&2
		exit 1
	fi
	done
if [[ -f $MNT/etc/os-release ]]; then
	info "$(. "$MNT/etc/os-release" 2>/dev/null; echo "${PRETTY_NAME:-unknown}")"
fi
info "kernel modules: $(ls -1 "$MNT/lib/modules/$KVER/kernel" 2>/dev/null | wc -l) top-level groups"
info "extlinux: $(grep -c '^LABEL' "$MNT/boot/extlinux/extlinux.conf" 2>/dev/null || echo 0) labels"

log "Stage 3 done"
