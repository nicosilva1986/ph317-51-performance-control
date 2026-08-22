# Research

Living investigation notes that explain **why** this project exists and what
the wider PH317-51 / Helios 300 ecosystem reported. Not runtime code.

| Document | Purpose |
|----------|---------|
| [platform-thermal-context.md](platform-thermal-context.md) | Root cause: micro vs Acer platform vs software layers |
| [cross-vendor-control-landscape.md](cross-vendor-control-landscape.md) | How ASUS/Lenovo/MSI/NBFC/etc. control fans and power; what to borrow |
| [cpu-gpu-silicon-notes.md](cpu-gpu-silicon-notes.md) | 7700HQ bins/PL/cTDP; 1060 TGP/Optimus; PSU; limit stack |
| [prochot-and-tcc-offset.md](prochot-and-tcc-offset.md) | PROCHOT vs BD PROCHOT vs Tcc offset; MSRs; read-only posture |
| [gpu-thermal-and-undervolt.md](gpu-thermal-and-undervolt.md) | GTX 1060 heat role, Afterburner UV/PL, what improves, non-goals |
| [evidence-benchmarks-analysis.md](evidence-benchmarks-analysis.md) | Interpretation of Auto vs Max and recovery JSON on main |
| [forum-sources.md](forum-sources.md) | Curated forum/review links (multi-language) |
| [conversation-coverage-2026-08-22.md](conversation-coverage-2026-08-22.md) | Topic → doc coverage after 2026-08-22 research pass |
| [repo-health-2026-08-22.md](repo-health-2026-08-22.md) | Point-in-time health and navigability of this repository |
| [log.md](log.md) | Chronological research log (append-only) |

## Rules for this folder

- Prefer **primary** links (Acer Community, Notebookcheck, LaptopMedia, NVD, project READMEs, Intel MSR documentation).
- Separate **fact** (measured on reference machine or cited review) from **hypothesis**.
- No secrets, serials, full instance IDs, or BitLocker material.
- New findings: append a short entry to `log.md` and, if durable, a dedicated note.
- Implementation decisions stay in `docs/`; research stays here until promoted.
- **Do not** document step-by-step disable of thermal protections as a recommended default; read-only telemetry first.

## Related production docs

- [docs/wmi-surface.md](../docs/wmi-surface.md)
- [docs/architecture.md](../docs/architecture.md)
- [docs/native-turbo-plan.md](../docs/native-turbo-plan.md)
- [docs/roadmap-next-controls.md](../docs/roadmap-next-controls.md)
- [docs/limit-telemetry-proposal.md](../docs/limit-telemetry-proposal.md)
- [evidence/benchmarks](../evidence/benchmarks/)
