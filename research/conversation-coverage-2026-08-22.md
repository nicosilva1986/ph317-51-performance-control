# Conversation coverage map — 2026-08-22 research pass

Maps topics discussed in the extended research/engineering thread to **where they live in the repo** after this documentation pass.

| Topic | In research before? | Now |
|-------|---------------------|-----|
| Micro vs Acer platform root cause | Yes — `platform-thermal-context.md` | Unchanged core conclusion |
| Multi-language Helios forums | Yes — `forum-sources.md` | Still the link index |
| Cross-vendor fan/power (G-Helper, LLT, NBFC, etc.) | Yes — `cross-vendor-control-landscape.md` | — |
| Repo health / navigability | Yes — `repo-health-2026-08-22.md` | — |
| GTX 1060 UV / Afterburner / what UV improves | Yes — `gpu-thermal-and-undervolt.md` | Issue #24 |
| **7700HQ turbo bins, cTDP, PL/Tau, 31.7 W evidence** | Partial (turbo plan in `docs/`) | **Added** `cpu-gpu-silicon-notes.md` |
| **1060 TGP ~80 W, Optimus, PSU 135/180 W** | Partial in GPU note | **Expanded** in silicon notes |
| **PROCHOT / BD PROCHOT / Tcc offset** | No dedicated note | **Added** `prochot-and-tcc-offset.md` |
| **Structured analysis of evidence JSON** | README table only | **Added** `evidence-benchmarks-analysis.md` |
| WMI surface, architecture, modularization | `docs/` + branch | Not duplicated here |
| CRUW explanation | User Q; recovery docs | Not a research gap |
| ThrottleStop fork idea | Rejected in chat | Non-goal; native turbo doc |

## Intentional non-duplication

Implementation detail stays in `docs/` (`wmi-surface`, `architecture`, `native-turbo-plan`, `limit-telemetry-proposal`). Research explains **why** and **what the industry/silicon does**; code and runbooks stay production docs.

## Still open for measurement (not missing prose)

- Reference-machine Tcc offset / BD PROCHOT under load
- Native turbo FMA A/B without 28×
- 3D GPU telemetry suite (#24)
