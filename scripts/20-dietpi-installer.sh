#!/usr/bin/env bash
# Stage 2: bootstrap Debian into the mounted rootfs and convert it to DietPi.
#
# This is the same two-step process upstream uses (mmdebstrap, then run
# DietPi-Installer inside the new root), with one difference: DietPi has no
# hardware ID for a generic MSM8916 stick, so we select "Generic device" (22),
# which is the documented path for boards DietPi does not ship an image for.
# Kernel, bootloader and device tree stay ours; stage 3 installs them.
#
# Environment:
#   DISTRO        trixie | bookworm   (default trixie)
#   MNT           mounted rootfs      (default $PWD/mnt)
#   OUT_DIR       (default $PWD/out)
#   DIETPI_BRANCH (default master)
set -euo pipefail

DISTRO="${DISTRO:-trixie}"
MNT="${MNT:-$PWD/mnt}"
OUT_DIR="${OUT_DIR:-$PWD/out}"; mkdir -p "$OUT_DIR"; OUT_DIR="$(cd "$OUT_DIR" && pwd)"
DIETPI_BRANCH="${DIETPI_BRANCH:-master}"

log() { printf '\n\033[1;36m==> %s\033[0m\n' "$*"; }
info() { printf '    %s\n' "$*"; }
die() { printf '\033[1;31m[x] %s\033[0m\n' "$*" >&2; exit 1; }

[[ $EUID -eq 0 ]] || die "run as root"
mountpoint -q "$MNT" || die "$MNT is not a mountpoint (run 10-make-disk.sh first)"

log "Preparing chroot plumbing"
cp /etc/resolv.conf "$MNT/etc/resolv.conf" 2>/dev/null || true
for d in dev dev/pts proc sys; do mountpoint -q "$MNT/$d" || mount --bind "/$d" "$MNT/$d"; done

cleanup() {
	for d in dev/pts dev proc sys; do umount -lf "$MNT/$d" 2>/dev/null || true; done
}
trap cleanup EXIT

if [[ ! -x $MNT/usr/bin/apt-get ]]; then
	log "Bootstrapping Debian $DISTRO into $MNT"
	# Package set: what DietPi-Installer itself needs plus a usable base. It
	# prunes what it does not want afterwards, so keeping this close to
	# dietpi-build's own list avoids surprises.
	PKGS="systemd,systemd-sysv,udev,dbus,apt,dpkg,debconf,locales,tzdata,\
ca-certificates,curl,wget,gnupg,openssh-server,sudo,passwd,login,\
procps,psmisc,mawk,grep,sed,gawk,coreutils,util-linux,mount,e2fsprogs,\
kmod,iptables,iproute2,ifupdown,isc-dhcp-client,whiptail,dialog,\
console-setup,usbutils,pciutils,ethtool,iw,rfkill,wireless-tools,\
wpasupplicant,net-tools,htop,nano,less,file,fdisk,parted,rsync,git,\
python3,libc-bin,libc6,libssl3,zlib1g"
	mmdebstrap --architectures=arm64 --variant=minbase \
		--include="$PKGS" "$DISTRO" "$MNT"
else
	log "Base system already present, skipping mmdebstrap"
fi

log "Running DietPi-Installer (Generic device, HW_MODEL=22)"
# IMAGE_CREATOR=0 / PREIMAGE_INFO=0 keep it fully non-interactive; the
# installer reads them from the environment and skips the prompts.
chroot "$MNT" /usr/bin/env -i \
	PATH=/usr/local/sbin:/usr/local/bin:/usr/sbin:/usr/bin:/sbin:/bin \
	HOME=/root TERM=dumb LC_ALL=C.UTF-8 LANG=C.UTF-8 \
	DEBIAN_FRONTEND=noninteractive \
	GITOWNER=MichaIng GITBRANCH="$DIETPI_BRANCH" \
	HW_MODEL=22 IMAGE_CREATOR=0 PREIMAGE_INFO=0 \
	WIFI_REQUIRED=1 DISTRO_TARGET=auto TMPDIR=/tmp \
	/bin/bash -euc '
		curl -sSf "https://raw.githubusercontent.com/MichaIng/DietPi/${GITBRANCH}/.build/images/dietpi-installer" -o /tmp/dietpi-installer
		bash /tmp/dietpi-installer
	' 2>&1 | tee "$OUT_DIR/dietpi-installer.log"

log "Stage 2 done"
info "log: $OUT_DIR/dietpi-installer.log"
