# Research

Living investigation notes that explain **why** this project exists and what
the wider PH317-51 / Helios 300 ecosystem reported. Not runtime code.

**Layout:** files stay **flat** in this folder. Categories below are an index
only (no subdirectories until the set grows enough to justify moves).

---

## Platform / root cause

Why this SKU needs a control stack beyond “Intel is hot.”

| Document | Purpose |
|----------|---------|
| [platform-thermal-context.md](platform-thermal-context.md) | Root cause: micro vs Acer platform vs software layers |
| [forum-sources.md](forum-sources.md) | Curated forum/review links (multi-language) |

## Silicon / limits

CPU, GPU, power and thermal trip mechanisms that bound performance.

| Document | Purpose |
|----------|---------|
| [cpu-gpu-silicon-notes.md](cpu-gpu-silicon-notes.md) | 7700HQ bins/PL/cTDP; 1060 TGP/Optimus; PSU; limit stack |
| [prochot-and-tcc-offset.md](prochot-and-tcc-offset.md) | PROCHOT vs BD PROCHOT vs Tcc offset; MSRs; read-only posture |
| [gpu-thermal-and-undervolt.md](gpu-thermal-and-undervolt.md) | GTX 1060 heat role, Afterburner UV/PL, what improves, non-goals |

## Ecosystem / other vendors

How peers solve the same class of problem; what to borrow without leaving WMI.

| Document | Purpose |
|----------|---------|
| [cross-vendor-control-landscape.md](cross-vendor-control-landscape.md) | ASUS/Lenovo/MSI/NBFC/etc.; official API vs EC poke |

## Incidents / verdicts

Closed questions with measurements attached. Read before re-opening any of them.

| Document | Purpose |
|----------|---------|
| [fan-max-on-resume-2026-08-24.md](fan-max-on-resume-2026-08-24.md) | Fans at 100 % after resume: fail-closed startup hold, not a fault |
| [undervolt-effectiveness-2026-08-24.md](undervolt-effectiveness-2026-08-24.md) | CPU undervolt firmware-locked; GPU undervolt a measured regression |
| [acer-auto-curve-and-custom-mode-2026-08-24.md](acer-auto-curve-and-custom-mode-2026-08-24.md) | Acer's stock curve tops at 4761 RPM and goes flat 65–89 °C; CUSTOM mode validated |
| [undervolt-unlock-analysis-2026-08-24.md](undervolt-unlock-analysis-2026-08-24.md) | A proposed BIOS setup-variable unlock targets the wrong lock; microcode 0xDE is reapplied every boot |

## Meta / evidence interpretation

Repo process, coverage maps, and reading of local measurements (not raw JSON).

| Document | Purpose |
|----------|---------|
| [evidence-benchmarks-analysis.md](evidence-benchmarks-analysis.md) | Interpretation of Auto vs Max and recovery JSON on main |
| [conversation-coverage-2026-08-22.md](conversation-coverage-2026-08-22.md) | Topic → doc coverage after 2026-08-22 research pass |
| [repo-health-2026-08-22.md](repo-health-2026-08-22.md) | Point-in-time health and navigability of this repository |
| [log.md](log.md) | Chronological research log (append-only) |

---

## Rules for this folder

- Prefer **primary** links (Acer Community, Notebookcheck, LaptopMedia, NVD, project READMEs, Intel MSR documentation).
- Separate **fact** (measured on reference machine or cited review) from **hypothesis**.
- No secrets, serials, full instance IDs, or BitLocker material.
- New findings: append a short entry to `log.md` and, if durable, a dedicated note in the matching category above.
- Implementation decisions stay in `docs/`; research stays here until promoted.
- **Do not** document step-by-step disable of thermal protections as a recommended default; read-only telemetry first.
- Keep the tree **flat** until there are roughly 15+ durable notes or clear ownership split; then reconsider subdirectories.

## Related production docs

- [docs/handoff.md](../docs/handoff.md) — state of play: what runs, what works, what is closed
- [docs/wmi-surface.md](../docs/wmi-surface.md)
- [docs/architecture.md](../docs/architecture.md)
- [docs/native-turbo-plan.md](../docs/native-turbo-plan.md)
- [docs/roadmap-next-controls.md](../docs/roadmap-next-controls.md)
- [docs/limit-telemetry-proposal.md](../docs/limit-telemetry-proposal.md)
- [evidence/benchmarks](../evidence/benchmarks/)
