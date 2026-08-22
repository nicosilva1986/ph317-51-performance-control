# PowerShell layout — modularization plan

Target structure for the fan control plane and related tooling.
**Production behavior must not change** until extraction PRs prove
parity (same WMI payloads, same status schema, same fail-closed rules).

Branch: `refactor/fan-modules`  
Issue: modularize fan PowerShell (Core + Wmi + Fan hosts)

## Current state (main)

```text
src/powershell/
  fan/
    AcerAdaptiveFanController.ps1   # ~25 KB monolithic loop
    AcerFanWatchdog.ps1             # integrity + emergency MAX
    Secure-Install-AcerFanController.ps1
    Deploy-SecureAcerFanUpdate.ps1
    fan-controller-config.json
  maintenance/                      # CRUW — separate product; do not import from fan
  Export-SanitizedBaseline.ps1
```

Scheduled tasks and `C:\ProgramData\AcerAdaptiveFanControl` still point at
the **host scripts** under `fan/`. Integrity manifests hash those files.

## Target state

```text
src/powershell/
  modules/
    PredatorPh317.Core/     # hardware assert, JSONL, hashes, paths
    PredatorPh317.Wmi/      # AcerGamingFunction only (see docs/wmi-surface.md)
    PredatorPh317.Fan/      # config validate, policy AUTO/MAX, status schema
    PredatorPh317.Watchdog/ # integrity check + emergency recovery helpers

  hosts/
    AcerAdaptiveFanController.ps1   # thin: Import-Module + loop
    AcerFanWatchdog.ps1             # thin: Import-Module + loop

  fan/                      # transitional: current monoliths until cutover
  maintenance/              # CRUW unchanged in this refactor
  tools/                    # lab only (Custom matrix, limit telemetry)
```

### Module dependency graph

```text
Core  <──  Wmi  <──  Fan  <──  hosts/AcerAdaptiveFanController.ps1
  ^                ^
  └──  Watchdog ───┴──  hosts/AcerFanWatchdog.ps1

maintenance/*  does not import Fan or Watchdog
tools/*        may import Core + Wmi (read-only experiments prefer Wmi reads)
```

## Extraction order (small PRs)

| Step | Move | Done when |
|-----:|------|----------|
| 1 | Hex payloads + CIM calls → `PredatorPh317.Wmi` | Controller/watchdog call module functions; same gmInput values |
| 2 | JSONL rotate, SHA256 helper, path constants → `Core` | No duplicated log/hash helpers |
| 3 | Config Assert ranges + status object builder → `Fan` | Validate-FanControllerConfig used by install + runtime |
| 4 | Integrity + Set-EmergencyMax shared → `Watchdog` (or Fan) | Watchdog host &lt; ~120 lines |
| 5 | Thin hosts; update install/deploy to ship modules + hosts | Tasks still SYSTEM; integrity lists module files too |
| 6 | Delete dead inlined copies from old monoliths | Simulation tests green |

Do **not** fold CRUW into these modules in this track.

## Integrity / deploy rules

After cutover, `integrity.json` (or successor) must pin SHA-256 of:

- both host scripts
- every shipped `.psm1` (and `.psd1` if used)
- `fan-controller-config.json`

Install/update remains transactional: on failure leave firmware **MAX**, never silent Auto.

`$env:PSModulePath` or explicit `Import-Module -Name (Join-Path $Root 'modules\...')` from the protected ProgramData tree — prefer **explicit path** under the protected root so a user-writable module path cannot shadow SYSTEM.

## Testing gates

- Parse/validate all modules under `Set-StrictMode -Version Latest`
- Existing fan simulation tests still pass
- Manual: one cycle AUTO→MAX→AUTO on reference PH317-51 with RPM verify
- Watchdog `-ProbeOnly` healthy against a running controller

## Non-goals

- C# / Windows Service rewrite
- Changing AUTO/MAX thresholds
- Moving ProgramData root without a migrate issue
- Public release packaging (#5) as part of this refactor
