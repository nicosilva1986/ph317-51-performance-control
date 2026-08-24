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
Two distinct mechanisms act on that counter, and only one of them is a reset:

- `releaseReset` — a sample **outside the thermal envelope**, a rapid rise, or
  `loadSamples >= preemptLoadSamples`. This zeroes `coolSamples`.
- `releaseIdleSample` — cool **and** under `releaseCpuLoadPct`. When temperature
  is fine but load is above 40 %, the counter neither resets nor increments: it
  **stalls**.

The published telemetry (one line per 15 polls, so a 1-in-15 subsample):

| Time | CPU load | CPU temp | coolSamples | loadSamples |
|------|----------|----------|-------------|-------------|
| 08:10:12 | 47 % | 60 °C | 1 | 0 |
| 08:10:49 | 16 % | 51 °C | 3 | 0 |
| 08:11:25 | 22 % | 43 °C | 10 | 0 |
| 08:12:01 | 10 % | 41 °C | **8** | 0 |
| 08:12:36 | 15 % | 55 °C | 21 | 0 |
| 08:13:02 | — | — | released | — |

`loadSamples` is **0 at every point**, so the sustained-demand reset never fired.
The 10 → 8 drop is still a reset: 18 polls separate those two lines, so the
counter must have gone to zero and climbed back to 8 in between. With the load
path excluded, the only remaining causes are a **thermal-envelope breach**
(> 65 °C) or a **rapid rise** (≥ 4 °C inside the 6 s window) landing on one of
the 14 polls that telemetry does not publish. The visible 41–60 °C readings are
a subsample, not a bound — the resume burst that showed 87 °C the previous
evening is exactly the kind of excursion that hides between two published lines.

So both terms extended the window, in different ways: **temperature excursions
reset** the evidence, and **load above 40 % stalled** its accumulation between
resets. Neither on its own explains 3 min 30 s; together they do.

## Interpretation

The stack behaved exactly as `AGENTS.md` requires:

> Invalid telemetry, state, integrity, or heartbeat must fail toward maximum cooling.

A 9-hour-stale heartbeat is unknown state. Assuming "hot until proven cool" is
the correct posture, and the verification that followed was real (`max_verified`
with RPM readback, then release only on measured cool samples). Nothing here
should be relaxed on the temperature side, and the thermal resets above are the
mechanism doing the actual safety work.

What is wrong is applying a **load** gate to the release of an *unproven startup
default* during the one window where load is guaranteed to be high for reasons
unrelated to heat. Load predicts heat that has not happened yet: that is the
right question when deciding to *enter* MAX, and the wrong one when deciding
whether a machine the sensors already show at 41 °C may leave a fail-safe it
adopted before it had read a single sample. The operator experiences a correct
safety mechanism as a malfunction, which is itself a cost — a safety behaviour
that reads as a fault invites the operator to disable the whole stack.

## Fix applied (2026-08-24)

Option 1 below, scoped strictly to the startup hold:

- New `startupReleaseIgnoresLoad` (default `true`): while `startupMaxHold` is in
  force, release evidence is `releaseThermalEnvelope` alone. Every thermal reset
  is retained unchanged.
- New `startupReleaseSamples` (default 15 = 30 s), separate from the 30 samples a
  triggered MAX still needs. Validated to never exceed `releaseSamples`.
- The `startupMinMaxSeconds` floor is untouched, so with `pollSeconds: 2` a clean
  resume now releases at the **60 s** floor rather than accumulating a second
  60 s of perfect samples on top of it. After a thermal reset the machine needs
  30 s of clean temperature instead of 60 s.

The triggered-MAX path (`sustained_cool_idle`) keeps the full load term and the
full `minMaxSeconds` residence — a MAX entered from measured heat is unchanged.

Two simulation cases guard the new behaviour:
`startup-max-releases-when-cool-but-busy` (cool silicon plus non-idle load must
release, and never before the floor) and
`startup-max-holds-outside-thermal-envelope` (dropping the load term must not let
a machine above `releaseCpuC` leave the hold, however idle). Full suite: 42/42.

### Options considered

1. **Drop the load term from the release gate once `startupMinMaxSeconds` has
   elapsed.** ← implemented. Temperature already bounds the decision.
2. **Exempt the first ~90 s after a resume from the load term.** Narrower, but
   needs a reliable resume signal inside the controller.
3. **Distinguish resume from cold boot** and use a shorter hold for resume — the
   heatsink is at ambient after a 9 h sleep, so the conservative hold buys little.
4. **Do nothing.** 3.5 min of noise per resume, correct and safe.

Still open: the thermal excursions that cause the resets are invisible in the
published telemetry. Raising `telemetryEverySamples` resolution during a startup
hold would confirm the mechanism directly rather than by elimination.

## What this rules out

- Not the thermal paste (idle floor 41–43 °C is healthy).
- Not a stuck embedded controller — the release wrote through cleanly and RPM
  readback followed it down to ~1 950.
- Not ThrottleStop, which has no fan control path on this platform.
- Not a failed install — the 08-23 secure install reported `PASS` with ACLs and
  hashes verified.
