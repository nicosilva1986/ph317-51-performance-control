# Changelog

## Unreleased

- Added the mock-tested, read-only limit telemetry v0 sampler with sanitized JSONL, bounded rotation, WHEA aggregates, GPU fail-soft collection, hypothesis summaries, and an AST prohibition gate; reference-machine FMA/GPU windows remain pending.
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
