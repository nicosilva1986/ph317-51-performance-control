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
- fail-safe `MAX` after 3 invalid samples;
- minimum `MAX` residence: 5 minutes;
- return to `AUTO` only after 5 minutes simultaneously below CPU 55 °C, GPU 50 °C (or absent), system 50 °C, total CPU 20 %, and stable trend;
- reassert after two consecutive mode/RPM mismatches.

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

## Non-goals

- direct embedded-controller register writes;
- all-core 38x on a locked i7-7700HQ;
- disabling BD PROCHOT or thermal throttling;
- universal support inferred from one Acer WMI implementation;
- automatic voltage, PL1/PL2/PL4, IccMax, BIOS, or driver changes.
