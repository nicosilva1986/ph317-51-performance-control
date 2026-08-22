# Proposal — limit telemetry (read-only)

> Estado: implementado en v0 por el sampler documentado en
> [limit-telemetry.md](limit-telemetry.md). La aceptación sobre hardware sigue
> pendiente.

## Problem

Fan policy optimizes temperature. Performance drops may come from package
power, current, GPU power/thermal, or the old artificial 28x cap—not from
insufficient airflow. Without a labeled “who is limiting” signal, fan and
Turbo work can be mis-aimed.

## Goal

A **read-only** sampler that records, alongside existing fan status:

- effective CPU frequency vs stock ratio envelope by active core count
- optional package power if available without privileged MSR writes
- GPU clocks, power draw, temperature via `nvidia-smi` when present
- coarse `limitReasonHypothesis`: `thermal | power | gpu | ratio_cap | unknown`

No fan writes, no power-plan changes, no MSR undervolt, no BD PROCHOT
toggles. Safe to run during Native Turbo validation and fan experiments.

## Suggested signals (Windows)

| Signal | Source (preferred) | Notes |
|---|---|---|
| CPU MHz / performance state | `Win32_PerfFormattedData_Counters_ProcessorInformation` or PDH | Per logical processor |
| Active core estimate | count of non-idle logical CPUs or C0 residency if available | Map to 38/36/35/34 envelope |
| CPU temp / fan | existing `AcerGamingFunction` path | Already in controller |
| GPU util, clocks, power, temp | `nvidia-smi --query-gpu=... --format=csv` | Fail soft if NVIDIA stack absent |
| WHEA | existing review process | Any new event fails the window |

Avoid requiring WinRing0 or third-party kernel drivers.

## Coarse `limitReasonHypothesis` heuristics (v0)

Document as **hypothesis only** in logs, not as ground truth:

1. `ratio_cap` — a sustained all-core ratio near 28x after Turbo migration is
   compatible with an artificial ratio cap and requires independent follow-up.
2. `thermal` — temp near critical while clocks fall.
3. `gpu` — GPU power or temp high while CPU cool and CPU clocks OK.
4. `power` — clocks fall while temps moderate (candidate for later PL study).
5. `unknown` — default.

## Deliverables

1. Implemented: read-only script under `src/powershell/telemetry/`, without an
   elevation assertion.
2. Implemented: sanitized JSONL under ProgramData by default; reviewed excerpts
   may enter `evidence/` separately.
3. Implemented: compact summary is emitted separately. The fan status JSON is
   never modified.

## Acceptance

- Runs without changing fan mode or power plan.
- Produces at least one complete sample on the reference machine with GPU
  under load and one under CPU-only FMA.
- Does not log secrets, full device instance IDs, or usernames.

No reference-machine sample was captured by the implementation change. The
CPU-only FMA and GPU-load windows remain pending, so issue acceptance is not
complete.

## Out of scope for this proposal

- Automatic PL1/PL2 changes
- Controllers that react to `limitReasonHypothesis` (later phase, after Native Turbo
  acceptance criteria in [native-turbo-plan.md](native-turbo-plan.md))
