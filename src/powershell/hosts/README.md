# Thin hosts (target)

After modularization, Scheduled Tasks should point at **thin** entrypoints
here (or still named like today's files but reduced to Import-Module + loop).

Example shape (not live):

```powershell
#Requires -Version 7.0
param(
    [string] $Root = 'C:\ProgramData\AcerAdaptiveFanControl',
    [string] $ConfigPath = $(Join-Path $Root 'fan-controller-config.json'),
    [string] $LogPath = $(Join-Path $Root 'adaptive-fan.jsonl'),
    [string] $StatusPath = $(Join-Path $Root 'adaptive-fan-status.json')
)

Set-StrictMode -Version Latest
$ErrorActionPreference = 'Stop'

$modules = Join-Path $Root 'modules'
Import-Module (Join-Path $modules 'PredatorPh317.Core\PredatorPh317.Core.psm1') -Force
Import-Module (Join-Path $modules 'PredatorPh317.Wmi\PredatorPh317.Wmi.psm1') -Force
Import-Module (Join-Path $modules 'PredatorPh317.Fan\PredatorPh317.Fan.psm1') -Force

Assert-SupportedHardware
# ... loop using Get-FanPolicyDecision / Set-GamingFansMax / status write ...
```

Until cutover, **do not** register tasks against this folder. Live hosts remain:

- `src/powershell/fan/AcerAdaptiveFanController.ps1`
- `src/powershell/fan/AcerFanWatchdog.ps1`
