# Documentation map

Read order for humans. Implementation details live in the linked files.

## Start here

1. [README](../README.md) — why the project exists and measured fan Auto vs Max
2. [research/platform-thermal-context.md](../research/platform-thermal-context.md) — micro vs Acer platform
3. [research/cross-vendor-control-landscape.md](../research/cross-vendor-control-landscape.md) — how other brands solve the same class of problem
4. [research/cpu-gpu-silicon-notes.md](../research/cpu-gpu-silicon-notes.md) — turbo bins, GPU TGP, power limit stack
5. [architecture.md](architecture.md) — control planes and fail-closed rules
6. [usage.md](usage.md) — how to run tests and the fan stack on the reference machine

## Fan / WMI (daily control plane)

| Doc | Content |
|-----|---------|
| [wmi-surface.md](wmi-surface.md) | AcerGamingFunction methods and hex payloads |
| [architecture.md](architecture.md) | Controller + watchdog design |
| [fan-curve-experiment.md](fan-curve-experiment.md) | Custom % matrix protocol (lab) |
| [limit-telemetry-proposal.md](limit-telemetry-proposal.md) | Read-only “who is limiting” |
| [roadmap-next-controls.md](roadmap-next-controls.md) | Ordered next control work |
| [powershell-layout.md](powershell-layout.md) | Module layout (may live on `refactor/fan-modules` until merge) |

**Code (main):** `src/powershell/fan/`

## Turbo / power

| Doc | Content |
|-----|---------|
| [native-turbo-plan.md](native-turbo-plan.md) | Leave ThrottleStop 28×; stock Intel ratios + power plan |
| [research/prochot-and-tcc-offset.md](../research/prochot-and-tcc-offset.md) | PROCHOT / BD PROCHOT / Tcc offset (read-only research) |

## Driver hygiene / CRUW (maintenance window only)

| Doc | Content |
|-----|---------|
| [recovery-and-rollback.md](recovery-and-rollback.md) | CRUW removal, BitLocker, no `/force` |
| [hardware-and-driver-baseline.md](hardware-and-driver-baseline.md) | Inventory baseline |

**Code:** `src/powershell/maintenance/` — do not import from the fan host.

## Research (not runtime)

| Doc | Content |
|-----|---------|
| [research/README.md](../research/README.md) | Index |
| [research/platform-thermal-context.md](../research/platform-thermal-context.md) | Micro vs Acer |
| [research/cross-vendor-control-landscape.md](../research/cross-vendor-control-landscape.md) | Multi-vendor control methods |
| [research/cpu-gpu-silicon-notes.md](../research/cpu-gpu-silicon-notes.md) | CPU/GPU silicon and platform power |
| [research/prochot-and-tcc-offset.md](../research/prochot-and-tcc-offset.md) | Thermal trip offsets and BD PROCHOT |
| [research/gpu-thermal-and-undervolt.md](../research/gpu-thermal-and-undervolt.md) | GTX 1060 heat, UV/PL, non-goals |
| [research/evidence-benchmarks-analysis.md](../research/evidence-benchmarks-analysis.md) | Analysis of evidence JSON |
| [research/forum-sources.md](../research/forum-sources.md) | Multi-language sources |
| [research/conversation-coverage-2026-08-22.md](../research/conversation-coverage-2026-08-22.md) | Topic coverage matrix |
| [research/repo-health-2026-08-22.md](../research/repo-health-2026-08-22.md) | Navigability / health snapshot |
| [research/log.md](../research/log.md) | Append-only research log |

## Evidence

Sanitized measurements only: `evidence/benchmarks/`, `evidence/manifests/`.

## Security / process

- [SECURITY.md](../SECURITY.md)
- [AGENTS.md](../AGENTS.md)
- [CONTRIBUTING.md](../CONTRIBUTING.md)
