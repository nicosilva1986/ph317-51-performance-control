# Usage

> Only the Acer Predator PH317-51 hardware path has been validated. The controller and installer refuse other models.

## Run deterministic tests

From the repository root in PowerShell 7:

```powershell
pwsh -NoProfile -File .\tests\Test-AcerAdaptiveFanController.ps1
pwsh -NoProfile -File .\tests\Test-AcerFanWatchdog.ps1
pwsh -NoProfile -File .\tests\Test-ExportSanitizedBaseline.ps1
```

Expected result: controller policy 6/6, watchdog probes 8/8, baseline exporter 26 assertions, and process exit code `0` for every script.

## Validate a release without changing hardware

```powershell
pwsh -NoProfile -File .\src\powershell\fan\Deploy-SecureAcerFanUpdate.ps1 -ValidateOnly
```

This parses the release and verifies the pinned controller/config/watchdog/installer hashes. It does not elevate, write WMI state, replace tasks, or install files.

## Install the fan controller

Installation is privileged and changes scheduled tasks plus Acer firmware fan state:

```powershell
pwsh -NoProfile -File .\src\powershell\fan\Deploy-SecureAcerFanUpdate.ps1
```

The deployer:

1. verifies the exact release hashes;
2. copies the package into a SYSTEM-owned protected staging directory;
3. validates hardware/model and configuration;
4. requests Max cooling before stopping any existing guardian;
5. backs up files and task definitions;
6. installs controller + watchdog as SYSTEM startup tasks;
7. requires two consecutive healthy Max readbacks within 60 seconds;
8. rolls back or leaves Max active on failure.

Inspect local results:

```powershell
Get-Content C:\Acer-Driver-Audit\secure-fan-deploy.json
Get-Content C:\Acer-Driver-Audit\secure-fan-installation.json
Get-Content C:\ProgramData\AcerAdaptiveFanControl\adaptive-fan-status.json
```

## Live fault tests

These intentionally alter fan/task state and must only be run on the supported laptop after installation:

```powershell
pwsh -NoProfile -File .\tests\Test-AcerFanOverrideRecovery.ps1
pwsh -NoProfile -File .\tests\Test-AcerFanWatchdogRecoveryLive.ps1
```

The first forces Auto and requires the controller to restore Max. The second stops only the primary controller task and requires the watchdog to restart it, recover Max mode/RPM and remain running.

## Export a sanitized baseline

The parent directory must already exist. The exporter writes only the exact requested JSON file and refuses suspicious secret-bearing input:

```powershell
New-Item -ItemType Directory .\local -Force | Out-Null
pwsh -NoProfile -File .\src\powershell\Export-SanitizedBaseline.ps1 `
  -OutputPath .\local\baseline.json
```

`local/` is ignored by Git. Review any generated evidence manually before copying a sanitized subset into `evidence/`.

## Storage-driver maintenance

`Prepare-CRUWBlockerRemoval.ps1` is a preflight/backup tool, not a one-click removal script. The actual driver correction remains intentionally separate and requires:

- `-OffMachineRecoveryKeyConfirmed` only after the operator has verified access;
- WinRE and a recent restore point;
- dual backup verification;
- zero pending-reboot indicators;
- a physical reboot window.

Never paste the recovery password into a parameter, terminal log, issue, or repository file.
