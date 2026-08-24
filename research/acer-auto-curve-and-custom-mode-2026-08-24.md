# Acer's stock fan curve, and CUSTOM mode validated (2026-08-24)

**Status:** both open questions closed by measurement. The proportional band is
now viable on this hardware and the calibration is no longer guesswork.

Raw evidence: `evidence/benchmarks/2026-08-24-acer-auto-curve.json`.
Runner: `tools/EJECUTAR-Medicion.cmd`. Protocol: `docs/fan-curve-experiment.md`.

---

## 1. Acer leaves 22 % of the fan range unused

Measured in `AUTO` with the agent paused, eight-thread load, sampling every 2 s.
The run **aborted at 92 °C** as designed, with **zero WHEA events**.

| CPU °C | n | RPM p50 | RPM p90 | RPM max |
|--------|---|---------|---------|---------|
| 50–54 | 46 | 2500 | 2521 | 2654 |
| 55–59 | 37 | 2970 | 3000 | 3409 |
| 60–64 | 12 | 3409 | 3846 | 4109 |
| 65–69 | 4 | 3846 | 4000 | 4411 |
| 75–79 | 5 | 3370 | 3797 | 4687 |
| 80–84 | 2 | 3370 | 3370 | 3409 |
| 85–89 | 6 | 3750 | 3846 | 4347 |
| 90–94 | 8 | 4687 | 4687 | 4761 |

Two findings, and the second is the important one.

**Acer's ceiling in AUTO is 4761 RPM.** The hardware does 6122. Even with the
package at 92 °C — eight degrees from Tjmax — the stock policy never commands
the top **1361 RPM, 22 % of the available range**.

**Between 65 °C and 89 °C the curve is flat.** It climbs to ~3846 RPM by 69 °C
and then *stops*: 3370 at 75–84 °C, 3750 at 85–89 °C. Acer spends 25 degrees of
thermal headroom holding the fans roughly still, and only reacts once the
package is above 90 °C. That plateau is the whole reason this project exists,
and it is the exact band where a proportional curve has something to offer.

Sample counts in the upper buckets are small because the run aborted on the
safety limit; the direction is unambiguous but a longer run would tighten the
numbers.

## 2. Firmware CUSTOM mode works

Behaviour word `0x00C30009`, previously a hypothesis from `docs/wmi-surface.md`
and never executed on this machine — the only bitmaps ever observed in
production telemetry were `0x0100` (AUTO) and `0x0200` (MAX).

| Commanded | RPM p50 | RPM min | RPM max | Stayed in mode 3 |
|-----------|---------|---------|---------|------------------|
| 40 % | 3000 | 2941 | 5000 | 20/20 |
| 60 % | 4285 | 4285 | 4347 | 20/20 |
| 80 % | 5454 | 5454 | 5555 | 20/20 |
| 100 % | 6122 | 6122 | 6122 | 20/20 |

**Verdict: `CUSTOM_VALIDO`.** All four points accepted, response monotonic, and
fan mode held at 3 for every one of the 80 samples — no drift back to AUTO,
which was the main failure mode this test existed to catch.

The 5000 RPM maximum at 40 % is the tail of the preceding MAX state settling
during the first samples, not curve behaviour; the p50 is the real value.

### Percent → RPM

Close to linear, slightly compressive at the top (~52 RPM per point overall):

```
40 % -> 3000      60 % -> 4285      80 % -> 5454     100 % -> 6122
        +1285 for +20pp   +1169 for +20pp   +668 for +20pp
```

Interpolating: 45 % ≈ 3320, 55 % ≈ 3960, 65 % ≈ 4580, 75 % ≈ 5160, 90 % ≈ 5790.

## 3. What this unlocks

The controller has only ever had two settings: Acer's lazy AUTO, or 6122 RPM.
That binary is why entering MAX had to be gated so conservatively — entry meant
maximum noise, so the thresholds were pushed high (`maxCpuC: 72`).

With a proportional band, **entering the band no longer costs full noise**, so
the entry threshold can come down to where Acer's curve actually goes flat
(~65 °C) without the machine becoming loud at idle. That is the design change
this measurement makes available, and it is what the operator asked for:
trigger around the same temperatures Acer does, but use the full RPM range
instead of stopping at 4761.

Calibration is not yet chosen or applied; `curveEnabled` still ships `false`.
Any candidate curve should be validated against the same FMA workload as
`evidence/benchmarks/2026-08-21-fan-auto-vs-max.json`, comparing max/avg/p95
temperature and iterations, not just RPM.
