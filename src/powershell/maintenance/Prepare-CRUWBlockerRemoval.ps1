[CmdletBinding()]
param(
    [switch] $OffMachineRecoveryKeyConfirmed,
    [switch] $UserDeclaredOriginalSystemRestoreDisabled,
    [switch] $UserDeclaredOriginalWinReDisabled
)

Set-StrictMode -Version Latest
$ErrorActionPreference = 'Stop'

$producerSha256AtStart = [string](Get-FileHash -LiteralPath $PSCommandPath -Algorithm SHA256 -ErrorAction Stop).Hash
$corePath = Join-Path $PSScriptRoot 'CRUWBlockerPreflight.Core.ps1'
if (-not (Test-Path -LiteralPath $corePath)) {
    throw "Required preflight core is missing: $corePath"
}
$coreSha256BeforeLoad = [string](Get-FileHash -LiteralPath $corePath -Algorithm SHA256 -ErrorAction Stop).Hash
. $corePath
$coreSha256AfterLoad = [string](Get-FileHash -LiteralPath $corePath -Algorithm SHA256 -ErrorAction Stop).Hash
if (-not [string]::Equals($coreSha256BeforeLoad, $coreSha256AfterLoad, [StringComparison]::OrdinalIgnoreCase)) {
    throw 'CRUW preflight core changed while being loaded'
}
$implementationContract = Get-CruwImplementationArtifactContract `
    -SourceDirectory $PSScriptRoot `
    -ProducerPath $PSCommandPath
$producerArtifact = @($implementationContract.artifacts | Where-Object { $_.role -eq 'preflight-producer' })
$coreArtifact = @($implementationContract.artifacts | Where-Object { $_.role -eq 'preflight-core' })
if ($producerArtifact.Count -ne 1 -or
    $coreArtifact.Count -ne 1 -or
    -not [string]::Equals([string]$producerArtifact[0].sha256, $producerSha256AtStart, [StringComparison]::OrdinalIgnoreCase) -or
    -not [string]::Equals([string]$coreArtifact[0].sha256, $coreSha256BeforeLoad, [StringComparison]::OrdinalIgnoreCase)) {
    throw 'CRUW preflight implementation changed between load and contract sealing'
}

if (-not ([Security.Principal.WindowsPrincipal][Security.Principal.WindowsIdentity]::GetCurrent()).IsInRole(
    [Security.Principal.WindowsBuiltInRole]::Administrator
)) {
    $pwshCandidate = Join-Path $PSHOME 'pwsh.exe'
    $pwsh = if (Test-Path -LiteralPath $pwshCandidate) { $pwshCandidate } else { (Get-Command powershell.exe -ErrorAction Stop).Source }
    $elevationArguments = @(
        '-NoProfile', '-ExecutionPolicy', 'Bypass', '-File', ('"' + $PSCommandPath + '"')
    )
    if ($OffMachineRecoveryKeyConfirmed) { $elevationArguments += '-OffMachineRecoveryKeyConfirmed' }
    if ($UserDeclaredOriginalSystemRestoreDisabled) { $elevationArguments += '-UserDeclaredOriginalSystemRestoreDisabled' }
    if ($UserDeclaredOriginalWinReDisabled) { $elevationArguments += '-UserDeclaredOriginalWinReDisabled' }
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

$stamp = Get-Date -Format 'yyyyMMdd-HHmmss-fff'
$root = 'C:\Acer-Driver-Audit\Recovery'
$recoveryPath = Join-Path $root "CRUWBlocker-$stamp"
$driverPath = Join-Path $recoveryPath 'driver'
$implementationPath = Join-Path $recoveryPath 'implementation'
$secondaryRoot = 'D:\Acer-Recovery'
$secondaryPath = Join-Path $secondaryRoot "CRUWBlocker-$stamp"
$failurePath = Join-Path $recoveryPath 'preflight-error.txt'
trap {
    $details = ($_ | Format-List * -Force | Out-String)
    if (Test-Path -LiteralPath $recoveryPath -PathType Container) {
        [System.IO.File]::WriteAllText($failurePath, $details, [System.Text.UTF8Encoding]::new($false))
    }
    [Console]::Error.WriteLine($details)
    exit 1
}
$logicalDisks = @(Get-CimInstance -ClassName Win32_LogicalDisk -Filter "DeviceID='C:' OR DeviceID='D:'" -ErrorAction Stop)
foreach ($drive in @('C:', 'D:')) {
    $matches = @($logicalDisks | Where-Object { [string]::Equals([string]$_.DeviceID, $drive, [StringComparison]::OrdinalIgnoreCase) })
    if ($matches.Count -ne 1 -or [int]$matches[0].DriveType -ne 3) {
        throw "Recovery drive must resolve to exactly one local fixed disk before any write: $drive"
    }
}
[void](Assert-CruwLocalRecoveryPathBeforeWrite -CandidatePath $recoveryPath -AllowedBasePath $root -ExpectedDrive 'C:')
[void](Assert-CruwLocalRecoveryPathBeforeWrite -CandidatePath $secondaryPath -AllowedBasePath $secondaryRoot -ExpectedDrive 'D:')
$primaryParentAnchors = @(Enter-CruwDirectoryAnchorChain -DirectoryPath $root -AnchorBasePath 'C:\Acer-Driver-Audit' -ExpectedDrive 'C:')
$secondaryParentAnchors = @(Enter-CruwDirectoryAnchorChain -DirectoryPath $secondaryRoot -AnchorBasePath $secondaryRoot -ExpectedDrive 'D:')
foreach ($fixedParent in @($root, $secondaryRoot)) {
    if (-not (Test-Path -LiteralPath $fixedParent -PathType Container)) {
        throw "Fixed recovery parent must already exist before this transaction: $fixedParent"
    }
    Set-CruwProtectedRecoveryAcl -Path $fixedParent
    $fixedParentAcl = Test-CruwProtectedRecoveryAcl -Path $fixedParent
    if (-not $fixedParentAcl.Verified) {
        throw "Fixed recovery parent is not protected for SYSTEM and Administrators only: $fixedParent"
    }
}
if ((Test-Path -LiteralPath $recoveryPath) -or (Test-Path -LiteralPath $secondaryPath)) {
    throw 'Timestamped recovery roots must not pre-exist'
}
New-Item -ItemType Directory -Path $recoveryPath -ErrorAction Stop | Out-Null
Set-CruwProtectedRecoveryAcl -Path $recoveryPath
New-Item -ItemType Directory -Path $secondaryPath -ErrorAction Stop | Out-Null
Set-CruwProtectedRecoveryAcl -Path $secondaryPath
$primaryRecoveryAnchors = @(Enter-CruwDirectoryAnchorChain -DirectoryPath $recoveryPath -AnchorBasePath $root -ExpectedDrive 'C:')
$secondaryRecoveryAnchors = @(Enter-CruwDirectoryAnchorChain -DirectoryPath $secondaryPath -AnchorBasePath $secondaryRoot -ExpectedDrive 'D:')
[void](Assert-CruwLocalRecoveryPathBeforeWrite -CandidatePath $recoveryPath -AllowedBasePath $root -ExpectedDrive 'C:')
[void](Assert-CruwLocalRecoveryPathBeforeWrite -CandidatePath $secondaryPath -AllowedBasePath $secondaryRoot -ExpectedDrive 'D:')
$freshPrimaryAcl = Test-CruwProtectedRecoveryAcl -Path $recoveryPath
$freshSecondaryAcl = Test-CruwProtectedRecoveryAcl -Path $secondaryPath
if (-not $freshPrimaryAcl.Verified -or -not $freshSecondaryAcl.Verified) {
    throw 'Fresh recovery roots lost their protected ACL before payload writes'
}
New-Item -ItemType Directory -Path $driverPath -Force | Out-Null
New-Item -ItemType Directory -Path $implementationPath -Force | Out-Null
foreach ($artifact in @($implementationContract.artifacts)) {
    $artifactFileName = [IO.Path]::GetFileName([string]$artifact.relativePath)
    $artifactSourcePath = if ($artifact.role -eq 'preflight-producer') {
        $PSCommandPath
    }
    else {
        Join-Path $PSScriptRoot $artifactFileName
    }
    $artifactDestinationPath = Join-Path $implementationPath $artifactFileName
    Copy-Item -LiteralPath $artifactSourcePath -Destination $artifactDestinationPath -Force
    $sealedArtifactSha256 = [string](Get-FileHash -LiteralPath $artifactDestinationPath -Algorithm SHA256).Hash
    if (-not [string]::Equals($sealedArtifactSha256, [string]$artifact.sha256, [StringComparison]::OrdinalIgnoreCase)) {
        throw "CRUW implementation artifact changed while being sealed: $artifactFileName"
    }
}
$sealedImplementationEntries = @(Get-ChildItem -LiteralPath $implementationPath -Force -ErrorAction Stop)
$expectedImplementationNames = @($implementationContract.artifacts | ForEach-Object { [IO.Path]::GetFileName([string]$_.relativePath) })
if ($sealedImplementationEntries.Count -ne $expectedImplementationNames.Count -or
    @($sealedImplementationEntries | Where-Object {
        $_.PSIsContainer -or
        ($_.Attributes -band [IO.FileAttributes]::ReparsePoint) -ne 0 -or
        $expectedImplementationNames -cnotcontains $_.Name
    }).Count -gt 0) {
    throw 'Sealed implementation directory does not contain the exact six-file artifact set'
}
$preflightSchemaVersion = 3
$operatingSystem = Get-CimInstance -ClassName Win32_OperatingSystem -ErrorAction Stop
$lastBootUpTime = if ($operatingSystem.LastBootUpTime -is [datetime]) {
    [datetime]$operatingSystem.LastBootUpTime
}
else {
    [Management.ManagementDateTimeConverter]::ToDateTime([string]$operatingSystem.LastBootUpTime)
}
$lastBootUpTimeUtc = $lastBootUpTime.ToUniversalTime().ToString('o')
$bootMarkerSha256 = Get-CruwSha256Text -Text ($lastBootUpTimeUtc + '|' + [string]$operatingSystem.BuildNumber)
$bootIdentityReady = -not [string]::IsNullOrWhiteSpace($lastBootUpTimeUtc) -and $bootMarkerSha256 -match '^[A-F0-9]{64}$'

$power = [PredatorPowerStatus+SYSTEM_POWER_STATUS]::new()
[void][PredatorPowerStatus]::GetSystemPowerStatus([ref]$power)

$allBitLockerVolumes = @(Get-BitLockerVolume)
$osBitLockerMatches = @($allBitLockerVolumes | Where-Object { ([string]$_.MountPoint).TrimEnd('\') -ieq 'C:' })
if ($osBitLockerMatches.Count -ne 1) { throw 'C: did not resolve to exactly one BitLocker volume' }
$bitLocker = $osBitLockerMatches[0]
# Deliberately count protectors without ever serializing a RecoveryPassword value.
$recoveryPasswordCount = @($bitLocker.KeyProtector | Where-Object KeyProtectorType -eq 'RecoveryPassword').Count
$encryptedMountedVolumeReadiness = @($allBitLockerVolumes | Where-Object {
    -not [string]::IsNullOrWhiteSpace([string]$_.MountPoint) -and
    -not (Test-CruwStringEqual $_.VolumeStatus 'FullyDecrypted')
} | ForEach-Object {
    $volume = $_
    $protectorCount = @($volume.KeyProtector | Where-Object KeyProtectorType -eq 'RecoveryPassword').Count
    $readyForTransaction =
        (Test-CruwStringEqual $volume.VolumeStatus 'FullyEncrypted') -and
        (Test-CruwStringEqual $volume.ProtectionStatus 'On') -and
        (Test-CruwStringEqual $volume.LockStatus 'Unlocked') -and
        [int]$volume.EncryptionPercentage -eq 100 -and
        $protectorCount -ge 1
    [pscustomobject]@{
        MountPoint = [string]$volume.MountPoint
        VolumeStatus = [string]$volume.VolumeStatus
        ProtectionStatus = [string]$volume.ProtectionStatus
        LockStatus = [string]$volume.LockStatus
        EncryptionPercentage = $volume.EncryptionPercentage
        RecoveryPasswordProtectorCount = $protectorCount
        Recoverable = $protectorCount -ge 1
        ReadyForTransaction = $readyForTransaction
    }
})
$allEncryptedMountedVolumesRecoverable = @($encryptedMountedVolumeReadiness | Where-Object { -not $_.Recoverable }).Count -eq 0
$allEncryptedMountedVolumesReady = @($encryptedMountedVolumeReadiness | Where-Object { -not $_.ReadyForTransaction }).Count -eq 0
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
$winReLocationSha256 = $null
if (-not [string]::IsNullOrWhiteSpace($winReLocation)) {
    try {
        $winReLocationSha256 = Get-CruwCanonicalWinReLocationSha256 -Location $winReLocation
    }
    catch {
        $winReLocationSha256 = $null
    }
}
$winReLocationReady = [string]$winReLocationSha256 -match '^[A-F0-9]{64}$'
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
$checkpointNowBefore = Get-Date
$checkpointCutoffBefore = $checkpointNowBefore.AddHours(-23)
$recentNamedBefore = @(Get-CruwLatestRestorePointBySequence -RestorePoints @($restoreBeforeRecords | Where-Object {
    $_.Description -ceq $checkpointDescription -and
    $null -ne $_.CreationDate -and
    $_.CreationDate -ge $checkpointCutoffBefore -and
    $_.CreationDate -le $checkpointNowBefore
}))
$latestRestoreBefore = @(Get-CruwLatestRestorePointBySequence -RestorePoints $restoreBeforeRecords)
$recentNamedBeforeIsLatest = Test-CruwLatestRestorePointMatch `
    -UsableNamedRestore $recentNamedBefore `
    -LatestRestore $latestRestoreBefore

$restoreCreated = $false
$restoreReused = $false
$restoreError = $null
if (-not $restoreQuerySucceeded) {
    $restoreError = "Restore-point inventory failed; checkpoint was not attempted to avoid a duplicate: $restoreQueryError"
}
elseif ($recentNamedBeforeIsLatest) {
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
$checkpointValidationNow = Get-Date
$checkpointCutoff = $checkpointValidationNow.AddHours(-23)
$usableNamedRestore = @(Get-CruwLatestRestorePointBySequence -RestorePoints @($restoreAfterRecords | Where-Object {
    $_.Description -ceq $checkpointDescription -and
    $null -ne $_.CreationDate -and
    $_.CreationDate -ge $checkpointCutoff -and
    $_.CreationDate -le $checkpointValidationNow
}))
$latestRestore = @(Get-CruwLatestRestorePointBySequence -RestorePoints $restoreAfterRecords)
$restoreUsable = Test-CruwLatestRestorePointMatch `
    -UsableNamedRestore $usableNamedRestore `
    -LatestRestore $latestRestore

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
$systemRestoreReady = $restoreQuerySucceeded -and
    $systemRestoreOperationalAtStart -eq $true -and
    $policyDisableSR -ne 1 -and
    $runtimeDisableSR -ne 1 -and
    $restoreUsable

$targetFilterName = 'CRUWBlocker'
$expectedOriginalInf = 'cruwblocker.inf'
$expectedProvider = 'CRU Acquisition Group, LLC'
$expectedDriverClass = 'DiskDrive'
$expectedDriverVersion = '1.2.1.1'
$diskDevices = @(Get-PnpDevice -Class DiskDrive -PresentOnly -ErrorAction Stop)
$diskBindings = @($diskDevices | ForEach-Object {
    $device = $_
    $id = [string]$device.InstanceId
    $inf = Get-PnpDeviceProperty -InstanceId $id -KeyName 'DEVPKEY_Device_DriverInfPath' -ErrorAction Stop
    $lower = Get-PnpDeviceProperty -InstanceId $id -KeyName 'DEVPKEY_Device_LowerFilters' -ErrorAction SilentlyContinue
    $upper = Get-PnpDeviceProperty -InstanceId $id -KeyName 'DEVPKEY_Device_UpperFilters' -ErrorAction SilentlyContinue
    $lowerFilters = if ($null -eq $lower) { @() } else { @($lower.Data) }
    $upperFilters = if ($null -eq $upper) { @() } else { @($upper.Data) }
    $provider = Get-PnpDeviceProperty -InstanceId $id -KeyName 'DEVPKEY_Device_DriverProvider' -ErrorAction Stop
    $version = Get-PnpDeviceProperty -InstanceId $id -KeyName 'DEVPKEY_Device_DriverVersion' -ErrorAction Stop
    [pscustomobject]@{
        DeviceInstanceId = $id
        FriendlyName = [string]$device.FriendlyName
        Status = [string]$device.Status
        ClassName = [string]$device.Class
        PublishedName = [string]$inf.Data
        Provider = [string]$provider.Data
        Version = [string]$version.Data
        LowerFilters = @($lowerFilters)
        UpperFilters = @($upperFilters)
    }
})

$onlineDriverPackages = @(Get-WindowsDriver -Online -All -ErrorAction Stop | ForEach-Object {
    [pscustomobject]@{
        PublishedName = [string]$_.Driver
        OriginalInf = [string]$_.OriginalFileName
        Provider = [string]$_.ProviderName
        ClassName = [string]$_.ClassName
        Version = [string]$_.Version
        BootCritical = [bool]$_.BootCritical
    }
})
$driverIdentity = Resolve-CruwDriverIdentity -DiskBindings $diskBindings -DriverPackages $onlineDriverPackages `
    -ExpectedFilter $targetFilterName -ExpectedOriginalInf $expectedOriginalInf -ExpectedProvider $expectedProvider `
    -ExpectedClass $expectedDriverClass -ExpectedVersion $expectedDriverVersion
$targetPublishedName = [string]$driverIdentity.PublishedName
$targetBindings = @($driverIdentity.TargetBindings)
$targetBindingVerified = $true
$targetDevicesHealthy = @($targetBindings | Where-Object { -not (Test-CruwStringEqual $_.Status 'OK') }).Count -eq 0
$presentDiskTopologyVerified = $diskBindings.Count -eq 2
$targetDeviceCountVerified = $targetBindings.Count -eq 2

$win32Disks = @(Get-CimInstance -ClassName Win32_DiskDrive -ErrorAction Stop)
$volumeLayouts = @(@('C', 'D') | ForEach-Object {
    $driveLetter = $_
    $partition = Get-Partition -DriveLetter $driveLetter -ErrorAction Stop
    $disk = $partition | Get-Disk -ErrorAction Stop
    $volume = Get-Volume -DriveLetter $driveLetter -ErrorAction Stop
    $mappedDisks = @($win32Disks | Where-Object { [int]$_.Index -eq [int]$disk.Number })
    if ($mappedDisks.Count -ne 1) { throw "Drive $driveLetter did not map to exactly one PnP disk" }
    [pscustomobject]@{
        DriveLetter = $driveLetter
        Mounted = (Test-Path -LiteralPath "${driveLetter}:\") -and [string]$volume.DriveLetter -eq $driveLetter
        DiskNumber = [int]$disk.Number
        DeviceInstanceId = [string]$mappedDisks[0].PNPDeviceID
        IsOffline = [bool]$disk.IsOffline
        IsReadOnly = [bool]$disk.IsReadOnly
        DiskHealth = [string]$disk.HealthStatus
        DiskOperationalStatus = @($disk.OperationalStatus | ForEach-Object { [string]$_ })
        VolumeHealth = [string]$volume.HealthStatus
        VolumeOperationalStatus = @($volume.OperationalStatus | ForEach-Object { [string]$_ })
        FileSystem = [string]$volume.FileSystem
    }
})
$volumeLayoutGate = Test-CruwVolumeLayout -VolumeLayouts $volumeLayouts `
    -TargetDeviceInstanceIds @($targetBindings | ForEach-Object { [string]$_.DeviceInstanceId })

$diskInfPath = Join-Path $env:windir 'INF\disk.inf'
$diskInfPackages = @($onlineDriverPackages | Where-Object {
    ((Test-CruwStringEqual ([IO.Path]::GetFileName([string]$_.OriginalInf)) 'disk.inf') -or (Test-CruwStringEqual $_.PublishedName 'disk.inf')) -and
    (Test-CruwStringEqual $_.Provider 'Microsoft') -and
    (Test-CruwStringEqual $_.ClassName 'DiskDrive')
})
$fallbackDeviceChecks = @($targetBindings | ForEach-Object {
    $targetId = [string]$_.DeviceInstanceId
    $fallbackOutput = (& pnputil.exe /enum-devices /instanceid $targetId /drivers 2>&1 | Out-String).Trim()
    $fallbackExitCode = $LASTEXITCODE
    [pscustomobject]@{
        DeviceInstanceIdSha256 = Get-CruwSha256Text -Text $targetId
        ExitCode = $fallbackExitCode
        DiskInfPresent = $fallbackOutput -match '(?i)\bdisk\.inf\b'
    }
})
$fallbackGate = Test-CruwFallbackReadiness -DiskInfFilePresent (Test-Path -LiteralPath $diskInfPath) `
    -DiskInfPackageVerified ($diskInfPackages.Count -ge 1) -DeviceChecks $fallbackDeviceChecks -ExpectedDeviceCount 2

$exportOutput = (& pnputil.exe /export-driver $targetPublishedName $driverPath 2>&1 | Out-String).Trim()
if ($LASTEXITCODE -ne 0) { throw "Driver export failed for $targetPublishedName`: $exportOutput" }
$expectedFiles = @('cruwblocker.inf', 'CRUWBlocker.sys', 'CRUWBlocker.cat')
$exportedFiles = @(Get-ChildItem -LiteralPath $driverPath -Force -ErrorAction Stop)
if ($exportedFiles.Count -ne $expectedFiles.Count -or
    @($exportedFiles | Where-Object {
        $_.PSIsContainer -or
        ($_.Attributes -band [IO.FileAttributes]::ReparsePoint) -ne 0 -or
        $expectedFiles -cnotcontains $_.Name
    }).Count -gt 0) {
    throw 'Driver export must contain exactly cruwblocker.inf, CRUWBlocker.sys and CRUWBlocker.cat with no extra payload'
}
foreach ($expected in $expectedFiles) {
    if ($exportedFiles.Name -cnotcontains $expected) { throw "Export is incomplete; missing exact-case $expected" }
}
$hashes = @($exportedFiles | Get-FileHash -Algorithm SHA256 | Select-Object @{n='file';e={Split-Path -Leaf $_.Path}}, Hash)
$exportedDriverMatches = @($exportedFiles | Where-Object Name -ieq 'CRUWBlocker.sys')
$exportedCatalogMatches = @($exportedFiles | Where-Object Name -ieq 'CRUWBlocker.cat')
if ($exportedDriverMatches.Count -ne 1 -or $exportedCatalogMatches.Count -ne 1) {
    throw 'Exported CRUWBlocker driver/catalog identity is ambiguous'
}
$exportedDriverPath = $exportedDriverMatches[0].FullName
$exportedCatalogPath = $exportedCatalogMatches[0].FullName
$exportedDriverSignature = Get-AuthenticodeSignature -FilePath $exportedDriverPath
$exportedCatalogSignature = Get-AuthenticodeSignature -FilePath $exportedCatalogPath
$exportedInfMatches = @($exportedFiles | Where-Object Name -ieq 'cruwblocker.inf')
if ($exportedInfMatches.Count -ne 1) { throw 'Exported CRUWBlocker INF identity is ambiguous' }
$exportedInfPath = $exportedInfMatches[0].FullName
$exportedInfSignature = Get-AuthenticodeSignature -FilePath $exportedInfPath
$exportedPackageSigned = $exportedInfSignature.Status -eq [Management.Automation.SignatureStatus]::Valid -and
    $exportedDriverSignature.Status -eq [Management.Automation.SignatureStatus]::Valid -and
    $exportedCatalogSignature.Status -eq [Management.Automation.SignatureStatus]::Valid
$exportedInfSha256 = (Get-FileHash -LiteralPath $exportedInfPath -Algorithm SHA256).Hash
$exportedInfText = [IO.File]::ReadAllText($exportedInfPath)
$knownPackageSha256 = [ordered]@{
    'cruwblocker.inf' = 'D9A075F6849EE76CD43BBA4C4FE6B27D27A5788D9A25695413E7791CCA5EBA2B'
    'CRUWBlocker.sys' = 'F59BE364EB9360C999C6F68218100D0A343BA8D1D67E5AC4419DD79C56A7A18C'
    'CRUWBlocker.cat' = '5D8298B9C1908A84E2CD68B6AFF4EA71E9AF3F5B3C850694A74626775A4E3862'
}
$knownPackageHashesVerified = @($hashes | Where-Object {
    $expectedHash = $knownPackageSha256[[string]$_.file]
    [string]::IsNullOrWhiteSpace([string]$expectedHash) -or
    -not [string]::Equals([string]$_.Hash, [string]$expectedHash, [StringComparison]::OrdinalIgnoreCase)
}).Count -eq 0 -and $hashes.Count -eq $knownPackageSha256.Count

$systemHivePath = Join-Path $recoveryPath 'SYSTEM.before.hiv'
$regOutput = (& reg.exe save 'HKLM\SYSTEM' $systemHivePath /y 2>&1 | Out-String).Trim()
if ($LASTEXITCODE -ne 0 -or -not (Test-Path -LiteralPath $systemHivePath)) { throw "SYSTEM hive backup failed: $regOutput" }

$diskDriverInventory = (& pnputil.exe /enum-devices /class DiskDrive /drivers 2>&1 | Out-String).Trim()
if ($LASTEXITCODE -ne 0) { throw 'Full DiskDrive driver inventory failed' }
[System.IO.File]::WriteAllText((Join-Path $recoveryPath 'disk-drivers-before.txt'), $diskDriverInventory, [System.Text.UTF8Encoding]::new($false))
[System.IO.File]::WriteAllText((Join-Path $recoveryPath 'winre-before.txt'), $winReOutput, [System.Text.UTF8Encoding]::new($false))

$devices = @($targetBindings | ForEach-Object {
    [ordered]@{
        instanceIdSha256 = Get-CruwSha256Text -Text ([string]$_.DeviceInstanceId)
        friendlyName = [string]$_.FriendlyName
        status = [string]$_.Status
        className = [string]$_.ClassName
        inf = [string]$_.PublishedName
        provider = [string]$_.Provider
        version = [string]$_.Version
        lowerFilters = @($_.LowerFilters)
        upperFilters = @($_.UpperFilters)
    }
})

$diskDriveClassGuid = '{4D36E967-E325-11CE-BFC1-08002BE10318}'
$diskClassRegistryPath = "HKLM:\SYSTEM\CurrentControlSet\Control\Class\$diskDriveClassGuid"
$diskClassRegistry = Get-ItemProperty -LiteralPath $diskClassRegistryPath -ErrorAction Stop
$classLowerFilters = @(Get-CruwPropertyValue -InputObject $diskClassRegistry -Name 'LowerFilters')
$classUpperFilters = @(Get-CruwPropertyValue -InputObject $diskClassRegistry -Name 'UpperFilters')
$filterServiceRegistryPath = 'HKLM:\SYSTEM\CurrentControlSet\Services\CRUWBlocker'
$filterServiceRegistry = Get-ItemProperty -LiteralPath $filterServiceRegistryPath -ErrorAction Stop
$filterServiceStartOverridePath = Join-Path $filterServiceRegistryPath 'StartOverride'
$filterServiceStartOverrideAbsent = -not (Test-Path -LiteralPath $filterServiceStartOverridePath)
$filterSystemDrivers = @(Get-CimInstance -ClassName Win32_SystemDriver -Filter "Name='CRUWBlocker'" -ErrorAction Stop)
$filterServiceBinaryPath = Join-Path $env:windir 'System32\drivers\CRUWBlocker.sys'
$filterServiceImagePath = [string]$filterServiceRegistry.ImagePath
$filterServiceImagePathReady = $filterServiceImagePath -match '(?i)^(?:\\SystemRoot\\)?System32\\drivers\\CRUWBlocker\.sys$'
$filterServiceBinarySha256 = if (Test-Path -LiteralPath $filterServiceBinaryPath) {
    (Get-FileHash -LiteralPath $filterServiceBinaryPath -Algorithm SHA256).Hash
}
else { $null }
$exportedDriverSha256 = (Get-FileHash -LiteralPath $exportedDriverPath -Algorithm SHA256).Hash
$exportedCatalogSha256 = (Get-FileHash -LiteralPath $exportedCatalogPath -Algorithm SHA256).Hash
$filterServiceBinaryMatchesExport = -not [string]::IsNullOrWhiteSpace($filterServiceBinarySha256) -and
    $filterServiceBinarySha256 -eq $exportedDriverSha256
$exportedPackageVerified = $exportedPackageSigned -and $knownPackageHashesVerified -and $filterServiceBinaryMatchesExport
$filterServiceReady = $filterSystemDrivers.Count -eq 1 -and
    (Test-CruwStringEqual $filterSystemDrivers[0].State 'Running') -and
    [int]$filterServiceRegistry.Type -eq 1 -and [int]$filterServiceRegistry.Start -eq 0 -and
    [int]$filterServiceRegistry.ErrorControl -eq 1 -and
    (Test-CruwStringEqual $filterServiceRegistry.Group 'Pnp Filter') -and
    $filterServiceStartOverrideAbsent -and
    $filterServiceImagePathReady -and (Test-Path -LiteralPath $filterServiceBinaryPath) -and
    $filterServiceBinaryMatchesExport -and $exportedPackageVerified
$setupApiPromotionEvidence = @(Get-CruwSetupApiPromotionEvidence -InfDirectory (Join-Path $env:windir 'INF'))
$rollbackCapability = Get-CruwRollbackCapabilityContract `
    -InfText $exportedInfText `
    -ExportedPackageVerified $exportedPackageVerified `
    -ExportedInfSha256 $exportedInfSha256 `
    -LiveService ([pscustomobject]@{
        Start = $filterServiceRegistry.Start
        Type = $filterServiceRegistry.Type
        ErrorControl = $filterServiceRegistry.ErrorControl
        Group = $filterServiceRegistry.Group
        ImagePath = $filterServiceImagePath
        StartOverrideAbsent = $filterServiceStartOverrideAbsent
        State = if ($filterSystemDrivers.Count -eq 1) { [string]$filterSystemDrivers[0].State } else { $null }
    }) `
    -PromotionEvidence $setupApiPromotionEvidence
$filterSnapshot = [ordered]@{
    schemaVersion = 1
    capturedAt = (Get-Date).ToString('o')
    bootMarkerSha256 = $bootMarkerSha256
    diskDriveClassGuid = $diskDriveClassGuid
    publishedName = $targetPublishedName
    classFilters = [ordered]@{
        lowerFilters = @($classLowerFilters)
        upperFilters = @($classUpperFilters)
    }
    targetDevices = @($targetBindings | ForEach-Object {
        [ordered]@{
            instanceIdSha256 = Get-CruwSha256Text -Text ([string]$_.DeviceInstanceId)
            lowerFilters = @($_.LowerFilters)
            upperFilters = @($_.UpperFilters)
        }
    })
    service = [ordered]@{
        name = 'CRUWBlocker'
        start = [int]$filterServiceRegistry.Start
        type = [int]$filterServiceRegistry.Type
        errorControl = [int]$filterServiceRegistry.ErrorControl
        group = [string]$filterServiceRegistry.Group
        imagePath = $filterServiceImagePath
        imagePathCanonical = ConvertTo-CruwCanonicalServiceImagePath -ImagePath $filterServiceImagePath
        startOverrideAbsent = $filterServiceStartOverrideAbsent
        imagePathVerified = $filterServiceImagePathReady
        state = if ($filterSystemDrivers.Count -eq 1) { [string]$filterSystemDrivers[0].State } else { $null }
        binaryPresent = Test-Path -LiteralPath $filterServiceBinaryPath
        binarySha256 = $filterServiceBinarySha256
        binaryMatchesExport = $filterServiceBinaryMatchesExport
        exportedDriverSignatureStatus = [string]$exportedDriverSignature.Status
        exportedCatalogSignatureStatus = [string]$exportedCatalogSignature.Status
        exportedInfSignatureStatus = [string]$exportedInfSignature.Status
        knownPackageHashesVerified = $knownPackageHashesVerified
        ready = $filterServiceReady
    }
}
$filterSnapshotPath = Join-Path $recoveryPath 'filter-snapshot-before.json'
$filterSnapshotJson = $filterSnapshot | ConvertTo-Json -Depth 8
[System.IO.File]::WriteAllText($filterSnapshotPath, $filterSnapshotJson + [Environment]::NewLine, [System.Text.UTF8Encoding]::new($false))

$physicalDisks = @(Get-PhysicalDisk | Select-Object FriendlyName, HealthStatus, OperationalStatus)
$disksHealthy = $physicalDisks.Count -ge 2 -and @($physicalDisks | Where-Object {
    $operationalStatus = @($_.OperationalStatus)
    -not (Test-CruwStringEqual $_.HealthStatus 'Healthy') -or
    $operationalStatus.Count -ne 1 -or
    -not (Test-CruwStringEqual $operationalStatus[0] 'OK')
}).Count -eq 0
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
    'winre-before.txt',
    'filter-snapshot-before.json'
) + @($implementationContract.artifacts | ForEach-Object { [string]$_.relativePath })
Get-ChildItem -LiteralPath $recoveryPath -Force | Copy-Item -Destination $secondaryPath -Recurse -Force
[void](Assert-CruwExactRecoveryTree -RootPath $recoveryPath -RequiredRelativeFiles $requiredBackupFiles)
[void](Assert-CruwExactRecoveryTree -RootPath $secondaryPath -RequiredRelativeFiles $requiredBackupFiles)
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
[void](Assert-CruwImplementationArtifactFileHashes `
    -ImplementationContract $implementationContract `
    -FileVerification $secondaryFileVerification)
[void](Assert-CruwDriverPayloadFileHashes `
    -DriverExportHashes $hashes `
    -FileVerification $secondaryFileVerification `
    -ExportedInfSha256 $exportedInfSha256 `
    -ExportedDriverSha256 $exportedDriverSha256 `
    -ExportedCatalogSha256 $exportedCatalogSha256)
$secondaryVerified = @($secondaryFileVerification | Where-Object { -not $_.hashesMatch }).Count -eq 0
Set-CruwProtectedRecoveryTreeAcl -Path $recoveryPath
Set-CruwProtectedRecoveryTreeAcl -Path $secondaryPath
$primaryAcl = Test-CruwProtectedRecoveryAcl -Path $recoveryPath -Recurse
$secondaryAcl = Test-CruwProtectedRecoveryAcl -Path $secondaryPath -Recurse
$bitLockerReady = (Test-CruwStringEqual $bitLocker.VolumeStatus 'FullyEncrypted') -and
    (Test-CruwStringEqual $bitLocker.ProtectionStatus 'On') -and
    (Test-CruwStringEqual $bitLocker.LockStatus 'Unlocked') -and
    [int]$bitLocker.EncryptionPercentage -eq 100 -and
    $recoveryPasswordCount -ge 1
$technicalPreflightPass = ($power.ACLineStatus -eq 1) -and $winReEnabled -and $winReLocationReady -and
    $bitLockerReady -and $allEncryptedMountedVolumesRecoverable -and $allEncryptedMountedVolumesReady -and
    [bool]$OffMachineRecoveryKeyConfirmed -and
    $systemRestoreReady -and (Test-Path -LiteralPath $systemHivePath) -and $secondaryVerified -and
    $primaryAcl.Verified -and $secondaryAcl.Verified -and
    $disksHealthy -and $targetBindingVerified -and $targetDevicesHealthy -and
    $presentDiskTopologyVerified -and $targetDeviceCountVerified -and $bootIdentityReady -and
    $filterServiceReady -and $rollbackCapability.automaticRollbackEligible -and
    $volumeLayoutGate.Verified -and $fallbackGate.Verified -and -not $pendingRebootDetected

$preflight = [ordered]@{
    schemaVersion = $preflightSchemaVersion
    checkedAt = (Get-Date).ToString('o')
    implementation = $implementationContract
    bootIdentity = [ordered]@{
        lastBootUpTimeUtc = $lastBootUpTimeUtc
        operatingSystemBuild = [string]$operatingSystem.BuildNumber
        markerSha256 = $bootMarkerSha256
        removalMustMatchThisBoot = $true
        verified = $bootIdentityReady
    }
    recoveryPath = $recoveryPath
    secondaryRecoveryPath = $secondaryPath
    acConnected = $power.ACLineStatus -eq 1
    initialState = [ordered]@{
        winRe = [ordered]@{
            state = $winReInitialState
            enabled = $winReEnabled
            userDeclaredOriginalDisabled = [bool]$UserDeclaredOriginalWinReDisabled
            originalStateDeclarationSource = if ($UserDeclaredOriginalWinReDisabled) { 'explicit-user-switch' } else { 'not-provided' }
            originalStateWasNotInferred = $true
            infoExitCode = $winReInfoExitCode
            recoveryLocation = $winReLocation
            recoveryLocationSha256 = $winReLocationSha256
            recoveryLocationVerified = $winReLocationReady
            rawEvidenceFile = 'winre-before.txt'
        }
        systemRestore = [ordered]@{
            readyForTransaction = $systemRestoreReady
            operationalAtStart = $systemRestoreOperationalAtStart
            stateBasis = $systemRestoreStateBasis
            userDeclaredOriginalDisabled = [bool]$UserDeclaredOriginalSystemRestoreDisabled
            originalStateDeclarationSource = if ($UserDeclaredOriginalSystemRestoreDisabled) { 'explicit-user-switch' } else { 'not-provided' }
            originalStateWasNotInferred = $true
            restorePointQuerySucceeded = $restoreQuerySucceeded
            restorePointQueryError = $restoreQueryError
            restorePointCountBefore = $restoreBeforeRecords.Count
            policyDisableSR = $policyDisableSR
            policyDisableConfig = $policyDisableConfig
            disableConfigRecordedButNotUsedAsDisableSignal = $true
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
        readyForBoundedSuspension = $bitLockerReady
        allEncryptedMountedVolumesRecoverable = $allEncryptedMountedVolumesRecoverable
        allEncryptedMountedVolumesReady = $allEncryptedMountedVolumesReady
        mountedEncryptedVolumes = @($encryptedMountedVolumeReadiness | ForEach-Object {
            [ordered]@{
                mountPoint = [string]$_.MountPoint
                volumeStatus = [string]$_.VolumeStatus
                protectionStatus = [string]$_.ProtectionStatus
                lockStatus = [string]$_.LockStatus
                encryptionPercentage = $_.EncryptionPercentage
                recoveryPasswordProtectorCount = $_.RecoveryPasswordProtectorCount
                recoverable = [bool]$_.Recoverable
                readyForTransaction = [bool]$_.ReadyForTransaction
            }
        })
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
        latestSequenceNumber = if ($latestRestore.Count) { [long]$latestRestore[0].SequenceNumber } else { $null }
        latestCreationTime = if ($latestRestore.Count -and $null -ne $latestRestore[0].CreationDate) { $latestRestore[0].CreationDate.ToString('o') } else { $null }
        usablePointSequenceNumber = if ($restoreUsable) { $usableNamedRestore[0].SequenceNumber } else { $null }
        usablePointCreationTime = if ($restoreUsable) { $usableNamedRestore[0].CreationDate.ToString('o') } else { $null }
        error = $restoreError
    }
    driverExport = [ordered]@{
        publishedName = $targetPublishedName
        originalInf = [string]$driverIdentity.OriginalInf
        provider = [string]$driverIdentity.Provider
        className = [string]$driverIdentity.ClassName
        version = [string]$driverIdentity.Version
        expectedFilesPresent = $true
        hashes = $hashes
        driverSignatureStatus = [string]$exportedDriverSignature.Status
        catalogSignatureStatus = [string]$exportedCatalogSignature.Status
        infSignatureStatus = [string]$exportedInfSignature.Status
        signaturesValid = $exportedPackageSigned
        knownPackageHashesVerified = $knownPackageHashesVerified
        exportOutput = $exportOutput
    }
    rollbackCapability = $rollbackCapability
    systemHiveSaved = (Test-Path -LiteralPath $systemHivePath)
    devices = @($devices)
    driverBindingDiscovery = [ordered]@{
        class = 'DiskDrive'
        presentOnly = $true
        publishedName = $targetPublishedName
        lowerFilter = $targetFilterName
        targetDeviceCount = @($devices).Count
        expectedTargetDeviceCount = 2
        presentDiskDriveCount = $diskBindings.Count
        exactlyTwoPresentDiskDrives = $presentDiskTopologyVerified
        exactlyTwoTargetBindings = $targetDeviceCountVerified
        allPackageBindingsAlsoHaveFilter = $true
        identityCrossCheck = [ordered]@{
            originalInf = Test-CruwStringEqual $driverIdentity.OriginalInf $expectedOriginalInf
            provider = Test-CruwStringEqual $driverIdentity.Provider $expectedProvider
            className = Test-CruwStringEqual $driverIdentity.ClassName $expectedDriverClass
            version = Test-CruwStringEqual $driverIdentity.Version $expectedDriverVersion
        }
        verified = $targetBindingVerified
        targetDevicesHealthy = $targetDevicesHealthy
    }
    filterSnapshot = [ordered]@{
        relativePath = 'filter-snapshot-before.json'
        sha256 = (Get-FileHash -LiteralPath $filterSnapshotPath -Algorithm SHA256).Hash
        deviceAndClassUpperAndLowerFiltersCaptured = $true
        serviceReady = $filterServiceReady
    }
    storageLayout = [ordered]@{
        verified = $volumeLayoutGate.Verified
        failures = @($volumeLayoutGate.Failures)
        distinctPhysicalDiskCount = $volumeLayoutGate.DistinctPhysicalDiskCount
        volumes = @($volumeLayouts | ForEach-Object {
            [ordered]@{
                driveLetter = [string]$_.DriveLetter
                mounted = [bool]$_.Mounted
                diskNumber = [int]$_.DiskNumber
                deviceInstanceIdSha256 = Get-CruwSha256Text -Text ([string]$_.DeviceInstanceId)
                offline = [bool]$_.IsOffline
                readOnly = [bool]$_.IsReadOnly
                diskHealth = [string]$_.DiskHealth
                diskOperationalStatus = @($_.DiskOperationalStatus)
                volumeHealth = [string]$_.VolumeHealth
                volumeOperationalStatus = @($_.VolumeOperationalStatus)
                fileSystem = [string]$_.FileSystem
            }
        })
    }
    fallbackDriver = [ordered]@{
        publishedName = 'disk.inf'
        filePresent = Test-Path -LiteralPath $diskInfPath
        microsoftDiskDrivePackagePresent = $diskInfPackages.Count -ge 1
        deviceChecks = @($fallbackDeviceChecks)
        failures = @($fallbackGate.Failures)
        verified = $fallbackGate.Verified
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
    restorationIntent = [ordered]@{
        winReOriginalState = if ($UserDeclaredOriginalWinReDisabled) { 'Disabled' } else { 'Unknown' }
        winReOriginalStateSource = if ($UserDeclaredOriginalWinReDisabled) { 'explicit-user-switch' } else { 'not-provided' }
        systemRestoreOriginalState = if ($UserDeclaredOriginalSystemRestoreDisabled) { 'Disabled' } else { 'Unknown' }
        systemRestoreOriginalStateSource = if ($UserDeclaredOriginalSystemRestoreDisabled) { 'explicit-user-switch' } else { 'not-provided' }
        declarationAffectsTechnicalPass = $false
    }
    driverMutationPerformed = $false
    rebootPerformed = $false
    # Legacy field retained for existing consumers; it means no target-driver mutation.
    mutationPerformed = $false
    secondaryBackup = [ordered]@{
        verified = $secondaryVerified
        files = $secondaryFileVerification
    }
    protectedAcl = [ordered]@{
        primary = $primaryAcl
        secondary = $secondaryAcl
        onlySystemAndAdministrators = $primaryAcl.Verified -and $secondaryAcl.Verified
    }
    secondaryBackupVerified = $secondaryVerified
    technicalPreflightPass = $technicalPreflightPass
}

$preflightPath = Join-Path $recoveryPath 'preflight.json'
$preflightJson = $preflight | ConvertTo-Json -Depth 12
[System.IO.File]::WriteAllText($preflightPath, $preflightJson + [Environment]::NewLine, [System.Text.UTF8Encoding]::new($false))

# Copy the already-finalized JSON, then prove every recovery payload byte matches.
$secondaryPreflightPath = Join-Path $secondaryPath 'preflight.json'
Copy-Item -LiteralPath $preflightPath -Destination $secondaryPreflightPath -Force
$finalRequiredBackupFiles = @($requiredBackupFiles) + @('preflight.json')
[void](Assert-CruwExactRecoveryTree -RootPath $recoveryPath -RequiredRelativeFiles $finalRequiredBackupFiles)
[void](Assert-CruwExactRecoveryTree -RootPath $secondaryPath -RequiredRelativeFiles $finalRequiredBackupFiles)
$finalFileVerification = @($finalRequiredBackupFiles | ForEach-Object {
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
if (@($finalFileVerification | Where-Object { -not $_.hashesMatch }).Count -gt 0) {
    throw 'One or more finalized primary and secondary recovery payload hashes do not match'
}
[void](Assert-CruwImplementationArtifactFileHashes `
    -ImplementationContract $implementationContract `
    -FileVerification $finalFileVerification)
[void](Assert-CruwDriverPayloadFileHashes `
    -DriverExportHashes $hashes `
    -FileVerification $finalFileVerification `
    -ExportedInfSha256 $exportedInfSha256 `
    -ExportedDriverSha256 $exportedDriverSha256 `
    -ExportedCatalogSha256 $exportedCatalogSha256)

$integrityManifest = [ordered]@{
    schemaVersion = 1
    role = 'authoritative-removal-preflight-manifest'
    checkedAt = (Get-Date).ToString('o')
    finalizedBeforeCopy = $true
    recoveryPath = $recoveryPath
    secondaryRecoveryPath = $secondaryPath
    bootIdentity = [ordered]@{
        lastBootUpTimeUtc = $lastBootUpTimeUtc
        markerSha256 = $bootMarkerSha256
    }
    implementation = $implementationContract
    driverIdentity = [ordered]@{
        publishedName = $targetPublishedName
        originalInf = [string]$driverIdentity.OriginalInf
        provider = [string]$driverIdentity.Provider
        className = [string]$driverIdentity.ClassName
        version = [string]$driverIdentity.Version
        targetDeviceCount = $targetBindings.Count
        exportedInfSha256 = $exportedInfSha256
        exportedDriverSha256 = $exportedDriverSha256
        exportedCatalogSha256 = $exportedCatalogSha256
        infSignatureStatus = [string]$exportedInfSignature.Status
        driverSignatureStatus = [string]$exportedDriverSignature.Status
        catalogSignatureStatus = [string]$exportedCatalogSignature.Status
        signaturesValid = $exportedPackageSigned
        knownPackageHashesVerified = $knownPackageHashesVerified
        installedBinaryMatchesExport = $filterServiceBinaryMatchesExport
    }
    technicalPreflightPass = $technicalPreflightPass
    requiredRelativePaths = @($finalRequiredBackupFiles | Sort-Object)
    requiredFileCount = $finalRequiredBackupFiles.Count
    files = $finalFileVerification
    allHashesMatch = $true
    removalValidationContract = [ordered]@{
        trustPreflightJsonWithoutThisManifest = $false
        recomputeEveryListedHash = $true
        requirePrimarySecondaryManifestByteEquality = $true
        requireSameBootMarker = $true
        requireProtectedAcl = $true
    }
}
$finalizedPreflight = Get-Content -LiteralPath $preflightPath -Raw -ErrorAction Stop | ConvertFrom-Json -ErrorAction Stop
if ([int]$finalizedPreflight.schemaVersion -ne 3) {
    throw 'Only CRUW preflight schema version 3 can be sealed into the final integrity manifest'
}
$preflightImplementationJson = $finalizedPreflight.implementation | ConvertTo-Json -Depth 5 -Compress
$manifestImplementationJson = $integrityManifest.implementation | ConvertTo-Json -Depth 5 -Compress
if (-not [string]::Equals($preflightImplementationJson, $manifestImplementationJson, [StringComparison]::Ordinal)) {
    throw 'Preflight and integrity manifest implementation contracts are not byte-identical'
}
$integrityManifestPath = Join-Path $recoveryPath 'backup-integrity-final.json'
$secondaryIntegrityManifestPath = Join-Path $secondaryPath 'backup-integrity-final.json'
$integrityManifestJson = $integrityManifest | ConvertTo-Json -Depth 6
[System.IO.File]::WriteAllText($integrityManifestPath, $integrityManifestJson + [Environment]::NewLine, [System.Text.UTF8Encoding]::new($false))
Copy-Item -LiteralPath $integrityManifestPath -Destination $secondaryIntegrityManifestPath -Force
$primaryIntegrityHash = (Get-FileHash -LiteralPath $integrityManifestPath -Algorithm SHA256).Hash
$secondaryIntegrityHash = (Get-FileHash -LiteralPath $secondaryIntegrityManifestPath -Algorithm SHA256).Hash
if ($primaryIntegrityHash -ne $secondaryIntegrityHash) { throw 'Final integrity manifest hashes do not match' }
$sealedTreeFiles = @($finalRequiredBackupFiles) + @('backup-integrity-final.json')
[void](Assert-CruwExactRecoveryTree -RootPath $recoveryPath -RequiredRelativeFiles $sealedTreeFiles)
[void](Assert-CruwExactRecoveryTree -RootPath $secondaryPath -RequiredRelativeFiles $sealedTreeFiles)

Set-CruwProtectedRecoveryTreeAcl -Path $recoveryPath
Set-CruwProtectedRecoveryTreeAcl -Path $secondaryPath
$finalPrimaryAcl = Test-CruwProtectedRecoveryAcl -Path $recoveryPath -Recurse
$finalSecondaryAcl = Test-CruwProtectedRecoveryAcl -Path $secondaryPath -Recurse
if (-not $finalPrimaryAcl.Verified -or -not $finalSecondaryAcl.Verified) {
    throw 'A finalized recovery tree no longer has the required SYSTEM-and-Administrators-only ACL'
}

$latestPreflightPath = Join-Path $root 'CRUWBlocker-preflight-latest.json'
Copy-Item -LiteralPath $preflightPath -Destination $latestPreflightPath -Force
Set-CruwProtectedFileAcl -Path $latestPreflightPath
$latestAcl = Test-CruwProtectedRecoveryAcl -Path $latestPreflightPath
if (-not $latestAcl.Verified) { throw 'Latest preflight pointer does not have a protected ACL' }
$allRecoveryAnchors = @($primaryParentAnchors) + @($secondaryParentAnchors) + @($primaryRecoveryAnchors) + @($secondaryRecoveryAnchors)
Exit-CruwDirectoryAnchorChain -Anchors $allRecoveryAnchors
$preflightJson

if (-not $preflight.technicalPreflightPass) { exit 2 }
