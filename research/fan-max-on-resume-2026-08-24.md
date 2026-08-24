# Fans at maximum after resume — incident reconstruction (2026-08-24)

**Status:** closed, no code change made. Behaviour was correct by design;
the open question is whether the recovery window should be shortened.

**Reported symptom:** "the fan is running at 100 % after the restart."

**Finding:** not thermal, not hardware, not a stuck EC. The machine was cold
(CPU 55 °C, GPU 39 °C, system 37 °C, 15 % load) while both fans held
6 122 RPM. The cause was this project's own fail-closed startup hold, after the
watchdog correctly restarted a controller that had gone silent overnight.

---

## Timeline

All times local (-03:00), from `adaptive-fan.jsonl`, `watchdog.jsonl` and the
Windows System event log.

| Time | Source | Event |
|------|--------|-------|
| 08-23 23:01:35 | Kernel-General 13 | OS shutting down (operator restart) |
| 08-23 23:01:51 | Kernel-General 12 | OS started |
| 08-23 23:02:47 | watchdog | `watchdog_started` |
| 08-23 23:02:58 | controller | `controller_started`, `startupMaxHold: true`, state MAX |
| 08-23 23:03:00 | watchdog | `primary_restarted`, heartbeat stale 81.5 s |
| 08-23 23:03:10 | controller | `max_verified` 6 122 / 6 122 RPM |
| 08-23 23:03:36 | controller | CPU **87 °C** at 84 % load — logon burst, MAX genuinely warranted |
| 08-23 23:04:58 | controller | last telemetry before sleep, CPU 77 °C |
| 08-23 23:04:58 | Kernel-Power 42 | **system entering sleep** |
| 08-24 08:09:03 | Kernel-General 1 | system time jumped ~9 h — resume |
| 08-24 08:09:07 | Power-Troubleshooter 1 | "system was in a low power state and resumed" |
| 08-24 08:09:32 | controller | `controller_started`, `startupMaxHold: true`, state MAX |
| 08-24 08:09:33 | watchdog | `primary_restarted`, **heartbeat stale 32 646.3 s** |
| 08-24 08:09:48 | controller | `max_verified` 6 122 / 6 122 RPM |
| 08-24 08:13:02 | controller | `profile_changed` MAX → AUTO, `startup_max_released_on_verified_cool` |
| 08-24 08:13:12 | controller | AUTO, 2 290 / 2 255 RPM, CPU 43 °C |

Time spent at maximum RPM on a cold machine: **3 min 30 s**.

The 32 646 s stale heartbeat maps exactly onto the sleep interval
(23:05 → 08:09 ≈ 9 h 04 m). The controller did not crash; it was suspended with
the machine and never resumed its sampling loop.

## Why it held MAX for 3.5 minutes instead of ~60 s

Relevant config (`fan-controller-config.json`):

```
pollSeconds:            2
startupMinMaxSeconds:   60
releaseSamples:         30      -> 30 x 2 s = 60 s of consecutive cool samples
releaseCpuC:            65
releaseCpuLoadPct:      40
```

Release requires 30 **consecutive** samples that are cool *and* below 40 % CPU.
The post-resume Windows burst violated the load term repeatedly:

| Time | CPU load | CPU temp | coolSamples |
|------|----------|----------|-------------|
| 08:10:12 | 47 % | 60 °C | 1 |
| 08:10:49 | 16 % | 51 °C | 3 |
| 08:11:25 | 22 % | 43 °C | 10 |
| 08:12:01 | 10 % | 41 °C | **8** ← counter reset |
| 08:12:36 | 15 % | 55 °C | 21 |
| 08:13:02 | — | — | released |

Temperature was never the obstacle — it sat between 41 °C and 60 °C against a
65 °C release threshold the whole time. The **load term** was the obstacle, and
the load in question was Windows finishing its own resume, not the operator's
work.

## Interpretation

The stack behaved exactly as `AGENTS.md` requires:

> Invalid telemetry, state, integrity, or heartbeat must fail toward maximum cooling.

A 9-hour-stale heartbeat is unknown state. Assuming "hot until proven cool" is
the correct posture, and the verification that followed was real (`max_verified`
with RPM readback, then release only on measured cool samples). Nothing here
should be relaxed on the temperature side.

What is arguably wrong is applying a **load** gate to the release decision during
the one window where load is guaranteed to be high for reasons unrelated to
thermals. The operator experiences a correct safety mechanism as a malfunction,
which is itself a cost — a safety behaviour that reads as a fault invites the
operator to disable the whole stack.

## Options considered (none implemented)

1. **Drop the load term from the release gate once `startupMinMaxSeconds` has
   elapsed.** Temperature already bounds the decision; load is a proxy for
   *predicted* heat, which matters when entering MAX, not when leaving a startup
   hold on a cold machine. Simplest, keeps the thermal guarantee intact.
2. **Exempt the first ~90 s after a resume from the load term.** Narrower, but
   needs a reliable resume signal inside the controller.
3. **Distinguish resume from cold boot** and use a shorter hold for resume — the
   heatsink is at ambient after a 9 h sleep, so the conservative hold buys little.
4. **Do nothing.** 3.5 min of noise per resume, correct and safe.

Recommendation: option 1, gated on a measured run showing release still occurs
only when genuinely cool. Not urgent — it is a comfort defect, not a safety one.

## What this rules out

- Not the thermal paste (idle floor 41–43 °C is healthy).
- Not a stuck embedded controller — the release wrote through cleanly and RPM
  readback followed it down to ~1 950.
- Not ThrottleStop, which has no fan control path on this platform.
- Not a failed install — the 08-23 secure install reported `PASS` with ACLs and
  hashes verified.
