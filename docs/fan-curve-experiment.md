# Experiment — Custom fan percent matrix (PH317-51)

## Goal

Determine whether firmware `CUSTOM` mode plus `SetGamingFanSpeed` can
hold intermediate CPU/GPU fan percentages stably enough to justify a
graduated adaptive policy. Today the production path only uses
`AUTO` and forced `MAX` at 100 %.

## Background

From [wmi-surface.md](wmi-surface.md):

- `SetGamingFanBehavior` modes: AUTO=`1`, TURBO/MAX=`2`, CUSTOM=`3`
- CPU fan ID `0x01`, GPU fan ID `0x04`
- Speed in bits 8–15 (0–100)

Candidate CUSTOM behavior word (both fans, mode 3):

```text
bitmap 0x0009
CPU mode 3 << 16  = 0x00030000
GPU mode 3 << 22  = 0x00C00000
→ gmInput = 0x00C30009
```

**Do not use this value in the installed controller until this experiment
records successful readback on the reference machine.** Treat it as a
laboratory hypothesis only.

## Runner

Implemented by [`tools/EJECUTAR-Medicion.cmd`](../tools/EJECUTAR-Medicion.cmd),
which self-elevates, keeps its window open and writes a transcript. Phase 1
(Acer's stock curve, `AUTO` only) can be run alone with `-SoloFase1`.

## Safety constraints

- Physical console; AC power preferred.
- Abort immediately if CPU ≥ 92 °C or any WHEA appears.
- On any failed write, mode mismatch, or non-monotonic RPM: force Max
  (`0x00820009` + 100 % / 100 %) and stop the matrix.
- Do not run overnight unattended.
- Log only redacted JSON (no machine name, serials, or full instance IDs).

## Protocol

### Preparation

1. Confirm model PH317-51, `AcerGamingFunction` present.
2. Note BIOS, Windows build, driver baseline hash if available.
3. Idle until CPU ≤ 55 °C, GPU ≤ 50 °C (or GPU absent/0).
4. Capture one Auto baseline sample (mode + both RPM + temps).

### Matrix points

For each target percent `P` in `{0 or Auto, 40, 60, 80, 100}`:

1. Set CUSTOM behavior (once validated) or, for 100, use existing Max path.
2. `SetGamingFanSpeed` CPU = `P`, GPU = `P` (and a second pass with
   asymmetric pairs if symmetric pass is green: e.g. CPU 60 / GPU 80).
3. Wait 15 seconds without load; sample mode, CPU RPM, GPU RPM, temps
   every 2 s for 60 s (30 samples).
4. Record:
   - commanded P
   - behavior raw / decoded mode
   - median and min RPM per fan
   - whether mode drifted back to Auto
   - any `gmOutput` non-zero status

### Load spot-check (only if idle matrix is green)

Repeat `P ∈ {60, 80, 100}` under the standard ten-minute FMA workload
(or a shorter 3-minute pilot). Compare to evidence
`2026-08-21-fan-auto-vs-max.json` style metrics: max/avg/p95 temp,
iterations, WHEA.

### Pass criteria (idle matrix)

- Mode remains CUSTOM (or Max path for 100) for the full 60 s window.
- Median RPM is **non-decreasing** as P increases (allow small noise;
  no rank inversion between 40→60→80→100).
- Both fans respond; neither stuck at ~0 while the other is high unless
  documented as hardware asymmetry.
- Fail-safe Max still restores ≥ `minimumMaxRpm` (default 5000) within
  the existing verification budget.

### Fail criteria

- Firmware ignores Custom and stays Auto.
- Percent writes succeed but RPM flat across P.
- Oscillation or external override faster than watchdog can correct.
- Any thermal abort or WHEA.

## Outputs

Sanitize and store under `evidence/benchmarks/` only after manual review:

```text
evidence/benchmarks/YYYY-MM-DD-custom-fan-matrix-idle.json
evidence/benchmarks/YYYY-MM-DD-custom-fan-matrix-load.json   # if run
```

Schema suggestion:

```json
{
  "machine": "PH317-51",
  "bios": "V1.22",
  "points": [
    {
      "commandedPercentCpu": 60,
      "commandedPercentGpu": 60,
      "behaviorRaw": 0,
      "modeDecoded": 3,
      "cpuRpmMedian": 0,
      "gpuRpmMedian": 0,
      "heldSeconds": 60,
      "status": "PASS|FAIL",
      "notes": ""
    }
  ]
}
```

## Decision

| Result | Next step |
|---|---|
| Fail | Keep binary AUTO/MAX; close graduated-curve implementation |
| Pass idle only | Optional short load pilots; still no production policy |
| Pass idle + load | Design 3–4 step policy with hysteresis; new config keys; tests |

## Implementation sketch (post-gate only)

- States: `AUTO | STEP_n | MAX` with MAX still fail-closed.
- Independent CPU/GPU step tables.
- Reassert on mode/RPM mismatch; never infer health from write alone.
- Extend simulation tests with Custom transitions before live install.
