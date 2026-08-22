# Limit telemetry v0 (read-only)

`Invoke-LimitTelemetry.ps1` records sanitized evidence for investigating CPU,
GPU, thermal, ratio-envelope, and WHEA behavior. It is an observer only. It
does not change fan mode, power policy, firmware, drivers, services, scheduled
tasks, the registry, or the adaptive fan controller status file.

## Read-only boundary

The sampler uses only shared reads of the controller status JSON, read-only
`Get-CimInstance` queries, one persistent `nvidia-smi` query process, and
bounded `Get-WinEvent` queries. Status reads request `ReadWrite|Delete` sharing
so controller replacement or update is never blocked. Missing, locked, denied,
invalid, absent, or interrupted providers produce null values and a short error
category; they do not stop the session.

The GPU provider keeps one child process at a time. If the full throttle-field
query exits, it retries with the identifier-free base fields after backoff;
after at most two restarts it gives up for that session and continues with null
GPU blocks.

The implementation and its AST gate prohibit:

- `Invoke-CimMethod`, `Invoke-WmiMethod`, `Set-CimInstance`, WMI instance
  mutation, and any OEM `AcerGamingFunction` call;
- fan-mode writes and every create/write/move/delete against
  `adaptive-fan-status.json`;
- `powercfg`, MSR read/write tools, WinRing0, ThrottleStop, voltage,
  current-limit, package-limit, BD PROCHOT, Turbo, or thermal-protection changes;
- service mutation and scheduled-task registration, mutation, start, stop,
  enablement, disablement, or removal;
- registry writes and driver or firmware changes;
- elevation checks or an administrative-rights requirement.

An AST gate enforces the command, method-invocation, type, and file-target parts
of this boundary in the sampler and its deterministic tests.

## Actions

From the repository root:

```powershell
# Start a detached one-hour session and return its opaque id and log path.
.\src\powershell\telemetry\Invoke-LimitTelemetry.ps1 -Action Start

# Add a safe label to delimit a measurement window.
.\src\powershell\telemetry\Invoke-LimitTelemetry.ps1 -Action Mark -Label 'fma-start'

# Signal stop and wait up to the bounded grace period for the final WHEA snapshot.
.\src\powershell\telemetry\Invoke-LimitTelemetry.ps1 -Action Stop

# Run for 60 seconds in the foreground.
.\src\powershell\telemetry\Invoke-LimitTelemetry.ps1 -Action Run -DurationSeconds 60

# Print one compact JSON summary without modifying the input.
.\src\powershell\telemetry\Invoke-LimitTelemetry.ps1 -Action Summarize -InputPath 'C:\ProgramData\PredatorLimitTelemetry\session-opaque.jsonl'
```

`-IntervalSeconds` defaults to 2 and accepts 1 through 60. Scheduling uses a
monotonic stopwatch and subtracts collection time from the wait, while every
new start is still based on at least one interval after the prior start.
`-StatusPath` overrides the read-only status source. `-LogPath` overrides the
telemetry directory; its default is
`C:\ProgramData\PredatorLimitTelemetry`. `-DurationSeconds` defaults to 3600.
`-GracePeriodSeconds` defaults to 15. `-WheaMaxEvents` defaults to 512.
`-MaxLogBytes` defaults to 8 MiB and `-MaxLogFiles` defaults to 5. Marker labels
must match `^[a-z0-9][a-z0-9._-]{0,63}$`.

`-SessionId` is reserved for the detached child invocation.
`-InternalTestHook` and `-TestFixturePath` are internal seams and are rejected
unless `PREDATOR_TELEMETRY_TEST_HOOK=1`; production use must not set that guard.

## Record schema

Every UTF-8-without-BOM JSONL record has LF termination and these top-level
fields: `schemaVersion`, opaque random `sessionId`, monotonic `sampleIndex`, UTC
`timestampUtc`, `recordType`, `status`, `cpu`, `gpu`, `marker`, `whea`,
`hypothesis`, `redactions`, and `errors`.

- `status` retains only fan mode, both RPMs, CPU/GPU temperature, timestamp age,
  and `statusError`.
- `cpu` retains only the selected formatted counters, selected processor clock
  and topology counts, derived effective MHz/ratio, active-core estimate, and
  the documented 1C/2C/3C/4C stock envelope of 38/36/35/34.
- `gpu` retains only numeric index, utilization, clocks, power, temperature,
  throttle booleans, and an error category. No GPU or device identifier is queried.
- `whea` contains start/end aggregates by numeric event id and level, plus only
  the newest UTC timestamp. It never contains event text or raw properties.

Synthetic sample, wrapped for readability although actual JSONL is compact:

```json
{
  "schemaVersion": 1,
  "sessionId": "8e6c548d309a4d2da9d2d2fe912d5be7",
  "sampleIndex": 4,
  "timestampUtc": "2026-08-22T15:00:08.0000000Z",
  "recordType": "sample",
  "status": {"cpuFanRpm": 3200, "gpuFanRpm": 3100, "cpuTempC": 74, "gpuTempC": 67, "timestampAgeSeconds": 0.4, "fanMode": "AUTO", "statusError": null},
  "cpu": {"effectiveMHz": 3388, "effectiveRatio": 33.88, "activeCoreEstimate": 4, "stockEnvelopeRatio": 34, "maxClockMHz": 2800, "currentClockMHz": 2800, "numberOfCores": 4, "numberOfLogicalProcessors": 8, "total": {"percentProcessorPerformance": 121, "percentProcessorTime": 82, "percentIdleTime": 18, "processorFrequencyMHz": 2800, "percentOfMaximumFrequency": 121, "percentPerformanceLimit": 0, "performanceLimitFlags": 0}, "logicalProcessors": [], "errorCategory": null},
  "gpu": {"index": 0, "utilizationGpuPct": 91, "utilizationMemoryPct": 32, "clockSmMHz": 1700, "clockMemoryMHz": 4000, "powerDrawW": 104.2, "powerLimitW": 120, "temperatureC": 78, "errorCategory": null, "throttle": {"active": false, "gpuIdle": false, "applicationsClocksSetting": false, "softwarePowerCap": false, "hardwareSlowdown": false, "hardwareThermalSlowdown": false, "hardwarePowerBrakeSlowdown": false, "syncBoost": false}},
  "marker": {"label": null},
  "whea": {"start": null, "end": null},
  "hypothesis": {"kind": "hypothesis", "limitReasonHypothesis": "unknown", "confidence": "low", "basis": ["no-v0-rule-matched"], "disclaimer": "Heuristic hypothesis, not a measured limit cause."},
  "redactions": {"record": 0},
  "errors": []
}
```

The sanitizer is the only JSONL writer path. It reconstructs each record from
an explicit whitelist, drops all other properties, and replaces usernames,
hostnames, GUIDs, PCI bus addresses, device-instance IDs, serial-like runs, and
absolute user/UNC paths with `[redacted]` or null. Each record reports its
redaction count.

## Summary and rotation

`Summarize` returns compact JSON with record/sample/marker counts, observed
duration, min/max/mean/p50/p95/p99 for effective ratio and temperatures plus
GPU power/temperature, total redactions, WHEA start-to-end deltas, error
categories, and the five-value hypothesis distribution.

Before an append would cross `-MaxLogBytes`, the active file is closed and
renamed inside the resolved telemetry directory. Older segments shift through
bounded numeric suffixes and only the oldest in-directory segment is deleted.
Each record is flushed as one complete LF-terminated byte sequence.

## Interpretation and validation status

`limitReasonHypothesis` is always nested in an object with `kind`, `confidence`,
short rule-id `basis`, and this exact disclaimer: “Heuristic hypothesis, not a
measured limit cause.” The v0 rules are intentionally coarse; null essential
inputs always produce `unknown` with low confidence.

This change captured no sample on the reference machine. CPU-only FMA and GPU
load marker windows remain pending hardware acceptance work; therefore these
mock-backed tests are not hardware validation.

Run deterministic tests without CIM, GPU tooling, event-log access, elevation,
stress, or hardware writes:

```powershell
pwsh -NoProfile -File .\tests\Test-InvokeLimitTelemetry.ps1
powershell.exe -NoProfile -ExecutionPolicy Bypass -File .\tests\Test-InvokeLimitTelemetry.ps1
pwsh -NoProfile -File .\tests\Test-LimitTelemetryForbiddenCommands.ps1
```
