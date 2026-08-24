# Handoff — state of play

Last updated: **2026-08-24**

Living document. It answers, for whoever picks this up next: what is actually
running on the reference machine, which levers were proven to work, which were
proven dead, and what is safe to remove.

Implementation detail lives in the rest of `docs/`; investigation lives in
`research/`. This file is the short version with the conclusions.

---

## 1. What is deployed right now

| Component | Location | State |
|-----------|----------|-------|
| Adaptive fan controller (primary writer) | `%ProgramData%\AcerAdaptiveFanControl` | Running, `HEALTHY_VERIFIED` |
| Fan watchdog (supervisor) | same folder | Running |
| Rollback snapshot | `%ProgramData%\AcerAdaptiveFanControl-Rollback` | Present, install id `20260823-121745` |
| Deployment journal | `%ProgramData%\AcerAdaptiveFanDeployments` | Present |
| Published status (read-only, unprivileged) | `adaptive-fan-status.json` | Fresh |

Routine health check stays `src/powershell/fan/Get-AcerFanAgentStatus.ps1`.
Do not query the protected scheduled tasks directly (see `AGENTS.md`).

Secure install of 2026-08-23 reported `status: PASS`, `aclVerified: true`,
`hashesVerified: true`, no rollback needed.

---

## 2. The one lever that is proven to work

**Forcing fans to maximum via `AcerGamingFunction` WMI/ACPI.**

Measured on the reference machine (`evidence/benchmarks/2026-08-21-fan-auto-vs-max.json`),
10 min sustained AVX2/FMA matrix multiply, CPU pinned at 28x:

| | Acer Auto fans | Forced Max fans | Delta |
|---|---|---|---|
| Max CPU temp | 91.0 °C | 79.0 °C | **-12.0 °C** |
| Average CPU temp | 86.8 °C | 76.3 °C | **-10.5 °C** |
| Iterations completed | 153 | 166 | **+8.5 %** |
| WHEA events | 0 | 0 | — |

This is the project's justification. Acer's stock Auto curve lets the part sit
in the high 80s / low 90s under sustained load; the fan overlay buys ~12 °C and
~8.5 % throughput with no stability cost.

---

## 3. Levers that are proven dead — do not spend more time here

### 3.1 CPU undervolt via ThrottleStop — **blocked by firmware**

A -99.6 mV offset is configured on core and cache of the active profile
(`FIVRVoltage00` / `FIVRVoltage20` = `0xF3400000`, `UnlockVoltage00/20 = 1`)
and ThrottleStop accepts it in the UI without error.

**It never reaches the silicon.** VID sampled under load at a fixed 28x
multiplier is flat across a full month spanning the change:

| Date | Samples | Mean VID at 28x |
|------|---------|-----------------|
| 2026-07-23 | 9 651 | 0.9213 V |
| 2026-07-25 | 6 320 | 0.9255 V |
| 2026-07-27 | 19 115 | 0.9263 V |
| 2026-08-21 | 2 897 | 0.9270 V |
| 2026-08-22 | 5 012 | 0.9356 V |
| 2026-08-23 | 53 | 0.9250 V |

Total spread 14 mV — binning and sampling noise. A working -100 mV offset would
show as a ~100 mV step down to roughly 0.82 V. There is no step.

Cause: the CVE-2019-11157 ("Plundervolt") mitigation. Acer's Kaby Lake microcode
makes MSR `0x150` writes a silent no-op. Nothing in software can re-open it;
this is a firmware decision, not a configuration mistake.

**Consequence:** ThrottleStop has no undervolt value on this machine. It is
still useful as a *logger* (the VID/FID/temperature history above is what made
this determination possible) and for multiplier caps, but it will never lower
voltage here. See `research/undervolt-effectiveness-2026-08-24.md`.

### 3.2 GPU undervolt via Afterburner — **measured regression, revert it**

Before/after under a 180 s loaded run:

| Metric | Before | After | Verdict |
|--------|--------|-------|---------|
| Mean SM clock | 1388 MHz | 1261 MHz | **-127 MHz (-9.2 %)** |
| P05 SM clock | 1341 MHz | 1227 MHz | -114 MHz |
| Mean power | 81.7 W | 83.6 W | **higher** |
| % time power-capped | 64 % | 78.8 % | **worse** |
| % time thermal-capped | 0 % | 0 % | never the binding limit |
| Max temp | 86 °C | 83 °C | -3 °C |

A correct undervolt trades voltage for *more* clock at the same power. This one
lost 9 % of clock while drawing slightly more power and hitting the power cap
more often — the V/F curve was flattened at too low a point. The 3 °C is bought
with performance, and the GPU was never thermally capped to begin with.

**Action:** revert the Afterburner V/F curve to stock. Do not re-apply without a
run that shows clock held or improved.

### 3.3 Thermal paste — not the problem

MX-6, applied ~2025-08. Idle package temperature after resume settles at
**41–43 °C** with fans at ~1 950 RPM. That is a healthy mount; degraded paste
shows up as a high idle floor and it is not present. Repasting would not move
the numbers that matter here.

---

## 4. Open incident closed on 2026-08-24 — fans at 100 % after resume

Reported symptom: fans at full speed after restarting the machine.

Not a fault, and not thermal. Full reconstruction in
`research/fan-max-on-resume-2026-08-24.md`. Summary:

1. Machine slept overnight; the controller stopped sampling with it.
2. On resume the watchdog saw the heartbeat stale by 32 646 s (~9 h 04 m) and
   restarted the primary controller — correct fail-closed behaviour.
3. A restarted controller enters `startupMaxHold`: fans are pinned at maximum
   until the machine is *verified* cool. Invalid or unknown state must fail
   toward maximum cooling (`AGENTS.md`), so a cold boot into MAX is by design.
4. Release needs 30 consecutive cool samples at 2 s. Temperature excursions
   hidden between published telemetry lines **reset** that counter, and the
   Windows resume burst (47 % load, above `releaseCpuLoadPct: 40`) **stalled**
   its accumulation in between. `loadSamples` was 0 throughout, so the
   sustained-demand reset never fired.
5. Released cleanly at 08:13:02, `startup_max_released_on_verified_cool`.
   Fans dropped 6 122 → ~1 950 RPM. Total noise window **3 min 30 s**.

The design held. The cost is up to a few minutes of full-speed fans on every
resume-from-sleep, which reads to the operator as a failure.

**Fixed on 2026-08-24.** While `startupMaxHold` is in force the release
evidence is now temperature-only (`startupReleaseIgnoresLoad`, default true) and
needs `startupReleaseSamples` (15 = 30 s) rather than the full 30. The
`startupMinMaxSeconds` floor is untouched, so a clean resume releases at the
**60 s** floor instead of stacking a second 60 s of perfect samples on top.

Every thermal reset is retained, and the triggered-MAX path is unchanged: a MAX
entered from measured heat still keeps the full load term and the full
`minMaxSeconds` residence. Guarded by `startup-max-releases-when-cool-but-busy`
and `startup-max-holds-outside-thermal-envelope`; suite 42/42 in both engines.

Not yet verified on hardware — needs one real suspend/resume cycle to confirm
the 60 s release in the field.

---

## 5. Where the remaining headroom is

Ranked by expected value now that undervolt is off the table:

1. **Nothing further on CPU voltage.** Firmware-locked. Closed.
2. **Confirm the resume fix on hardware** (§4) — one suspend/resume cycle,
   checking `profile_changed` lands ~60 s after `controller_started`.
3. **Proportional fan curve — built, calibrated, NOT YET DEPLOYED.** See §7.
4. **Limit telemetry** — read-only sampler on branch
   `codex/issue-9-limit-telemetry-read`. Tells us *which* limit binds
   (power, thermal, current) instead of inferring it.
5. **Physical** — fan/heatsink dust removal is the only untried hardware lever;
   paste is fine (§3.3).

---

## 6. Standing constraints

Unchanged from `AGENTS.md`, restated because they bound everything above:

- One privileged writer per control plane.
- Invalid telemetry, state, integrity or heartbeat **must** fail toward maximum
  cooling. The 100 %-fan behaviour in §4 is this rule working, not a bug.
- No BIOS, PL1/PL2/PL4, IccMax, voltage or thermal-protection changes as part of
  routine fan/power work.
- No readback, no success claim.

---

## 7. Proportional band — state as of 2026-08-24

**Measured and settled.** Firmware CUSTOM mode is `CUSTOM_VALIDO`: 40/60/80/100 %
returned 3000/4285/5454/6122 RPM, monotonic, fan mode held at 3 for all 80
samples. Acer's own AUTO tops out at **4761 RPM** of 6122 and goes **flat
between 65 °C and 89 °C** (~3370–3846 RPM) while letting the package reach
92 °C. Details in `research/acer-auto-curve-and-custom-mode-2026-08-24.md`.

**Calibration shipped in the repo** (conservative: match Acer where Acer still
works, attack the plateau):

| CPU °C | Acer stock | This calibration |
|--------|-----------|------------------|
| 65 | 3846 | 3963 |
| 70 | ~3800 | 4869 |
| 75 | 3370 | **5454** |
| 80 | 3370 | **5788** |
| 85+ | 3750 | **6122** |

`curveMinTempC 65 → curveMinPct 55`, `curveMaxTempC 85 → curveMaxPct 100`,
`maxCpuC 65`, `releaseCpuC 60`, `curveEnabled true`.

**One structural bug found and fixed the same day.** The band was enabled,
calibrated, and never engaged once: release only ever targets AUTO and is gated
on `releaseCpuC`, so a machine that stays busy never leaves the startup MAX, and
the band is only entered from AUTO. Measured: 32 consecutive samples at
64–82 °C with `coolSamples` at 0 and `curvePercent` at 0 while the fans held
6122 RPM. The startup MAX now hands over to the band once its floor elapses —
a critical sample still commands MAX, and `curveEnabled false` is unchanged.

### Outstanding — in order

1. **Deploy it.** `tools/EJECUTAR-Desplegar.cmd`. Until this runs the machine
   keeps the old controller and the table above does nothing. This is the only
   item blocking the feature from being real.
2. **Stress test.** `tools/EJECUTAR-StressTest.cmd` — CPU (same NumPy FMA
   workload as the 2026-08-21 benchmark, so iterations compare against the 166
   of forced MAX) then CPU+GPU, which no measurement here has covered yet.
3. **Confirm the resume fix on hardware** (§4). Never verified in the field:
   one suspend/resume cycle, checking `profile_changed` lands ~60 s after
   `controller_started`.
4. **Push `docs/handoff-2026-08-24` and open the PR.** Nine commits local.

### Known interference

A recursive BIOS-file scan (`*.fd`, `*.rom`, `*.cap` across `C:\Windows`,
`AppData`, `ProgramData`) was running from another session at 99 % CPU during
the 2026-08-24 work, holding the package at 79–82 °C. Any thermal measurement
taken while something like that runs describes the scan, not the fan policy.
Check `Win32_Process` for unexpected load before trusting a run.
