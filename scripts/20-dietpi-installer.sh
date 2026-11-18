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
# Canonicalise to an absolute path: stages run from different working
# directories (and under sudo), so a relative default would resolve
# differently in each one and "mountpoint" checks would disagree.
mkdir -p "$MNT"
MNT="$(cd "$MNT" && pwd)"
OUT_DIR="${OUT_DIR:-$PWD/out}"; mkdir -p "$OUT_DIR"; OUT_DIR="$(cd "$OUT_DIR" && pwd)"
DIETPI_BRANCH="${DIETPI_BRANCH:-master}"

log() { printf '\n\033[1;36m==> %s\033[0m\n' "$*"; }
info() { printf '    %s\n' "$*"; }
die() { printf '\033[1;31m[x] %s\033[0m\n' "$*" >&2; exit 1; }

[[ $EUID -eq 0 ]] || die "run as root"
mountpoint -q "$MNT" || die "$MNT is not a mountpoint (run 10-make-disk.sh first)"

log "Preparing chroot plumbing"
# The rootfs partition was just formatted, so it only has lost+found.
mkdir -p "$MNT/etc" "$MNT/var" "$MNT/tmp" "$MNT/root"
cp /etc/resolv.conf "$MNT/etc/resolv.conf" 2>/dev/null || true
# The mounts need their target directories: on a freshly formatted ext4 they do
# not exist yet, and "mount --bind" fails with ENOENT rather than creating them.
for d in dev dev/pts proc sys; do
	mkdir -p "$MNT/$d"
	mountpoint -q "$MNT/$d" || mount --bind "/$d" "$MNT/$d"
done

# DietPi-Installer refuses to run when it cannot find a partition table under
# the boot filesystem: it resolves /boot to a device, then walks up to the whole
# disk with "lsblk -no PKNAME" and bails out in non-interactive mode if that is
# empty. Inside the chroot /sys is the host's, so the loop device hierarchy is
# visible and /boot resolves through the rootfs mount - no extra passthrough is
# needed. Verify it here so a failure is reported before the long bootstrap
# instead of in the middle of the installer.
ROOT_SRC=$(findmnt -Ufvnro SOURCE -T "$MNT")
PART_TABLE_OK=0
if [[ $ROOT_SRC ]]; then
	PARENT=$(lsblk -npo PKNAME "$ROOT_SRC" 2>/dev/null || true)
	[[ $PARENT ]] && PART_TABLE_OK=1
fi
if (( PART_TABLE_OK )); then
	info "root device: $ROOT_SRC (parent ${PARENT:-?}), partition table visible"
else
	info "root device: ${ROOT_SRC:-unknown}, no parent disk visible"
	info "DietPi-Installer will treat this as a tableless disk; HW_MODEL=22"
	info "handles that, but if it aborts, run this stage on the real stick"
fi

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
	if ! mmdebstrap --architectures=arm64 --variant=minbase \
		--include="$PKGS" "$DISTRO" "$MNT"; then
		die "mmdebstrap failed; the partial rootfs is left in place for inspection"
	fi
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
	' > "$OUT_DIR/dietpi-installer.log" 2>&1 || INSTALLER_RC=$?

# Report the installer's own exit status: piping into tee would mask it.
INSTALLER_RC=${INSTALLER_RC:-0}
tail -40 "$OUT_DIR/dietpi-installer.log" 2>/dev/null | sed 's/^/    /' || true
if (( INSTALLER_RC != 0 )); then
	die "DietPi-Installer failed (exit $INSTALLER_RC); see $OUT_DIR/dietpi-installer.log"
fi

log "Stage 2 done"
info "log: $OUT_DIR/dietpi-installer.log"
