[CmdletBinding()]
param()

Set-StrictMode -Version Latest
$ErrorActionPreference = 'Stop'

$repoRoot = Split-Path -Parent $PSScriptRoot
$corePath = Join-Path $repoRoot 'src\powershell\maintenance\CRUWBlockerPreflight.Core.ps1'
$preflightPath = Join-Path $repoRoot 'src\powershell\maintenance\Prepare-CRUWBlockerRemoval.ps1'
$recoveryFacilitiesPath = Join-Path $repoRoot 'src\powershell\maintenance\Prepare-CRUWRecoveryFacilities.ps1'
$legacyWinReWrapperPath = Join-Path $repoRoot 'src\powershell\maintenance\Ensure-WinREEnabled.ps1'
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

$implementationFixtureRoot = Join-Path ([IO.Path]::GetTempPath()) ('CruwImplementationContract-' + [guid]::NewGuid().ToString('N'))
$expectedImplementationArtifacts = @(
    [pscustomobject]@{ fileName = 'Prepare-CRUWBlockerRemoval.ps1'; role = 'preflight-producer'; driverMutationCapable = $false },
    [pscustomobject]@{ fileName = 'CRUWBlockerPreflight.Core.ps1'; role = 'preflight-core'; driverMutationCapable = $false },
    [pscustomobject]@{ fileName = 'CRUWStateMachine.Common.ps1'; role = 'state-machine-common'; driverMutationCapable = $true },
    [pscustomobject]@{ fileName = 'Invoke-CRUWBlockerRemoval.ps1'; role = 'removal-executor'; driverMutationCapable = $true },
    [pscustomobject]@{ fileName = 'Repair-CRUWInterruptedRemoval.ps1'; role = 'interruption-repair'; driverMutationCapable = $true },
    [pscustomobject]@{ fileName = 'Test-CRUWBlockerPostboot.ps1'; role = 'postboot-validator'; driverMutationCapable = $true }
)
try {
    New-Item -ItemType Directory -Path $implementationFixtureRoot -Force | Out-Null
    foreach ($expectedArtifact in $expectedImplementationArtifacts) {
        $fixturePath = Join-Path $implementationFixtureRoot $expectedArtifact.fileName
        $fixtureSource = "# parser-only fixture: $($expectedArtifact.fileName)`r`nparam()`r`n"
        [IO.File]::WriteAllText($fixturePath, $fixtureSource, [Text.UTF8Encoding]::new($false))
    }

    $fixtureProducerPath = Join-Path $implementationFixtureRoot 'Prepare-CRUWBlockerRemoval.ps1'
    $implementationContract = Get-CruwImplementationArtifactContract `
        -SourceDirectory $implementationFixtureRoot `
        -ProducerPath $fixtureProducerPath
    Assert-True (-not $implementationContract.producerPerformsDriverMutation) 'the producer must be represented as not performing driver mutation'
    Assert-True $implementationContract.sealedBundleContainsBootCriticalMutation 'the sealed bundle must disclose boot-critical mutation capability'
    Assert-True (@($implementationContract.artifacts).Count -eq 6) 'the implementation contract must seal exactly six artifacts'
    Assert-True ((@($implementationContract.PSObject.Properties.Name) -join '|') -eq 'producerPerformsDriverMutation|sealedBundleContainsBootCriticalMutation|artifacts') 'the implementation contract must expose only the schema-v3 fields'
    for ($artifactIndex = 0; $artifactIndex -lt $expectedImplementationArtifacts.Count; $artifactIndex++) {
        $expectedArtifact = $expectedImplementationArtifacts[$artifactIndex]
        $actualArtifact = @($implementationContract.artifacts)[$artifactIndex]
        $expectedRelativePath = 'implementation/' + $expectedArtifact.fileName
        $expectedHash = (Get-FileHash -LiteralPath (Join-Path $implementationFixtureRoot $expectedArtifact.fileName) -Algorithm SHA256).Hash
        Assert-True ($actualArtifact.role -ceq $expectedArtifact.role) "artifact $artifactIndex must retain its exact role"
        Assert-True ($actualArtifact.relativePath -ceq $expectedRelativePath) "artifact $artifactIndex must retain its exact relative path"
        Assert-True ($actualArtifact.sha256 -ceq $expectedHash) "artifact $artifactIndex must retain its exact SHA-256"
        Assert-True ($actualArtifact.sha256 -cmatch '^[A-F0-9]{64}$') "artifact $artifactIndex SHA-256 must be uppercase hexadecimal"
        Assert-True ($actualArtifact.driverMutationCapable -eq $expectedArtifact.driverMutationCapable) "artifact $artifactIndex must retain its driver-mutation capability"
        Assert-True ((@($actualArtifact.PSObject.Properties.Name) -join '|') -eq 'role|relativePath|sha256|driverMutationCapable') "artifact $artifactIndex must expose exactly four contract fields"
    }

    $validImplementationFileVerification = @($implementationContract.artifacts | ForEach-Object {
        [pscustomobject]@{
            relativePath = $_.relativePath
            primaryExists = $true
            secondaryExists = $true
            primarySha256 = $_.sha256
            secondarySha256 = $_.sha256
            hashesMatch = $true
        }
    })
    Assert-True (Assert-CruwImplementationArtifactFileHashes `
        -ImplementationContract $implementationContract `
        -FileVerification $validImplementationFileVerification) 'every primary and secondary implementation hash must match the artifact contract'
    $tamperedImplementationFileVerification = @($validImplementationFileVerification | ForEach-Object {
        [pscustomobject]@{
            relativePath = $_.relativePath
            primaryExists = $_.primaryExists
            secondaryExists = $_.secondaryExists
            primarySha256 = $_.primarySha256
            secondarySha256 = $_.secondarySha256
            hashesMatch = $_.hashesMatch
        }
    })
    $tamperedImplementationFileVerification[2].secondarySha256 = ''.PadLeft(64, [char]'0')
    Assert-Throws {
        Assert-CruwImplementationArtifactFileHashes `
            -ImplementationContract $implementationContract `
            -FileVerification $tamperedImplementationFileVerification | Out-Null
    } 'a primary-secondary pair that no longer matches the artifact contract must fail'

    $missingSiblingRoot = Join-Path $implementationFixtureRoot 'missing-sibling'
    New-Item -ItemType Directory -Path $missingSiblingRoot -Force | Out-Null
    foreach ($expectedArtifact in @($expectedImplementationArtifacts | Where-Object { $_.fileName -ne 'Test-CRUWBlockerPostboot.ps1' })) {
        $fixturePath = Join-Path $missingSiblingRoot $expectedArtifact.fileName
        [IO.File]::WriteAllText($fixturePath, "# parser-only fixture`r`nparam()`r`n", [Text.UTF8Encoding]::new($false))
    }
    Assert-Throws {
        Get-CruwImplementationArtifactContract `
            -SourceDirectory $missingSiblingRoot `
            -ProducerPath (Join-Path $missingSiblingRoot 'Prepare-CRUWBlockerRemoval.ps1') | Out-Null
    } 'a missing postboot sibling must fail before a bundle can be sealed'

    $invalidSyntaxRoot = Join-Path $implementationFixtureRoot 'invalid-syntax'
    New-Item -ItemType Directory -Path $invalidSyntaxRoot -Force | Out-Null
    foreach ($expectedArtifact in $expectedImplementationArtifacts) {
        $fixturePath = Join-Path $invalidSyntaxRoot $expectedArtifact.fileName
        $fixtureSource = if ($expectedArtifact.fileName -eq 'Repair-CRUWInterruptedRemoval.ps1') { 'function Broken {' } else { "# parser-only fixture`r`nparam()`r`n" }
        [IO.File]::WriteAllText($fixturePath, $fixtureSource, [Text.UTF8Encoding]::new($false))
    }
    Assert-Throws {
        Get-CruwImplementationArtifactContract `
            -SourceDirectory $invalidSyntaxRoot `
            -ProducerPath (Join-Path $invalidSyntaxRoot 'Prepare-CRUWBlockerRemoval.ps1') | Out-Null
    } 'a sibling with invalid PowerShell syntax must fail before a bundle can be sealed'
}
finally {
    $resolvedFixtureRoot = [IO.Path]::GetFullPath($implementationFixtureRoot)
    $safeTempRoot = [IO.Path]::GetFullPath([IO.Path]::GetTempPath()).TrimEnd('\') + '\'
    if ($resolvedFixtureRoot.StartsWith($safeTempRoot, [StringComparison]::OrdinalIgnoreCase) -and (Test-Path -LiteralPath $resolvedFixtureRoot)) {
        Remove-Item -LiteralPath $resolvedFixtureRoot -Recurse -Force -ErrorAction SilentlyContinue
    }
}

$recoveryPathFixtureRoot = Join-Path ([IO.Path]::GetTempPath()) ('CruwRecoveryPath-' + [guid]::NewGuid().ToString('N'))
try {
    New-Item -ItemType Directory -Path $recoveryPathFixtureRoot | Out-Null
    $expectedFixtureDrive = [IO.Path]::GetPathRoot($recoveryPathFixtureRoot).Substring(0, 2)
    $fixtureLeaf = Join-Path $recoveryPathFixtureRoot 'evidence.json'
    Assert-True (
        (Assert-CruwLocalRecoveryPathBeforeWrite -CandidatePath $fixtureLeaf -AllowedBasePath $recoveryPathFixtureRoot -ExpectedDrive $expectedFixtureDrive) -ceq [IO.Path]::GetFullPath($fixtureLeaf)
    ) 'pre-write recovery-path validation must allow an absent final file under the exact parent'
    [IO.File]::WriteAllText($fixtureLeaf, '{}', [Text.UTF8Encoding]::new($false))
    Assert-Throws {
        Assert-CruwLocalRecoveryPathBeforeWrite -CandidatePath $fixtureLeaf -AllowedBasePath $recoveryPathFixtureRoot -ExpectedDrive $expectedFixtureDrive | Out-Null
    } 'directory-only recovery-path validation must reject an existing file leaf'
    Assert-True (
        (Assert-CruwLocalRecoveryPathBeforeWrite -CandidatePath $fixtureLeaf -AllowedBasePath $recoveryPathFixtureRoot -ExpectedDrive $expectedFixtureDrive -RequireFinalLeafFile) -ceq [IO.Path]::GetFullPath($fixtureLeaf)
    ) 'post-write recovery-path validation must accept exactly the existing non-reparse file leaf'
    Assert-Throws {
        Assert-CruwLocalRecoveryPathBeforeWrite -CandidatePath (Join-Path $recoveryPathFixtureRoot 'missing.json') -AllowedBasePath $recoveryPathFixtureRoot -ExpectedDrive $expectedFixtureDrive -RequireFinalLeafFile | Out-Null
    } 'post-write recovery-path validation must reject a missing final file leaf'
    $directoryLeaf = Join-Path $recoveryPathFixtureRoot 'directory-leaf'
    New-Item -ItemType Directory -Path $directoryLeaf | Out-Null
    Assert-Throws {
        Assert-CruwLocalRecoveryPathBeforeWrite -CandidatePath $directoryLeaf -AllowedBasePath $recoveryPathFixtureRoot -ExpectedDrive $expectedFixtureDrive -RequireFinalLeafFile | Out-Null
    } 'post-write recovery-path validation must reject a directory as the final file leaf'
}
finally {
    $resolvedRecoveryPathFixture = [IO.Path]::GetFullPath($recoveryPathFixtureRoot)
    $safeTempRoot = [IO.Path]::GetFullPath([IO.Path]::GetTempPath()).TrimEnd('\') + '\'
    if ($resolvedRecoveryPathFixture.StartsWith($safeTempRoot, [StringComparison]::OrdinalIgnoreCase) -and (Test-Path -LiteralPath $resolvedRecoveryPathFixture)) {
        Remove-Item -LiteralPath $resolvedRecoveryPathFixture -Recurse -Force -ErrorAction SilentlyContinue
    }
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

$matchingRestore = [pscustomobject]@{ SequenceNumber = 42; CreationDate = [datetime]'2026-08-22T00:00:00Z' }
Assert-True (Test-CruwLatestRestorePointMatch -UsableNamedRestore @($matchingRestore) -LatestRestore @($matchingRestore)) 'the selected named restore point may pass only when it is also the latest global point'
$newerRestore = [pscustomobject]@{ SequenceNumber = 43; CreationDate = [datetime]'2026-08-22T00:01:00Z' }
Assert-True (-not (Test-CruwLatestRestorePointMatch -UsableNamedRestore @($matchingRestore) -LatestRestore @($newerRestore))) 'a newer global restore point must invalidate the selected named point'
Assert-True (-not (Test-CruwLatestRestorePointMatch -UsableNamedRestore @() -LatestRestore @($matchingRestore))) 'a missing selected restore point must fail'
Assert-True (-not (Test-CruwLatestRestorePointMatch -UsableNamedRestore @([pscustomobject]@{ SequenceNumber = 0 }) -LatestRestore @([pscustomobject]@{ SequenceNumber = 0 }))) 'a non-positive restore-point sequence must fail'
$clockRollbackRestore = [pscustomobject]@{ SequenceNumber = 44; CreationDate = [datetime]'2026-08-21T23:00:00Z' }
$latestBySequence = @(Get-CruwLatestRestorePointBySequence -RestorePoints @($matchingRestore, $newerRestore, $clockRollbackRestore))
Assert-True ($latestBySequence.Count -eq 1 -and [long]$latestBySequence[0].SequenceNumber -eq 44) 'latest restore-point authority must be maximum positive sequence even when its wall-clock time is older'
Assert-True (@(Get-CruwLatestRestorePointBySequence -RestorePoints @([pscustomobject]@{ SequenceNumber = 0 }, [pscustomobject]@{ SequenceNumber = 'invalid' })).Count -eq 0) 'restore-point sequence selection must reject non-positive and malformed sequences'
Assert-True (@(Get-CruwLatestRestorePointBySequence -RestorePoints @([pscustomobject]@{ SequenceNumber = 45 }, [pscustomobject]@{ SequenceNumber = 45 })).Count -eq 0) 'duplicate maximum restore-point sequence records must fail as ambiguous'
$validWinReLocation = '\\?\GLOBALROOT\device\harddisk0\partition4\Recovery\WindowsRE'
Assert-True ((Get-CruwCanonicalWinReLocationSha256 -Location $validWinReLocation) -cmatch '^[A-F0-9]{64}$') 'an exact canonical WinRE GLOBALROOT recovery path must hash'
Assert-Throws { Get-CruwCanonicalWinReLocationSha256 -Location '\\?\GLOBALROOT\device\harddisk0' | Out-Null } 'a partial GLOBALROOT device path must fail'
Assert-Throws { Get-CruwCanonicalWinReLocationSha256 -Location 'C:\Recovery\WindowsRE' | Out-Null } 'a drive-relative WinRE path must fail'
Assert-True ((ConvertTo-CruwCanonicalServiceImagePath -ImagePath 'System32\drivers\CRUWBlocker.sys') -ceq '\SystemRoot\System32\drivers\CRUWBlocker.sys') 'the observed relative system ImagePath must canonicalize without losing its raw evidence'
Assert-True ((ConvertTo-CruwCanonicalServiceImagePath -ImagePath '\SystemRoot\System32\drivers\CRUWBlocker.sys') -ceq '\SystemRoot\System32\drivers\CRUWBlocker.sys') 'the explicit system-root ImagePath must retain the same canonical identity'
Assert-Throws { ConvertTo-CruwCanonicalServiceImagePath -ImagePath 'C:\Windows\System32\drivers\CRUWBlocker.sys' | Out-Null } 'an arbitrary absolute ImagePath must not be treated as a canonical equivalent'
$localRecoveryBase = Join-Path ([IO.Path]::GetTempPath()) ('CruwPathContract-' + [guid]::NewGuid().ToString('N'))
try {
    New-Item -ItemType Directory -Path $localRecoveryBase -Force | Out-Null
    $expectedDrive = [IO.Path]::GetPathRoot($localRecoveryBase).TrimEnd('\')
    $validRecoveryChild = Join-Path $localRecoveryBase 'CRUWBlocker-test'
    Assert-True ((Assert-CruwLocalRecoveryPathBeforeWrite -CandidatePath $validRecoveryChild -AllowedBasePath $localRecoveryBase -ExpectedDrive $expectedDrive) -ceq [IO.Path]::GetFullPath($validRecoveryChild)) 'a local child beneath the exact fixed recovery parent must pass'
    Assert-Throws { Assert-CruwLocalRecoveryPathBeforeWrite -CandidatePath (Join-Path $localRecoveryBase '..\escape') -AllowedBasePath $localRecoveryBase -ExpectedDrive $expectedDrive | Out-Null } 'a normalized parent escape must fail'
    Assert-Throws { Assert-CruwLocalRecoveryPathBeforeWrite -CandidatePath ($validRecoveryChild + ':stream') -AllowedBasePath $localRecoveryBase -ExpectedDrive $expectedDrive | Out-Null } 'an alternate data stream must fail'
    Assert-Throws { Assert-CruwLocalRecoveryPathBeforeWrite -CandidatePath '\\server\share\CRUWBlocker-test' -AllowedBasePath $localRecoveryBase -ExpectedDrive $expectedDrive | Out-Null } 'a UNC recovery path must fail before access'
}
finally {
    $resolvedLocalRecoveryBase = [IO.Path]::GetFullPath($localRecoveryBase)
    $safeTempRootForPathTest = [IO.Path]::GetFullPath([IO.Path]::GetTempPath()).TrimEnd('\') + '\'
    if ($resolvedLocalRecoveryBase.StartsWith($safeTempRootForPathTest, [StringComparison]::OrdinalIgnoreCase) -and (Test-Path -LiteralPath $resolvedLocalRecoveryBase)) {
        Remove-Item -LiteralPath $resolvedLocalRecoveryBase -Recurse -Force -ErrorAction SilentlyContinue
    }
}

$anchorFixtureRoot = Join-Path ([IO.Path]::GetTempPath()) ('CruwAnchor-' + [guid]::NewGuid().ToString('N'))
$anchorHandles = @()
try {
    $anchoredLeaf = Join-Path $anchorFixtureRoot 'parent\leaf'
    New-Item -ItemType Directory -Path $anchoredLeaf -Force | Out-Null
    $anchorExpectedDrive = [IO.Path]::GetPathRoot($anchorFixtureRoot).TrimEnd('\')
    $anchorHandles = @(Enter-CruwDirectoryAnchorChain -DirectoryPath $anchoredLeaf -AnchorBasePath $anchorFixtureRoot -ExpectedDrive $anchorExpectedDrive)
    Assert-True ($anchorHandles.Count -ge 2 -and @($anchorHandles | Where-Object { $_.Identity -cnotmatch '^[A-F0-9]{8}:[A-F0-9]{16}$' }).Count -eq 0) 'directory anchor chain must hold stable volume/file identities'
    Assert-Throws { Rename-Item -LiteralPath $anchoredLeaf -NewName 'renamed-while-held' -ErrorAction Stop } 'no-FILE_SHARE_DELETE leaf handle must block rename while producer paths are in use'
    Exit-CruwDirectoryAnchorChain -Anchors $anchorHandles
    $anchorHandles = @()
    Rename-Item -LiteralPath $anchoredLeaf -NewName 'renamed-after-release' -ErrorAction Stop
    Assert-True (Test-Path -LiteralPath (Join-Path $anchorFixtureRoot 'parent\renamed-after-release') -PathType Container) 'anchored directory must become renamable only after every handle is released'
}
finally {
    if ($anchorHandles.Count -gt 0) { Exit-CruwDirectoryAnchorChain -Anchors $anchorHandles }
    $resolvedAnchorFixtureRoot = [IO.Path]::GetFullPath($anchorFixtureRoot)
    $safeTempRootForAnchor = [IO.Path]::GetFullPath([IO.Path]::GetTempPath()).TrimEnd('\') + '\'
    if ($resolvedAnchorFixtureRoot.StartsWith($safeTempRootForAnchor, [StringComparison]::OrdinalIgnoreCase) -and (Test-Path -LiteralPath $resolvedAnchorFixtureRoot)) {
        Remove-Item -LiteralPath $resolvedAnchorFixtureRoot -Recurse -Force -ErrorAction SilentlyContinue
    }
}

$validInf = @'
[CRUWBlocker_install.NT.Services]
Include=disk.inf
Needs=disk_install.NT.Services
AddService=CRUWBlocker,,CRUWBlocker_ServiceInstallSection

[CRUWBlocker_ServiceInstallSection]
ServiceType=1
StartType=3
ErrorControl=1
ServiceBinary=%12%\CRUWBlocker.sys
LoadOrderGroup=Pnp Filter
'@
$driverHashA = ''.PadLeft(64, [char]'A')
$driverHashB = ''.PadLeft(64, [char]'B')
$driverHashC = ''.PadLeft(64, [char]'C')
$driverExportHashContract = @(
    [pscustomobject]@{ file='cruwblocker.inf'; Hash=$driverHashA },
    [pscustomobject]@{ file='CRUWBlocker.sys'; Hash=$driverHashB },
    [pscustomobject]@{ file='CRUWBlocker.cat'; Hash=$driverHashC }
)
$driverFileVerification = @(
    [pscustomobject]@{ relativePath='driver\cruwblocker.inf'; primaryExists=$true; secondaryExists=$true; primarySha256=$driverHashA; secondarySha256=$driverHashA; hashesMatch=$true },
    [pscustomobject]@{ relativePath='driver\CRUWBlocker.sys'; primaryExists=$true; secondaryExists=$true; primarySha256=$driverHashB; secondarySha256=$driverHashB; hashesMatch=$true },
    [pscustomobject]@{ relativePath='driver\CRUWBlocker.cat'; primaryExists=$true; secondaryExists=$true; primarySha256=$driverHashC; secondarySha256=$driverHashC; hashesMatch=$true }
)
Assert-True (Assert-CruwDriverPayloadFileHashes -DriverExportHashes $driverExportHashContract -FileVerification $driverFileVerification `
    -ExportedInfSha256 $driverHashA -ExportedDriverSha256 $driverHashB -ExportedCatalogSha256 $driverHashC) 'physical driver bytes must match all three signed export identity hashes'
$tamperedDriverFileVerification = @($driverFileVerification | ForEach-Object { [pscustomobject]@{ relativePath=$_.relativePath; primaryExists=$_.primaryExists; secondaryExists=$_.secondaryExists; primarySha256=$_.primarySha256; secondarySha256=$_.secondarySha256; hashesMatch=$_.hashesMatch } })
$tamperedDriverFileVerification[1].primarySha256 = $driverHashC
Assert-Throws { Assert-CruwDriverPayloadFileHashes -DriverExportHashes $driverExportHashContract -FileVerification $tamperedDriverFileVerification `
    -ExportedInfSha256 $driverHashA -ExportedDriverSha256 $driverHashB -ExportedCatalogSha256 $driverHashC | Out-Null } 'a post-signature driver payload substitution must fail even when another manifest could seal it'

$exactTreeFixtureRoot = Join-Path ([IO.Path]::GetTempPath()) ('CruwExactTree-' + [guid]::NewGuid().ToString('N'))
$exactTreeRequired = @('driver\a.bin', 'implementation/b.ps1', 'root.txt')
try {
    New-Item -ItemType Directory -Path (Join-Path $exactTreeFixtureRoot 'driver') -Force | Out-Null
    New-Item -ItemType Directory -Path (Join-Path $exactTreeFixtureRoot 'implementation') -Force | Out-Null
    foreach ($relative in $exactTreeRequired) {
        $path = Join-Path $exactTreeFixtureRoot $relative
        [IO.File]::WriteAllText($path, $relative, [Text.UTF8Encoding]::new($false))
    }
    Assert-True (Assert-CruwExactRecoveryTree -RootPath $exactTreeFixtureRoot -RequiredRelativeFiles $exactTreeRequired) 'an exact physical recovery tree without alternate streams must pass'
    $extraPath = Join-Path $exactTreeFixtureRoot 'driver\extra.bin'
    [IO.File]::WriteAllText($extraPath, 'extra', [Text.UTF8Encoding]::new($false))
    Assert-Throws { Assert-CruwExactRecoveryTree -RootPath $exactTreeFixtureRoot -RequiredRelativeFiles $exactTreeRequired | Out-Null } 'an unmanifested physical payload file must fail'
    Remove-Item -LiteralPath $extraPath -Force
    Set-Content -LiteralPath (Join-Path $exactTreeFixtureRoot 'root.txt') -Stream 'unexpected' -Value 'hidden'
    Assert-Throws { Assert-CruwExactRecoveryTree -RootPath $exactTreeFixtureRoot -RequiredRelativeFiles $exactTreeRequired | Out-Null } 'an alternate data stream on a sealed payload must fail'
    Remove-Item -LiteralPath (Join-Path $exactTreeFixtureRoot 'root.txt') -Stream 'unexpected' -Force
    Rename-Item -LiteralPath (Join-Path $exactTreeFixtureRoot 'driver\a.bin') -NewName 'A.bin'
    Assert-Throws { Assert-CruwExactRecoveryTree -RootPath $exactTreeFixtureRoot -RequiredRelativeFiles $exactTreeRequired | Out-Null } 'a physical payload casing drift must fail the exact wire contract'
}
finally {
    $resolvedExactTreeFixtureRoot = [IO.Path]::GetFullPath($exactTreeFixtureRoot)
    $safeTempRootForExactTree = [IO.Path]::GetFullPath([IO.Path]::GetTempPath()).TrimEnd('\') + '\'
    if ($resolvedExactTreeFixtureRoot.StartsWith($safeTempRootForExactTree, [StringComparison]::OrdinalIgnoreCase) -and (Test-Path -LiteralPath $resolvedExactTreeFixtureRoot)) {
        Remove-Item -LiteralPath $resolvedExactTreeFixtureRoot -Recurse -Force -ErrorAction SilentlyContinue
    }
}

$validLiveService = [pscustomobject]@{
    Start = 0; Type = 1; ErrorControl = 1; Group = 'Pnp Filter'
    ImagePath = 'System32\drivers\CRUWBlocker.sys'; StartOverrideAbsent = $true; State = 'Running'
}
$validPromotionEvidence = @([pscustomobject]@{
    FileName = 'setupapi.dev.20260821_123456.log'
    Sha256 = ''.PadLeft(64, [char]'A')
    Length = 1234
    MatchCount = 2
})
$rollbackContract = Get-CruwRollbackCapabilityContract -InfText $validInf -ExportedPackageVerified $true `
    -ExportedInfSha256 (''.PadLeft(64, [char]'B')) -LiveService $validLiveService -PromotionEvidence $validPromotionEvidence
Assert-True $rollbackContract.automaticRollbackEligible 'exact package, INF, live configuration and stable promotion evidence must permit a bounded rollback attempt'
Assert-True ($rollbackContract.infStartType -eq 3 -and $rollbackContract.sealedLiveStart -eq 0) 'the contract must preserve the intentional INF demand-start versus live boot-start distinction'
Assert-True (-not $rollbackContract.setupApiTextIsAuthority -and -not $rollbackContract.restorationGuaranteed) 'diagnostic SetupAPI text must never be authority or a rollback guarantee'
Assert-True $rollbackContract.postAddExactLiveReadbackMandatory 'rollback must require exact post-add live readback'
$wrongInfRollback = Get-CruwRollbackCapabilityContract -InfText ($validInf -replace 'StartType=3', 'StartType=0') -ExportedPackageVerified $true `
    -ExportedInfSha256 (''.PadLeft(64, [char]'B')) -LiveService $validLiveService -PromotionEvidence $validPromotionEvidence
Assert-True (-not $wrongInfRollback.automaticRollbackEligible) 'an INF that does not match the exported demand-start contract must block automatic rollback eligibility'
$flaggedAddServiceRollback = Get-CruwRollbackCapabilityContract -InfText ($validInf -replace 'CRUWBlocker,,CRUWBlocker_ServiceInstallSection', 'CRUWBlocker,2,CRUWBlocker_ServiceInstallSection') -ExportedPackageVerified $true `
    -ExportedInfSha256 (''.PadLeft(64, [char]'B')) -LiveService $validLiveService -PromotionEvidence $validPromotionEvidence
Assert-True (-not $flaggedAddServiceRollback.automaticRollbackEligible) 'unexpected AddService flags must block exact rollback eligibility'
$wrongInheritedDiskServiceRollback = Get-CruwRollbackCapabilityContract -InfText ($validInf -replace 'Needs=disk_install.NT.Services', 'Needs=unexpected.Services') -ExportedPackageVerified $true `
    -ExportedInfSha256 (''.PadLeft(64, [char]'B')) -LiveService $validLiveService -PromotionEvidence $validPromotionEvidence
Assert-True (-not $wrongInheritedDiskServiceRollback.automaticRollbackEligible) 'unexpected inherited disk-service semantics must block exact rollback eligibility'
$wrongLiveRollback = Get-CruwRollbackCapabilityContract -InfText $validInf -ExportedPackageVerified $true `
    -ExportedInfSha256 (''.PadLeft(64, [char]'B')) -LiveService ([pscustomobject]@{ Start=3; Type=1; ErrorControl=1; Group='Pnp Filter'; ImagePath='System32\drivers\CRUWBlocker.sys'; StartOverrideAbsent=$true; State='Running' }) -PromotionEvidence $validPromotionEvidence
Assert-True (-not $wrongLiveRollback.automaticRollbackEligible) 'a live service that is not BOOT_START must block automatic rollback eligibility'
$missingLiveStartRollback = Get-CruwRollbackCapabilityContract -InfText $validInf -ExportedPackageVerified $true `
    -ExportedInfSha256 (''.PadLeft(64, [char]'B')) -LiveService ([pscustomobject]@{ Type=1; ErrorControl=1; Group='Pnp Filter'; ImagePath='System32\drivers\CRUWBlocker.sys'; StartOverrideAbsent=$true; State='Running' }) -PromotionEvidence $validPromotionEvidence
Assert-True (-not $missingLiveStartRollback.automaticRollbackEligible) 'a missing live Start value must not be coerced into BOOT_START eligibility'
$startOverrideRollback = Get-CruwRollbackCapabilityContract -InfText $validInf -ExportedPackageVerified $true `
    -ExportedInfSha256 (''.PadLeft(64, [char]'B')) -LiveService ([pscustomobject]@{ Start=0; Type=1; ErrorControl=1; Group='Pnp Filter'; ImagePath='System32\drivers\CRUWBlocker.sys'; StartOverrideAbsent=$false; State='Running' }) -PromotionEvidence $validPromotionEvidence
Assert-True (-not $startOverrideRollback.automaticRollbackEligible) 'a StartOverride subkey must block exact rollback eligibility'
$noPromotionRollback = Get-CruwRollbackCapabilityContract -InfText $validInf -ExportedPackageVerified $true `
    -ExportedInfSha256 (''.PadLeft(64, [char]'B')) -LiveService $validLiveService -PromotionEvidence @()
Assert-True (-not $noPromotionRollback.automaticRollbackEligible) 'missing stable historical promotion evidence must block automatic rollback eligibility'
$malformedPromotionRollback = Get-CruwRollbackCapabilityContract -InfText $validInf -ExportedPackageVerified $true `
    -ExportedInfSha256 (''.PadLeft(64, [char]'B')) -LiveService $validLiveService -PromotionEvidence @([pscustomobject]@{ FileName='setupapi.dev.log'; Sha256='bad'; Length=1; MatchCount=1 })
Assert-True (-not $malformedPromotionRollback.automaticRollbackEligible) 'unsealed or live SetupAPI evidence must block automatic rollback eligibility'

$setupApiFixtureRoot = Join-Path ([IO.Path]::GetTempPath()) ('CruwSetupApi-' + [guid]::NewGuid().ToString('N'))
try {
    New-Item -ItemType Directory -Path $setupApiFixtureRoot -Force | Out-Null
    [IO.File]::WriteAllText((Join-Path $setupApiFixtureRoot 'setupapi.dev.20260821_123456.log'), "before`r`nUpdated service 'cruwblocker' to be boot start.`r`nafter", [Text.UTF8Encoding]::new($false))
    [IO.File]::WriteAllText((Join-Path $setupApiFixtureRoot 'setupapi.dev.log'), "Updated service 'cruwblocker' to be boot start.", [Text.UTF8Encoding]::new($false))
    $stablePromotionEvidence = @(Get-CruwSetupApiPromotionEvidence -InfDirectory $setupApiFixtureRoot)
    Assert-True ($stablePromotionEvidence.Count -eq 1 -and $stablePromotionEvidence[0].MatchCount -eq 1) 'only immutable-style archived SetupAPI logs may become hash-sealed diagnostic evidence'
}
finally {
    $resolvedSetupApiFixtureRoot = [IO.Path]::GetFullPath($setupApiFixtureRoot)
    $safeTempRootForSetupApiTest = [IO.Path]::GetFullPath([IO.Path]::GetTempPath()).TrimEnd('\') + '\'
    if ($resolvedSetupApiFixtureRoot.StartsWith($safeTempRootForSetupApiTest, [StringComparison]::OrdinalIgnoreCase) -and (Test-Path -LiteralPath $resolvedSetupApiFixtureRoot)) {
        Remove-Item -LiteralPath $resolvedSetupApiFixtureRoot -Recurse -Force -ErrorAction SilentlyContinue
    }
}

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
        [string] $DiskHealth = 'Healthy',
        [string[]] $DiskOperationalStatus = @('Online'),
        [string[]] $VolumeOperationalStatus = @('OK')
    )
    [pscustomobject]@{
        DriveLetter = $DriveLetter
        Mounted = $true
        DiskNumber = $DiskNumber
        DeviceInstanceId = $DeviceInstanceId
        IsOffline = $false
        IsReadOnly = $IsReadOnly
        DiskHealth = $DiskHealth
        DiskOperationalStatus = $DiskOperationalStatus
        VolumeHealth = 'Healthy'
        VolumeOperationalStatus = $VolumeOperationalStatus
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

$ambiguousOperationalStatusGate = Test-CruwVolumeLayout -VolumeLayouts @(
    (New-TestVolumeLayout -DriveLetter C -DiskNumber 0 -DeviceInstanceId 'TEST\DISK0' -DiskOperationalStatus @('Online', 'Degraded')),
    (New-TestVolumeLayout -DriveLetter D -DiskNumber 1 -DeviceInstanceId 'TEST\DISK1' -VolumeOperationalStatus @('OK', 'Unknown'))
) -TargetDeviceInstanceIds @('TEST\DISK0', 'TEST\DISK1')
Assert-True (-not $ambiguousOperationalStatusGate.Verified) 'additional disk or volume operational states must fail the exact health gate even when Online or OK is present'

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
$recoveryFacilitiesSource = Get-Content -LiteralPath $recoveryFacilitiesPath -Raw
$legacyWinReWrapperSource = Get-Content -LiteralPath $legacyWinReWrapperPath -Raw
Assert-True ($source -notmatch '(?i)oem127\.inf') 'preflight source must not pin the current OEM published name'
Assert-True ($source -match '/export-driver\s+\$targetPublishedName') 'driver export must use the discovered published name'
Assert-True ($source -match '\[switch\]\s*\$UserDeclaredOriginalSystemRestoreDisabled') 'user-declared System Restore baseline switch must exist'
Assert-True ($source -match "elevationArguments \+= '-UserDeclaredOriginalSystemRestoreDisabled'") 'baseline switch must survive elevation'
Assert-True ($source -match '\[switch\]\s*\$UserDeclaredOriginalWinReDisabled') 'user-declared WinRE baseline switch must exist'
Assert-True ($source -match "elevationArguments \+= '-UserDeclaredOriginalWinReDisabled'") 'WinRE baseline switch must survive elevation'
Assert-True ($source -notmatch '(?i)/delete-driver|Restart-Computer|Suspend-BitLocker') 'preflight must not contain removal, restart or BitLocker suspension capability'
$technicalPassBlock = [regex]::Match($source, '(?s)\$technicalPreflightPass\s*=.*?\r?\n\s*\$preflight\s*=').Value
Assert-True ($technicalPassBlock -notmatch 'UserDeclaredOriginalSystemRestoreDisabled') 'declared baseline must not influence technical PASS'
Assert-True ($technicalPassBlock -notmatch 'UserDeclaredOriginalWinReDisabled') 'declared WinRE baseline must not influence technical PASS'
Assert-True ($source -match 'Set-CruwProtectedRecoveryAcl') 'recovery trees must receive protected ACLs before backup use'
Assert-True ($source -match '\$diskBindings\.Count\s+-eq\s+2' -and $source -match '\$targetBindings\.Count\s+-eq\s+2') 'preflight must require exactly two present and two target disks'
Assert-True ($source -match 'lastBootUpTimeUtc' -and $source -match 'bootMarkerSha256') 'same-boot identity must be sealed'
Assert-True ($source -match 'DEVPKEY_Device_UpperFilters' -and $source -match 'DEVPKEY_Device_LowerFilters') 'device UpperFilters and LowerFilters must be captured'
Assert-True ($source -match 'authoritative-removal-preflight-manifest' -and $source -match 'recomputeEveryListedHash') 'final manifest must define independent removal validation'
Assert-True ($source -match '\$filterServiceRegistry\.Start\s+-eq\s+0') 'legacy filter must be BOOT_START before the preliminary reboot'
Assert-True ($source -match 'Get-AuthenticodeSignature' -and $source -match 'filterServiceBinaryMatchesExport') 'exported signatures and installed/exported driver bytes must be verified'
Assert-True ($source -match 'exportedInfSignature' -and $source -match 'knownPackageHashesVerified') 'INF catalog membership and all three known package hashes must be verified'
Assert-True ($source -match 'allEncryptedMountedVolumesRecoverable') 'every mounted encrypted volume must have a recovery-password protector'
Assert-True ($source -match 'allEncryptedMountedVolumesReady' -and $source -match 'ReadyForTransaction' -and $source -match "LockStatus 'Unlocked'") 'every mounted encrypted volume must be fully encrypted, protected, unlocked and recoverable before PASS'
Assert-True ($technicalPassBlock -match 'allEncryptedMountedVolumesReady') 'technical PASS must consume the exact all-volume BitLocker readiness gate'
Assert-True ($source -match 'Test-CruwLatestRestorePointMatch' -and $source -match 'usablePointSequenceNumber\s*=\s*if\s*\(\$restoreUsable\)') 'the producer must seal only a named restore point that is also the latest global point'
Assert-True ($source -match 'recentNamedBeforeIsLatest\s*=\s*Test-CruwLatestRestorePointMatch' -and $source -match 'elseif\s*\(\$recentNamedBeforeIsLatest\)') 'producer must not reuse a recent named restore point when a newer global point exists'
Assert-True ($source -match '\$checkpointNowBefore\s*=\s*Get-Date' -and $source -match '\$checkpointCutoffBefore\s*=\s*\$checkpointNowBefore\.AddHours\(-23\)' -and $source -match '\$checkpointValidationNow\s*=\s*Get-Date' -and $source -match '\$checkpointCutoff\s*=\s*\$checkpointValidationNow\.AddHours\(-23\)' -and $source -match 'CreationDate\s+-le\s+\$checkpointValidationNow') 'producer restore-point freshness must use bounded before/after clock samples, stay strictly inside 24 hours and reject future points without excluding a newly created point'
Assert-True ($technicalPassBlock -match 'winReLocationReady' -and $source -match 'recoveryLocationSha256\s*=\s*\$winReLocationSha256') 'technical PASS must require and seal an exact canonical WinRE location hash'
Assert-True ($technicalPassBlock -match 'systemRestoreReady' -and $source -match 'readyForTransaction\s*=\s*\$systemRestoreReady' -and $source -match '\$policyDisableSR\s+-ne\s+1' -and $source -match '\$runtimeDisableSR\s+-ne\s+1' -and $source -notmatch '\$policyDisableConfig\s+-ne\s+1' -and $source -match 'disableConfigRecordedButNotUsedAsDisableSignal\s*=\s*\$true' -and $source -match '\$restoreQuerySucceeded\s+-and') 'technical PASS must independently prove System Restore is queryable, not disabled and backed by the exact latest checkpoint without misclassifying the configuration-only policy'
Assert-True ($technicalPassBlock -match 'rollbackCapability\.automaticRollbackEligible' -and $source -match 'rollbackCapability\s*=\s*\$rollbackCapability') 'technical PASS and the emitted preflight must consume the exact rollback-capability contract'
Assert-True ($source -match 'filterServiceRegistry\.ErrorControl\s+-eq\s+1' -and $source -match "filterServiceRegistry\.Group 'Pnp Filter'") 'legacy ErrorControl and load-order group must be exact before PASS'
Assert-True ($source -match 'Driver export must contain exactly' -and $source -match 'Sealed implementation directory does not contain the exact six-file artifact set') 'producer must reject every extra or non-file payload before sealing'
Assert-True (([regex]::Matches($source, 'Assert-CruwExactRecoveryTree')).Count -eq 6) 'producer must prove exact primary and secondary physical trees before both manifests and after final sealing'
Assert-True (([regex]::Matches($source, 'Assert-CruwDriverPayloadFileHashes')).Count -eq 2) 'producer must cross-check signed driver bytes before preflight and final manifest serialization'
Assert-True ($source -match "Timestamped recovery roots must not pre-exist" -and $source -notmatch 'New-Item\s+-ItemType\s+Directory\s+-Path\s+\$recoveryPath\s+-Force') 'timestamped roots must be fresh atomic creations rather than merged with prior content'
Assert-True ($source -match 'Fixed recovery parent is not protected for SYSTEM and Administrators only' -and $source -match 'Fresh recovery roots lost their protected ACL before payload writes') 'dedicated parents and fresh roots must be protected before any payload write'
Assert-True (([regex]::Matches($source, 'Enter-CruwDirectoryAnchorChain')).Count -eq 4 -and $source -match 'Exit-CruwDirectoryAnchorChain') 'producer must hold no-FILE_SHARE_DELETE handles on both full parent and recovery-root chains throughout serialization'
Assert-True (([regex]::Matches($source, 'Assert-CruwLocalRecoveryPathBeforeWrite')).Count -ge 4 -and $source -match "DriveType\s+-ne\s+3") 'both recovery roots must be local fixed paths and reparse-safe before and after creation'
Assert-True ($coreSource -match 'Required ACL identity') 'ACL verification must require both SYSTEM and Administrators, not merely reject outsiders'
Assert-True ($source -match '(?m)^\$preflightSchemaVersion\s*=\s*3\s*$') 'the producer must emit top-level preflight schema version 3'
Assert-True ($source -notmatch '(?m)^\$preflightSchemaVersion\s*=\s*2\s*$') 'the producer must not emit the rejected schema version 2'
Assert-True ($source.IndexOf('$implementationContract = Get-CruwImplementationArtifactContract') -ge 0 -and $source.IndexOf('$implementationContract = Get-CruwImplementationArtifactContract') -lt $source.IndexOf('New-Item -ItemType Directory -Path $recoveryPath')) 'required sibling existence and parsing must happen before recovery-tree writes'
Assert-True ($source.IndexOf('$producerSha256AtStart') -ge 0 -and $source.IndexOf('$producerSha256AtStart') -lt $source.IndexOf('. $corePath')) 'producer bytes must be pinned before loading the core'
Assert-True ($source -match 'coreSha256BeforeLoad' -and $source -match 'coreSha256AfterLoad' -and $source -match 'preflight core changed while being loaded') 'core bytes must remain unchanged across dot-sourcing'
Assert-True ($source -match 'producerArtifact\[0\]\.sha256' -and $source -match 'coreArtifact\[0\]\.sha256' -and $source -match 'changed between load and contract sealing') 'the contract must match the exact producer and loaded core bytes'
Assert-True ($source -match 'foreach\s*\(\$artifact\s+in\s+@\(\$implementationContract\.artifacts\)\)') 'the producer must copy every contracted implementation artifact'
Assert-True ($source -match '\+\s*@\(\$implementationContract\.artifacts\s*\|') 'all implementation artifacts must feed the required backup paths'
Assert-True (([regex]::Matches($source, 'implementation\s*=\s*\$implementationContract')).Count -eq 2) 'preflight and final manifest must reuse the exact implementation contract'
Assert-True ($source -match 'preflightImplementationJson' -and $source -match 'manifestImplementationJson' -and $source -match 'not byte-identical') 'producer must enforce byte-identical implementation metadata in both JSON contracts'
Assert-True ($source -match '\$finalizedPreflight\s*=\s*Get-Content\s+-LiteralPath\s+\$preflightPath\s+-Raw' -and $source -match '\[int\]\$finalizedPreflight\.schemaVersion\s+-ne\s+3') 'final manifest sealing must re-read the finalized preflight and reject every non-v3 schema'
Assert-True (([regex]::Matches($source, 'Assert-CruwImplementationArtifactFileHashes')).Count -eq 2) 'producer must compare sealed hashes before preflight serialization and again before final manifest serialization'
Assert-True ($source -notmatch 'driverMutationCapabilityPresent') 'ambiguous legacy mutation capability metadata must be absent'
Assert-True ($coreSource -match 'producerPerformsDriverMutation\s*=\s*\$false') 'schema v3 must distinguish producer behavior from bundle capability'
Assert-True ($coreSource -match 'sealedBundleContainsBootCriticalMutation') 'schema v3 must disclose boot-critical mutation in the sealed bundle'
Assert-True ($recoveryFacilitiesSource -match 'ConfirmTemporaryRecoveryEnablement' -and $recoveryFacilitiesSource -match 'Enable-ComputerRestore' -and $recoveryFacilitiesSource -match 'reagentc\.exe /enable') 'temporary recovery-facilities enablement must require an explicit gate and cover WinRE plus System Restore'
Assert-True ($recoveryFacilitiesSource -notmatch '(?i)/delete-driver|Suspend-BitLocker|Restart-Computer|Disable-ComputerRestore|reagentc\.exe /disable') 'recovery-facilities preparation must not remove drivers, change BitLocker, reboot or restore disabled preferences'
Assert-True ($recoveryFacilitiesSource -match "DriveType\s+-ne\s+3" -and ([regex]::Matches($recoveryFacilitiesSource, 'Enter-CruwDirectoryAnchorChain')).Count -eq 2) 'recovery-facilities evidence must use exact local fixed drives and hold both parent anchor chains'
Assert-True ($recoveryFacilitiesSource -match 'FileMode\]::CreateNew' -and $recoveryFacilitiesSource -match 'FileOptions\]::WriteThrough' -and $recoveryFacilitiesSource -match 'RequireFinalLeafFile') 'dual evidence must be fresh, durable and revalidated as an exact final file leaf'
Assert-True ($recoveryFacilitiesSource.IndexOf('BEFORE_TEMPORARY_ENABLEMENT') -ge 0 -and $recoveryFacilitiesSource.IndexOf('BEFORE_TEMPORARY_ENABLEMENT') -lt $recoveryFacilitiesSource.IndexOf('reagentc.exe /enable') -and $recoveryFacilitiesSource.IndexOf('BEFORE_TEMPORARY_ENABLEMENT') -lt $recoveryFacilitiesSource.IndexOf('Enable-ComputerRestore')) 'BEFORE evidence must be constructed and written before either temporary recovery mutation'
Assert-True ($recoveryFacilitiesSource -match 'Checkpoint-Computer' -and $recoveryFacilitiesSource -match 'Get-CruwLatestRestorePointBySequence' -and $recoveryFacilitiesSource -match 'Test-CruwLatestRestorePointMatch') 'recovery-facilities preparation must create or reuse and then prove the exact latest positive-sequence checkpoint'
Assert-True ($recoveryFacilitiesSource -match '\$checkpointCutoffBefore\s*=\s*\$checkpointNowBefore\.AddHours\(-23\)' -and $recoveryFacilitiesSource -match '\$checkpointCutoff\s*=\s*\$checkpointValidationNow\.AddHours\(-23\)' -and $recoveryFacilitiesSource -match 'CreationDate\s+-le\s+\$checkpointNowBefore' -and $recoveryFacilitiesSource -match 'CreationDate\s+-le\s+\$checkpointValidationNow') 'recovery-facilities checkpoint freshness must bound reuse and post-create validation against their own clock samples'
Assert-True ($recoveryFacilitiesSource -match 'beforePrimaryHashAfter' -and $recoveryFacilitiesSource -match 'beforeSecondaryHashAfter' -and $recoveryFacilitiesSource -match 'beforeEvidenceReverifiedBeforeResult' -and $recoveryFacilitiesSource.IndexOf('beforePrimaryHashAfter') -lt $recoveryFacilitiesSource.IndexOf('Write-CruwDualRecoveryEvidence -FileName $resultName')) 'both BEFORE copies must be rehashed before a PASS/FAILED RESULT is committed'
Assert-True ($source -match '\$physicalDisks\.Count\s+-ge\s+2' -and $source -match '\$operationalStatus\.Count\s+-ne\s+1' -and $source -notmatch 'OperationalStatus\s+-notcontains\s+''OK''') 'global physical-disk health must reject empty inventory and every ambiguous operational-status array'
Assert-True ($legacyWinReWrapperSource -match 'Prepare-CRUWRecoveryFacilities\.ps1' -and $legacyWinReWrapperSource -notmatch 'reagentc\.exe' -and ([regex]::Matches($legacyWinReWrapperSource, 'UserDeclaredOriginal(?:SystemRestore|WinRe)Disabled')).Count -ge 4) 'legacy WinRE entrypoint must delegate to the guarded combined preparer and preserve both original-state declarations'

Write-Host "PASS: CRUWBlocker preflight core ($assertionCount assertions)"
exit 0
