# Research

Living investigation notes that explain **why** this project exists and what
the wider PH317-51 / Helios 300 ecosystem reported. Not runtime code.

| Document | Purpose |
|----------|---------|
| [platform-thermal-context.md](platform-thermal-context.md) | Root cause: micro vs Acer platform vs software layers |
| [forum-sources.md](forum-sources.md) | Curated forum/review links (multi-language) |
| [repo-health-2026-08-22.md](repo-health-2026-08-22.md) | Point-in-time health and navigability of this repository |
| [log.md](log.md) | Chronological research log (append-only) |

## Rules for this folder

- Prefer **primary** links (Acer Community, Notebookcheck, LaptopMedia, NVD).
- Separate **fact** (measured on reference machine or cited review) from **hypothesis**.
- No secrets, serials, full instance IDs, or BitLocker material.
- New findings: append a short entry to `log.md` and, if durable, a dedicated note.
- Implementation decisions stay in `docs/`; research stays here until promoted.

## Related production docs

- [docs/wmi-surface.md](../docs/wmi-surface.md)
- [docs/architecture.md](../docs/architecture.md)
- [docs/native-turbo-plan.md](../docs/native-turbo-plan.md)
- [docs/roadmap-next-controls.md](../docs/roadmap-next-controls.md)
- [evidence/benchmarks](../evidence/benchmarks/)
