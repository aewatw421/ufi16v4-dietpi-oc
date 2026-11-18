# Flashing the UFI_16__V4

Read this once before the first flash. The stick has two ways in and one way to
permanently lose your modem calibration.

## Identify the board

Look at the silkscreen. This guide covers:

- `UFI_16__V4` (silkscreen on the board)
- `UFI001B_MB_V01` / `UFI001B_MB_V02`
- `UFI001C`

All three are MSM8916 + PM8916, 512 MB LPDDR3, 4 GB eMMC, and share the same
OpenStick GPT and the `thwc,ufi001c` device tree. Other Zhihe sticks (UF898,
UF896, UZ801) use different GPIOs for the LEDs and buttons — do not flash those
with this image.

Check what you have over USB:

```bash
lsusb | grep -i -E '05c6|qualcomm'
# 05c6:9008  -> EDL / download mode
# 05c6:900e  -> fastboot (stock aboot or lk2nd)
# 05c6:901d  -> Android/adb (stock firmware running)
```

## Back up first — always

`modemst1`, `modemst2` and `fsg` hold the per-device RF calibration and the
IMEI. They are unique to your unit; no download can restore them. Losing them
turns the stick into a WiFi-less brick that cannot register on any network.

`flash.sh --backup DIR` does this automatically for whichever mode it detects.
Do it once, keep the files somewhere that is not the stick:

```bash
sudo ./flash.sh --backup ./backup-ufi16
# fastboot path: fastboot oem dump <part> && fastboot get_staged ...
# edl path:      edl r <part> ...
```

Verify you actually got data:

```bash
ls -l backup-ufi16
# modemst1.bin and modemst2.bin should be 1.5 MiB each, fsg.bin 1.5 MiB
sha256sum backup-ufi16/*.bin > backup-ufi16/SHA256SUMS
```

## Path A: EDL / 9008 (recommended for the first flash)

EDL is the SoC's own USB download mode. It works even when the bootloader is
gone, which makes it the safe choice.

1. **Find the EDL point.** On UFI-001C it is the only button, wired to GPIO 37.
   On UFI-001B it is the small button next to the SIM slot. On `UFI_16__V4`
   boards the pads are usually marked `EDL` or `D+/D-` near the USB connector.
2. **Enter EDL.** Hold the button, plug the stick into USB, keep holding for
   ~2 s, release. The LED goes dark and `lsusb` shows `05c6:9008`.
3. **Flash.**

```bash
sudo apt install python3-pip android-tools-adb android-tools-fastboot
pip install edlclient

sudo ./flash.sh --edl
```

The script writes GPT, SBL1, RPM, TZ, HYP, aboot, lk2nd, and the rootfs, then
resets. First boot takes 30–60 s (the rootfs is fsck'd and resized).

## Path B: fastboot (stock aboot still alive)

If the stock firmware still boots, or you are already on lk2nd, fastboot is
faster and touches less.

```bash
adb devices            # if stock Android-ish firmware is running
adb reboot bootloader
fastboot devices       # should list the stick

sudo ./flash.sh --fastboot
```

This writes only `boot` (lk2nd) and `rootfs`. The GPT and boot firmware are
left alone, which is what you want on a stick that already works.

## After the first boot

The stick comes up as a USB Ethernet gadget:

- `192.168.68.1`, DHCP hands out `192.168.68.10–100`
- serial console on `/dev/ttyACM0` at 115200 (autologin as root)
- SSH on port 22

```bash
ssh root@192.168.68.1     # password: dietpi
```

Confirm the overclock took:

```bash
cat /sys/devices/system/cpu/cpu0/cpufreq/scaling_available_frequencies
# expect 1996800 near the top
cat /sys/devices/system/cpu/cpu0/cpufreq/cpuinfo_max_freq
```

Check the temperature under load:

```bash
cat /sys/class/thermal/thermal_zone*/type /sys/class/thermal/thermal_zone*/temp
```

## Modem / 4G

The image ships ModemManager. Bring the modem up once you have a SIM:

```bash
mmcli -m 0 --enable
nmcli connection add type gsm ifname cdc-wdm0 con-name lte apn internet
nmcli connection up lte
```

If `mmcli -L` shows nothing, the modem firmware did not come up — check
`dmesg | grep -i -E 'mba|mpss|q6v5'`. The `mpss` region is loaded from the
`modem` partition that stock firmware left in place; flashing this image does
not touch it.

## Going back to stock

Two options:

1. **Keep the bootloader chain.** Flash the stock `boot` and `rootfs` back with
   fastboot. The stock aboot is still in its partition, so this restores the
   original Android firmware as long as you also restore `system`/`userdata`.
2. **Full EDL restore.** Use `stick-blobs/stock-ufi001b` from the OpenStick
   project with `rawprogram0.xml` and `edl`. That rewrites every partition
   including the GPT, which is the only way back if you wiped the partition table.

Either way, restore your `modemst1`/`modemst2`/`fsg` backups first if you ever
wrote over them.

## Troubleshooting

| symptom | cause | fix |
|---|---|---|
| no `05c6:9008` after holding the button | button released too early, or cable is charge-only | hold until you see the device, try a different cable |
| `fastboot devices` empty after `flash boot` | lk2nd not on the boot partition | re-flash via EDL |
| boots but no USB NIC | gadget configfs failed | `journalctl -u usb-gadget`, check `dmesg | grep dummy_udc` |
| no `/extlinux/extlinux.conf` in lk2nd log | rootfs partition not ext4 or not labelled `rootfs` | `blkid`, re-flash stage 1 |
| `1996800` missing from available frequencies | OPP rejected by regulator range | `dmesg | grep -i opp` |
| bootloops after enabling 2 GHz | sample cannot hold 1.35 V | let `oc-watchdog` cap it, or set `scaling_max_freq` to 1401600 |
| modem gone after flashing | `modemst`/`fsg` were overwritten | restore your backups with `edl w` |

## Notes on the partition layout

This image uses the OpenStick GPT, which is smaller than the stock one and
reclaims ~3 GB for the rootfs:

```
cdt       131072      sbl1      262144      rpm       263168
tz        264192      hyp       266240      sec       267264
modemst1  267296      modemst2  271392      fsc       275488
fsg       393216      aboot     524288      boot      526336  (64 MiB)
devinfo   657408      rootfs    659456      (rest of the eMMC)
```

Once you flash this GPT the stock Android layout is gone. That is why the
backup step matters and why `flash.sh` refuses to write `modemst*` unless you
pass `--with-modem-data`.
