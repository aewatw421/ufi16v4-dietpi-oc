# Why the ceiling is 1996.8 MHz (and not 2.0 GHz)

Short version: the CPU PLL can only produce integer multiples of 19.2 MHz, and
the PMIC that feeds the CPU tops out at 1.35 V. 1996.8 MHz is the highest point
that satisfies both.

## 1. Which clock is in charge

MSM8916 (Snapdragon 410) runs its four Cortex-A53 cores from one of two parents,
picked by the APCS A53 mux/divider:

| CPU frequency | parent |
|---|---|
| up to 998.4 MHz | GPLL0 through `a53mux` |
| 998.4 MHz and above | `a53pll` |

Both are visible in the mainline device tree:

```
apcs: mailbox@b011000 {
	compatible = "qcom,msm8916-apcs-kpss-global", "syscon";
	clocks = <&a53pll>, <&gcc GPLL0_VOTE>;
	clock-names = "pll", "aux";
};

a53pll: clock@b016000 {
	compatible = "qcom,msm8916-a53pll";
	reg = <0x0b016000 0x40>;
	clocks = <&xo_board>;
};
```

Everything at or above ~1 GHz is therefore PLL-bound, and that is where the
overclock has to happen.

## 2. The A53PLL frequency equation

`clk_pll_sr2_set_rate()` programs three registers: an L (integer), an M
(numerator) and an N (denominator). The mainline A53PLL driver fills them like
this (`drivers/clk/qcom/a53-pll.c`):

```c
freq_tbl[i].freq = freq;
freq_tbl[i].l    = freq / xo_freq;   /* xo_freq = 19200000 */
freq_tbl[i].n    = 1;                /* no fractional part */
```

So M is never used and N is always 1:

```
f_cpu = XO × L / N = 19200000 × L
```

`L` lives in a 10-bit field (`regmap_update_bits(..., 0x3ff, f->l)`), giving a
theoretical maximum of `19200000 × 1023 ≈ 19.6 GHz`. The limit is not the
register — it is the silicon and the PMIC.

Only multiples of 19.2 MHz are reachable, so a "2.0 GHz" request is rounded
**down** to the nearest achievable point:

| target | L | actual |
|---|---|---|
| 1200 MHz | 62 | 1190.4 MHz |
| 1401.6 MHz | 73 | 1401.6 MHz ← highest tier stock Android ever uses |
| 1612.8 MHz | 84 | 1612.8 MHz |
| 1804.8 MHz | 94 | 1804.8 MHz |
| **2000 MHz** | **104** | **1996.8 MHz** |

There is no `L` that gives exactly 2 000 000 000 Hz. The next step up would be
`L = 105` → 2016 MHz, which is already past the request.

## 3. The voltage side

VDD_APC is PM8916's buck **S2**. It is reachable over SPMI (not the RPM path that
exposes S1/S3/S4), which is why the mainline `pm8916.dtsi` never described it —
the node only exists once the CPR driver is in play (msm8916-mainline's
`wip/msm8916/cpr` branch). We do not need CPR to describe the regulator itself,
so patch 1 adds the container node and patch 2 the S2 child with

```
regulator-min-microvolt = <1050000>;
regulator-max-microvolt = <1350000>;
```

1.35 V is not arbitrary. It is the highest ceiling in Qualcomm's own CPR tables
for MSM8916 — the vendor `qcom,cpr-voltage-ceiling` for the top corner is
`<1050000 1150000 1350000>`, and the 1.4016 GHz step added by community kernels
uses corner 10, which is still capped at 1.35 V. Anything higher is outside
what the part was characterised for.

The chosen OPP ladder:

| frequency | L | VDD_APC | source |
|---|---|---|---|
| 200 MHz | – (GPLL0) | 1.05 V | stock |
| 400 MHz | – | 1.05 V | stock |
| 800 MHz | – | 1.05 V | stock |
| 998.4 MHz | 52 | 1.15 V | stock corner |
| 1209.6 MHz | 63 | 1.20 V | stock corner |
| **1401.6 MHz** | 73 | 1.25 V | vendor max |
| 1612.8 MHz | 84 | 1.30 V | this repo |
| 1804.8 MHz | 94 | 1.325 V | this repo |
| **1996.8 MHz** | 104 | 1.35 V | this repo, PMIC ceiling |

## 4. How the voltage actually gets set

There is no CPR power domain in mainline for MSM8916, so the DT declares the
buck as an ordinary OPP regulator instead:

```dts
&CPU0 { cpu-supply = <&pm8916_spmi_s2>; };
&cpu_opp_table {
	opp-1996800000 {
		opp-hz = /bits/ 64 <1996800000>;
		opp-microvolt = <1350000>;
	};
};
```

`cpufreq-dt` sees `cpu-supply`, calls `dev_pm_opp_set_regulators()`, and the OPP
core then does the right ordering on every frequency change: raise the voltage
first, change the clock second, and reverse that when dropping down
(`opp_parse_supplies()` → `_set_opp()` → `regulator_set_voltage()` around
`clk_set_rate()`).

Because `opp-microvolt` is now present, the OPP core also validates each entry
against the regulator's declared range and marks anything outside it as
unavailable. If you raise `regulator-max-microvolt`, the extra OPPs light up; if
you lower it, the top tiers silently disappear from `scaling_available_frequencies`
instead of failing at runtime.

## 5. Why not higher

Three independent walls:

1. **PMIC**: S2's `hfs430`/`ftsmps` range tops out at 1.35 V for the corners used
   here. More voltage means a different regulator and a board rework.
2. **Silicon**: the vendor's own speed bins stop at corner 4 for most parts; the
   `0x4` (`opp-supported-hw`) entry that allows 1.3632 GHz applies to speed bin 2
   only. Running every sample at 2 GHz is already past binning.
3. **Thermals**: a plastic 4G stick has no airflow and no heatsink. See below.

So the honest description is "the highest OPP that this PMIC and this DT can
express", not "2 GHz guaranteed".

## 6. Thermal consequences

The stock device tree trips passive throttling at 75 °C and shuts down at 110 °C.
At 2 GHz those are too generous — the case reaches uncomfortable temperatures
before the first trip even fires. The OC dtsi lowers them:

```dts
&cpu0_1_alert0 { temperature = <68000>; };
&cpu2_3_alert0 { temperature = <68000>; };
&cpu0_1_crit   { temperature = <100000>; };
&cpu2_3_crit   { temperature = <100000>; };
```

Both existing cooling maps already drive all four cores across the full OPP
range, so only the temperatures need to change.

## 7. What happens on an unstable sample

Not every MSM8916 will hold 1996.8 MHz at 1.35 V, especially warm. Rather than
shipping something that bootloops, `oc-watchdog.service` counts boots that never
reach userspace and, after two failures, drops a drop-in that caps the CPU at the
vendor-validated 1401.6 MHz:

```
/var/lib/oc-watchdog/failures      counter
/var/lib/oc-watchdog/boot-ok       written once userspace is up
/etc/systemd/system/oc-watchdog-cap.conf   generated cap after 2 failures
```

To do it by hand instead:

```bash
for p in /sys/devices/system/cpu/cpu*/cpufreq/scaling_max_freq; do
  echo 1401600 > "$p"
done
```

## 8. Verifying what you actually got

```bash
cat /sys/devices/system/cpu/cpu0/cpufreq/scaling_available_frequencies
# 1996800 1804800 1612800 1401600 1209600 998400 800000 400000 200000

cat /sys/devices/system/cpu/cpu0/cpufreq/cpuinfo_max_freq
# 1996800

cat /sys/kernel/debug/regulator/regulator_summary | grep -i s2
# shows the live VDD_APC voltage

grep -i '' /sys/class/thermal/thermal_zone*/temp
# CPU zone temperatures
```

If `1996800` is missing from `scaling_available_frequencies`, the OPP was
rejected — check `dmesg | grep -i opp` for "OPP not supported by regulators",
which means the S2 node did not get its `regulator-max-microvolt` or the
`cpu-supply` phandle is wrong.
