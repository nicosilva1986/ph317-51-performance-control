# tools — laboratory launchers

Attended, elevated operations. Double-click the `.cmd`; it requests elevation
itself, and the window **stays open** at the end so a failure is readable
instead of vanishing. Each run also writes a transcript next to the script
(`*.log`, git-ignored — transcripts carry the machine name).

Do not wire any of these into a scheduled task. They are meant to be watched.

| Launcher | What it does | Needs |
|----------|--------------|-------|
| `EJECUTAR-Medicion.cmd` | Measures Acer's stock fan curve, then validates firmware `CUSTOM` mode | admin, ~25 min, **presence** |
| `EJECUTAR-Limpieza.cmd` | Removes Afterburner/RivaTuner/HWiNFO, unpins ThrottleStop from startup, deploys the fan controller | admin, ~5 min |

## EJECUTAR-Medicion.cmd

Implements [../docs/fan-curve-experiment.md](../docs/fan-curve-experiment.md).

**Phase 1 — Acer's stock curve.** Pauses the fan agent, sets `AUTO`, loads all
eight threads and samples temperature and RPM every 2 s, then measures the
cool-down. Writes only `AUTO`, which the agent already writes daily, so this
phase carries no more risk than normal operation.

It exists because the production telemetry is **censored above 74 °C**: the
agent forces MAX at `maxCpuC` (72 °C), so no `AUTO` sample above that has ever
been recorded. Whether Acer's curve ramps hard near its ceiling is still unknown.

**Phase 2 — does `CUSTOM` hold a percentage?** Commands 40/60/80/100 % via
behaviour word `0x00C30009` and reads RPM back at each point, recording whether
the firmware accepted the write and whether fan mode stayed at 3 or drifted
back to `AUTO`.

This payload has **never executed on the reference machine** — the only
behaviour bitmaps ever observed are `0x0100` (AUTO) and `0x0200` (MAX). It is a
hypothesis from [../docs/wmi-surface.md](../docs/wmi-surface.md), which is why
the proportional band ships with `curveEnabled: false`. Skip this phase with
`-SoloFase1`.

Verdicts: `CUSTOM_VALIDO` (calibrate and enable the curve), `CUSTOM_PARCIAL`,
`CUSTOM_INESTABLE` (mode drifts back), `CUSTOM_NO_MONOTONO` (RPM does not track
percent), `CUSTOM_RECHAZADO` (firmware refuses the payload).

**Safety.** Aborts at 92 °C or on any WHEA event during the run. A `finally`
block always forces MAX, returns to AUTO and restarts both agent tasks — on
error, on Ctrl-C, on an abort. Evidence lands in
`../evidence/benchmarks/2026-08-24-acer-auto-curve.json`.

## EJECUTAR-Limpieza.cmd

One-off host cleanup after the 2026-08 investigation, plus a transactional
deploy of the fan controller through `Deploy-SecureAcerFanUpdate.ps1` (hashes
verified, previous version backed up, automatic rollback). Pass `-SinDesplegar`
to do the uninstalls without touching the agent.
