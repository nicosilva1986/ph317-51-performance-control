[CmdletBinding()]
param(
    [switch] $OffMachineRecoveryKeyConfirmed
)

Set-StrictMode -Version Latest
$ErrorActionPreference = 'Stop'

if (-not ([Security.Principal.WindowsPrincipal][Security.Principal.WindowsIdentity]::GetCurrent()).IsInRole(
    [Security.Principal.WindowsBuiltInRole]::Administrator
)) {
    $pwsh = Join-Path $PSHOME 'pwsh.exe'
    $elevationArguments = @(
        '-NoProfile', '-ExecutionPolicy', 'Bypass', '-File', ('"' + $PSCommandPath + '"')
    )
    if ($OffMachineRecoveryKeyConfirmed) { $elevationArguments += '-OffMachineRecoveryKeyConfirmed' }
    $process = Start-Process -FilePath $pwsh -Verb RunAs -WindowStyle Hidden -ArgumentList $elevationArguments -Wait -PassThru
    exit $process.ExitCode
}

Add-Type @'
using System;
using System.Runtime.InteropServices;
public static class PredatorPowerStatus {
    [StructLayout(LayoutKind.Sequential)]
    public struct SYSTEM_POWER_STATUS {
        public byte ACLineStatus;
        public byte BatteryFlag;
        public byte BatteryLifePercent;
        public byte SystemStatusFlag;
        public int BatteryLifeTime;
        public int BatteryFullLifeTime;
    }
    [DllImport("kernel32.dll")]
    public static extern bool GetSystemPowerStatus(out SYSTEM_POWER_STATUS status);
}
'@

function ConvertTo-AtlasRestorePointDate {
    param([Parameter(Mandatory)] $CreationTime)

    if ($CreationTime -is [datetime]) { return [datetime]$CreationTime }
    try {
        return [Management.ManagementDateTimeConverter]::ToDateTime([string]$CreationTime)
    }
    catch {
        return $null
    }
}

function Get-AtlasPropertyValue {
    param(
        [AllowNull()] $InputObject,
        [Parameter(Mandatory)] [string] $Name
    )

    if ($null -eq $InputObject) { return $null }
    $property = $InputObject.PSObject.Properties[$Name]
    if ($null -eq $property) { return $null }
    return $property.Value
}

$stamp = Get-Date -Format 'yyyyMMdd-HHmmss'
$root = 'C:\Acer-Driver-Audit\Recovery'
$recoveryPath = Join-Path $root "CRUWBlocker-$stamp"
$driverPath = Join-Path $recoveryPath 'driver'
$secondaryRoot = 'D:\Acer-Recovery'
$secondaryPath = Join-Path $secondaryRoot "CRUWBlocker-$stamp"
New-Item -ItemType Directory -Path $driverPath -Force | Out-Null
New-Item -ItemType Directory -Path $secondaryRoot -Force | Out-Null
$failurePath = Join-Path $recoveryPath 'preflight-error.txt'
trap {
    $details = ($_ | Format-List * -Force | Out-String)
    [System.IO.File]::WriteAllText($failurePath, $details, [System.Text.UTF8Encoding]::new($false))
    Write-Error $details
    exit 1
}

$power = [PredatorPowerStatus+SYSTEM_POWER_STATUS]::new()
[void][PredatorPowerStatus]::GetSystemPowerStatus([ref]$power)

$bitLocker = Get-BitLockerVolume -MountPoint 'C:'
# Deliberately count protectors without ever serializing a RecoveryPassword value.
$recoveryPasswordCount = @($bitLocker.KeyProtector | Where-Object KeyProtectorType -eq 'RecoveryPassword').Count
$winReOutput = (& reagentc.exe /info 2>&1 | Out-String).Trim()
$winReInfoExitCode = $LASTEXITCODE
$winReEnabled = $winReInfoExitCode -eq 0 -and
    $winReOutput -match '(?im)Windows[^\r\n]*RE[^\r\n]*:\s*(Enabled|Habilitado)'
$winReDisabled = $winReInfoExitCode -eq 0 -and
    $winReOutput -match '(?im)Windows[^\r\n]*RE[^\r\n]*:\s*(Disabled|Deshabilitado)'
$winReLocationMatch = [regex]::Match(
    $winReOutput,
    '(?im)(?:location|Ubicaci[oó]n)[^\r\n]*:\s*(\\\\\?\\GLOBALROOT[^\r\n]*)'
)
$winReLocation = if ($winReLocationMatch.Success) { $winReLocationMatch.Groups[1].Value.Trim() } else { $null }
$winReInitialState = if ($winReEnabled) { 'Enabled' } elseif ($winReDisabled) { 'Disabled' } else { 'Unknown' }

$systemRestorePolicyPath = 'HKLM:\SOFTWARE\Policies\Microsoft\Windows NT\SystemRestore'
$systemRestoreRuntimePath = 'HKLM:\SOFTWARE\Microsoft\Windows NT\CurrentVersion\SystemRestore'
$systemRestorePolicy = Get-ItemProperty -LiteralPath $systemRestorePolicyPath -ErrorAction SilentlyContinue
$systemRestoreRuntime = Get-ItemProperty -LiteralPath $systemRestoreRuntimePath -ErrorAction SilentlyContinue
$policyDisableSR = Get-AtlasPropertyValue -InputObject $systemRestorePolicy -Name 'DisableSR'
$policyDisableConfig = Get-AtlasPropertyValue -InputObject $systemRestorePolicy -Name 'DisableConfig'
$runtimeDisableSR = Get-AtlasPropertyValue -InputObject $systemRestoreRuntime -Name 'DisableSR'
$systemRestoreTask = Get-ScheduledTask -TaskPath '\Microsoft\Windows\SystemRestore\' -TaskName 'SR' -ErrorAction SilentlyContinue

$restoreQuerySucceeded = $false
$restoreQueryError = $null
$restoreBeforeAll = @()
try {
    $restoreBeforeAll = @(Get-ComputerRestorePoint -ErrorAction Stop)
    $restoreQuerySucceeded = $true
}
catch {
    $restoreQueryError = $_.Exception.Message
}

$restoreBeforeRecords = @($restoreBeforeAll | ForEach-Object {
    [pscustomobject]@{
        SequenceNumber = $_.SequenceNumber
        Description = [string]$_.Description
        CreationDate = ConvertTo-AtlasRestorePointDate -CreationTime $_.CreationTime
        RestorePointType = $_.RestorePointType
    }
})
$checkpointDescription = 'Before CRUWBlocker removal'
$checkpointCutoff = (Get-Date).AddHours(-26)
$recentNamedBefore = @($restoreBeforeRecords | Where-Object {
    $_.Description -eq $checkpointDescription -and
    $null -ne $_.CreationDate -and
    $_.CreationDate -ge $checkpointCutoff
} | Sort-Object CreationDate -Descending | Select-Object -First 1)

$restoreCreated = $false
$restoreReused = $false
$restoreError = $null
if (-not $restoreQuerySucceeded) {
    $restoreError = "Restore-point inventory failed; checkpoint was not attempted to avoid a duplicate: $restoreQueryError"
}
elseif ($recentNamedBefore.Count -eq 1) {
    $restoreReused = $true
}
else {
    try {
        Checkpoint-Computer -Description $checkpointDescription -RestorePointType MODIFY_SETTINGS
        $restoreCreated = $true
    }
    catch {
        $restoreError = $_.Exception.Message
    }
}

$restoreAfterAll = $restoreBeforeAll
if ($restoreCreated) {
    try {
        $restoreAfterAll = @(Get-ComputerRestorePoint -ErrorAction Stop)
    }
    catch {
        $restoreError = "Checkpoint was created but could not be inventoried: $($_.Exception.Message)"
        $restoreAfterAll = @()
    }
}
$restoreAfterRecords = @($restoreAfterAll | ForEach-Object {
    [pscustomobject]@{
        SequenceNumber = $_.SequenceNumber
        Description = [string]$_.Description
        CreationDate = ConvertTo-AtlasRestorePointDate -CreationTime $_.CreationTime
        RestorePointType = $_.RestorePointType
    }
})
$usableNamedRestore = @($restoreAfterRecords | Where-Object {
    $_.Description -eq $checkpointDescription -and
    $null -ne $_.CreationDate -and
    $_.CreationDate -ge $checkpointCutoff
} | Sort-Object CreationDate -Descending | Select-Object -First 1)
$restoreUsable = $usableNamedRestore.Count -eq 1
$latestRestore = @($restoreAfterRecords | Sort-Object CreationDate -Descending | Select-Object -First 1)

$systemRestoreOperationalAtStart = $null
$systemRestoreStateBasis = 'No conclusive read-only signal'
if ($policyDisableSR -eq 1 -or $runtimeDisableSR -eq 1) {
    $systemRestoreOperationalAtStart = $false
    $systemRestoreStateBasis = 'DisableSR registry value was set'
}
elseif ($restoreBeforeRecords.Count -gt 0) {
    $systemRestoreOperationalAtStart = $true
    $systemRestoreStateBasis = 'Restore points were queryable before this run'
}
elseif ($restoreCreated) {
    # Checkpoint-Computer cannot succeed unless protection was operational at invocation time.
    $systemRestoreOperationalAtStart = $true
    $systemRestoreStateBasis = 'Checkpoint creation succeeded with no pre-existing points'
}
elseif (-not $restoreQuerySucceeded) {
    $systemRestoreStateBasis = 'Restore-point inventory failed'
}

$exportOutput = (& pnputil.exe /export-driver oem127.inf $driverPath 2>&1 | Out-String).Trim()
if ($LASTEXITCODE -ne 0) { throw "Driver export failed: $exportOutput" }
$expectedFiles = @('cruwblocker.inf', 'CRUWBlocker.sys', 'CRUWBlocker.cat')
$exportedFiles = @(Get-ChildItem -LiteralPath $driverPath -File)
foreach ($expected in $expectedFiles) {
    if (-not ($exportedFiles.Name -icontains $expected)) { throw "Export is incomplete; missing $expected" }
}
$hashes = @($exportedFiles | Get-FileHash -Algorithm SHA256 | Select-Object @{n='file';e={Split-Path -Leaf $_.Path}}, Hash)

$systemHivePath = Join-Path $recoveryPath 'SYSTEM.before.hiv'
$regOutput = (& reg.exe save 'HKLM\SYSTEM' $systemHivePath /y 2>&1 | Out-String).Trim()
if ($LASTEXITCODE -ne 0 -or -not (Test-Path -LiteralPath $systemHivePath)) { throw "SYSTEM hive backup failed: $regOutput" }

$diskDriverInventory = (& pnputil.exe /enum-devices /class DiskDrive /drivers 2>&1 | Out-String).Trim()
[System.IO.File]::WriteAllText((Join-Path $recoveryPath 'disk-drivers-before.txt'), $diskDriverInventory, [System.Text.UTF8Encoding]::new($false))
[System.IO.File]::WriteAllText((Join-Path $recoveryPath 'winre-before.txt'), $winReOutput, [System.Text.UTF8Encoding]::new($false))

$targetPublishedName = 'oem127.inf'
$targetFilterName = 'CRUWBlocker'
$diskDevices = @(Get-PnpDevice -Class DiskDrive -PresentOnly -ErrorAction Stop)
$devices = foreach ($device in $diskDevices) {
    $id = [string]$device.InstanceId
    $inf = Get-PnpDeviceProperty -InstanceId $id -KeyName 'DEVPKEY_Device_DriverInfPath' -ErrorAction Stop
    $lower = Get-PnpDeviceProperty -InstanceId $id -KeyName 'DEVPKEY_Device_LowerFilters' -ErrorAction SilentlyContinue
    $lowerFilters = if ($null -eq $lower) { @() } else { @($lower.Data) }
    $matchesPublishedName = [string]$inf.Data -ieq $targetPublishedName
    $matchesLowerFilter = @($lowerFilters | Where-Object { [string]$_ -ieq $targetFilterName }).Count -gt 0
    if (-not ($matchesPublishedName -or $matchesLowerFilter)) { continue }

    $provider = Get-PnpDeviceProperty -InstanceId $id -KeyName 'DEVPKEY_Device_DriverProvider' -ErrorAction Stop
    $version = Get-PnpDeviceProperty -InstanceId $id -KeyName 'DEVPKEY_Device_DriverVersion' -ErrorAction Stop
    [ordered]@{
        instanceId = $id
        friendlyName = $device.FriendlyName
        status = [string]$device.Status
        inf = [string]$inf.Data
        provider = [string]$provider.Data
        version = [string]$version.Data
        lowerFilters = $lowerFilters
        matchedBy = @(
            if ($matchesPublishedName) { 'publishedName' }
            if ($matchesLowerFilter) { 'lowerFilter' }
        )
    }
}
if (@($devices).Count -eq 0) {
    throw "No present DiskDrive device is currently bound by $targetPublishedName or $targetFilterName"
}
$targetBindingVerified = @($devices).Count -gt 0
$targetDevicesHealthy = @($devices | Where-Object { $_.status -ne 'OK' }).Count -eq 0

$physicalDisks = @(Get-PhysicalDisk | Select-Object FriendlyName, HealthStatus, OperationalStatus)
$disksHealthy = @($physicalDisks | Where-Object { $_.HealthStatus -ne 'Healthy' -or $_.OperationalStatus -notcontains 'OK' }).Count -eq 0
$cbsReboot = Test-Path 'HKLM:\SOFTWARE\Microsoft\Windows\CurrentVersion\Component Based Servicing\RebootPending'
$wuReboot = Test-Path 'HKLM:\SOFTWARE\Microsoft\Windows\CurrentVersion\WindowsUpdate\Auto Update\RebootRequired'
$pendingRename = @((Get-ItemProperty 'HKLM:\SYSTEM\CurrentControlSet\Control\Session Manager' -Name PendingFileRenameOperations -ErrorAction SilentlyContinue).PendingFileRenameOperations).Count
$pendingRebootDetected = $cbsReboot -or $wuReboot -or $pendingRename -gt 0

$requiredBackupFiles = @(
    'driver\cruwblocker.inf',
    'driver\CRUWBlocker.sys',
    'driver\CRUWBlocker.cat',
    'SYSTEM.before.hiv',
    'disk-drivers-before.txt',
    'winre-before.txt'
)
Copy-Item -LiteralPath $recoveryPath -Destination $secondaryPath -Recurse -Force
$secondaryFileVerification = @($requiredBackupFiles | ForEach-Object {
    $relativePath = $_
    $primaryFile = Join-Path $recoveryPath $relativePath
    $secondaryFile = Join-Path $secondaryPath $relativePath
    $primaryExists = Test-Path -LiteralPath $primaryFile
    $secondaryExists = Test-Path -LiteralPath $secondaryFile
    $primaryHash = if ($primaryExists) { (Get-FileHash -LiteralPath $primaryFile -Algorithm SHA256).Hash } else { $null }
    $secondaryHash = if ($secondaryExists) { (Get-FileHash -LiteralPath $secondaryFile -Algorithm SHA256).Hash } else { $null }
    [ordered]@{
        relativePath = $relativePath
        primaryExists = $primaryExists
        secondaryExists = $secondaryExists
        primarySha256 = $primaryHash
        secondarySha256 = $secondaryHash
        hashesMatch = $primaryExists -and $secondaryExists -and $primaryHash -eq $secondaryHash
    }
})
$secondaryVerified = @($secondaryFileVerification | Where-Object { -not $_.hashesMatch }).Count -eq 0
$technicalPreflightPass = ($power.ACLineStatus -eq 1) -and $winReEnabled -and
    ([string]$bitLocker.ProtectionStatus -ne 'On' -or $recoveryPasswordCount -ge 1) -and
    [bool]$OffMachineRecoveryKeyConfirmed -and
    $restoreUsable -and (Test-Path -LiteralPath $systemHivePath) -and $secondaryVerified -and
    $disksHealthy -and $targetBindingVerified -and $targetDevicesHealthy -and -not $pendingRebootDetected

$preflight = [ordered]@{
    checkedAt = (Get-Date).ToString('o')
    recoveryPath = $recoveryPath
    secondaryRecoveryPath = $secondaryPath
    acConnected = $power.ACLineStatus -eq 1
    initialState = [ordered]@{
        winRe = [ordered]@{
            state = $winReInitialState
            enabled = $winReEnabled
            infoExitCode = $winReInfoExitCode
            recoveryLocation = $winReLocation
            rawEvidenceFile = 'winre-before.txt'
        }
        systemRestore = [ordered]@{
            operationalAtStart = $systemRestoreOperationalAtStart
            stateBasis = $systemRestoreStateBasis
            restorePointQuerySucceeded = $restoreQuerySucceeded
            restorePointQueryError = $restoreQueryError
            restorePointCountBefore = $restoreBeforeRecords.Count
            policyDisableSR = $policyDisableSR
            policyDisableConfig = $policyDisableConfig
            runtimeDisableSR = $runtimeDisableSR
            scheduledTaskState = if ($null -ne $systemRestoreTask) { [string]$systemRestoreTask.State } else { $null }
            scheduledTaskEnabled = if ($null -ne $systemRestoreTask) { [bool]$systemRestoreTask.Settings.Enabled } else { $null }
        }
    }
    bitLocker = [ordered]@{
        volumeStatus = [string]$bitLocker.VolumeStatus
        protectionStatus = [string]$bitLocker.ProtectionStatus
        encryptionPercentage = $bitLocker.EncryptionPercentage
        recoveryPasswordProtectorPresent = $recoveryPasswordCount -ge 1
        recoveryPasswordProtectorCount = $recoveryPasswordCount
        secretRecorded = $false
    }
    winReEnabled = $winReEnabled
    restorePoint = [ordered]@{
        createdByThisRun = $restoreCreated
        reusedRecentNamedPoint = $restoreReused
        usableRecentPoint = $restoreUsable
        requiredDescription = $checkpointDescription
        cutoff = $checkpointCutoff.ToString('o')
        latestDescription = if ($latestRestore.Count) { [string]$latestRestore[0].Description } else { $null }
        latestCreationTime = if ($latestRestore.Count -and $null -ne $latestRestore[0].CreationDate) { $latestRestore[0].CreationDate.ToString('o') } else { $null }
        usablePointSequenceNumber = if ($usableNamedRestore.Count) { $usableNamedRestore[0].SequenceNumber } else { $null }
        usablePointCreationTime = if ($usableNamedRestore.Count) { $usableNamedRestore[0].CreationDate.ToString('o') } else { $null }
        error = $restoreError
    }
    driverExport = [ordered]@{
        publishedName = $targetPublishedName
        expectedFilesPresent = $true
        hashes = $hashes
        exportOutput = $exportOutput
    }
    systemHiveSaved = (Test-Path -LiteralPath $systemHivePath)
    devices = @($devices)
    driverBindingDiscovery = [ordered]@{
        class = 'DiskDrive'
        presentOnly = $true
        publishedName = $targetPublishedName
        lowerFilter = $targetFilterName
        targetDeviceCount = @($devices).Count
        verified = $targetBindingVerified
        targetDevicesHealthy = $targetDevicesHealthy
    }
    physicalDisks = $physicalDisks
    disksHealthy = $disksHealthy
    pendingReboot = [ordered]@{
        cbs = $cbsReboot
        windowsUpdate = $wuReboot
        pendingFileRenameEntries = $pendingRename
        detected = $pendingRebootDetected
        cleanPreliminaryRestartRequired = $pendingRebootDetected
    }
    offMachineRecoveryKeyConfirmed = [bool]$OffMachineRecoveryKeyConfirmed
    userMustConfirmOffMachineRecoveryKey = -not [bool]$OffMachineRecoveryKeyConfirmed
    driverMutationPerformed = $false
    rebootPerformed = $false
    # Legacy field retained for existing consumers; it means no target-driver mutation.
    mutationPerformed = $false
    secondaryBackup = [ordered]@{
        verified = $secondaryVerified
        files = $secondaryFileVerification
    }
    secondaryBackupVerified = $secondaryVerified
    technicalPreflightPass = $technicalPreflightPass
}

$preflightPath = Join-Path $recoveryPath 'preflight.json'
$preflightJson = $preflight | ConvertTo-Json -Depth 12
[System.IO.File]::WriteAllText($preflightPath, $preflightJson + [Environment]::NewLine, [System.Text.UTF8Encoding]::new($false))

# Copy the already-finalized JSON, then prove the primary and secondary bytes match.
$secondaryPreflightPath = Join-Path $secondaryPath 'preflight.json'
Copy-Item -LiteralPath $preflightPath -Destination $secondaryPreflightPath -Force
$primaryPreflightHash = (Get-FileHash -LiteralPath $preflightPath -Algorithm SHA256).Hash
$secondaryPreflightHash = (Get-FileHash -LiteralPath $secondaryPreflightPath -Algorithm SHA256).Hash
if ($primaryPreflightHash -ne $secondaryPreflightHash) {
    throw 'Finalized primary and secondary preflight JSON hashes do not match'
}
$jsonVerification = [ordered]@{
    checkedAt = (Get-Date).ToString('o')
    finalizedBeforeCopy = $true
    primaryPath = $preflightPath
    secondaryPath = $secondaryPreflightPath
    primarySha256 = $primaryPreflightHash
    secondarySha256 = $secondaryPreflightHash
    hashesMatch = $true
}
$jsonVerificationPath = Join-Path $recoveryPath 'preflight-json-copy-verification.json'
$jsonVerificationJson = $jsonVerification | ConvertTo-Json -Depth 4
[System.IO.File]::WriteAllText($jsonVerificationPath, $jsonVerificationJson + [Environment]::NewLine, [System.Text.UTF8Encoding]::new($false))
Copy-Item -LiteralPath $jsonVerificationPath -Destination (Join-Path $secondaryPath 'preflight-json-copy-verification.json') -Force

Copy-Item -LiteralPath $preflightPath -Destination (Join-Path $root 'CRUWBlocker-preflight-latest.json') -Force
$preflightJson

if (-not $preflight.technicalPreflightPass) { exit 2 }
