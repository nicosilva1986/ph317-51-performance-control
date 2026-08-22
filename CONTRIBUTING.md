# Contributing

Open an issue with:

- exact Acer model and BIOS;
- Windows build;
- CPU/GPU;
- sanitized WMI class/method availability;
- reproducible baseline and proposed change;
- rollback plan;
- test evidence, including temperatures and WHEA.

Do not upload OEM packages or raw support bundles. A pull request that changes privileged control logic must include isolated simulations for every affected trigger/failure path and a clear statement of what was and was not tested on physical hardware.

Public support for another model requires explicit detection and refusal on unsupported devices; similar WMI method names are not sufficient compatibility proof.
