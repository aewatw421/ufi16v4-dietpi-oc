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
# DietPi-Installer inside systemd-nspawn
##############################################################################
log "Running DietPi-Installer inside systemd-nspawn"

# Stage the installer so the container does not depend on network timing.
curl -sSfL "https://raw.githubusercontent.com/MichaIng/DietPi/${DIETPI_BRANCH}/.build/images/dietpi-installer" \
	-o "$MNT/root/dietpi-installer"
chmod 755 "$MNT/root/dietpi-installer"

cat > "$MNT/root/dietpi-build.sh" <<'BUILDSCRIPT'
#!/bin/dash -e
export GITOWNER=MichaIng
export GITBRANCH="__DIETPI_BRANCH__"
export HW_MODEL=22          # "Generic device"
export IMAGE_CREATOR=0      # non-interactive
export PREIMAGE_INFO=0      # non-interactive
export WIFI_REQUIRED=1
export DISTRO_TARGET=auto
export TMPDIR=/tmp
infocmp "$TERM" >/dev/null 2>&1 || export TERM=dumb
bash /root/dietpi-installer
rm -f /etc/systemd/system/multi-user.target.wants/dietpi-build.service \
      /etc/systemd/system/dietpi-build.service /root/dietpi-build.sh
touch /success
poweroff -f || exit 0
BUILDSCRIPT
sed -i "s|__DIETPI_BRANCH__|${DIETPI_BRANCH}|" "$MNT/root/dietpi-build.sh"
chmod 755 "$MNT/root/dietpi-build.sh"

cat > "$MNT/etc/systemd/system/dietpi-build.service" <<'UNIT'
[Unit]
Description=Run DietPi-Installer
# Wants= plus WantedBy= (not After=) is what actually schedules this. An
# "After=multi-user.target" in combination with "WantedBy=multi-user.target"
# orders the unit after the target it is supposed to start with, so systemd
# leaves it pending while getty takes the console -- which is what happened:
# the container sat at a login prompt for 50 minutes and never ran anything.
Wants=network-online.target
After=network-online.target systemd-user-sessions.service

[Service]
# Type=idle defers the start until other jobs are dispatched, which is what
# upstream dietpi-build uses for exactly this setup.
Type=idle
StandardOutput=tty
StandardError=tty
# Serial console access is not needed and a getty would race for the tty.
TTYPath=/dev/tty1
ExecStart=-/root/dietpi-build.sh

[Install]
WantedBy=multi-user.target
UNIT
mkdir -p "$MNT/etc/systemd/system/multi-user.target.wants"
ln -sf ../dietpi-build.service \
	"$MNT/etc/systemd/system/multi-user.target.wants/dietpi-build.service"

# Keep a getty from grabbing the console before the installer runs.
for f in getty@tty1.service serial-getty@ttyS0.service \
         console-getty.service; do
	ln -sf /dev/null "$MNT/etc/systemd/system/$f"
done

# nspawn mounts /proc, /sys and /dev itself, so drop the chroot bind mounts.
release_chroot_mounts

# The container must see the disk it installs to: /dev/disk for UUID resolution
# and the loop device for the partition-table check.
NSPAWN_BINDS=()
[[ -d /dev/disk ]] && NSPAWN_BINDS+=(--bind=/dev/disk)
[[ $LOOP_DEV && -b $LOOP_DEV ]] && NSPAWN_BINDS+=(--bind="$LOOP_DEV")
info "nspawn binds: ${NSPAWN_BINDS[*]:-none}"

set +e
# "--console=pipe" makes the container's systemd wait for a controlling tty
# that never appears on a CI runner; the call then blocks silently until the
# job times out (seen: 3 hours with no output). Write the console to a file and
# treat the /success marker as the source of truth. The timeout is a backstop,
# not the expected exit path.
: > "$OUT_DIR/dietpi-installer.log"
# Run it in the background and echo progress, so the job log shows the
# installer moving instead of a silent 3-hour gap.
timeout --signal=TERM --kill-after=120 3000 \
	systemd-nspawn --quiet --link-journal=no -bD "$MNT" "${NSPAWN_BINDS[@]}" \
	>"$OUT_DIR/dietpi-installer.log" 2>&1 &
NSPAWN_PID=$!
ELAPSED=0
while kill -0 "$NSPAWN_PID" 2>/dev/null; do
	sleep 60
	ELAPSED=$(( ELAPSED + 60 ))
	if [[ -s $OUT_DIR/dietpi-installer.log ]]; then
		printf '    [%s] %s\n' "$(date +%H:%M:%S)" \
			"$(tail -1 "$OUT_DIR/dietpi-installer.log" | tr -d "\r" | cut -c1-160)"
	fi
	# If the container has been up for a while but showed nothing but a login
	# prompt, the installer unit never ran. Say so instead of waiting out the
	# whole timeout in silence.
	if (( ELAPSED >= 300 )) && ! grep -qi 'DietPi-Installer' "$OUT_DIR/dietpi-installer.log"; then
		info "no installer output after ${ELAPSED}s -- dumping diagnostics"
		# Everything here is best effort and time-boxed: a hung diagnostic must
		# not turn into a second silent stall.
		MACHINE=$(basename "$MNT")
		timeout 20 machinectl status "$MACHINE" 2>&1 | tail -15 | sed 's/^/    /' || true
		timeout 20 journalctl -M "$MACHINE" --no-pager -n 15 2>&1 \
			| sed 's/^/    /' || true
		timeout 20 systemctl -M "$MACHINE" list-units --state=failed --no-pager \
			2>&1 | tail -10 | sed 's/^/    /' || true
		ELAPSED=0   # report once per five minutes, not every minute
	fi
done
wait "$NSPAWN_PID"
NSPAWN_RC=$?
set -e
info "nspawn exited with $NSPAWN_RC"

if [[ ! -f $MNT/success ]]; then
	printf '\033[1;31m[x] DietPi-Installer did not complete (nspawn exit %s)\033[0m\n' \
		"${NSPAWN_RC:-?}" >&2
	tail -40 "$OUT_DIR/dietpi-installer.log" | sed 's/^/    /' >&2 || true
	exit 1
fi
rm -f "$MNT/success"

# The container powered itself off; make sure nothing is still mounted.
umount -R "$MNT" 2>/dev/null || true
mountpoint -q "$MNT" || mount "$(cat "$WORK/root.dev")" "$MNT"

log "Stage 2 done"
info "log: $OUT_DIR/dietpi-installer.log"
