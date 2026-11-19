# DietPi for MSM8916 4G sticks — UFI_16__V4 / UFI-001B / UFI-001C

Builds a DietPi (Debian) image for the Qualcomm MSM8916 ("Snapdragon 410")
USB 4G modem sticks sold as **UFI_16__V4**, UFI-001B and UFI-001C, with the CPU
pushed to the top OPP tier and a one-shot flasher attached.

> **About "2.0 GHz":** the tier is **1996.8 MHz**, not a round 2.000 GHz.
> MSM8916's high-frequency CPU clock comes from the A53PLL, whose output is
> `19.2 MHz × L` with integer `L`; the closest value at or below 2 GHz is
> `L = 104` → 1996800000 Hz. See [docs/overclock.md](docs/overclock.md) for the
> full PLL/PMIC arithmetic and why pushing higher needs a different PMIC.

## What you get

| | |
|---|---|
| OS | DietPi (Debian Trixie), arm64, systemd |
| Kernel | `msm8916-mainline/linux` @ `msm8916/6.12` + this repo's patches |
| Device tree | `msm8916-thwc-ufi001c-oc.dtb` (the OC variant) |
| Bootloader | lk2nd (stock aboot stays in place, GPT is the OpenStick one) |
| CPU | 200 MHz … **1996.8 MHz**, OPP-driven VDD_APC via PM8916 buck S2 |
| Thermal | passive trip 68 °C (was 75 °C), critical 100 °C (was 110 °C) |
| Access | USB gadget ECM NIC at `192.168.68.1`, `ttyACM0` serial console, SSH |
| Login | `root` / `dietpi` (change it on first boot) |

## Verified build

GitHub Actions run [#21](https://github.com/aewatw421/ufi16v4-dietpi-oc/actions/runs/44456285993)
completed every step on `ubuntu-24.04-arm` in about 20 minutes of build time:

```
Stage 1/5: disk image skeleton          GPT + 7 firmware partitions + lk2nd
Stage 2/5: Debian bootstrap + DietPi    trixie, HW_MODEL=22, installer "Completed"
Stage 3/5: kernel, modules, DTB         Debian 13, 7 module groups, 2 extlinux labels
Stage 4/5: board glue                   fstab, USB gadget, dnsmasq, governor
Stage 5/5: pack                         fsck clean, rootfs shrunk to 291829 blocks
```

The overclock device tree is validated out of the built binary, not the source:

```
check-opp: 10 distinct opp-hz values
  19.2MHz 200.0MHz 400.0MHz 800.0MHz 998.4MHz 1209.6MHz
  1401.6MHz 1612.8MHz 1804.8MHz 1996.8MHz
check-opp: OK, all requested tiers present
cpu-supply phandles: 4
regulator-max-microvolt = <0x149970>   # 1350000 uV = PM8916 S2 ceiling
```

Artifacts: `ufi16v4-dietpi-oc.img.xz` (183 MiB, 4.0 GiB uncompressed) and
`msm8916-thwc-ufi001c-oc.dtb`.

## Quick start

```bash
# grab a release bundle, then:
tar xf ufi16v4-dietpi-oc-flash-*.tar.gz
cd flash

# put the stick in EDL (hold the button on GPIO37 while plugging in) ...
sudo ./flash.sh --backup ./backup
```

`flash.sh` auto-detects fastboot vs EDL and picks the right path. Read
[docs/flashing.md](docs/flashing.md) before the first run — it covers the EDL
button location, how to back up `modemst1/2` + `fsg` (lose those and the modem
is dead), and how to get back to the stock firmware.

## Build it yourself

The CI workflow in `.github/workflows/build.yml` does the whole thing on an
arm64 runner:

```bash
gh workflow run build-dietpi-ufi16v4 \
  -f kernel_branch=msm8916/6.12 \
  -f dietpi_distro=trixie \
  -f img_size_mb=4096 \
  -f upload_release=true
```

Locally (needs root for the loop mounts, an arm64 host or qemu binfmt):

```bash
sudo ./scripts/build-all.sh
```

Stages are separate scripts, so a failure can be resumed:

| stage | script | what it does |
|---|---|---|
| 0 | `build-kernel.sh` | clone kernel, apply `patches/*`, build Image.gz + modules + DTB |
| 1 | `10-make-disk.sh` | OpenStick GPT, boot firmware blobs, lk2nd, empty ext4 |
| 2 | `20-dietpi-installer.sh` | mmdebstrap, then DietPi-Installer (generic, HW_MODEL=22) via chroot + a systemctl shim |
| 3 | `30-install-kernel.sh` | kernel/modules/DTB + `extlinux.conf`, OC watchdog unit |
| 4 | `40-finalize.sh` | fstab, module autoload, USB gadget, dnsmasq, governor |
| 5 | `50-pack-image.sh` | fsck, shrink, xz |

## Repository layout

```
patches/     three patches against msm8916-mainline/linux
config/      kernel fragment on top of msm8916_defconfig
scripts/     build stages, flasher, watchdog
docs/        overclock arithmetic, flashing procedure, troubleshooting
```

## The patches

1. `0001-dts-pm8916-add-spmi-s2-regulator.patch` — adds the PM8916 SPMI
   regulator container and buck S2 (`VDD_APC`) to `pm8916.dtsi`. Mainline only
   describes the RPM-managed regulators; without this there is no way to
   describe CPU voltage.
2. `0002-dts-msm8916-add-ufi-overclock.patch` — the OC device tree include and
   the `msm8916-thwc-ufi001c-oc.dts` board file: OPP table with
   `opp-microvolt`, `cpu-supply` on all four CPUs, `regulator-always-on` S2,
   lowered thermal trips, and the A53PLL OPP table that tells the PLL driver
   which `L` values to program.
3. `0003-dts-qcom-build-oc-dtb.patch` — builds the extra DTB.

None of them change behaviour for boards that do not include the OC dtsi.

## Limitations

- 1996.8 MHz is unstable on some samples. The included `oc-watchdog.service`
  caps the CPU at the vendor-validated 1401.6 MHz after two failed boots.
- No CPR driver: voltage comes from a static OPP table, so each unit gets the
  same voltage rather than a per-chip calibrated one. Expect slightly worse
  power/heat than a stock Android firmware with CPR enabled.
- The A53PLL tops out at `L = 104`; going further means a higher VDD_APC than
  the PM8916 S2 ceiling of 1.35 V allows.
- 512 MB RAM: the image targets a headless stick. Do not expect a desktop.

## Credits

Standing on: [msm8916-mainline](https://github.com/msm8916-mainline) (kernel,
lk2nd), [OpenStick](https://github.com/OpenStick/OpenStick) (boot firmware
blobs, GPT layout, flashing workflow), [DietPi](https://github.com/MichaIng/DietPi)
(rootfs installer).
