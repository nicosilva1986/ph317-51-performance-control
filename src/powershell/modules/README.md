# PredatorPh317 PowerShell modules

Skeleton modules for the fan control plane. **Not yet wired** into the
live Scheduled Tasks. Authoritative runtime remains under `../fan/` until
extraction PRs land.

| Module | Role |
|--------|------|
| `PredatorPh317.Core` | Hardware gate, JSONL, hashes, shared paths |
| `PredatorPh317.Wmi` | `AcerGamingFunction` read/write helpers |
| `PredatorPh317.Fan` | Config validation, policy helpers, status schema |
| `PredatorPh317.Watchdog` | Integrity + emergency MAX helpers |

Import by **full path** from a protected install root, never by ambient
`PSModulePath` alone, when running as SYSTEM.

See [docs/powershell-layout.md](../../../docs/powershell-layout.md).
