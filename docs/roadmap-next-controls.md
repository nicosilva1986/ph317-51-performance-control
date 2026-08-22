# Roadmap — next control surfaces

Investigation and proposal notes after the initial AUTO/MAX controller,
WMI surface map, and native Turbo plan. Nothing here is authorized for
production install until the listed evidence gates pass on the reference
PH317-51.

Related issues track each workstream separately. This document is the
index and the ordering rationale.

## Current baseline (already shipped conceptually)

- Binary fan policy: firmware `AUTO` ↔ forced `MAX` (100 % via
  `SetGamingFanBehavior` + `SetGamingFanSpeed`).
- Fail-closed watchdog; observed mode + RPM beat write success.
- Evidence: Auto vs Max FMA workload (−12 °C max, +8.5 % throughput).
- Native Turbo plan and CRUW/driver hygiene remain separate tracks.

## Recommended order

```text
1. Limit telemetry (read-only)     → know thermal vs power vs GPU limits
2. Native Turbo baseline (#2)     → remove artificial 28x before fan tuning claims
3. Custom % matrix experiment     → prove firmware holds intermediate speeds
4. Graduated fan policy           → only if (3) is green
5. Resume + AC/DC lifecycle       → reliability of any fan policy
6. CoolBoost probe                → close or adopt; likely low upside if Max=6122 RPM
7. GPU-asymmetric refinements     → after (3)–(4)
8. Optional single-step PL experiment after stock-native acceptance
```

Do not combine fan-policy changes with power-limit changes in the same
measurement window.

## Workstreams

| # | Topic | Doc | Gate before code in the hot path |
|---|---|---|---|
| A | Who is limiting performance | [limit-telemetry-proposal.md](limit-telemetry-proposal.md) | Sampler is read-only; no fan/power writes |
| B | Custom % / graduated curves | [fan-curve-experiment.md](fan-curve-experiment.md) | Monotonic RPM, stable hold, fail-closed to 100 % |
| C | Binary policy tuning | (issue only) | Same 10-minute FMA + WHEA=0 vs current config |
| D | CoolBoost | (issue only) | RPM delta vs current Max; no benefit → close |
| E | Resume / AC–DC | (issue only) | Reassert mode+RPM after S3 and on DC |
| F | GPU-first policy | (issue only) | Depends on B for independent GPU % |

## Non-goals (unchanged)

- EC register writes
- Disabling BD PROCHOT, VBS/HVCI, or thermal protections
- Undervolt / IccMax as routine tuning
- Claiming multi-model support from one laptop
- Shipping a PID continuous controller without the Custom matrix

## Principles for any new writer path

1. One privileged writer per control plane.
2. Invalid telemetry or integrity failure → maximum cooling.
3. Every claim links a reproducible workload, thermals, and WHEA review.
4. Transactional install/update; leave Max on failure.
