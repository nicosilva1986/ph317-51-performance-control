# Usage

> Only the Acer Predator PH317-51 hardware path has been validated. The controller and installer refuse other models.

## Run deterministic tests

From the repository root in PowerShell 7:

```powershell
pwsh -NoProfile -File .\tests\Test-AcerAdaptiveFanController.ps1
pwsh -NoProfile -File .\tests\Test-AcerFanWatchdog.ps1
pwsh -NoProfile -File .\tests\Test-ExportSanitizedBaseline.ps1
pwsh -NoProfile -File .\tests\Test-CRUWBlockerPreflightCore.ps1
pwsh -NoProfile -File .\tests\Test-CRUWStateMachine.Simulated.ps1
pwsh -NoProfile -File .\tests\Test-CRUWCrossEngineJournal.ps1
```

Repeat the three CRUW tests with Windows PowerShell 5.1 before a maintenance window:

```powershell
powershell.exe -NoProfile -ExecutionPolicy Bypass -File .\tests\Test-CRUWBlockerPreflightCore.ps1
powershell.exe -NoProfile -ExecutionPolicy Bypass -File .\tests\Test-CRUWStateMachine.Simulated.ps1
powershell.exe -NoProfile -ExecutionPolicy Bypass -File .\tests\Test-CRUWCrossEngineJournal.ps1
```

Expected result: a non-zero executed-assertion count, an explicit `PASS`, and process exit code `0` for every script. Simulation never substitutes for the real preflight and postboot evidence.

From an already elevated console, the optional native mutex smoke verifies real cross-process exclusion between PS5.1 and PS7. It creates only an ephemeral named mutex and temporary readiness files; it performs no driver, BitLocker, registry, service or reboot operation:

```powershell
powershell.exe -NoProfile -ExecutionPolicy Bypass -File .\tests\Test-CRUWNativeMutex.Smoke.ps1
powershell.exe -NoProfile -ExecutionPolicy Bypass -File .\tests\Test-CRUWNativeJournal.Smoke.ps1
```

The second smoke writes and deletes one uniquely named test journal under the fixed `C:\Acer-Driver-Audit\Native-Smoke` and `D:\Acer-Recovery\Native-Smoke` parents. It verifies write-through publication, byte equality, SHA-256 chaining and protected file ACLs; it does not use a real recovery bundle.

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

`Prepare-CRUWBlockerRemoval.ps1` is the preflight/backup producer, not a read-only command: it writes the two recovery trees, exports evidence, saves the SYSTEM hive and may create the named restore point. It performs no target-driver deletion, device rebind, BitLocker suspension, service edit or reboot. Schema v3 seals six exact implementation artifacts, dual backups and the current boot identity before any target-driver change. It requires:

- `-OffMachineRecoveryKeyConfirmed` only after the operator has verified access;
- WinRE and a recent restore point;
- dual backup verification;
- zero pending-reboot indicators;
- a physical reboot window.

For this notebook, where the owner explicitly stated that System Restore was disabled before the temporary maintenance window, the fresh preflight is:

```powershell
pwsh -NoProfile -File .\src\powershell\maintenance\Prepare-CRUWBlockerRemoval.ps1 `
  -OffMachineRecoveryKeyConfirmed `
  -UserDeclaredOriginalSystemRestoreDisabled `
  -UserDeclaredOriginalWinReDisabled
```

The two original-state switches record the owner's declarations for later restoration; they do not make a failed technical gate pass. If either declaration is omitted, the corresponding original state remains `Unknown` and no finalizer may infer or disable it. The preflight discovers the current OEM INF instead of assuming `oem127.inf`, requires exactly the two internal C:/D: disks, verifies the Microsoft `disk.inf` fallback, seals the boot identity and complete filter snapshot, and writes byte-matched backups with SYSTEM/Administrators-only ACLs on both physical disks.

If the preflight reports any pending-reboot indicator or exits non-zero, stop. Perform a separately authorized preliminary restart and generate a completely new preflight; never reuse the old timestamped bundle.

If WinRE or System Restore were intentionally disabled, temporarily enable both before that preliminary restart. This command first writes byte-identical `BEFORE` evidence on the protected C:/D: parents, enables only those recovery facilities, creates or reuses the exact latest positive-sequence named checkpoint, verifies WinRE and the checkpoint, and then writes byte-identical `RESULT` evidence. It does not touch BitLocker, mutate the driver or reboot:

```powershell
pwsh -NoProfile -File .\src\powershell\maintenance\Prepare-CRUWRecoveryFacilities.ps1 `
  -ConfirmTemporaryRecoveryEnablement `
  -UserDeclaredOriginalSystemRestoreDisabled `
  -UserDeclaredOriginalWinReDisabled
```

Those two declaration switches record this owner's stated original baseline; they never make the technical preparation pass. The fresh post-restart preflight independently revalidates or recreates the exact named checkpoint and remains the removal authority. Original disabled preferences are restored only by a later separately reviewed finalizer after a distinct stable boot.

The only authoritative input is the `preflight.json` inside its timestamped primary recovery root. `C:\Acer-Driver-Audit\Recovery\CRUWBlocker-preflight-latest.json` is a convenience copy and must never be passed to a mutating or recovery entrypoint.

After the fresh schema-v3 preflight passes, open an already elevated **Windows PowerShell 5.1** console and execute only the sealed primary copy:

```powershell
$recoveryRoot = 'C:\Acer-Driver-Audit\Recovery\CRUWBlocker-YYYYMMDD-HHMMSS-fff'

powershell.exe -NoProfile -ExecutionPolicy Bypass -File `
  "$recoveryRoot\implementation\Invoke-CRUWBlockerRemoval.ps1" `
  -PreflightPath "$recoveryRoot\preflight.json" `
  -ConfirmationPhrase REMOVE-CRUWBLOCKER-WITHOUT-FORCE `
  -OffMachineRecoveryKeyConfirmed `
  -PhysicalConsoleAccessConfirmed `
  -ManualRebootWindowConfirmed `
  -ConfirmBootCriticalDriverRemoval
```

Do not restart unless the result contains a dual-committed `REBOOT_AUTHORIZED` terminal checkpoint. Record its exact `terminalCheckpoint.primaryPath`; no script restarts Windows automatically. After the one deliberate manual restart, run the sealed postboot validator with that exact path:

The removal transaction accepts only PnPUtil exit code `0` or `3010`, together with an independently verified exact clean live state. Code `259`, `1641`, or any other result blocks reboot authorization and preserves diagnostic evidence. A clean-looking inventory never overrides an undocumented or contradictory process result.

```powershell
powershell.exe -NoProfile -ExecutionPolicy Bypass -File `
  "$recoveryRoot\implementation\Test-CRUWBlockerPostboot.ps1" `
  -RebootAuthorizedCheckpointPath '<exact terminalCheckpoint.primaryPath>' `
  -OffMachineRecoveryKeyConfirmed `
  -PhysicalConsoleAccessConfirmed `
  -ConfirmResumeBitLockerOnExit
```

An all-green first postboot run returns `POSTBOOT_STABILITY_PENDING`: the driver removal can be complete and BitLocker must already be back On, but WinRE and System Restore remain enabled. This version deliberately does not automate restoration of those original preferences. Keep the machine through a later stable boot and use a separately reviewed finalization procedure; never infer an `Unknown` baseline.

If an invocation is interrupted, use the sealed `Repair-CRUWInterruptedRemoval.ps1` with the exact operation ID printed by the original run. Recovery inspects live storage state and may roll back or re-authorize an already-clean state, but it never repeats `/delete-driver` after an ambiguous intent.

Never paste the recovery password into a parameter, terminal log, issue, or repository file.
