# Undervolt effectiveness on the reference machine (2026-08-24)

**Status:** closed for CPU (firmware-locked, unfixable in software).
**Action pending:** revert the GPU V/F curve — it is a measured regression.

Answers two questions that had been open: does the ThrottleStop CPU undervolt
actually reach the silicon, and did the GPU undervolt help.

---

## 1. CPU — the offset is configured and silently ignored

### What is configured

`ThrottleStop.ini`, active profile (`Profile=0`):

```
FIVRVoltage00 = 0xF3400000   UnlockVoltage00 = 1    # CPU core
FIVRVoltage20 = 0xF3400000   UnlockVoltage20 = 1    # CPU cache
```

Decoding the FIVR encoding (bits 31:21, 11-bit signed, 1000/1024 mV per step):

```
0xF3400000 >> 21 = 1946  ->  1946 - 2048 = -102 steps  ->  -102 x 1000/1024 = -99.6 mV
```

So **-99.6 mV on core and cache**, accepted by the UI without error.

### The measurement

If a ~100 mV offset were reaching the silicon, VID requested at a *fixed*
multiplier would drop by ~100 mV. VID at 28x under load (`C0 > 50 %`), taken
from ThrottleStop's own log history, spans a month across the change:

| Date | Samples | Mean VID at 28x |
|------|---------|-----------------|
| 2026-07-23 | 9 651 | 0.9213 V |
| 2026-07-25 | 6 320 | 0.9255 V |
| 2026-07-27 | 19 115 | 0.9263 V |
| 2026-08-21 | 2 897 | 0.9270 V |
| 2026-08-22 | 5 012 | 0.9356 V |
| 2026-08-23 | 53 | 0.9250 V |

Total spread: **14.3 mV**, unordered with respect to the change. Expected
signature of a working offset: a clean step down to ≈0.82 V. **Absent.**

28x was chosen because the July logs are dominated by it (the multiplier was
capped there at the time), giving a directly comparable fixed operating point on
both sides of the window. At 34x the August-only samples are likewise flat
(1.0690 / 1.0595 / 1.0558 V).

### Conclusion and cause

The undervolt **never reached the CPU**. This is the CVE-2019-11157
("Plundervolt") mitigation: Intel's Kaby Lake microcode, as shipped in this
Acer BIOS, turns MSR `0x150` writes into a silent no-op. The tool reports
success because the write itself does not fault — only its effect is discarded.

This is a firmware decision. No version of ThrottleStop, XTU, or any other
user-space tool can restore it. The only theoretical path is a BIOS predating
the mitigation, which trades a security fix for ~100 mV and is not a trade this
project makes.

`research/prochot-and-tcc-offset.md` already documents the read-only posture on
MSR-level controls; this note is the empirical confirmation that the voltage
plane specifically is closed.

### What ThrottleStop is still good for here

- **Logging.** The VID/FID/temperature history above is the evidence that
  settled this question. Worth keeping for that alone.
- **Multiplier caps**, which do work (the 28x cap used in the fan benchmark).
- Not voltage. Ever, on this firmware.

---

## 2. GPU — the undervolt is a net loss

Two 180 s loaded runs, before and after applying an Afterburner V/F curve:

| Metric | Before | After | Delta |
|--------|--------|-------|-------|
| Mean SM clock | 1388 MHz | 1261 MHz | **-127 MHz (-9.2 %)** |
| Min SM clock | 1341 MHz | 1215 MHz | -126 MHz |
| P05 SM clock | 1341 MHz | 1227 MHz | -114 MHz |
| Mean power | 81.7 W | 83.6 W | **+1.9 W** |
| Peak power | 86.22 W | 86.37 W | +0.15 W |
| Max temp | 86 °C | 83 °C | -3 °C |
| Mean temp | 76.8 °C | 72.2 °C | -4.6 °C |
| % time power-capped | 64 % | 78.8 % | **+14.8 pp** |
| % time thermal-capped | 0 % | 0 % | unchanged |

### Reading

A successful undervolt lowers voltage at a given clock, so the same power budget
buys **more** clock. The opposite happened: clock fell 9 % while mean power rose
slightly and the card spent substantially more time against its power cap. The
curve was flattened at too low a point, capping frequency rather than improving
efficiency.

The temperature improvement is therefore not a win — it is the thermal
signature of a slower card. Decisively, `pctConThermalCap` is **0 % in both
runs**: this GPU was never thermally limited, so buying 3–4 °C at the cost of
9 % clock trades away performance for a margin that was not binding.

### Action

Revert to the stock V/F curve. Any future attempt must be validated against
mean/P05 SM clock at equal or better power, not against temperature — on this
card temperature is a lagging indicator and the power cap is the real limit.

See `gpu-thermal-and-undervolt.md` for the general landscape; this note is the
local measurement that contradicts the optimistic case on this specific unit.

---

## 3. Net effect on the project

With the CPU voltage plane firmware-locked and the GPU undervolt reverted, the
**fan overlay is the only demonstrated lever on this machine**
(-12 °C, +8.5 % throughput, `evidence/benchmarks/2026-08-21-fan-auto-vs-max.json`).
Remaining headroom is fan policy quality and limit telemetry, not voltage.
