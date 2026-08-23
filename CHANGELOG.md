# Changelog

## Unreleased

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
