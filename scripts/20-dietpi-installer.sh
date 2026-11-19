#!/usr/bin/env bash
# Stage 2: bootstrap Debian into the mounted rootfs and convert it to DietPi.
#
# Two steps, same as upstream:
#   1. mmdebstrap a minimal Debian into the rootfs partition
#   2. run DietPi-Installer for the "Generic device" model (HW_MODEL=22)
#
# DietPi has no hardware ID for a generic MSM8916 stick, and 22 is its supported
# path for boards it does not ship an image for. Kernel, bootloader and device
# tree stay ours; stage 3 installs them.
#
# DietPi-Installer drives systemctl and expects a running init, so it runs
# inside systemd-nspawn rather than a plain chroot - in a chroot the first
# "systemctl --now disable apt-daily.service" aborts the run.
#
# Environment:
#   DISTRO        trixie | bookworm   (default trixie)
#   MNT           mounted rootfs      (default $PWD/mnt)
#   OUT_DIR       (default $PWD/out)
#   DIETPI_BRANCH (default master)
set -euo pipefail

HERE="$(cd "$(dirname "${BASH_SOURCE[0]}")/.." && pwd)"
DISTRO="${DISTRO:-trixie}"
OUT_DIR="${OUT_DIR:-$PWD/out}"
mkdir -p "$OUT_DIR"
OUT_DIR="$(cd "$OUT_DIR" && pwd)"
MNT="${MNT:-$PWD/mnt}"
mkdir -p "$MNT"
MNT="$(cd "$MNT" && pwd)"
WORK="$OUT_DIR/work"
DIETPI_BRANCH="${DIETPI_BRANCH:-master}"

. "$HERE/scripts/lib-chroot.sh"

log()  { printf '\n\033[1;36m==> %s\033[0m\n' "$*"; }
info() { printf '    %s\n' "$*"; }
die()  { printf '\033[1;31m[x] %s\033[0m\n' "$*" >&2; exit 1; }

[[ $EUID -eq 0 ]] || die "run as root"
mountpoint -q "$MNT" || die "$MNT is not a mountpoint (run 10-make-disk.sh first)"

##############################################################################
# Chroot plumbing (only needed for the bootstrap half)
##############################################################################
log "Preparing chroot plumbing"
# The rootfs partition was just formatted, so it only holds lost+found.
mkdir -p "$MNT/etc" "$MNT/var" "$MNT/tmp" "$MNT/root"
cp /etc/resolv.conf "$MNT/etc/resolv.conf" 2>/dev/null || true

# bind mounts need their target directories to exist first
for d in dev dev/pts proc sys; do
	mkdir -p "$MNT/$d"
	mountpoint -q "$MNT/$d" || mount --bind "/$d" "$MNT/$d"
done

release_chroot_mounts() {
	local d
	for d in dev/pts dev proc sys; do
		umount -lf "$MNT/$d" 2>/dev/null || true
	done
}
trap release_chroot_mounts EXIT

# DietPi-Installer refuses to run when it cannot resolve a partition table under
# /boot: it maps /boot to a device, walks up to the whole disk with
# "lsblk -no PKNAME", and aborts in non-interactive mode when that is empty.
# Inside nspawn /sys is the host's, so the loop hierarchy is visible.
ROOT_SRC=$(findmnt -Ufvnro SOURCE -T "$MNT" || true)
PARENT_DISK=""
if [[ $ROOT_SRC ]]; then
	PARENT_DISK=$(lsblk -npo PKNAME "$ROOT_SRC" 2>/dev/null || true)
fi
if [[ $PARENT_DISK ]]; then
	info "root device: $ROOT_SRC (parent $PARENT_DISK), partition table visible"
else
	info "root device: ${ROOT_SRC:-unknown}, no parent disk visible"
	info "DietPi-Installer treats this as a tableless disk; HW_MODEL=22 allows it"
fi

LOOP_DEV=""
[[ -f $WORK/loop.dev ]] && LOOP_DEV=$(cat "$WORK/loop.dev")

##############################################################################
# Debian bootstrap
##############################################################################
# A runner image can carry a Debian keyring that predates the current signing
# keys, which surfaces as "NO_PUBKEY" during the bootstrap's apt-get update.
# mmdebstrap is packaged in Debian but not in every Ubuntu image. The workflow
# installs it up front; this is the fallback for running the stage by hand.
if ! command -v mmdebstrap >/dev/null; then
	log "Installing mmdebstrap"
	if ! apt-get install -y --no-install-recommends mmdebstrap; then
		curl -sSfL "https://salsa.debian.org/debian/mmdebstrap/-/raw/master/mmdebstrap" \
			-o /usr/local/bin/mmdebstrap
		chmod +x /usr/local/bin/mmdebstrap
	fi
fi
command -v mmdebstrap >/dev/null \
	|| die "mmdebstrap unavailable; install it with apt or from upstream"
info "mmdebstrap: $(command -v mmdebstrap)"
log "Refreshing the Debian archive keyring"
apt-get update -qq || true
apt-get install -y --no-install-recommends debian-archive-keyring || true
KEYRING=/usr/share/keyrings/debian-archive-keyring.gpg
[[ -f $KEYRING ]] || die "debian-archive-keyring.gpg missing after install"
info "keyring: $KEYRING ($(stat -c%s "$KEYRING") bytes)"

if [[ ! -x $MNT/usr/bin/apt-get ]]; then
	log "Bootstrapping Debian $DISTRO"
	# Package set: what DietPi-Installer itself needs plus a usable base. It
	# prunes what it does not want afterwards, so staying close to upstream's
	# own list avoids surprises.
	PKGS='systemd,systemd-sysv,udev,dbus,apt,dpkg,debconf,locales,tzdata,'
	PKGS+='ca-certificates,curl,wget,gnupg,openssh-server,sudo,passwd,login,'
	PKGS+='procps,psmisc,mawk,grep,sed,gawk,coreutils,util-linux,mount,e2fsprogs,'
	PKGS+='kmod,iptables,iproute2,ifupdown,isc-dhcp-client,whiptail,dialog,'
	PKGS+='console-setup,usbutils,pciutils,ethtool,iw,rfkill,wireless-tools,'
	PKGS+='wpasupplicant,net-tools,htop,nano,less,file,fdisk,parted,rsync,git,'
	PKGS+='python3,libc-bin,libc6,libssl3,zlib1g'

	# mmdebstrap insists on an empty target directory, and $MNT already holds
	# lost+found plus the bind-mount points. Bootstrap into a scratch tree and
	# copy the result in.
	STAGE=$(mktemp -d "$OUT_DIR/bootstrap.XXXXXX")
	info "bootstrap target: $STAGE"
	if ! mmdebstrap --architectures=arm64 --variant=minbase \
		--keyring="$KEYRING" --include="$PKGS" "$DISTRO" "$STAGE"; then
		die "mmdebstrap failed; partial tree kept at $STAGE"
	fi

	log "Copying the bootstrap into the rootfs partition"
	# -aHAX preserves modes, ownership, xattrs and device nodes.
	rsync -aHAX --numeric-ids "$STAGE"/ "$MNT"/
	rm -rf "$STAGE"
else
	log "Base system already present, skipping mmdebstrap"
fi

##############################################################################
# DietPi-Installer (chroot + systemctl shim)
##############################################################################
log "Running DietPi-Installer"
# DietPi-Installer calls systemctl for enable/disable/mask/daemon-reload and
# expects a running init. Booting the rootfs in systemd-nspawn seemed like the
# obvious answer, but on this minimal target the container reaches
# graphical.target and never dispatches our unit (three attempts, three 50+
# minute stalls).
#
# Instead, run the installer in a chroot with a systemctl shim on PATH: it
# forwards the operations that must persist into the image via "systemctl
# --root", and turns the ones that only make sense on a live system (--now,
# daemon-reload, is-active, start/stop) into no-ops that report success. That is
# exactly what the installer needs while building a disk image, and it makes the
# run deterministic and observable.

curl -sSfL "https://raw.githubusercontent.com/MichaIng/DietPi/${DIETPI_BRANCH}/.build/images/dietpi-installer" \
	-o "$MNT/root/dietpi-installer"
chmod 755 "$MNT/root/dietpi-installer"

mkdir -p "$MNT/usr/local/sbin"
cat > "$MNT/usr/local/sbin/systemctl" <<'SHIM'
#!/bin/bash
# systemctl shim for image building: act on the target tree, never on a live init.
args=()
action=""
for a in "$@"; do
	case $a in
		--root=*|--no-reload|--no-block|-q|--quiet) ;;
		enable|disable|mask|unmask|preset|daemon-reload|is-enabled|is-active|is-failed) action=$a ;;
		start|stop|restart|disable-now|--now) ;;
		*) args+=("$a") ;;
	esac
done

case $action in
	enable|disable|mask|unmask|preset|is-enabled)
		exec /usr/bin/systemctl --root=/ "$action" "${args[@]}" 2>/dev/null || exit 0
		;;
	*)
		# start/stop/restart/daemon-reload/is-active: nothing to do while offline
		exit 0
		;;
esac
SHIM
chmod 755 "$MNT/usr/local/sbin/systemctl"

log "Running DietPi-Installer in chroot (HW_MODEL=22)"
chroot_mounts_up "$MNT"
set +e
chroot "$MNT" /usr/bin/env -i \
	PATH=/usr/local/sbin:/usr/local/bin:/usr/sbin:/usr/bin:/sbin:/bin \
	HOME=/root TERM=dumb LC_ALL=C.UTF-8 LANG=C.UTF-8 \
	DEBIAN_FRONTEND=noninteractive \
	GITOWNER=MichaIng GITBRANCH="$DIETPI_BRANCH" \
	HW_MODEL=22 IMAGE_CREATOR=0 PREIMAGE_INFO=0 \
	WIFI_REQUIRED=1 DISTRO_TARGET=auto TMPDIR=/tmp \
	/bin/bash /root/dietpi-installer \
	>"$OUT_DIR/dietpi-installer.log" 2>&1
INSTALLER_RC=$?
set -e
chroot_mounts_down "$MNT"

tail -30 "$OUT_DIR/dietpi-installer.log" | sed 's/^/    /'
if (( INSTALLER_RC != 0 )); then
	printf '\033[1;31m[x] DietPi-Installer exited %s\033[0m\n' "$INSTALLER_RC" >&2
	exit 1
fi

# Remove the shim: the finished image must talk to its own systemd.
rm -f "$MNT/usr/local/sbin/systemctl"

log "Stage 2 done"
info "log: $OUT_DIR/dietpi-installer.log"
