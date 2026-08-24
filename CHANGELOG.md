# Changelog

## Unreleased

- Enabled the proportional fan band with a calibration measured on the reference machine, replacing the binary Acer-AUTO-or-6122-RPM policy. Acer's stock curve tops out at 4761 RPM of the 6122 available and goes flat between 65 °C and 89 °C, sitting at 3370 RPM while the package climbs to 92 °C. The band starts exactly where MAX used to be entered and reaches 100 % before the critical threshold.
- Calibrated conservatively: 65 °C → 55 % and 85 °C → 100 %, which lands within 117 RPM of Acer at 65 °C and roughly 2400 RPM above it across the plateau. Matching Acer where Acer still works is what keeps the machine from becoming audible at light load.
- Moved the thresholds the band depends on: `maxCpuC`/`maxGpuC` 72 → 65, `releaseCpuC`/`releaseGpuC` 65 → 60, `preemptTemperatureC` 62 → 56. Entry could come down because entering the band no longer costs full noise; the validator's `preemptTemperatureC < releaseCpuC < maxCpuC <= criticalCpuC` ordering forced the rest.
- Made the test harness pin `curveEnabled` per case instead of inheriting the shipped default. Leaving it implicit meant the meaning of a case depended on a value the calibration is free to change: when the default flipped, cases written against the AUTO/MAX policy silently began asserting against the proportional one.
- Derived every curve expectation from the policy. Temperatures like 46/50/60/70 and percentages like 30/45/65/80/90 were pinned to the 45–75 °C / 30–100 % calibration, so recalibrating read as a broken curve rather than a moved one. The brief-drop case now sizes its drop from `curveDecreaseHoldSeconds`, because band entry is temperature-driven now and happens earlier than the load-driven entry it was written against.
- Added `curve-calibration-contract` and `shipped-calibration-enters-curve`. Suite at 44 cases, green in both PowerShell engines.

- Stopped the startup fail-safe from holding maximum RPM on a machine the sensors already show is cold. On 2026-08-24 a 9-hour sleep left the primary heartbeat stale by 32646 seconds; the watchdog restarted it, the controller adopted its unproven `startupMaxHold` MAX, and both fans ran 6122 RPM for 3 minutes 30 seconds with the package between 41 °C and 60 °C.
- Scoped the cause precisely: `loadSamples` was 0 at every published sample, so the sustained-demand reset never fired. Temperature excursions hidden between telemetry lines reset the cool counter, and the Windows resume burst above `releaseCpuLoadPct` (40 %) stalled its accumulation in between. Load predicts heat that has not happened yet — the right question when entering MAX, the wrong one when leaving a default adopted before the controller read a single sample.
- Added `startupReleaseIgnoresLoad` (default true): while `startupMaxHold` is in force, release evidence is the thermal envelope alone. Every thermal reset — envelope breach, rapid rise, sustained demand — is retained unchanged.
- Added `startupReleaseSamples` (default 15 = 30 seconds), separate from the 30 samples a triggered MAX still needs, and validated to never exceed `releaseSamples`. With `startupMinMaxSeconds` untouched, a clean resume now releases at the 60-second floor instead of stacking a second 60 seconds of perfect samples on top of it.
- Left the triggered-MAX path alone: a MAX entered from measured heat keeps the full load term and the full `minMaxSeconds` residence. Guarded by two new simulation cases — `startup-max-releases-when-cool-but-busy` and `startup-max-holds-outside-thermal-envelope` — with the suite at 42/42 in both PowerShell engines.
- Corrected `research/fan-max-on-resume-2026-08-24.md`, which had attributed the whole 3.5-minute window to the load term. Resets and stalls are separate mechanisms and the note now distinguishes them.

- Recalibrated the fan policy so maximum RPM means a machine that is genuinely hot and genuinely busy. Demand now needs CPU ≥72 °C (was 60 °C), or a logical core ≥95 % (was 70 %) sustained for 20 seconds (was 4 seconds), across 3 consecutive samples (was 2). Critical stays immediate at 85 °C (was 75 °C).
- Made the release envelope reachable. It was CPU ≤55 °C with 2 minutes of unbroken idle, and a normally loaded machine crosses 55 °C every minute or two, so the countdown was reset before it could finish. Now CPU ≤65 °C with 60 seconds, and the minimum MAX residence drops from 5 minutes to 2.
- Kept `preemptTemperatureC` (62 °C) below `releaseCpuC` (65 °C) on purpose: above it, the thermal-envelope check would always fire first and the rapid-rise trigger would be unreachable.
- Derived the controller simulation fixtures from the policy instead of hard-coding them, so a future recalibration does not mean rewriting forty cases by hand, and added contract assertions that reject a calibration which would again force MAX on a warm idle.

- Added an optional proportional fan band so demand no longer means 6122 RPM. Firmware CUSTOM mode (fan mode 3) carries a real percentage, and the controller interpolates it linearly from the hotter of the CPU and GPU sensors. Measured motivation: 59.6 % of a 35.5-hour window at maximum RPM with a median CPU temperature of 42 °C.
- Borrowed the shape from established fan controllers: linear interpolation with clamping (lm-sensors `fancontrol`), a moving average over the temperature source, asymmetric response — immediate increases, damped decreases — and a falling hysteresis measured from the lower edge of the current step (FanControl), plus a `curveStartPct` spin-up floor (`MINSTART`).
- Kept the policy behind `curveEnabled`, which ships **false**. With it off the controller is behaviourally identical to the AUTO/MAX policy, which the 26 pre-existing simulation cases still prove.
- Taught the watchdog that `CURVE` is a legitimate driving state, verified against firmware mode 3 and a `curveMinimumVerifiedRpm` floor. Without this every proportional episode would read as a dead controller and be answered with MAX.
- Left the `0x00C30009` CUSTOM payload and the percent-to-RPM relationship unvalidated on real hardware; that measurement is still outstanding and is why the curve ships disabled.

- Fixed a watchdog recovery loop that held the fans at maximum RPM. Over a measured 35.5-hour window the machine spent 59.6 % of its time in `MAX` with a median CPU temperature of 42 °C during that time; 32 of 68 `MAX` episodes began at a controller restart and 30 of those 32 restarts coincided with a watchdog recovery event.
- Classified an unreadable heartbeat as transient instead of fatal. Absent, empty or unparseable status documents are debounced across `TransientHeartbeatTolerance` consecutive polls; stale, malformed or semantically invalid heartbeats keep recovering on first observation.
- Published the controller heartbeat with an atomic `File.Replace` and read it sharing write and delete, closing the `Move-Item -Force` window that made the watchdog observe its own reader race as a dead controller.
- Widened restart verification to `PrimaryStartTimeoutSeconds` and accepted a heartbeat newer than the restart mark as proof of life. The previous gate required five consecutive `Running` samples inside five seconds and never succeeded in production: 38 `primary_recovery_error` events against 8 `primary_restarted`.
- Waited for the primary task to leave `Running` after a stop, so the following start is not discarded by `MultipleInstances IgnoreNew`.
- Escalated repeated recovery failures to a task rebuild instead of retrying a restart that cannot work while the fans stay at `MAX`.
- Added `startupMinMaxSeconds` (60 s) so the unproven fail-safe `MAX` adopted at controller start releases on verified cool telemetry rather than holding 6122 RPM for the full 5-minute residence after every restart. Triggered `MAX` keeps the 5-minute floor unchanged.

- Recorded the PH317-51 hardware/driver baseline and cross-OEM bindings.
- Validated direct Acer WMI/ACPI fan control at 6122 RPM on both fans.
- Measured a 12 °C maximum-temperature reduction and 8.5 % throughput increase versus Auto under an identical ten-minute FMA workload.
- Demonstrated final-controller recovery from an external Auto override in 4.190 seconds.
- Demonstrated watchdog recovery from a deliberately stopped primary task in 7.970 seconds, returning to verified Max mode at 6122/6122 RPM.
- Identified the artificial 28x ThrottleStop cap and documented stock 38/36/35/34 ratios.
- Identified the loaded ThrottleStop.sys 3.0.0.0 security exposure and chose native Intel/Windows control for the permanent design.
- Began hardening the controller/watchdog installer after adversarial review found fail-open and nontransactional update paths.
- Added the schema-v3 CRUWBlocker maintenance transaction: six sealed implementation artifacts, dual durable journal, bounded BitLocker handling, no-force removal, interruption recovery without delete replay, postboot validation and cross-engine PowerShell simulations.
- Restricted PnPUtil success handling to documented exit codes 0/3010 plus independent live-state proof; all contradictory or undocumented results enter a protected diagnostic hold.
- Made the first green postboot result a non-final stability checkpoint; recovery facilities remain enabled until a later separately reviewed finalization.
- Recorded sanitized evidence that Windows repeatedly promoted the signed CRUW demand-start INF service to boot-start, while retaining exact live-state proof as the only rollback authority.
