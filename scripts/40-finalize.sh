#!/usr/bin/env bash
# Stage 4: final rootfs configuration and unmount.
#
# Everything here is board-specific glue that DietPi's generic path cannot know:
# USB gadget networking over the stick's micro-USB port, the modem APN hook,
# first-boot user setup, and making sure the kernel modules we built get loaded.
#
# Environment:
#   MNT       mounted rootfs (default $PWD/mnt)
#   OUT_DIR   (default $PWD/out)
#   HOSTNAME  (default ufi16v4)
set -euo pipefail

MNT="${MNT:-$PWD/mnt}"
OUT_DIR="${OUT_DIR:-$PWD/out}"; OUT_DIR="$(cd "$OUT_DIR" && pwd)"
HOSTNAME="${HOSTNAME:-ufi16v4}"

log() { printf '\n\033[1;36m==> %s\033[0m\n' "$*"; }
die() { printf '\033[1;31m[x] %s\033[0m\n' "$*" >&2; exit 1; }
[[ $EUID -eq 0 ]] || die "run as root"
mountpoint -q "$MNT" || die "$MNT not mounted"

log "Hostname and fstab"
echo "$HOSTNAME" > "$MNT/etc/hostname"
grep -q "$HOSTNAME" "$MNT/etc/hosts" 2>/dev/null || \
	echo "127.0.1.1	$HOSTNAME" >> "$MNT/etc/hosts"
cat > "$MNT/etc/fstab" <<'FSTAB'
# UFI_16__V4 / UFI-001B / UFI-001C
PARTLABEL=rootfs  /  ext4  noatime,lazytime,errors=remount-ro  0 1
tmpfs             /tmp  tmpfs  noatime,lazytime,nodev,nosuid,mode=1777  0 0
tmpfs             /var/log  tmpfs  size=32M,noatime,lazytime,nodev,nosuid  0 0
FSTAB

log "Kernel module autoload"
install -d "$MNT/etc/modules-load.d"
cat > "$MNT/etc/modules-load.d/ufi16v4.conf" <<'MODS'
# Remote processors + modem: needed before ModemManager probes
qcom_q6v5_mss
qcom_wcnss_pil
qcom_wcnss_ctrl
qcom_bam_dmux
rpmsg_wwan_ctrl
MODS

log "USB gadget networking"
# The stick's only port is micro-USB. In device mode it presents an ECM/RNDIS
# NIC plus a serial console, so it is reachable at 192.168.68.1 with no monitor
# or adapter. DietPi's generic setup does not create this, so we do.
install -d "$MNT/etc/systemd/system"
cat > "$MNT/usr/local/sbin/usb-gadget-up.sh" <<'GADGET'
#!/bin/sh
# Bring up a USB gadget: CDC-ECM network + ACM serial console.
set -e
G=/sys/kernel/config/usb_gadget/g1
[ -d "$G" ] && exit 0
modprobe libcomposite || exit 0

mkdir -p "$G"
echo 0x1d6b > "$G/idVendor"
echo 0x0104 > "$G/idProduct"
mkdir -p "$G/strings/0x409"
echo "ufi16v4"    > "$G/strings/0x409/serialnumber"
echo "DietPi"     > "$G/strings/0x409/manufacturer"
echo "MSM8916 Stick" > "$G/strings/0x409/product"

mkdir -p "$G/configs/c.1/strings/0x409"
echo "ECM+ACM" > "$G/configs/c.1/strings/0x409/configuration"
echo 250 > "$G/configs/c.1/MaxPower"

mkdir -p "$G/functions/ecm.usb0"
echo "02:11:22:33:44:55" > "$G/functions/ecm.usb0/dev_addr"
echo "02:11:22:33:44:56" > "$G/functions/ecm.usb0/host_addr"
ln -sf "$G/functions/ecm.usb0" "$G/configs/c.1/"

mkdir -p "$G/functions/acm.usb0"
ln -sf "$G/functions/acm.usb0" "$G/configs/c.1/"

UDC=$(ls /sys/class/udc 2>/dev/null | head -1)
[ "$UDC" ] && echo "$UDC" > "$G/UDC" || exit 0

# Static addressing for the gadget side; dhcpd/dnsmasq hands out leases.
ip link set usb0 up 2>/dev/null || true
ip addr add 192.168.68.1/24 dev usb0 2>/dev/null || true
GADGET
chmod 755 "$MNT/usr/local/sbin/usb-gadget-up.sh"

cat > "$MNT/etc/systemd/system/usb-gadget.service" <<'UNIT'
[Unit]
Description=USB gadget (ECM NIC + serial console)
After=local-fs.target
Before=network-pre.target

[Service]
Type=oneshot
RemainAfterExit=yes
ExecStart=/usr/local/sbin/usb-gadget-up.sh

[Install]
WantedBy=multi-user.target
UNIT

log "DHCP server for the gadget NIC"
# dnsmasq is tiny and DietPi already knows how to manage it.
chroot "$MNT" /usr/bin/env -i PATH=/usr/sbin:/usr/bin:/sbin:/bin \
	DEBIAN_FRONTEND=noninteractive \
	/bin/sh -c 'apt-get install -y --no-install-recommends dnsmasq >/dev/null 2>&1 || true'
cat > "$MNT/etc/dnsmasq.d/usb0.conf" <<'DNS'
interface=usb0
bind-dynamic
dhcp-range=192.168.68.10,192.168.68.100,255.255.255.0,12h
dhcp-option=3,192.168.68.1
dhcp-option=6,192.168.68.1
DNS

log "Serial console on the gadget ACM port"
mkdir -p "$MNT/etc/systemd/system/serial-getty@ttyGS0.service.d"
cat > "$MNT/etc/systemd/system/serial-getty@ttyGS0.service.d/autologin.conf" <<'GETTY'
[Service]
ExecStart=
ExecStart=-/sbin/agetty --autologin root --keep-baud 115200,38400,9600 %I $TERM
GETTY

log "Root password and SSH"
chroot "$MNT" /usr/bin/env -i PATH=/usr/sbin:/usr/bin:/sbin:/bin \
	/bin/sh -c 'echo "root:dietpi" | chpasswd; systemctl enable ssh 2>/dev/null || systemctl enable dropbear 2>/dev/null || true'

log "Enable our units"
chroot "$MNT" /usr/bin/env -i PATH=/usr/bin:/bin:/usr/sbin:/sbin \
	/bin/sh -c 'systemctl enable usb-gadget.service >/dev/null 2>&1 || true;
	             systemctl enable dnsmasq.service >/dev/null 2>&1 || true;
	             systemctl enable serial-getty@ttyGS0.service >/dev/null 2>&1 || true'

log "CPU governor default"
install -d "$MNT/etc/systemd/system"
cat > "$MNT/etc/systemd/system/cpu-governor.service" <<'GOV'
[Unit]
Description=Set CPU governor for the overclocked stick
After=multi-user.target

[Service]
Type=oneshot
RemainAfterExit=yes
# ondemand ramps fast but idles low, which matters on a passively cooled stick.
ExecStart=/bin/sh -c 'echo ondemand > /sys/devices/system/cpu/cpu0/cpufreq/scaling_governor 2>/dev/null || true'

[Install]
WantedBy=multi-user.target
GOV
chroot "$MNT" /usr/bin/env -i PATH=/usr/bin:/bin:/usr/sbin:/sbin \
	/bin/sh -c 'systemctl enable cpu-governor.service >/dev/null 2>&1 || true'

log "Trimming image size"
chroot "$MNT" /usr/bin/env -i PATH=/usr/sbin:/usr/bin:/sbin:/bin \
	/bin/sh -c 'apt-get clean; rm -rf /var/lib/apt/lists/* /var/cache/apt/* /tmp/* 2>/dev/null || true'
rm -rf "$MNT/var/log/journal"/* 2>/dev/null || true
: > "$MNT/etc/machine-id" 2>/dev/null || true

log "Stage 4 done"
