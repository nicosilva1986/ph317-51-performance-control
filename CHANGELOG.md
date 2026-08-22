# Changelog

## Unreleased

- Recorded the PH317-51 hardware/driver baseline and cross-OEM bindings.
- Validated direct Acer WMI/ACPI fan control at 6122 RPM on both fans.
- Measured a 12 °C maximum-temperature reduction and 8.5 % throughput increase versus Auto under an identical ten-minute FMA workload.
- Demonstrated final-controller recovery from an external Auto override in 4.190 seconds.
- Demonstrated watchdog recovery from a deliberately stopped primary task in 7.970 seconds, returning to verified Max mode at 6122/6122 RPM.
- Identified the artificial 28x ThrottleStop cap and documented stock 38/36/35/34 ratios.
- Identified the loaded ThrottleStop.sys 3.0.0.0 security exposure and chose native Intel/Windows control for the permanent design.
- Began hardening the controller/watchdog installer after adversarial review found fail-open and nontransactional update paths.
