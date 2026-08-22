# Lab tools

Scripts that are **not** installed as SYSTEM fan services:

- Custom fan % matrix ([docs/fan-curve-experiment.md](../../../docs/fan-curve-experiment.md))
- Limit telemetry sampler ([docs/limit-telemetry-proposal.md](../../../docs/limit-telemetry-proposal.md))
- One-off WMI probes

They should import `PredatorPh317.Core` / `PredatorPh317.Wmi` once those
modules are implemented, and must default to fail-closed Max if they write
fan state at all.
