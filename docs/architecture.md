# Architecture

## Principles

1. **One writer per control plane.** Only the fan controller writes Acer fan state. Intel HWP/Windows owns CPU frequency selection.
2. **Fail closed toward cooling.** Invalid telemetry, stale heartbeat, damaged state, or integrity failure requests `MAX`.
3. **Observed state beats requested state.** A successful WMI return is not enough; mode and RPM are read back.
4. **Hysteresis beats oscillation.** Enter `MAX` quickly, remain there for a minimum interval, and release only after sustained cool idle.
5. **Every privileged update is transactional.** Prevalidate, pin hashes, force `MAX`, install side by side, verify, then retire the old version.
6. **No security trade hidden as performance tuning.** VBS/HVCI, UAC configuration, thermal protection and BitLocker are outside automatic tuning.

## Fan policy

Current performance-first candidate:

- poll every 2 seconds;
- enter after 2 consecutive samples when any condition is true:
  - CPU ≥60 °C;
  - GPU ≥55 °C;
  - system ≥55 °C;
  - total CPU ≥30 %;
  - any logical CPU ≥70 %;
  - rise ≥4 °C in 6 seconds after reaching 55 °C;
- immediate `MAX` at CPU/GPU ≥75 °C or system ≥70 °C;
- optional proportional band (`curveEnabled`, ships **false**): when demand is not critical the
  controller drives firmware CUSTOM mode at an interpolated percentage instead of 100 %. Linear
  between `curveMinTempC`/`curveMinPct` and `curveMaxTempC`/`curveMaxPct`, driven by the hotter of
  the CPU and GPU sensors averaged over `curveAverageSamples` polls, quantised upward to
  `curveStepPct`. Increases apply on the sample that justifies them; reductions wait
  `curveDecreaseHoldSeconds` and then a further `curveDecreaseHysteresisC` below the temperature
  that still justified the previous step. `curveStartPct` is the spin-up floor for the first
  command. Critical temperature, sensor failure, readback failure and every watchdog recovery path
  keep commanding 100 %, so the fail-closed guarantee is unchanged;
- fail-safe `MAX` after 3 invalid samples;
- minimum `MAX` residence: 5 minutes for every `MAX` entered from a trigger;
- the `MAX` adopted at process start, before the controller has read a single sample, is an unproven fail-safe default rather than a response to measured heat. It uses the separate `startupMinMaxSeconds` floor (60 s) and still requires the full 2 minutes of qualifying idle samples, so it releases on verified cool telemetry instead of holding the fans at 6122 RPM for 5 minutes after every restart. Any trigger firing during that window promotes the hold to the full 5-minute residence;
- return to `AUTO` only after the 5-minute minimum `MAX` residence and 2 minutes of qualifying idle samples inside the CPU 55 °C, GPU 50 °C (or absent), system 50 °C and total CPU 20 % release envelope, with a stable trend at the transition instant; a transient non-idle sample pauses accumulation, while sustained demand, rapid thermal rise, or leaving the thermal envelope resets it;
- verify every `AUTO` write with a bounded post-write firmware readback before publishing the new state; stale or invalid readback requests `MAX` and reports a degraded fail-safe state;
- reassert after two consecutive mode/RPM mismatches.
- on `MAX + REASSERT_PENDING`, the controller remains the only privileged writer during the protected `verifyMaxAfterSeconds` interval; if the condition persists for at least two observations, the watchdog stops the controller, acquires its named write lease, requests `MAX`, releases the lease and only then restarts the controller. `AUTO + REASSERT_PENDING` is fatal and uses that same quiesced recovery path, while stale, malformed and integrity failures retain immediate fail-safe handling.
- a heartbeat the watchdog could not read at all — absent, empty or unparseable — is classified `TRANSIENT`, not fatal. The controller republishes that file every poll, so a lost read race is not evidence that it stopped. Recovery runs once the condition persists across `TransientHeartbeatTolerance` consecutive polls. A heartbeat that reads cleanly but is stale, malformed or semantically wrong is still real evidence and recovers on its first observation.
- the controller publishes the heartbeat with an atomic `File.Replace` and the watchdog reads it sharing write and delete, so neither side can observe or cause a gap in the file.
- restart verification accepts either a consistently `Running` task or a heartbeat published after the restart mark, within `PrimaryStartTimeoutSeconds`. Declaring failure while the controller is in fact alive makes the watchdog stop it again on the next poll, which pins the fans at `MAX` with no primary.
- `RECOVERY_FAILED` leaves the fans at `MAX` with the primary stopped, so consecutive failures escalate: after `RecoveryReregisterThreshold` of them the watchdog rebuilds the scheduled task from the trusted definition instead of repeating a restart that cannot work.

The reference firmware returns compact behavior values `256` for Auto and `512` for Max. The controller decodes CPU mode as `(raw >> 8) & 3` and also requires both fans ≥5000 RPM before declaring Max verified.

## Components

```text
Windows startup/resume
        |
        +--> Fan controller (SYSTEM, 2 s loop)
        |       |--> AcerGamingFunction WMI/ACPI
        |       +--> atomic status + bounded logs
        |
        +--> Watchdog (SYSTEM, independent heartbeat)
                |--> integrity + task + semantic status checks
                +--> emergency MAX + controlled restart

Intel HWP / Windows power policy
        +--> stock ratios 38/36/35/34 by active core count
        +--> EPP/boost policy, no custom multiplier daemon
```

## Boot-storage driver transaction

```text
schema-v3 producer
  -> dual sealed backup + six hashed implementation artifacts
  -> removal executor (fresh boot/live gates)
  -> bounded BitLocker suspension
  -> one exact PnPUtil delete attempt
  -> require exit 0/3010 plus independent exact live state
  -> live classify: LEGACY_INTACT | CLEAN_PREBOOT | MIXED/BROKEN
       | clean + all gates -> dual REBOOT_AUTHORIZED -> manual reboot
       | legacy           -> protect BitLocker and close
       | mixed            -> independently validate backup, then rollback
  -> postboot validator -> STABILITY_PENDING | SAFE_RESIDUAL | PROTECTED_DIAGNOSTIC_HOLD
  -> later distinct stable boot + separately reviewed baseline restoration -> COMPLETE
```

The journal is append-only and dual-root. Only the common byte-identical prefix is committed authority. Interruption recovery observes live state and never infers that an intent completed; specifically, it cannot replay driver deletion. A machine-wide protected mutex prevents concurrent writers, and entrypoints must execute from the sealed implementation directory.

The current transaction intentionally stops at `POSTBOOT_STABILITY_PENDING`; it does not disable WinRE or System Restore on the first successful boot. Baseline restoration is a separate follow-up contract because disabling System Restore removes provisional restore points.

## Non-goals

- direct embedded-controller register writes;
- all-core 38x on a locked i7-7700HQ;
- disabling BD PROCHOT or thermal throttling;
- universal support inferred from one Acer WMI implementation;
- automatic voltage, PL1/PL2/PL4, IccMax, BIOS, or driver changes.
