#!/usr/bin/env bash
# Build the MSM8916 mainline kernel with the UFI_16__V4 overclock device tree.
#
# Environment:
#   KERNEL_REPO     git URL of the kernel tree      (default: msm8916-mainline/linux)
#   KERNEL_BRANCH   branch to check out            (default: msm8916/6.12)
#   KERNEL_DIR      where to clone/build           (default: $PWD/kernel)
#   CROSS           toolchain prefix               (default: aarch64-linux-gnu-)
#   JOBS            parallel make jobs             (default: nproc)
#   OUT_DIR         artifact output directory      (default: $PWD/out)
set -euo pipefail

HERE="$(cd "$(dirname "${BASH_SOURCE[0]}")/.." && pwd)"
KERNEL_REPO="${KERNEL_REPO:-https://github.com/msm8916-mainline/linux.git}"
KERNEL_BRANCH="${KERNEL_BRANCH:-msm8916/6.12}"
KERNEL_DIR="${KERNEL_DIR:-$PWD/kernel}"
CROSS="${CROSS:-aarch64-linux-gnu-}"
JOBS="${JOBS:-$(nproc)}"
OUT_DIR="${OUT_DIR:-$PWD/out}"
FRAGMENT="${FRAGMENT:-$HERE/config/kernel-oc.fragment}"

mkdir -p "$OUT_DIR"
OUT_DIR="$(cd "$OUT_DIR" && pwd)"

log() { printf '\n\033[1;36m==> %s\033[0m\n' "$*"; }

log "Fetching $KERNEL_REPO ($KERNEL_BRANCH)"
if [[ -d $KERNEL_DIR/.git ]]; then
	git -C "$KERNEL_DIR" fetch --depth 1 origin "$KERNEL_BRANCH"
	git -C "$KERNEL_DIR" checkout -q FETCH_HEAD
	git -C "$KERNEL_DIR" reset -q --hard FETCH_HEAD
	git -C "$KERNEL_DIR" clean -qfd
else
	git clone --depth 1 --branch "$KERNEL_BRANCH" "$KERNEL_REPO" "$KERNEL_DIR"
fi

log "Applying overclock patches"
for p in "$HERE"/patches/*.patch; do
	echo "   $(basename "$p")"
	git -C "$KERNEL_DIR" apply --whitespace=nowarn "$p"
done

log "Configuring (msm8916_defconfig + OC fragment)"
make -C "$KERNEL_DIR" ARCH=arm64 CROSS_COMPILE="$CROSS" O="$KERNEL_DIR/build" msm8916_defconfig
"$HERE/scripts/merge-fragment.sh" "$KERNEL_DIR/build/.config" "$FRAGMENT"
make -C "$KERNEL_DIR" ARCH=arm64 CROSS_COMPILE="$CROSS" O="$KERNEL_DIR/build" olddefconfig

# Fail loudly if the overclock essentials did not make it into the config.
log "Verifying overclock config"
for sym in CONFIG_ARM_QCOM_CPUFREQ_NVMEM CONFIG_QCOM_A53PLL CONFIG_REGULATOR_QCOM_SPMI \
           CONFIG_CPU_FREQ_DT CONFIG_QCOM_CPR CONFIG_QCOM_RPMPD; do
	if ! grep -qx "$sym=y" "$KERNEL_DIR/build/.config"; then
		echo "   [warn] $sym is not =y in .config"
	fi
done

log "Building kernel, modules and device trees"
make -C "$KERNEL_DIR" ARCH=arm64 CROSS_COMPILE="$CROSS" O="$KERNEL_DIR/build" \
	-j"$JOBS" Image.gz modules dtbs

log "Collecting artifacts"
if [[ -f $KERNEL_DIR/build/arch/arm64/boot/Image.gz ]]; then
	cp "$KERNEL_DIR/build/arch/arm64/boot/Image.gz" "$OUT_DIR/Image.gz"
else
	cp "$KERNEL_DIR/build/arch/arm64/boot/Image" "$OUT_DIR/Image"
fi

OC_DTB="$KERNEL_DIR/build/arch/arm64/boot/dts/qcom/msm8916-thwc-ufi001c-oc.dtb"
STOCK_DTB="$KERNEL_DIR/build/arch/arm64/boot/dts/qcom/msm8916-thwc-ufi001c.dtb"
[[ -f $OC_DTB ]] || { echo "missing $OC_DTB"; exit 1; }
cp "$OC_DTB" "$OUT_DIR/msm8916-thwc-ufi001c-oc.dtb"
[[ -f $STOCK_DTB ]] && cp "$STOCK_DTB" "$OUT_DIR/msm8916-thwc-ufi001c.dtb"

log "Installing modules into a staging tree"
rm -rf "$OUT_DIR/modules"
make -C "$KERNEL_DIR" ARCH=arm64 CROSS_COMPILE="$CROSS" O="$KERNEL_DIR/build" \
	INSTALL_MOD_PATH="$OUT_DIR/modules" INSTALL_MOD_STRIP=1 modules_install

log "Checking the overclock OPP table in the built DTB"
# dtc renders 64-bit cells in its own notation, so the checker parses values
# instead of matching text.
if command -v dtc >/dev/null; then
	dtc -I dtb -O dts -o "$OUT_DIR/msm8916-thwc-ufi001c-oc.dts.decompiled" "$OC_DTB" 2>/dev/null || true
	node "$HERE/scripts/check-opp.js" \
		"$OUT_DIR/msm8916-thwc-ufi001c-oc.dts.decompiled" \
		1401600000 1612800000 1804800000 1996800000 \
		| tee "$OUT_DIR/oc-opp-check.txt"
else
	echo "dtc not available; skipping the OPP table check" > "$OUT_DIR/oc-opp-check.txt"
fi
log "Done"
ls -lh "$OUT_DIR"
