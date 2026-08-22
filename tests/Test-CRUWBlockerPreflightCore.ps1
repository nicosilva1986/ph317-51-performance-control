[CmdletBinding()]
param()

Set-StrictMode -Version Latest
$ErrorActionPreference = 'Stop'

$repoRoot = Split-Path -Parent $PSScriptRoot
$corePath = Join-Path $repoRoot 'src\powershell\maintenance\CRUWBlockerPreflight.Core.ps1'
$preflightPath = Join-Path $repoRoot 'src\powershell\maintenance\Prepare-CRUWBlockerRemoval.ps1'
. $corePath

$assertionCount = 0
function Assert-True {
    param([Parameter(Mandatory)] [bool] $Condition, [Parameter(Mandatory)] [string] $Message)
    $script:assertionCount++
    if (-not $Condition) { throw "ASSERTION FAILED: $Message" }
}

function Assert-Throws {
    param([Parameter(Mandatory)] [scriptblock] $Action, [Parameter(Mandatory)] [string] $Message)
    $script:assertionCount++
    $threw = $false
    try { & $Action }
    catch { $threw = $true }
    if (-not $threw) { throw "ASSERTION FAILED: $Message" }
}

function New-TestBinding {
    param(
        [string] $Id,
        [string] $PublishedName = 'oem42.inf',
        [string[]] $LowerFilters = @('CRUWBlocker'),
        [string] $Provider = 'CRU Acquisition Group, LLC',
        [string] $ClassName = 'DiskDrive',
        [string] $Version = '1.2.1.1',
        [string] $Status = 'OK'
    )
    [pscustomobject]@{
        DeviceInstanceId = $Id
        FriendlyName = $Id
        PublishedName = $PublishedName
        LowerFilters = $LowerFilters
        Provider = $Provider
        ClassName = $ClassName
        Version = $Version
        Status = $Status
    }
}

function New-TestPackage {
    param(
        [string] $PublishedName = 'oem42.inf',
        [string] $OriginalInf = 'C:\Windows\System32\DriverStore\FileRepository\cruwblocker.inf_amd64_test\cruwblocker.inf',
        [string] $Provider = 'CRU Acquisition Group, LLC',
        [string] $ClassName = 'DiskDrive',
        [string] $Version = '1.2.1.1'
    )
    [pscustomobject]@{
        PublishedName = $PublishedName
        OriginalInf = $OriginalInf
        Provider = $Provider
        ClassName = $ClassName
        Version = $Version
    }
}

$validBindings = @(
    (New-TestBinding -Id 'TEST\DISK0'),
    (New-TestBinding -Id 'TEST\DISK1')
)
$validPackages = @((New-TestPackage))
$identity = Resolve-CruwDriverIdentity -DiskBindings $validBindings -DriverPackages $validPackages
Assert-True ($identity.PublishedName -eq 'oem42.inf') 'published name must be discovered rather than pinned'
Assert-True ($identity.TargetBindings.Count -eq 2) 'both filtered disk bindings must be retained'
Assert-True ($identity.OriginalInf -eq 'cruwblocker.inf') 'original INF must be reduced and verified'

Assert-Throws {
    Resolve-CruwDriverIdentity -DiskBindings @(
        (New-TestBinding -Id 'TEST\DISK0'),
        (New-TestBinding -Id 'TEST\DISK1' -LowerFilters @())
    ) -DriverPackages $validPackages | Out-Null
} 'a package-bound disk without the lower filter must fail'

foreach ($badPackage in @(
    (New-TestPackage -OriginalInf 'wrong.inf'),
    (New-TestPackage -Provider 'Unexpected Provider'),
    (New-TestPackage -ClassName 'System'),
    (New-TestPackage -Version '9.9.9.9')
)) {
    Assert-Throws {
        Resolve-CruwDriverIdentity -DiskBindings $validBindings -DriverPackages @($badPackage) | Out-Null
    } 'original INF, provider, class and version package drift must fail'
}

Assert-Throws {
    Resolve-CruwDriverIdentity -DiskBindings @(
        (New-TestBinding -Id 'TEST\DISK0' -PublishedName 'oem42.inf'),
        (New-TestBinding -Id 'TEST\DISK1' -PublishedName 'oem99.inf')
    ) -DriverPackages @((New-TestPackage), (New-TestPackage -PublishedName 'oem99.inf')) | Out-Null
} 'multiple published packages behind one filter must fail'

function New-TestVolumeLayout {
    param(
        [string] $DriveLetter,
        [int] $DiskNumber,
        [string] $DeviceInstanceId,
        [bool] $IsReadOnly = $false,
        [string] $DiskHealth = 'Healthy'
    )
    [pscustomobject]@{
        DriveLetter = $DriveLetter
        Mounted = $true
        DiskNumber = $DiskNumber
        DeviceInstanceId = $DeviceInstanceId
        IsOffline = $false
        IsReadOnly = $IsReadOnly
        DiskHealth = $DiskHealth
        DiskOperationalStatus = @('Online')
        VolumeHealth = 'Healthy'
        VolumeOperationalStatus = @('OK')
        FileSystem = 'NTFS'
    }
}

$validLayouts = @(
    (New-TestVolumeLayout -DriveLetter C -DiskNumber 0 -DeviceInstanceId 'TEST\DISK0'),
    (New-TestVolumeLayout -DriveLetter D -DiskNumber 1 -DeviceInstanceId 'TEST\DISK1')
)
$layoutGate = Test-CruwVolumeLayout -VolumeLayouts $validLayouts -TargetDeviceInstanceIds @('TEST\DISK0', 'TEST\DISK1')
Assert-True $layoutGate.Verified 'healthy C and D volumes on separate filtered disks must pass'
Assert-True ($layoutGate.DistinctPhysicalDiskCount -eq 2) 'two distinct physical disks must be proven'

$sameDiskGate = Test-CruwVolumeLayout -VolumeLayouts @(
    (New-TestVolumeLayout -DriveLetter C -DiskNumber 0 -DeviceInstanceId 'TEST\DISK0'),
    (New-TestVolumeLayout -DriveLetter D -DiskNumber 0 -DeviceInstanceId 'TEST\DISK1')
) -TargetDeviceInstanceIds @('TEST\DISK0', 'TEST\DISK1')
Assert-True (-not $sameDiskGate.Verified) 'C and D on one physical disk must fail'

$readOnlyGate = Test-CruwVolumeLayout -VolumeLayouts @(
    (New-TestVolumeLayout -DriveLetter C -DiskNumber 0 -DeviceInstanceId 'TEST\DISK0'),
    (New-TestVolumeLayout -DriveLetter D -DiskNumber 1 -DeviceInstanceId 'TEST\DISK1' -IsReadOnly $true)
) -TargetDeviceInstanceIds @('TEST\DISK0', 'TEST\DISK1')
Assert-True (-not $readOnlyGate.Verified) 'a read-only recovery volume must fail'

$mappingGate = Test-CruwVolumeLayout -VolumeLayouts $validLayouts -TargetDeviceInstanceIds @('TEST\DISK0', 'TEST\OTHER')
Assert-True (-not $mappingGate.Verified) 'target bindings must exactly match the C and D physical disks'

$fallbackGate = Test-CruwFallbackReadiness -DiskInfFilePresent $true -DiskInfPackageVerified $true -DeviceChecks @(
    [pscustomobject]@{ ExitCode = 0; DiskInfPresent = $true },
    [pscustomobject]@{ ExitCode = 0; DiskInfPresent = $true }
)
Assert-True $fallbackGate.Verified 'disk.inf evidence for both devices must pass'
$badFallbackGate = Test-CruwFallbackReadiness -DiskInfFilePresent $true -DiskInfPackageVerified $true -DeviceChecks @(
    [pscustomobject]@{ ExitCode = 0; DiskInfPresent = $true },
    [pscustomobject]@{ ExitCode = 1; DiskInfPresent = $false }
)
Assert-True (-not $badFallbackGate.Verified) 'a missing per-device disk.inf fallback must fail'

$source = Get-Content -LiteralPath $preflightPath -Raw
$coreSource = Get-Content -LiteralPath $corePath -Raw
Assert-True ($source -notmatch '(?i)oem127\.inf') 'preflight source must not pin the current OEM published name'
Assert-True ($source -match '/export-driver\s+\$targetPublishedName') 'driver export must use the discovered published name'
Assert-True ($source -match '\[switch\]\s*\$UserDeclaredOriginalSystemRestoreDisabled') 'user-declared System Restore baseline switch must exist'
Assert-True ($source -match "elevationArguments \+= '-UserDeclaredOriginalSystemRestoreDisabled'") 'baseline switch must survive elevation'
Assert-True ($source -notmatch '(?i)/delete-driver|Restart-Computer|Suspend-BitLocker') 'preflight must not contain removal, restart or BitLocker suspension capability'
$technicalPassBlock = [regex]::Match($source, '(?s)\$technicalPreflightPass\s*=.*?\r?\n\s*\$preflight\s*=').Value
Assert-True ($technicalPassBlock -notmatch 'UserDeclaredOriginalSystemRestoreDisabled') 'declared baseline must not influence technical PASS'
Assert-True ($source -match 'Set-CruwProtectedRecoveryAcl') 'recovery trees must receive protected ACLs before backup use'
Assert-True ($source -match '\$diskBindings\.Count\s+-eq\s+2' -and $source -match '\$targetBindings\.Count\s+-eq\s+2') 'preflight must require exactly two present and two target disks'
Assert-True ($source -match 'lastBootUpTimeUtc' -and $source -match 'bootMarkerSha256') 'same-boot identity must be sealed'
Assert-True ($source -match 'DEVPKEY_Device_UpperFilters' -and $source -match 'DEVPKEY_Device_LowerFilters') 'device UpperFilters and LowerFilters must be captured'
Assert-True ($source -match 'authoritative-removal-preflight-manifest' -and $source -match 'recomputeEveryListedHash') 'final manifest must define independent removal validation'
Assert-True ($source -match '\$filterServiceRegistry\.Start\s+-eq\s+0') 'legacy filter must be BOOT_START before the preliminary reboot'
Assert-True ($source -match 'Get-AuthenticodeSignature' -and $source -match 'filterServiceBinaryMatchesExport') 'exported signatures and installed/exported driver bytes must be verified'
Assert-True ($source -match 'allEncryptedMountedVolumesRecoverable') 'every mounted encrypted volume must have a recovery-password protector'
Assert-True ($coreSource -match 'Required ACL identity') 'ACL verification must require both SYSTEM and Administrators, not merely reject outsiders'

Write-Host "PASS: CRUWBlocker preflight core ($assertionCount assertions)"
exit 0
