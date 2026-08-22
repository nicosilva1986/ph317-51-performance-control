Set-StrictMode -Version Latest

function Get-CRUWPropertyValue {
    param([AllowNull()] $InputObject, [Parameter(Mandatory)] [string] $Name, [AllowNull()] $Default = $null)
    if ($null -eq $InputObject) { return $Default }
    if ($InputObject -is [Collections.IDictionary] -and $InputObject.Contains($Name)) { return $InputObject[$Name] }
    $property = $InputObject.PSObject.Properties[$Name]
    if ($null -eq $property) { return $Default }
    return $property.Value
}

function Set-CRUWPropertyValue {
    param([Parameter(Mandatory)] $InputObject,[Parameter(Mandatory)][string]$Name,[AllowNull()]$Value)
    if ($InputObject -is [Collections.IDictionary]) { $InputObject[$Name]=$Value; return }
    $property=$InputObject.PSObject.Properties[$Name]
    if ($null -ne $property) { $property.Value=$Value; return }
    $InputObject | Add-Member -MemberType NoteProperty -Name $Name -Value $Value
}

function ConvertTo-CRUWStringArray {
    param([AllowNull()] $Value)
    if ($null -eq $Value) { return @() }
    return @($Value | ForEach-Object { [string] $_ })
}

function Get-CRUWPropertyNameArray {
    param([AllowNull()] $InputObject)
    if ($null -eq $InputObject) { return @() }
    if ($InputObject -is [Collections.IDictionary]) {
        return @($InputObject.Keys | ForEach-Object { [string]$_ })
    }
    return @($InputObject.PSObject.Properties.Name | ForEach-Object { [string]$_ })
}

function Test-CRUWRollbackCapabilityContract {
    param(
        [AllowNull()] $Capability,
        [Parameter(Mandatory)] $Preflight,
        [switch] $SimulationOnly
    )
    $failures = [Collections.Generic.List[string]]::new()
    $expectedProperties = @(
        'automaticRollbackEligible','exactServiceConfigurationTargetSealed','errorControlAndGroupSealed',
        'postAddExactLiveReadbackMandatory','setupApiTextIsAuthority','restorationGuaranteed',
        'exportedPackageVerified','exportedInfSha256','infServiceName','infServiceType','infStartType',
        'infErrorControl','infServiceBinary','infLoadOrderGroup','sealedLiveStart','sealedLiveType',
        'sealedLiveErrorControl','sealedLiveGroup','sealedLiveImagePathRaw','sealedLiveImagePathCanonical',
        'sealedLiveState','sealedLiveStartOverrideAbsent','bootPromotionObservationCount',
        'diagnosticPromotionEvidenceSealed','promotionEvidence','failures'
    )
    $actualProperties = @(Get-CRUWPropertyNameArray $Capability)
    if (
        $actualProperties.Count -ne $expectedProperties.Count -or
        @($expectedProperties | Where-Object { $actualProperties -cnotcontains $_ }).Count -gt 0 -or
        @($actualProperties | Where-Object { $expectedProperties -cnotcontains $_ }).Count -gt 0
    ) {
        $failures.Add('rollback capability property contract differs from schema v3')
    }
    $infRecord = @($Preflight.driverExport.hashes | Where-Object { [string]$_.file -ieq 'cruwblocker.inf' })
    if ($infRecord.Count -ne 1 -or [string]$Capability.exportedInfSha256 -notmatch '^[A-F0-9]{64}$' -or
        [string]$Capability.exportedInfSha256 -ine [string]$infRecord[0].Hash) {
        $failures.Add('rollback capability exported INF hash is not the sealed package hash')
    }
    if (
        [string](Get-CRUWPropertyValue $Preflight.driverExport 'infSignatureStatus') -cne 'Valid' -or
        [string](Get-CRUWPropertyValue $Preflight.driverExport 'driverSignatureStatus') -cne 'Valid' -or
        [string](Get-CRUWPropertyValue $Preflight.driverExport 'catalogSignatureStatus') -cne 'Valid' -or
        -not [bool](Get-CRUWPropertyValue $Preflight.driverExport 'signaturesValid' $false) -or
        -not [bool](Get-CRUWPropertyValue $Preflight.driverExport 'knownPackageHashesVerified' $false) -or
        -not [bool]$Capability.automaticRollbackEligible -or
        -not [bool]$Capability.exactServiceConfigurationTargetSealed -or
        -not [bool]$Capability.errorControlAndGroupSealed -or
        -not [bool]$Capability.postAddExactLiveReadbackMandatory -or
        [bool]$Capability.setupApiTextIsAuthority -or
        [bool]$Capability.restorationGuaranteed -or
        -not [bool]$Capability.exportedPackageVerified -or
        [string]$Capability.infServiceName -cne 'CRUWBlocker' -or
        [int]$Capability.infServiceType -ne 1 -or
        [int]$Capability.infStartType -ne 3 -or
        [int]$Capability.infErrorControl -ne 1 -or
        [string]$Capability.infServiceBinary -cne '%12%\CRUWBlocker.sys' -or
        [string]$Capability.infLoadOrderGroup -cne 'Pnp Filter' -or
        [int]$Capability.sealedLiveStart -ne 0 -or
        [int]$Capability.sealedLiveType -ne 1 -or
        [int]$Capability.sealedLiveErrorControl -ne 1 -or
        [string]$Capability.sealedLiveGroup -cne 'Pnp Filter' -or
        [string]$Capability.sealedLiveImagePathRaw -notmatch '^(?i:(?:\\SystemRoot\\)?System32\\drivers\\CRUWBlocker\.sys)$' -or
        [string]$Capability.sealedLiveImagePathCanonical -cne '\SystemRoot\System32\drivers\CRUWBlocker.sys' -or
        [string]$Capability.sealedLiveState -cne 'Running' -or
        -not [bool]$Capability.sealedLiveStartOverrideAbsent -or
        [int]$Capability.bootPromotionObservationCount -lt 1 -or
        -not [bool]$Capability.diagnosticPromotionEvidenceSealed -or
        @(Get-CRUWPropertyValue $Capability 'failures').Count -ne 0
    ) { $failures.Add('rollback capability exact INF/live/safety scalar contract failed') }
    if (-not $SimulationOnly) {
        $knownHashes = [ordered]@{
            'cruwblocker.inf'='D9A075F6849EE76CD43BBA4C4FE6B27D27A5788D9A25695413E7791CCA5EBA2B'
            'CRUWBlocker.sys'='F59BE364EB9360C999C6F68218100D0A343BA8D1D67E5AC4419DD79C56A7A18C'
            'CRUWBlocker.cat'='5D8298B9C1908A84E2CD68B6AFF4EA71E9AF3F5B3C850694A74626775A4E3862'
        }
        foreach ($known in $knownHashes.GetEnumerator()) {
            $record = @($Preflight.driverExport.hashes | Where-Object { [string]$_.file -ceq [string]$known.Key })
            if ($record.Count -ne 1 -or [string]$record[0].Hash -cne [string]$known.Value) {
                $failures.Add("rollback package hash is not the authorized CRUW package: $($known.Key)")
            }
        }
    }
    $promotionEvidence = @(Get-CRUWPropertyValue $Capability 'promotionEvidence')
    if ($promotionEvidence.Count -lt 1) { $failures.Add('rollback capability has no sealed diagnostic promotion evidence') }
    foreach ($evidence in $promotionEvidence) {
        $evidenceProperties = @(Get-CRUWPropertyNameArray $evidence)
        $expectedEvidenceProperties = @('fileName','sha256','length','matchCount')
        if (
            $evidenceProperties.Count -ne $expectedEvidenceProperties.Count -or
            @($expectedEvidenceProperties | Where-Object { $evidenceProperties -cnotcontains $_ }).Count -gt 0 -or
            @($evidenceProperties | Where-Object { $expectedEvidenceProperties -cnotcontains $_ }).Count -gt 0 -or
            [string]$evidence.fileName -notmatch '^[A-Za-z0-9._-]+$' -or
            [string]$evidence.sha256 -notmatch '^[A-F0-9]{64}$' -or
            [long]$evidence.length -le 0 -or
            [int]$evidence.matchCount -le 0
        ) { $failures.Add('rollback capability promotion evidence record invalid') }
    }
    return [ordered]@{verified=$failures.Count -eq 0;failures=@($failures)}
}

function Test-CRUWManifestDriverIdentityContract {
    param(
        [AllowNull()] $ManifestIdentity,
        [Parameter(Mandatory)] $Preflight,
        [switch] $SimulationOnly
    )
    $failures = [Collections.Generic.List[string]]::new()
    $expectedProperties = @(
        'publishedName','originalInf','provider','className','version','targetDeviceCount',
        'exportedInfSha256','exportedDriverSha256','exportedCatalogSha256',
        'infSignatureStatus','driverSignatureStatus','catalogSignatureStatus',
        'signaturesValid','installedBinaryMatchesExport','knownPackageHashesVerified'
    )
    $actualProperties = @(Get-CRUWPropertyNameArray $ManifestIdentity)
    if (
        $actualProperties.Count -ne $expectedProperties.Count -or
        @($expectedProperties | Where-Object { $actualProperties -cnotcontains $_ }).Count -gt 0 -or
        @($actualProperties | Where-Object { $expectedProperties -cnotcontains $_ }).Count -gt 0
    ) { $failures.Add('manifest driverIdentity property set differs from schema v3') }

    if (
        [string](Get-CRUWPropertyValue $Preflight.driverExport 'publishedName') -notmatch '^(?i:oem\d+\.inf)$' -or
        [string](Get-CRUWPropertyValue $Preflight.driverExport 'originalInf') -cne 'cruwblocker.inf' -or
        [string](Get-CRUWPropertyValue $ManifestIdentity 'publishedName') -notmatch '^(?i:oem\d+\.inf)$' -or
        [string](Get-CRUWPropertyValue $ManifestIdentity 'originalInf') -cne 'cruwblocker.inf'
    ) { $failures.Add('driver package names are not the fixed CRUW OEM/original INF identities') }

    $hashes = @(Get-CRUWPropertyValue (Get-CRUWPropertyValue $Preflight 'driverExport') 'hashes')
    $inf = @($hashes | Where-Object { [string]$_.file -ceq 'cruwblocker.inf' })
    $sys = @($hashes | Where-Object { [string]$_.file -ceq 'CRUWBlocker.sys' })
    $cat = @($hashes | Where-Object { [string]$_.file -ceq 'CRUWBlocker.cat' })
    if (
        $inf.Count -ne 1 -or $sys.Count -ne 1 -or $cat.Count -ne 1 -or
        [string](Get-CRUWPropertyValue $ManifestIdentity 'publishedName') -cne [string]$Preflight.driverExport.publishedName -or
        [string](Get-CRUWPropertyValue $ManifestIdentity 'originalInf') -cne [string]$Preflight.driverExport.originalInf -or
        [string](Get-CRUWPropertyValue $ManifestIdentity 'provider') -cne [string]$Preflight.driverExport.provider -or
        [string](Get-CRUWPropertyValue $ManifestIdentity 'className') -cne [string]$Preflight.driverExport.className -or
        [string](Get-CRUWPropertyValue $ManifestIdentity 'version') -cne [string]$Preflight.driverExport.version -or
        [int](Get-CRUWPropertyValue $ManifestIdentity 'targetDeviceCount' -1) -ne [int]$Preflight.driverBindingDiscovery.targetDeviceCount -or
        [string](Get-CRUWPropertyValue $ManifestIdentity 'exportedInfSha256') -ine [string]$inf[0].Hash -or
        [string](Get-CRUWPropertyValue $ManifestIdentity 'exportedDriverSha256') -ine [string]$sys[0].Hash -or
        [string](Get-CRUWPropertyValue $ManifestIdentity 'exportedCatalogSha256') -ine [string]$cat[0].Hash -or
        [string](Get-CRUWPropertyValue $ManifestIdentity 'infSignatureStatus') -cne 'Valid' -or
        [string](Get-CRUWPropertyValue $ManifestIdentity 'driverSignatureStatus') -cne 'Valid' -or
        [string](Get-CRUWPropertyValue $ManifestIdentity 'catalogSignatureStatus') -cne 'Valid' -or
        [string](Get-CRUWPropertyValue $ManifestIdentity 'infSignatureStatus') -cne [string]$Preflight.driverExport.infSignatureStatus -or
        [string](Get-CRUWPropertyValue $ManifestIdentity 'driverSignatureStatus') -cne [string]$Preflight.driverExport.driverSignatureStatus -or
        [string](Get-CRUWPropertyValue $ManifestIdentity 'catalogSignatureStatus') -cne [string]$Preflight.driverExport.catalogSignatureStatus -or
        -not [bool](Get-CRUWPropertyValue $ManifestIdentity 'signaturesValid' $false) -or
        -not [bool](Get-CRUWPropertyValue $ManifestIdentity 'installedBinaryMatchesExport' $false) -or
        -not [bool](Get-CRUWPropertyValue $ManifestIdentity 'knownPackageHashesVerified' $false) -or
        -not [bool]$Preflight.driverExport.knownPackageHashesVerified
    ) { $failures.Add('manifest driverIdentity values do not cross-link to the signed driver export') }

    if (-not $SimulationOnly) {
        $knownHashes = [ordered]@{
            exportedInfSha256='D9A075F6849EE76CD43BBA4C4FE6B27D27A5788D9A25695413E7791CCA5EBA2B'
            exportedDriverSha256='F59BE364EB9360C999C6F68218100D0A343BA8D1D67E5AC4419DD79C56A7A18C'
            exportedCatalogSha256='5D8298B9C1908A84E2CD68B6AFF4EA71E9AF3F5B3C850694A74626775A4E3862'
        }
        foreach ($known in $knownHashes.GetEnumerator()) {
            if ([string](Get-CRUWPropertyValue $ManifestIdentity ([string]$known.Key)) -cne [string]$known.Value) {
                $failures.Add("manifest driverIdentity hash is not the authorized CRUW package: $($known.Key)")
            }
        }
    }
    return [ordered]@{verified=$failures.Count -eq 0;failures=@($failures)}
}

function Test-CRUWRollbackLiveReadback {
    param(
        [Parameter(Mandatory)] $Snapshot,
        [Parameter(Mandatory)] $Capability
    )
    $service = Get-CRUWPropertyValue $Snapshot 'service'
    $rawImagePath = ([string](Get-CRUWPropertyValue $service 'imagePath')).Replace('/','\').Trim()
    $canonicalImagePath = if ($rawImagePath -match '^(?i:System32\\drivers\\CRUWBlocker\.sys)$') {
        '\SystemRoot\System32\drivers\CRUWBlocker.sys'
    }
    elseif ($rawImagePath -match '^(?i:\\SystemRoot\\System32\\drivers\\CRUWBlocker\.sys)$') {
        '\SystemRoot\System32\drivers\CRUWBlocker.sys'
    }
    else { $null }
    $gates = [ordered]@{
        exists = [bool](Get-CRUWPropertyValue $service 'exists' $false)
        state = [string](Get-CRUWPropertyValue $service 'state') -ceq [string]$Capability.sealedLiveState
        start = [int](Get-CRUWPropertyValue $service 'start' -1) -eq [int]$Capability.sealedLiveStart
        type = [int](Get-CRUWPropertyValue $service 'type' -1) -eq [int]$Capability.sealedLiveType
        errorControl = [int](Get-CRUWPropertyValue $service 'errorControl' -1) -eq [int]$Capability.sealedLiveErrorControl
        group = [string](Get-CRUWPropertyValue $service 'group') -ceq [string]$Capability.sealedLiveGroup
        imagePathRawAllowed = $null -ne $canonicalImagePath
        imagePathCanonical = [string]$canonicalImagePath -ceq [string]$Capability.sealedLiveImagePathCanonical
        binaryPresent = [bool](Get-CRUWPropertyValue $service 'binaryPresent' $false)
        binarySignature = [string](Get-CRUWPropertyValue $service 'binarySignatureStatus') -ceq 'Valid'
        noStartOverride = [bool]$Capability.sealedLiveStartOverrideAbsent -and @(Get-CRUWPropertyValue $service 'startOverride').Count -eq 0
    }
    $failed = @($gates.GetEnumerator() | Where-Object { -not [bool]$_.Value } | ForEach-Object Key)
    return [ordered]@{verified=$failed.Count -eq 0;gates=$gates;failedGates=$failed}
}

function ConvertTo-CRUWUtcRoundtripString {
    param([Parameter(Mandatory)] $Value)
    if ($Value -is [datetime]) { return ([datetime]$Value).ToUniversalTime().ToString('o') }
    if ($Value -is [DateTimeOffset]) { return ([DateTimeOffset]$Value).UtcDateTime.ToString('o') }
    return ([DateTimeOffset]::Parse([string]$Value)).UtcDateTime.ToString('o')
}

function Get-CRUWStringSha256 {
    param([Parameter(Mandatory)] [string] $Text)
    $sha = [Security.Cryptography.SHA256]::Create()
    try {
        $bytes = [Text.UTF8Encoding]::new($false).GetBytes($Text)
        return ([BitConverter]::ToString($sha.ComputeHash($bytes))).Replace('-', '')
    }
    finally { $sha.Dispose() }
}

function Get-CRUWObjectSha256 {
    param([Parameter(Mandatory)] $InputObject)
    return Get-CRUWStringSha256 -Text ($InputObject | ConvertTo-Json -Depth 20 -Compress)
}

function ConvertTo-CRUWExtendedPath {
    param([Parameter(Mandatory)] [string] $Path)
    $full = [IO.Path]::GetFullPath($Path)
    if ($full.StartsWith('\\?\')) { return $full }
    if ($full.StartsWith('\\')) { return '\\?\UNC\' + $full.Substring(2) }
    return '\\?\' + $full
}

function Resolve-CRUWSafeRelativeFilePath {
    param(
        [Parameter(Mandatory)] [string] $Root,
        [Parameter(Mandatory)] [string] $RelativePath
    )
    if (
        [string]::IsNullOrWhiteSpace($RelativePath) -or
        [IO.Path]::IsPathRooted($RelativePath) -or
        $RelativePath -match '(^|[\\/])\.\.([\\/]|$)' -or
        $RelativePath.Contains(':')
    ) {
        throw "Unsafe recovery-relative path: $RelativePath"
    }
    $rootFull = [IO.Path]::GetFullPath($Root).TrimEnd([IO.Path]::DirectorySeparatorChar,[IO.Path]::AltDirectorySeparatorChar)
    $nativeRelative = $RelativePath.Replace([char]'/',[IO.Path]::DirectorySeparatorChar).Replace([char]'\',[IO.Path]::DirectorySeparatorChar)
    $candidate = [IO.Path]::GetFullPath((Join-Path $rootFull $nativeRelative))
    $containedPrefix = $rootFull + [IO.Path]::DirectorySeparatorChar
    if (-not $candidate.StartsWith($containedPrefix,[StringComparison]::OrdinalIgnoreCase)) {
        throw "Recovery-relative path escapes its sealed root: $RelativePath"
    }
    return $candidate
}

function Test-CRUWPathHasReparseAncestor {
    param([Parameter(Mandatory)] [string] $Path)
    $inputPath = [string]$Path
    if (
        -not [IO.Path]::IsPathRooted($inputPath) -or
        $inputPath.StartsWith('\\') -or
        $inputPath.StartsWith('\\?\') -or
        $inputPath.StartsWith('\\.\') -or
        $inputPath.IndexOf(':',2) -ge 0
    ) { return $true }
    $full = [IO.Path]::GetFullPath($inputPath)
    if ($full -ine $inputPath.TrimEnd('\')) { return $true }
    $driveRoot = [IO.Path]::GetPathRoot($full)
    if ($driveRoot -notmatch '^[A-Za-z]:\\$') { return $true }

    # Walk from the already-local drive root toward the leaf. Inspecting a leaf
    # first can traverse a junction in one of its parents before detecting it.
    $currentPath = $driveRoot
    $rootItem = Get-Item -LiteralPath $currentPath -Force -ErrorAction Stop
    if ($rootItem.Attributes -band [IO.FileAttributes]::ReparsePoint) { return $true }
    $relative = $full.Substring($driveRoot.Length).Trim('\')
    if ([string]::IsNullOrWhiteSpace($relative)) { return $false }
    foreach ($component in @($relative -split '\\')) {
        if ([string]::IsNullOrWhiteSpace($component) -or $component -in @('.','..') -or $component.Contains(':')) { return $true }
        $nextPath = Join-Path $currentPath $component
        $item = Get-Item -LiteralPath $nextPath -Force -ErrorAction Stop
        if ($item.Attributes -band [IO.FileAttributes]::ReparsePoint) { return $true }
        $resolved = [IO.Path]::GetFullPath($item.FullName).TrimEnd('\')
        $expected = [IO.Path]::GetFullPath($nextPath).TrimEnd('\')
        if (-not [string]::Equals($resolved,$expected,[StringComparison]::OrdinalIgnoreCase)) { return $true }
        $currentPath = $expected
    }
    return $false
}

function Test-CRUWRecoveryRootTopology {
    param($Primary, $Secondary, [AllowNull()] $Expected)
    $basic =
        [string]$Primary.mountPoint -ceq 'C:' -and
        [string]$Secondary.mountPoint -ceq 'D:' -and
        [int]$Primary.diskNumber -ne [int]$Secondary.diskNumber -and
        [string]$Primary.deviceInstanceIdSha256 -cne [string]$Secondary.deviceInstanceIdSha256 -and
        [string]$Primary.deviceInstanceIdSha256 -match '^[A-Fa-f0-9]{64}$' -and
        [string]$Secondary.deviceInstanceIdSha256 -match '^[A-Fa-f0-9]{64}$' -and
        -not [bool]$Primary.diskReadOnly -and -not [bool]$Secondary.diskReadOnly -and
        -not [bool]$Primary.diskOffline -and -not [bool]$Secondary.diskOffline -and
        [string]$Primary.diskHealthStatus -ieq 'Healthy' -and
        [string]$Secondary.diskHealthStatus -ieq 'Healthy' -and
        @(ConvertTo-CRUWStringArray $Primary.diskOperationalStatus).Count -eq 1 -and
        @(ConvertTo-CRUWStringArray $Secondary.diskOperationalStatus).Count -eq 1 -and
        (Test-CRUWEqualSet $Primary.diskOperationalStatus @('Online')) -and
        (Test-CRUWEqualSet $Secondary.diskOperationalStatus @('Online')) -and
        [string]$Primary.diskBusType -match '^(?i:NVMe|SATA|SAS|RAID|USB|SCM)$' -and
        [string]$Secondary.diskBusType -match '^(?i:NVMe|SATA|SAS|RAID|USB|SCM)$'
    if (-not $basic) { return $false }
    if ($null -eq $Expected) { return $true }
    return ([int]$Primary.diskNumber -eq [int]$Expected.primary.diskNumber -and
        [int]$Secondary.diskNumber -eq [int]$Expected.secondary.diskNumber -and
        [string]$Primary.deviceInstanceIdSha256 -ieq [string]$Expected.primary.deviceInstanceIdSha256 -and
        [string]$Secondary.deviceInstanceIdSha256 -ieq [string]$Expected.secondary.deviceInstanceIdSha256 -and
        [string]$Primary.diskBusType -ieq [string]$Expected.primary.diskBusType -and
        [string]$Secondary.diskBusType -ieq [string]$Expected.secondary.diskBusType)
}

if ($null -eq ('CRUW.NativeFile' -as [type])) {
    Add-Type -TypeDefinition @'
using System;
using System.Runtime.InteropServices;
namespace CRUW {
    public static class NativeFile {
        [DllImport("kernel32.dll", CharSet = CharSet.Unicode, SetLastError = true)]
        [return: MarshalAs(UnmanagedType.Bool)]
        public static extern bool MoveFileEx(string existingName, string newName, int flags);
    }
}
'@
}

function Write-CRUWBytesDurableAtomic {
    param(
        [Parameter(Mandatory)] [string] $LiteralPath,
        [Parameter(Mandatory)] [byte[]] $Bytes,
        [hashtable] $Adapter,
        [switch] $ProtectAcl
    )
    $fullPath = [IO.Path]::GetFullPath($LiteralPath)
    $parent = Split-Path -Parent $fullPath
    if (-not (Test-Path -LiteralPath $parent -PathType Container)) { throw "Output directory does not exist: $parent" }
    if (Test-Path -LiteralPath $fullPath) { throw "Durable atomic destination already exists: $fullPath" }
    $temporaryPath = "$fullPath.$([guid]::NewGuid().ToString('N')).tmp"
    try {
        $stream = [IO.FileStream]::new(
            $temporaryPath,
            [IO.FileMode]::CreateNew,
            [IO.FileAccess]::Write,
            [IO.FileShare]::None,
            4096,
            [IO.FileOptions]::WriteThrough
        )
        try {
            $stream.Write($Bytes, 0, $Bytes.Length)
            $stream.Flush($true)
        }
        finally { $stream.Dispose() }

        $expectedHash = Get-CRUWBytesSha256 $Bytes
        $temporaryHashBeforeAcl = (Get-FileHash -LiteralPath $temporaryPath -Algorithm SHA256).Hash
        if ($temporaryHashBeforeAcl -cne $expectedHash) { throw 'Temporary durable file hash verification failed before ACL protection' }

        if ($ProtectAcl) {
            if ($null -eq $Adapter) { throw 'Protected durable write requires an adapter' }
            Invoke-CRUWAdapter $Adapter 'ProtectFileAcl' @($temporaryPath) | Out-Null
            $temporaryAcl = Invoke-CRUWAdapter $Adapter 'TestProtectedAcl' @($temporaryPath)
            if (-not [bool]$temporaryAcl.verified) { throw 'Temporary durable file ACL verification failed' }
            if ((Get-FileHash -LiteralPath $temporaryPath -Algorithm SHA256).Hash -cne $expectedHash) {
                throw 'Temporary durable file hash changed while ACL was protected'
            }
        }
        $moveFileWriteThrough = 0x00000008
        $nativeTemporaryPath = ConvertTo-CRUWExtendedPath $temporaryPath
        $nativeDestinationPath = ConvertTo-CRUWExtendedPath $fullPath
        if (-not [CRUW.NativeFile]::MoveFileEx($nativeTemporaryPath, $nativeDestinationPath, $moveFileWriteThrough)) {
            throw [ComponentModel.Win32Exception]::new([Runtime.InteropServices.Marshal]::GetLastWin32Error(), 'MoveFileExW(MOVEFILE_WRITE_THROUGH) failed')
        }
        $actualHash = (Get-FileHash -LiteralPath $fullPath -Algorithm SHA256).Hash
        if ($actualHash -ne $expectedHash) { throw 'Durable atomic file hash verification failed' }
        if ($ProtectAcl) {
            $finalAcl = Invoke-CRUWAdapter $Adapter 'TestProtectedAcl' @($fullPath)
            if (-not [bool]$finalAcl.verified) { throw 'Durable atomic destination ACL verification failed' }
        }
    }
    finally { if (Test-Path -LiteralPath $temporaryPath) { Remove-Item -LiteralPath $temporaryPath -Force } }
}

function Write-CRUWJsonAtomic {
    param([Parameter(Mandatory)] [string] $LiteralPath, [Parameter(Mandatory)] $InputObject)
    $json = ($InputObject | ConvertTo-Json -Depth 20) + [Environment]::NewLine
    $bytes = [Text.UTF8Encoding]::new($false).GetBytes($json)
    Write-CRUWBytesDurableAtomic -LiteralPath $LiteralPath -Bytes $bytes
}

function Get-CRUWBytesSha256 {
    param([Parameter(Mandatory)] [byte[]] $Bytes)
    $sha = [Security.Cryptography.SHA256]::Create()
    try { return ([BitConverter]::ToString($sha.ComputeHash($Bytes))).Replace('-', '') }
    finally { $sha.Dispose() }
}

function Enter-CRUWOperationMutex {
    $mutexName = 'Global\CRUWBlockerRemoval-MachineWide'
    $mutexOwnerSid = 'S-1-5-32-544'
    $security = [Security.AccessControl.MutexSecurity]::new()
    $security.SetAccessRuleProtection($true, $false)
    $fullControl = [Security.AccessControl.MutexRights]::FullControl
    $allow = [Security.AccessControl.AccessControlType]::Allow
    foreach ($sidText in @('S-1-5-18', 'S-1-5-32-544')) {
        $sid = [Security.Principal.SecurityIdentifier]::new($sidText)
        $security.AddAccessRule([Security.AccessControl.MutexAccessRule]::new($sid, $fullControl, $allow))
    }
    $security.SetOwner([Security.Principal.SecurityIdentifier]::new($mutexOwnerSid))
    $createdNew = $false
    if ($null -ne ('System.Threading.MutexAcl' -as [type])) {
        $mutex = [Threading.MutexAcl]::Create($false, $mutexName, [ref]$createdNew, $security)
    }
    else {
        $mutex = [Threading.Mutex]::new($false, $mutexName, [ref]$createdNew, $security)
    }
    $acquired = $false
    try { $acquired = $mutex.WaitOne(0) }
    catch [Threading.AbandonedMutexException] { $acquired = $true }
    if (-not $acquired) {
        $mutex.Dispose()
        throw 'Another writer already owns this CRUW removal operation'
    }
    try {
        $sections = [Security.AccessControl.AccessControlSections]::Owner -bor [Security.AccessControl.AccessControlSections]::Access
        $actualSecurity = [Security.AccessControl.MutexSecurity]::new($mutexName, $sections)
        $owner = $actualSecurity.GetOwner([Security.Principal.SecurityIdentifier]).Value
        $rules = @($actualSecurity.GetAccessRules($true, $false, [Security.Principal.SecurityIdentifier]))
        $ruleSids = @($rules | ForEach-Object { $_.IdentityReference.Value } | Sort-Object -Unique)
        $aclExact =
            $owner -ceq $mutexOwnerSid -and
            $actualSecurity.AreAccessRulesProtected -and
            (Test-CRUWEqualSet $ruleSids @('S-1-5-18','S-1-5-32-544')) -and
            @($rules | Where-Object {
                [string]$_.AccessControlType -cne 'Allow' -or
                ($_.MutexRights -band [Security.AccessControl.MutexRights]::FullControl) -ne [Security.AccessControl.MutexRights]::FullControl
            }).Count -eq 0
        if (-not $aclExact) { throw 'Global mutex is not Administrators-owned with exactly SYSTEM and Administrators FullControl' }
    }
    catch {
        try { $mutex.ReleaseMutex() } catch {}
        $mutex.Dispose()
        throw 'Global mutex ACL verification failed closed: ' + $_.Exception.Message
    }
    return [ordered]@{ mutex = $mutex; nameSha256 = Get-CRUWStringSha256 $mutexName; acquired = $true }
}

function Exit-CRUWOperationMutex {
    param([AllowNull()] $Handle)
    if ($null -eq $Handle -or -not [bool]$Handle.acquired) { return }
    try { $Handle.mutex.ReleaseMutex() }
    finally { $Handle.mutex.Dispose() }
}

function Invoke-CRUWAdapter {
    param([Parameter(Mandatory)] [hashtable] $Adapter, [Parameter(Mandatory)] [string] $Name, [object[]] $ArgumentList = @())
    if (-not $Adapter.ContainsKey($Name) -or $Adapter[$Name] -isnot [scriptblock]) { throw "Adapter operation missing: $Name" }
    return & $Adapter[$Name] @ArgumentList
}

function Test-CRUWEqualSet {
    param([AllowNull()] $Actual, [AllowNull()] $Expected)
    $a = @(ConvertTo-CRUWStringArray $Actual | ForEach-Object { $_.ToLowerInvariant() } | Sort-Object -Unique)
    $e = @(ConvertTo-CRUWStringArray $Expected | ForEach-Object { $_.ToLowerInvariant() } | Sort-Object -Unique)
    return ($a -join "`0") -ceq ($e -join "`0")
}

function Test-CRUWEqualOrdered {
    param([AllowNull()] $Actual, [AllowNull()] $Expected)
    $a = @(ConvertTo-CRUWStringArray $Actual)
    $e = @(ConvertTo-CRUWStringArray $Expected)
    if ($a.Count -ne $e.Count) { return $false }
    for ($index = 0; $index -lt $a.Count; $index++) {
        if ([string] $a[$index] -ine [string] $e[$index]) { return $false }
    }
    return $true
}

function Remove-CRUWFilterReference {
    param([AllowNull()] $Filters, [Parameter(Mandatory)] [string] $FilterName)
    return @(ConvertTo-CRUWStringArray $Filters | Where-Object { $_ -ine $FilterName })
}

function Get-CRUWNativeBootIdentity {
    $os = Get-CimInstance -ClassName Win32_OperatingSystem -ErrorAction Stop
    $lastBoot = if ($os.LastBootUpTime -is [datetime]) { [datetime] $os.LastBootUpTime } else {
        [Management.ManagementDateTimeConverter]::ToDateTime([string] $os.LastBootUpTime)
    }
    $lastBootUtc = $lastBoot.ToUniversalTime().ToString('o')
    $build = [string] $os.BuildNumber
    return [ordered]@{
        lastBootUpTimeUtc = $lastBootUtc
        operatingSystemBuild = $build
        markerSha256 = Get-CRUWStringSha256 -Text ($lastBootUtc + '|' + $build)
    }
}

function Get-CRUWNativeBitLockerState {
    param([Parameter(Mandatory)] [string] $MountPoint)
    $volume = Get-BitLockerVolume -MountPoint $MountPoint -ErrorAction Stop
    return [ordered]@{
        mountPoint = $MountPoint
        volumeStatus = [string] $volume.VolumeStatus
        protectionStatus = [string] $volume.ProtectionStatus
        lockStatus = [string] $volume.LockStatus
        encryptionPercentage = [int] $volume.EncryptionPercentage
        recoveryPasswordProtectorCount = @($volume.KeyProtector | Where-Object { [string] $_.KeyProtectorType -eq 'RecoveryPassword' }).Count
        secretRecorded = $false
    }
}

function Get-CRUWPnpPropertyData {
    param([string] $InstanceId, [string] $KeyName, [switch] $Optional)
    $ea = if ($Optional) { 'SilentlyContinue' } else { 'Stop' }
    $property = Get-PnpDeviceProperty -InstanceId $InstanceId -KeyName $KeyName -ErrorAction $ea
    if ($null -eq $property) { return $null }
    return $property.Data
}

function Get-CRUWNativePnpParentServiceChain {
    param([Parameter(Mandatory)] [string] $InstanceId)
    $chain = [Collections.Generic.List[object]]::new()
    $seen = [Collections.Generic.HashSet[string]]::new([StringComparer]::OrdinalIgnoreCase)
    $current = $InstanceId
    $terminated = $false
    $noCycle = $true
    for ($depth = 0; $depth -lt 16; $depth++) {
        $parent = [string](Get-CRUWPnpPropertyData $current 'DEVPKEY_Device_Parent' -Optional)
        if ([string]::IsNullOrWhiteSpace($parent)) { $terminated=$true; break }
        if (-not $seen.Add($parent)) { $noCycle=$false; break }
        $service = [string](Get-CRUWPnpPropertyData $parent 'DEVPKEY_Device_Service' -Optional)
        $chain.Add([ordered]@{
            depth = $depth + 1
            instanceIdSha256 = Get-CRUWStringSha256 $parent
            service = $service
        })
        $current = $parent
    }
    return [ordered]@{ items=@($chain);terminated=$terminated;noCycle=$noCycle;truncated=-not $terminated -and $noCycle }
}

function Get-CRUWNativeRecoveryRootEvidence {
    param([Parameter(Mandatory)] [string] $RootPath)
    $full = [IO.Path]::GetFullPath($RootPath)
    $mountPoint = [IO.Path]::GetPathRoot($full).TrimEnd('\').ToUpperInvariant()
    if ($mountPoint -notmatch '^[A-Z]:$') { throw 'Recovery root is not on a drive-letter volume' }
    $driveLetter = $mountPoint.TrimEnd(':')
    $partitions = @(Get-Partition -DriveLetter $driveLetter -ErrorAction Stop)
    if ($partitions.Count -ne 1) { throw "Recovery root $mountPoint partition mapping is ambiguous" }
    $disks = @(Get-Disk -Number $partitions[0].DiskNumber -ErrorAction Stop)
    if ($disks.Count -ne 1) { throw "Recovery root $mountPoint disk mapping is ambiguous" }
    $disk = $disks[0]
    $cimDisks = @(Get-CimInstance -ClassName Win32_DiskDrive -Filter "Index=$($partitions[0].DiskNumber)" -ErrorAction Stop)
    if ($cimDisks.Count -ne 1) { throw "Recovery root $mountPoint CIM disk mapping is ambiguous" }
    return [ordered]@{
        mountPoint = $mountPoint
        diskNumber = [int]$partitions[0].DiskNumber
        deviceInstanceIdSha256 = Get-CRUWStringSha256 ([string]$cimDisks[0].PNPDeviceID)
        diskReadOnly = [bool]$disk.IsReadOnly
        diskOffline = [bool]$disk.IsOffline
        diskHealthStatus = [string]$disk.HealthStatus
        diskOperationalStatus = @(ConvertTo-CRUWStringArray $disk.OperationalStatus)
        diskBusType = [string]$disk.BusType
    }
}

function ConvertTo-CRUWRestorePointDateTime {
    param([AllowNull()] $CreationTime)
    if ($null -eq $CreationTime) { return $null }
    if ($CreationTime -is [datetime]) { return [datetime]$CreationTime }
    if ($CreationTime -is [DateTimeOffset]) { return ([DateTimeOffset]$CreationTime).LocalDateTime }
    try {
        return [Management.ManagementDateTimeConverter]::ToDateTime([string]$CreationTime)
    }
    catch {
        return $null
    }
}

function Get-CRUWCanonicalWinReLocationSha256 {
    param([Parameter(Mandatory)] [string] $Location)
    $canonical = $Location.Trim().Replace('/','\').TrimEnd('\').ToLowerInvariant()
    if ([string]::IsNullOrWhiteSpace($canonical) -or $canonical -notmatch '^\\\\\?\\globalroot\\device\\harddisk\d+\\partition\d+\\recovery\\windowsre$') {
        throw 'WinRE location is not a canonical GLOBALROOT device path'
    }
    return Get-CRUWStringSha256 $canonical
}

function Get-CRUWNativeRecoveryReadiness {
    $reagentOutput = (& reagentc.exe /info 2>&1 | Out-String)
    $reagentExitCode = [int]$LASTEXITCODE
    $winReEnabled =
        $reagentExitCode -eq 0 -and
        $reagentOutput -match '(?im)(Windows\s+RE\s+status|Estado\s+de\s+Windows\s+RE)\s*:\s*(Enabled|Habilitado)'
    $locationMatch = [regex]::Match($reagentOutput, '(?im)(Windows\s+RE\s+location|Ubicaci[oó]n\s+de\s+Windows\s+RE)\s*:\s*(?<location>\\\\\?\\GLOBALROOT\\device\\harddisk[^\r\n]+)')
    $restorePointQuerySucceeded = $false
    $restorePoints = @()
    try {
        $restorePoints = @(Get-ComputerRestorePoint -ErrorAction Stop)
        $restorePointQuerySucceeded = $true
    }
    catch {
        $restorePoints = @()
    }

    $systemRestoreRegistryQuerySucceeded = $false
    $policyDisableSR = $null
    $policyDisableConfig = $null
    $runtimeDisableSR = $null
    try {
        $policyPath = 'HKLM:\SOFTWARE\Policies\Microsoft\Windows NT\SystemRestore'
        $runtimePath = 'HKLM:\SOFTWARE\Microsoft\Windows NT\CurrentVersion\SystemRestore'
        $policy = if (Test-Path -LiteralPath $policyPath -PathType Container) {
            Get-ItemProperty -LiteralPath $policyPath -ErrorAction Stop
        }
        else { $null }
        $runtime = if (Test-Path -LiteralPath $runtimePath -PathType Container) {
            Get-ItemProperty -LiteralPath $runtimePath -ErrorAction Stop
        }
        else { $null }
        $policyDisableSR = Get-CRUWPropertyValue $policy 'DisableSR'
        $policyDisableConfig = Get-CRUWPropertyValue $policy 'DisableConfig'
        $runtimeDisableSR = Get-CRUWPropertyValue $runtime 'DisableSR'
        $systemRestoreRegistryQuerySucceeded = $true
    }
    catch {
        $systemRestoreRegistryQuerySucceeded = $false
    }
    $datedRestorePoints = @($restorePoints | ForEach-Object {
        $creationDate = ConvertTo-CRUWRestorePointDateTime $_.CreationTime
        $sequenceNumber = 0L
        if ($null -ne $creationDate -and [long]::TryParse([string]$_.SequenceNumber,[ref]$sequenceNumber) -and $sequenceNumber -gt 0) {
            [ordered]@{ restorePoint=$_;creationDate=[datetime]$creationDate;sequenceNumber=$sequenceNumber }
        }
    })
    $maximumSequence = if ($datedRestorePoints.Count -gt 0) {
        [long]($datedRestorePoints.sequenceNumber | Measure-Object -Maximum).Maximum
    }
    else { 0L }
    $latestRestore = @($datedRestorePoints | Where-Object { [long]$_.sequenceNumber -eq $maximumSequence })
    $latestRestoreAgeHours = if ($latestRestore.Count -eq 1) {
        ([DateTimeOffset]::Now - [DateTimeOffset]$latestRestore[0].creationDate).TotalHours
    }
    else { $null }
    $recentRestorePointPresent =
        $latestRestore.Count -eq 1 -and
        $latestRestoreAgeHours -ge 0 -and
        $latestRestoreAgeHours -le 24
    $systemRestoreReadyForTransaction =
        $restorePointQuerySucceeded -and
        $systemRestoreRegistryQuerySucceeded -and
        $policyDisableSR -ne 1 -and
        $runtimeDisableSR -ne 1 -and
        $recentRestorePointPresent

    return [ordered]@{
        winReEnabled = $winReEnabled
        winReLocationPresent = $locationMatch.Success
        winReLocationSha256 = if ($locationMatch.Success) { Get-CRUWCanonicalWinReLocationSha256 $locationMatch.Groups['location'].Value } else { $null }
        reagentExitCode = $reagentExitCode
        restorePointPresent = $restorePoints.Count -gt 0
        restorePointCount = $restorePoints.Count
        restorePointQuerySucceeded = $restorePointQuerySucceeded
        recentRestorePointPresent = $recentRestorePointPresent
        latestRestorePointAgeHours = $latestRestoreAgeHours
        latestRestorePointSequenceNumber = if ($latestRestore.Count -eq 1) { [long]$latestRestore[0].sequenceNumber } else { $null }
        systemRestoreRegistryQuerySucceeded = $systemRestoreRegistryQuerySucceeded
        policyDisableSR = $policyDisableSR
        policyDisableConfig = $policyDisableConfig
        disableConfigRecordedButNotUsedAsDisableSignal = $true
        runtimeDisableSR = $runtimeDisableSR
        systemRestoreReadyForTransaction = $systemRestoreReadyForTransaction
    }
}

function Get-CRUWNativeAcPowerState {
    $sources = @(Get-CimInstance -Namespace root/WMI -ClassName BatteryStatus -ErrorAction Stop)
    return [ordered]@{ online=$sources.Count -gt 0 -and @($sources | Where-Object { -not [bool]$_.PowerOnline }).Count -eq 0;sourceCount=$sources.Count }
}

function Test-CRUWNativeProtectedAcl {
    param([Parameter(Mandatory)] [string] $Path)
    $allowed = @('S-1-5-18', 'S-1-5-32-544')
    $failures = [Collections.Generic.List[string]]::new()
    $items = @((Get-Item -LiteralPath $Path -ErrorAction Stop)) + @(Get-ChildItem -LiteralPath $Path -Recurse -Force -ErrorAction Stop)
    foreach ($item in $items) {
        $acl = Get-Acl -LiteralPath $item.FullName
        if (-not $acl.AreAccessRulesProtected) { $failures.Add("Inherited ACL: $($item.Name)") }
        try { $owner = ([Security.Principal.NTAccount] $acl.Owner).Translate([Security.Principal.SecurityIdentifier]).Value }
        catch { $owner = [string] $acl.Owner }
        if ($owner -ne 'S-1-5-18') { $failures.Add("Owner is not SYSTEM: $($item.Name)") }
        $seen = @{}
        foreach ($rule in @($acl.Access)) {
            try { $sid = $rule.IdentityReference.Translate([Security.Principal.SecurityIdentifier]).Value }
            catch { $sid = [string] $rule.IdentityReference }
            $seen[$sid] = $true
            if ($allowed -notcontains $sid -or [string] $rule.AccessControlType -ne 'Allow' -or
                ($rule.FileSystemRights -band [Security.AccessControl.FileSystemRights]::FullControl) -ne [Security.AccessControl.FileSystemRights]::FullControl) {
                $failures.Add("Unauthorized ACL: $($item.Name)")
            }
        }
        foreach ($required in $allowed) { if (-not $seen.ContainsKey($required)) { $failures.Add("Missing ACL $required`: $($item.Name)") } }
    }
    return [ordered]@{ verified = $failures.Count -eq 0; checkedItemCount = $items.Count; failures = @($failures) }
}

function Set-CRUWNativeProtectedFileAcl {
    param([Parameter(Mandatory)] [string] $Path)
    $administrators = [Security.Principal.SecurityIdentifier]::new('S-1-5-32-544')
    $system = [Security.Principal.SecurityIdentifier]::new('S-1-5-18')
    $acl = [Security.AccessControl.FileSecurity]::new()
    $acl.SetAccessRuleProtection($true, $false)
    $acl.SetOwner($system)
    $allow = [Security.AccessControl.AccessControlType]::Allow
    $full = [Security.AccessControl.FileSystemRights]::FullControl
    [void] $acl.AddAccessRule([Security.AccessControl.FileSystemAccessRule]::new($system, $full, $allow))
    [void] $acl.AddAccessRule([Security.AccessControl.FileSystemAccessRule]::new($administrators, $full, $allow))
    Set-Acl -LiteralPath $Path -AclObject $acl
}

function Get-CRUWNativePendingRebootState {
    $cbs = Test-Path 'HKLM:\SOFTWARE\Microsoft\Windows\CurrentVersion\Component Based Servicing\RebootPending'
    $wu = Test-Path 'HKLM:\SOFTWARE\Microsoft\Windows\CurrentVersion\WindowsUpdate\Auto Update\RebootRequired'
    $rename = @((Get-ItemProperty 'HKLM:\SYSTEM\CurrentControlSet\Control\Session Manager' -Name PendingFileRenameOperations -ErrorAction SilentlyContinue).PendingFileRenameOperations).Count
    return [ordered]@{ cbs = $cbs; windowsUpdate = $wu; pendingFileRenameEntries = $rename; detected = $cbs -or $wu -or $rename -gt 0 }
}

function Resolve-CRUWNativeDriverBinaryPath {
    param([AllowNull()] [string] $PathName)
    if ([string]::IsNullOrWhiteSpace($PathName)) { return $null }
    $candidate = $PathName.Trim().Trim('"')
    if ($candidate.StartsWith('\??\', [StringComparison]::OrdinalIgnoreCase)) { $candidate = $candidate.Substring(4) }
    if ($candidate.StartsWith('\SystemRoot\', [StringComparison]::OrdinalIgnoreCase)) {
        $candidate = Join-Path $env:SystemRoot $candidate.Substring('\SystemRoot\'.Length)
    }
    elseif ($candidate.StartsWith('System32\', [StringComparison]::OrdinalIgnoreCase)) {
        $candidate = Join-Path $env:SystemRoot $candidate
    }
    else { $candidate = [Environment]::ExpandEnvironmentVariables($candidate) }
    try { return [IO.Path]::GetFullPath($candidate) } catch { return $candidate }
}

function Get-CRUWNativeStorageServiceSnapshot {
    $names = @('partmgr','disk','mtinvme','iaStorAC')
    $result = foreach ($name in $names) {
        $matches = @(Get-CimInstance -ClassName Win32_SystemDriver -Filter "Name='$name'" -ErrorAction SilentlyContinue)
        if ($matches.Count -eq 0) { continue }
        if ($matches.Count -ne 1) { throw "Native storage service identity is ambiguous: $name" }
        $driver = $matches[0]
        $registryPath = "HKLM:\SYSTEM\CurrentControlSet\Services\$name"
        $registry = Get-ItemProperty -LiteralPath $registryPath -ErrorAction Stop
        $startOverride = Get-ItemProperty -LiteralPath (Join-Path $registryPath 'StartOverride') -ErrorAction SilentlyContinue
        $startOverrideEvidence = if ($null -eq $startOverride) {
            $null
        }
        else {
            @($startOverride.PSObject.Properties |
                Where-Object { $_.Name -match '^\d+$' } |
                Sort-Object { [int]$_.Name } |
                ForEach-Object { [ordered]@{ name = [string]$_.Name; value = [int]$_.Value } })
        }
        $expanded = Resolve-CRUWNativeDriverBinaryPath ([string]$driver.PathName)
        $registryImageExpanded = Resolve-CRUWNativeDriverBinaryPath ([string](Get-CRUWPropertyValue $registry 'ImagePath' ''))
        $present = -not [string]::IsNullOrWhiteSpace($expanded) -and (Test-Path -LiteralPath $expanded -PathType Leaf)
        $underSystemDrivers = $present -and (Split-Path -Parent $expanded) -ieq (Join-Path $env:SystemRoot 'System32\drivers')
        $basenameMatches = $present -and (Split-Path -Leaf $expanded) -ieq ($name + '.sys')
        $registryImageMatches =
            $present -and
            -not [string]::IsNullOrWhiteSpace($registryImageExpanded) -and
            [IO.Path]::GetFullPath($registryImageExpanded) -ieq [IO.Path]::GetFullPath($expanded)
        [ordered]@{
            name = $name
            state = [string]$driver.State
            started = [bool]$driver.Started
            status = [string]$driver.Status
            startMode = [string]$driver.StartMode
            pathSha256 = if ([string]::IsNullOrWhiteSpace($expanded)) { $null } else { Get-CRUWStringSha256 $expanded.ToLowerInvariant() }
            binaryPresent = $present
            binarySha256 = if ($present) { (Get-FileHash -LiteralPath $expanded -Algorithm SHA256).Hash } else { $null }
            binarySignatureStatus = if ($present) { [string](Get-AuthenticodeSignature -FilePath $expanded).Status } else { $null }
            pathUnderSystemDrivers = $underSystemDrivers
            pathBasenameMatchesService = $basenameMatches
            registryImagePathSha256 = if ([string]::IsNullOrWhiteSpace($registryImageExpanded)) { $null } else { Get-CRUWStringSha256 $registryImageExpanded.ToLowerInvariant() }
            registryImageMatchesCimPath = $registryImageMatches
            registry = [ordered]@{
                start = [int](Get-CRUWPropertyValue $registry 'Start' -1)
                type = [int](Get-CRUWPropertyValue $registry 'Type' -1)
                errorControl = [int](Get-CRUWPropertyValue $registry 'ErrorControl' -1)
                group = [string](Get-CRUWPropertyValue $registry 'Group' '')
                startOverride = $startOverrideEvidence
            }
        }
    }
    foreach ($required in @('partmgr','disk')) {
        if (@($result | Where-Object { [string]$_.name -ceq $required }).Count -ne 1) { throw "Required native storage service missing: $required" }
    }
    return @($result)
}

function Get-CRUWNativeStorageSnapshot {
    param([string] $PublishedName, [string] $FilterName, [string[]] $RequiredMountPoints, $ExpectedIdentity)
    $allWindowsDrivers = @(Get-WindowsDriver -Online -All -ErrorAction Stop)
    $packages = @($allWindowsDrivers | Where-Object {
        [string] $_.Driver -ieq $PublishedName -or (
            (Split-Path -Leaf ([string] $_.OriginalFileName)) -ieq [string] $ExpectedIdentity.originalInf -and
            [string] $_.ProviderName -ceq [string] $ExpectedIdentity.provider -and
            [string] $_.ClassName -ceq [string] $ExpectedIdentity.className -and
            [string] $_.Version -ceq [string] $ExpectedIdentity.version
        )
    } | ForEach-Object {
        [ordered]@{ publishedName = [string] $_.Driver; originalInf = Split-Path -Leaf ([string] $_.OriginalFileName); provider = [string] $_.ProviderName; className = [string] $_.ClassName; version = [string] $_.Version }
    })
    $serviceRegistry = Get-ItemProperty -LiteralPath 'HKLM:\SYSTEM\CurrentControlSet\Services\CRUWBlocker' -ErrorAction SilentlyContinue
    $serviceStartOverrideRaw = Get-ItemProperty -LiteralPath 'HKLM:\SYSTEM\CurrentControlSet\Services\CRUWBlocker\StartOverride' -ErrorAction SilentlyContinue
    $serviceStartOverride = if ($null -eq $serviceStartOverrideRaw) { @() } else {
        @($serviceStartOverrideRaw.PSObject.Properties | Where-Object { $_.Name -notmatch '^PS' } | Sort-Object Name | ForEach-Object {
            [ordered]@{name=[string]$_.Name;value=[int]$_.Value}
        })
    }
    $systemDrivers = @(Get-CimInstance -ClassName Win32_SystemDriver -Filter "Name='CRUWBlocker'" -ErrorAction SilentlyContinue)
    $binaryPath = Join-Path $env:windir 'System32\drivers\CRUWBlocker.sys'
    $binaryPresent = Test-Path -LiteralPath $binaryPath -PathType Leaf
    $classRegistry = Get-ItemProperty -LiteralPath 'HKLM:\SYSTEM\CurrentControlSet\Control\Class\{4D36E967-E325-11CE-BFC1-08002BE10318}' -ErrorAction Stop
    $devices = @(Get-PnpDevice -Class DiskDrive -PresentOnly -ErrorAction Stop | ForEach-Object {
        $rawId = [string] $_.InstanceId
        [ordered]@{
            instanceIdSha256 = Get-CRUWStringSha256 -Text $rawId
            status = [string] $_.Status
            inf = [string] (Get-CRUWPnpPropertyData $rawId 'DEVPKEY_Device_DriverInfPath')
            provider = [string] (Get-CRUWPnpPropertyData $rawId 'DEVPKEY_Device_DriverProvider')
            version = [string] (Get-CRUWPnpPropertyData $rawId 'DEVPKEY_Device_DriverVersion')
            lowerFilters = @(ConvertTo-CRUWStringArray (Get-CRUWPnpPropertyData $rawId 'DEVPKEY_Device_LowerFilters' -Optional))
            upperFilters = @(ConvertTo-CRUWStringArray (Get-CRUWPnpPropertyData $rawId 'DEVPKEY_Device_UpperFilters' -Optional))
        }
    })
    $physicalDisks = @(Get-PhysicalDisk -ErrorAction Stop | ForEach-Object { [ordered]@{ healthStatus = [string] $_.HealthStatus; operationalStatus = @(ConvertTo-CRUWStringArray $_.OperationalStatus) } })
    $volumes = foreach ($mount in $RequiredMountPoints) {
        $letter = $mount.TrimEnd(':')
        $volume = Get-Volume -DriveLetter $letter -ErrorAction SilentlyContinue
        $partitions = @(Get-Partition -DriveLetter $letter -ErrorAction SilentlyContinue)
        if ($null -ne $volume -and $partitions.Count -eq 1) {
            $partition = $partitions[0]
            $disks = @(Get-Disk -Number $partition.DiskNumber -ErrorAction Stop)
            if ($disks.Count -ne 1) { throw "Drive $letter did not map to exactly one Get-Disk result" }
            $disk = $disks[0]
            $cimDisk = @(Get-CimInstance -ClassName Win32_DiskDrive -Filter "Index=$($partition.DiskNumber)" -ErrorAction Stop)
            if ($cimDisk.Count -ne 1) { throw "Drive $letter did not map to exactly one Win32_DiskDrive" }
            $associatedPnp = @(Get-CimAssociatedInstance -InputObject $cimDisk[0] -ResultClassName Win32_PnPEntity -ErrorAction Stop | Where-Object { [string]$_.DeviceID -ceq [string]$cimDisk[0].PNPDeviceID })
            if ($associatedPnp.Count -ne 1) { throw "Drive $letter PnP association is ambiguous" }
            $presentPnp = @(Get-PnpDevice -InstanceId ([string]$associatedPnp[0].DeviceID) -PresentOnly -ErrorAction Stop)
            if ($presentPnp.Count -ne 1) { throw "Drive $letter present PnP identity is ambiguous" }
            $problemCode = Get-CRUWPnpPropertyData ([string]$associatedPnp[0].DeviceID) 'DEVPKEY_Device_ProblemCode' -Optional
            $parentChain = Get-CRUWNativePnpParentServiceChain ([string]$associatedPnp[0].DeviceID)
            [ordered]@{
                mountPoint = $letter.ToUpperInvariant() + ':'
                diskNumber = [int] $partition.DiskNumber
                deviceInstanceIdSha256 = Get-CRUWStringSha256 ([string]$associatedPnp[0].DeviceID)
                healthStatus = [string] $volume.HealthStatus
                operationalStatus = @(ConvertTo-CRUWStringArray $volume.OperationalStatus)
                fileSystem = [string] $volume.FileSystem
                readOnly = [bool] $disk.IsReadOnly
                offline = [bool] $disk.IsOffline
                diskHealthStatus = [string] $disk.HealthStatus
                diskOperationalStatus = @(ConvertTo-CRUWStringArray $disk.OperationalStatus)
                pnpStatus = [string]$presentPnp[0].Status
                pnpProblemCode = if ($null -eq $problemCode) { 0 } else { [int]$problemCode }
                parentServiceChain = @($parentChain.items)
                parentChainTerminated = [bool]$parentChain.terminated
                parentChainNoCycle = [bool]$parentChain.noCycle
                parentChainTruncated = [bool]$parentChain.truncated
            }
        }
    }
    $fallback = @($allWindowsDrivers | Where-Object { [string] $_.OriginalFileName -match '(?i)(^|\\)disk\.inf$' -and [string] $_.ProviderName -ceq 'Microsoft' }).Count -gt 0
    return [ordered]@{
        publishedName = $PublishedName
        filterName = $FilterName
        packages = $packages
        service = [ordered]@{
            exists = $null -ne $serviceRegistry -or $systemDrivers.Count -gt 0
            state = if ($systemDrivers.Count -eq 1) { [string] $systemDrivers[0].State } else { $null }
            start = if ($null -ne $serviceRegistry) { [int] $serviceRegistry.Start } else { $null }
            type = if ($null -ne $serviceRegistry) { [int] $serviceRegistry.Type } else { $null }
            errorControl = if ($null -ne $serviceRegistry) { [int] $serviceRegistry.ErrorControl } else { $null }
            group = if ($null -ne $serviceRegistry) { [string] $serviceRegistry.Group } else { $null }
            imagePath = if ($null -ne $serviceRegistry) { [string] $serviceRegistry.ImagePath } else { $null }
            startOverride = $serviceStartOverride
            binaryPresent = $binaryPresent
            binarySha256 = if ($binaryPresent) { (Get-FileHash -LiteralPath $binaryPath -Algorithm SHA256).Hash } else { $null }
            binarySignatureStatus = if ($binaryPresent) { [string](Get-AuthenticodeSignature -FilePath $binaryPath).Status } else { $null }
        }
        classFilters = [ordered]@{
            lowerFilters = @(ConvertTo-CRUWStringArray (Get-CRUWPropertyValue $classRegistry 'LowerFilters'))
            upperFilters = @(ConvertTo-CRUWStringArray (Get-CRUWPropertyValue $classRegistry 'UpperFilters'))
        }
        devices = $devices
        physicalDisks = $physicalDisks
        volumes = @($volumes)
        nativeFallbackPackagePresent = $fallback
        nativeStorageServices = @(Get-CRUWNativeStorageServiceSnapshot)
    }
}

function Invoke-CRUWNativeVolumeProbe {
    param([Parameter(Mandatory)] [string] $MountPoint)
    $token = [guid]::NewGuid().ToString('N')
    $path = Join-Path ($MountPoint + '\') ('.cruw-postboot-probe-' + $token + '.tmp')
    $payload = 'CRUW-PROBE|' + $token
    $written = $false; $read = $false; $hashMatches = $false; $deleted = $false; $writeHash = $null; $readHash = $null
    try {
        $bytes = [Text.UTF8Encoding]::new($false).GetBytes($payload)
        $stream = [IO.File]::Open($path, [IO.FileMode]::CreateNew, [IO.FileAccess]::Write, [IO.FileShare]::None)
        try { $stream.Write($bytes, 0, $bytes.Length); $stream.Flush($true); $written = $true } finally { $stream.Dispose() }
        $writeHash = Get-CRUWStringSha256 -Text $payload
        $readText = [IO.File]::ReadAllText($path, [Text.Encoding]::UTF8); $read = $true
        $readHash = Get-CRUWStringSha256 -Text $readText; $hashMatches = $writeHash -eq $readHash
    }
    finally {
        if (Test-Path -LiteralPath $path) { Remove-Item -LiteralPath $path -Force -ErrorAction SilentlyContinue }
        $deleted = -not (Test-Path -LiteralPath $path)
    }
    return [ordered]@{ mountPoint = $MountPoint; writeSucceeded = $written; readSucceeded = $read; writeSha256 = $writeHash; readSha256 = $readHash; hashMatches = $hashMatches; deleteSucceeded = $deleted; probePathSha256 = Get-CRUWStringSha256 -Text $path }
}

function Get-CRUWNativeEventsSince {
    param([DateTimeOffset] $Since)
    try {
        return @(Get-WinEvent -FilterHashtable @{ LogName = 'System'; ProviderName = @('disk','storahci','stornvme','iaStorA','iaStorAC','iaStorVD','volmgr','volsnap','Ntfs','Microsoft-Windows-WHEA-Logger'); Level = @(1,2,3); StartTime = $Since.LocalDateTime } -ErrorAction Stop | ForEach-Object {
            [ordered]@{ timeCreated = ([DateTimeOffset] $_.TimeCreated).ToString('o'); providerName = [string] $_.ProviderName; id = [int] $_.Id; level = [int] $_.Level; recordId = [long] $_.RecordId }
        })
    }
    catch {
        if ($_.FullyQualifiedErrorId -like 'NoMatchingEventsFound*' -or $_.Exception.Message -match '(?i)no events were found|no se encontraron eventos') { return @() }
        throw
    }
}

function Get-CRUWNativeSetupApiEvidence {
    $path = Join-Path $env:windir 'inf\setupapi.dev.log'
    if (-not (Test-Path -LiteralPath $path -PathType Leaf)) {
        return [ordered]@{ present=$false;pathSha256=Get-CRUWStringSha256 $path;length=0;tailOffset=0;tailLength=0;tailSha256=$null;lastWriteTimeUtc=$null }
    }
    $stream = [IO.File]::Open($path,[IO.FileMode]::Open,[IO.FileAccess]::Read,[IO.FileShare]::ReadWrite -bor [IO.FileShare]::Delete)
    try {
        $hasher = [Security.Cryptography.SHA256]::Create()
        try { $fullSha256 = ([BitConverter]::ToString($hasher.ComputeHash($stream))).Replace('-','') }
        finally { $hasher.Dispose() }
        $length = [long]$stream.Length
        $tailLength = [int][Math]::Min(65536,$length)
        $tailOffset = $length - $tailLength
        [void]$stream.Seek($tailOffset,[IO.SeekOrigin]::Begin)
        $bytes = New-Object byte[] $tailLength
        $read = 0
        while ($read -lt $tailLength) {
            $count = $stream.Read($bytes,$read,$tailLength-$read)
            if ($count -eq 0) { break }
            $read += $count
        }
        if ($read -ne $tailLength) { throw 'Short read while capturing bounded SetupAPI evidence' }
        return [ordered]@{
            present=$true;pathSha256=Get-CRUWStringSha256 $path;length=$length;fullSha256=$fullSha256;
            tailOffset=$tailOffset;tailLength=$tailLength;tailSha256=Get-CRUWBytesSha256 $bytes;
            lastWriteTimeUtc=([DateTimeOffset](Get-Item -LiteralPath $path -Force).LastWriteTimeUtc).ToString('o')
        }
    }
    finally { $stream.Dispose() }
}

function New-CRUWNativeAdapter {
    return @{
        IsAdministrator = { ([Security.Principal.WindowsPrincipal] [Security.Principal.WindowsIdentity]::GetCurrent()).IsInRole([Security.Principal.WindowsBuiltInRole]::Administrator) }
        EnterOperationMutex = { Enter-CRUWOperationMutex }
        ExitOperationMutex = { param($handle) Exit-CRUWOperationMutex $handle }
        GetNow = { [DateTimeOffset]::Now }
        GetBootIdentity = { Get-CRUWNativeBootIdentity }
        TestProtectedAcl = { param($path) Test-CRUWNativeProtectedAcl $path }
        ProtectFileAcl = { param($path) Set-CRUWNativeProtectedFileAcl $path }
        GetPendingRebootState = { Get-CRUWNativePendingRebootState }
        GetRecoveryRootEvidence = { param($root) Get-CRUWNativeRecoveryRootEvidence $root }
        GetRecoveryReadiness = { Get-CRUWNativeRecoveryReadiness }
        GetAcPowerState = { Get-CRUWNativeAcPowerState }
        GetBitLockerState = { param($mount) Get-CRUWNativeBitLockerState $mount }
        SuspendBitLocker = { param($mount,$count) Suspend-BitLocker -MountPoint $mount -RebootCount $count -ErrorAction Stop | Out-Null }
        ResumeBitLocker = { param($mount) Resume-BitLocker -MountPoint $mount -ErrorAction Stop | Out-Null }
        GetStorageSnapshot = { param($published,$filter,$mounts,$identity) Get-CRUWNativeStorageSnapshot $published $filter $mounts $identity }
        GetFileSignatureStatus = { param($path) [ordered]@{status=[string](Get-AuthenticodeSignature -FilePath $path -ErrorAction Stop).Status} }
        DeleteDriver = { param($published) $argsExact=@('/delete-driver',$published,'/uninstall'); $out=(& pnputil.exe @argsExact 2>&1|Out-String).Trim(); [ordered]@{executable='pnputil.exe';arguments=$argsExact;exitCode=[int]$LASTEXITCODE;output=$out} }
        ReinstallBackupDriver = { param($inf) $argsExact=@('/add-driver',$inf,'/install'); $out=(& pnputil.exe @argsExact 2>&1|Out-String).Trim(); [ordered]@{executable='pnputil.exe';arguments=$argsExact;exitCode=[int]$LASTEXITCODE;output=$out} }
        GetSetupApiEvidence = { Get-CRUWNativeSetupApiEvidence }
        GetCriticalEventsSince = { param($since) Get-CRUWNativeEventsSince ([DateTimeOffset]$since) }
        ProbeVolume = { param($mount) Invoke-CRUWNativeVolumeProbe $mount }
    }
}

function Test-CRUWBitLockerState {
    param($State, [ValidateSet('On','Off')] [string] $Protection)
    return [string]$State.volumeStatus -ieq 'FullyEncrypted' -and [string]$State.protectionStatus -ieq $Protection -and [string]$State.lockStatus -ieq 'Unlocked' -and [int]$State.encryptionPercentage -eq 100 -and [int]$State.recoveryPasswordProtectorCount -ge 1 -and -not [bool]$State.secretRecorded
}

function Get-CRUWEncryptedMountPoints {
    param($Preflight)
    $mounts = @($Preflight.bitLocker.mountedEncryptedVolumes | ForEach-Object {
        $candidate = if ($_ -is [string]) { [string]$_ } else { [string](Get-CRUWPropertyValue $_ 'mountPoint' (Get-CRUWPropertyValue $_ 'MountPoint')) }
        if (-not [string]::IsNullOrWhiteSpace($candidate)) { $candidate.TrimEnd(':').ToUpperInvariant() + ':' }
    } | Sort-Object -Unique)
    if ($mounts.Count -eq 0 -or $mounts -notcontains 'C:') { throw 'Sealed encrypted-volume inventory must include C:' }
    return $mounts
}

function Get-CRUWBitLockerInventoryEvidence {
    param([hashtable]$Adapter,[string[]]$MountPoints,[ValidateSet('AllOn','COffOthersOn')]$Expected)
    $states = @($MountPoints | ForEach-Object { Invoke-CRUWAdapter $Adapter 'GetBitLockerState' @($_) })
    return Test-CRUWBitLockerInventoryStates $states $MountPoints $Expected
}

function Test-CRUWBitLockerInventoryStates {
    param($States,[string[]]$MountPoints,[ValidateSet('AllOn','COffOthersOn')]$Expected)
    $states = @($States)
    $normalizedMounts = @($MountPoints | ForEach-Object { $_.TrimEnd(':').ToUpperInvariant() + ':' } | Sort-Object -Unique)
    $observedMounts = @($states | ForEach-Object {
        ([string]$_.mountPoint).TrimEnd(':').ToUpperInvariant() + ':'
    })
    $uniqueObservedMounts = @($observedMounts | Sort-Object -Unique)
    $verified =
        $states.Count -eq $MountPoints.Count -and
        $normalizedMounts.Count -eq $MountPoints.Count -and
        $normalizedMounts.Count -gt 0 -and
        $normalizedMounts -contains 'C:' -and
        $uniqueObservedMounts.Count -eq $observedMounts.Count -and
        (Test-CRUWEqualSet $uniqueObservedMounts $normalizedMounts)
    foreach ($state in $states) {
        $mount = ([string]$state.mountPoint).TrimEnd(':').ToUpperInvariant() + ':'
        $protection = if ($Expected -ceq 'COffOthersOn' -and $mount -ceq 'C:') { 'Off' } else { 'On' }
        if (-not (Test-CRUWBitLockerState $state $protection)) { $verified = $false }
    }
    return [ordered]@{ verified=$verified;expected=$Expected;mountPoints=$MountPoints;states=$states }
}

function Test-CRUWRecoveryReadiness {
    param($Evidence,$Preflight)
    $sequenceExpected = Get-CRUWPropertyValue $Preflight.restorePoint 'usablePointSequenceNumber'
    $sequenceObserved = Get-CRUWPropertyValue $Evidence 'latestRestorePointSequenceNumber'
    $sequenceMatches =
        $null -ne $sequenceExpected -and
        $null -ne $sequenceObserved -and
        [long]$sequenceExpected -gt 0 -and
        [long]$sequenceObserved -eq [long]$sequenceExpected
    $sealedWinReLocation = [string](Get-CRUWPropertyValue $Preflight.initialState.winRe 'recoveryLocation')
    $sealedWinReLocationSha256 = [string](Get-CRUWPropertyValue $Preflight.initialState.winRe 'recoveryLocationSha256')
    $recomputedWinReLocationSha256 = if ([string]::IsNullOrWhiteSpace($sealedWinReLocation)) {
        $null
    }
    else {
        Get-CRUWCanonicalWinReLocationSha256 $sealedWinReLocation
    }
    $winReLocationMatches =
        $sealedWinReLocationSha256 -match '^[A-F0-9]{64}$' -and
        [string]$recomputedWinReLocationSha256 -ceq $sealedWinReLocationSha256 -and
        [string]$Evidence.winReLocationSha256 -ceq $sealedWinReLocationSha256

    $sealedSystemRestore = Get-CRUWPropertyValue $Preflight.initialState 'systemRestore'
    $sealedSystemRestorePropertyNames = @(Get-CRUWPropertyNameArray $sealedSystemRestore)
    $sealedSystemRestoreHasRequiredFields = @(@(
            'readyForTransaction',
            'operationalAtStart',
            'restorePointQuerySucceeded',
            'policyDisableSR',
            'policyDisableConfig',
            'disableConfigRecordedButNotUsedAsDisableSignal',
            'runtimeDisableSR'
        ) | Where-Object { $sealedSystemRestorePropertyNames -cnotcontains $_ })
    $sealedSystemRestoreReady =
        $sealedSystemRestoreHasRequiredFields.Count -eq 0 -and
        [bool](Get-CRUWPropertyValue $sealedSystemRestore 'readyForTransaction') -and
        [bool](Get-CRUWPropertyValue $sealedSystemRestore 'operationalAtStart') -and
        [bool](Get-CRUWPropertyValue $sealedSystemRestore 'restorePointQuerySucceeded') -and
        (Get-CRUWPropertyValue $sealedSystemRestore 'policyDisableSR') -ne 1 -and
        [bool](Get-CRUWPropertyValue $sealedSystemRestore 'disableConfigRecordedButNotUsedAsDisableSignal') -and
        (Get-CRUWPropertyValue $sealedSystemRestore 'runtimeDisableSR') -ne 1
    $liveSystemRestoreReady =
        [bool](Get-CRUWPropertyValue $Evidence 'restorePointQuerySucceeded') -and
        [bool](Get-CRUWPropertyValue $Evidence 'systemRestoreRegistryQuerySucceeded') -and
        [bool](Get-CRUWPropertyValue $Evidence 'systemRestoreReadyForTransaction') -and
        (Get-CRUWPropertyValue $Evidence 'policyDisableSR') -ne 1 -and
        [bool](Get-CRUWPropertyValue $Evidence 'disableConfigRecordedButNotUsedAsDisableSignal') -and
        (Get-CRUWPropertyValue $Evidence 'runtimeDisableSR') -ne 1

    return ([bool]$Preflight.technicalPreflightPass -and
        [bool]$Preflight.winReEnabled -and
        [bool]$Preflight.restorePoint.usableRecentPoint -and
        $sealedSystemRestoreReady -and
        [bool]$Evidence.winReEnabled -and
        [bool]$Evidence.winReLocationPresent -and
        [string]$Evidence.winReLocationSha256 -match '^[A-F0-9]{64}$' -and
        $winReLocationMatches -and
        $liveSystemRestoreReady -and
        [bool]$Evidence.recentRestorePointPresent -and
        $sequenceMatches)
}

function Test-CRUWImplementationSeal {
    param($Integrity,$Preflight,[string]$PrimaryRoot,[string]$ScriptPath)
    $contract = @(
        [ordered]@{name='Prepare-CRUWBlockerRemoval.ps1';role='preflight-producer';capable=$false},
        [ordered]@{name='CRUWBlockerPreflight.Core.ps1';role='preflight-core';capable=$false},
        [ordered]@{name='CRUWStateMachine.Common.ps1';role='state-machine-common';capable=$true},
        [ordered]@{name='Invoke-CRUWBlockerRemoval.ps1';role='removal-executor';capable=$true},
        [ordered]@{name='Repair-CRUWInterruptedRemoval.ps1';role='interruption-repair';capable=$true},
        [ordered]@{name='Test-CRUWBlockerPostboot.ps1';role='postboot-validator';capable=$true}
    )
    $liveNames = @('CRUWStateMachine.Common.ps1','Invoke-CRUWBlockerRemoval.ps1','Test-CRUWBlockerPostboot.ps1','Repair-CRUWInterruptedRemoval.ps1')
    $scriptRoot = Split-Path -Parent ([IO.Path]::GetFullPath($ScriptPath))
    $failures = [Collections.Generic.List[string]]::new()
    $artifacts = @($Preflight.implementation.artifacts)
    $implementationProperties = @(Get-CRUWPropertyNameArray $Preflight.implementation)
    if (
        ($implementationProperties -join '|') -cne 'producerPerformsDriverMutation|sealedBundleContainsBootCriticalMutation|artifacts' -or
        $artifacts.Count -ne $contract.Count -or
        -not [bool]$Preflight.implementation.sealedBundleContainsBootCriticalMutation -or
        [bool]$Preflight.implementation.producerPerformsDriverMutation
    ) {
        $failures.Add('implementation v3 bundle header/cardinality invalid')
    }
    for ($index=0; $index -lt $contract.Count; $index++) {
        $item = $contract[$index]
        $name = [string]$item.name
        $relative = 'implementation/' + $name
        $sealed = Resolve-CRUWSafeRelativeFilePath $PrimaryRoot $relative
        if (-not (Test-Path -LiteralPath $sealed -PathType Leaf)) {
            $failures.Add("implementation seal file missing: $name")
            continue
        }
        if (Test-CRUWPathHasReparseAncestor $sealed) { $failures.Add("implementation seal reparse rejected: $name"); continue }
        $artifact = if ($index -lt $artifacts.Count) { $artifacts[$index] } else { $null }
        if (
            $null -eq $artifact -or
            (@(Get-CRUWPropertyNameArray $artifact) -join '|') -cne 'role|relativePath|sha256|driverMutationCapable' -or
            [string]$artifact.role -cne [string]$item.role -or
            [string]$artifact.relativePath -cne $relative -or
            [bool]$artifact.driverMutationCapable -ne [bool]$item.capable -or
            [string]$artifact.sha256 -notmatch '^[A-F0-9]{64}$' -or
            [string]$artifact.sha256 -ine (Get-FileHash -LiteralPath $sealed -Algorithm SHA256).Hash
        ) {
            $failures.Add("preflight implementation artifact identity invalid: $name")
        }
        if ($liveNames -contains $name) {
            $live = Join-Path $scriptRoot $name
            if (-not (Test-Path -LiteralPath $live -PathType Leaf) -or (Get-FileHash -LiteralPath $live -Algorithm SHA256).Hash -ne (Get-FileHash -LiteralPath $sealed -Algorithm SHA256).Hash) {
                $failures.Add("running implementation differs from sealed copy: $name")
            }
        }
    }
    $manifestArtifactsJson = @($Integrity.manifest.implementation.artifacts) | ConvertTo-Json -Depth 6 -Compress
    $preflightArtifactsJson = $artifacts | ConvertTo-Json -Depth 6 -Compress
    if ($manifestArtifactsJson -cne $preflightArtifactsJson) { $failures.Add('manifest/preflight implementation artifact arrays differ') }
    return [ordered]@{ verified=$failures.Count -eq 0;failures=@($failures);fileCount=$contract.Count }
}

function Test-CRUWBackupIntegrity {
    param($Preflight, [string] $PreflightPath, [hashtable] $Adapter)
    $failures = [Collections.Generic.List[string]]::new()
    if ([int]$Preflight.schemaVersion -ne 3) { $failures.Add('preflight schemaVersion is not 3') }
    $primary = [IO.Path]::GetFullPath([string]$Preflight.recoveryPath).TrimEnd('\')
    $secondary = [IO.Path]::GetFullPath([string]$Preflight.secondaryRecoveryPath).TrimEnd('\')
    if ($primary -ceq $secondary) { $failures.Add('primary and secondary recovery roots are not distinct') }
    foreach ($root in @($primary,$secondary)) {
        if (-not (Test-Path -LiteralPath $root -PathType Container)) { $failures.Add("recovery root missing: $root"); continue }
        if (Test-CRUWPathHasReparseAncestor $root) { $failures.Add("reparse-point recovery root/ancestor rejected: $root") }
    }
    $primaryRootEvidence = Invoke-CRUWAdapter $Adapter 'GetRecoveryRootEvidence' @($primary)
    $secondaryRootEvidence = Invoke-CRUWAdapter $Adapter 'GetRecoveryRootEvidence' @($secondary)
    $rootTopologyValid = Test-CRUWRecoveryRootTopology $primaryRootEvidence $secondaryRootEvidence $null
    $sealedCVolume = @($Preflight.storageLayout.volumes | Where-Object { ([string]$_.driveLetter).TrimEnd(':') -ieq 'C' })
    $sealedDVolume = @($Preflight.storageLayout.volumes | Where-Object { ([string]$_.driveLetter).TrimEnd(':') -ieq 'D' })
    $rootTopologyValid = $rootTopologyValid -and
        $sealedCVolume.Count -eq 1 -and $sealedDVolume.Count -eq 1 -and
        [int]$primaryRootEvidence.diskNumber -eq [int]$sealedCVolume[0].diskNumber -and
        [int]$secondaryRootEvidence.diskNumber -eq [int]$sealedDVolume[0].diskNumber -and
        [string]$primaryRootEvidence.deviceInstanceIdSha256 -ieq [string]$sealedCVolume[0].deviceInstanceIdSha256 -and
        [string]$secondaryRootEvidence.deviceInstanceIdSha256 -ieq [string]$sealedDVolume[0].deviceInstanceIdSha256
    if (-not $rootTopologyValid) { $failures.Add('recovery roots are not C:/D: on distinct healthy physical disks') }
    $expectedPreflight = Join-Path $primary 'preflight.json'
    if ([IO.Path]::GetFullPath($PreflightPath) -cne $expectedPreflight) { $failures.Add('preflight is not the authoritative primary copy') }
    $primaryManifestPath = Join-Path $primary 'backup-integrity-final.json'
    $secondaryManifestPath = Join-Path $secondary 'backup-integrity-final.json'
    if (-not (Test-Path -LiteralPath $primaryManifestPath -PathType Leaf) -or -not (Test-Path -LiteralPath $secondaryManifestPath -PathType Leaf)) { throw 'Both backup-integrity-final.json copies are required' }
    if (((Get-Item -LiteralPath $primaryManifestPath -Force).Attributes -band [IO.FileAttributes]::ReparsePoint) -or
        ((Get-Item -LiteralPath $secondaryManifestPath -Force).Attributes -band [IO.FileAttributes]::ReparsePoint)) { $failures.Add('reparse-point integrity manifest rejected') }
    $primaryManifestHash = (Get-FileHash -LiteralPath $primaryManifestPath -Algorithm SHA256).Hash
    $secondaryManifestHash = (Get-FileHash -LiteralPath $secondaryManifestPath -Algorithm SHA256).Hash
    if ($primaryManifestHash -ne $secondaryManifestHash) { $failures.Add('manifest byte hashes differ') }
    $manifest = Get-Content -LiteralPath $primaryManifestPath -Raw -Encoding UTF8 | ConvertFrom-Json
    if ([int]$manifest.schemaVersion -ne 1 -or [string]$manifest.role -cne 'authoritative-removal-preflight-manifest') { $failures.Add('manifest identity invalid') }
    if (-not [bool]$manifest.finalizedBeforeCopy -or -not [bool]$manifest.allHashesMatch -or -not [bool]$manifest.technicalPreflightPass) { $failures.Add('manifest finalization gates invalid') }
    if ([IO.Path]::GetFullPath([string]$manifest.recoveryPath).TrimEnd('\') -cne $primary -or [IO.Path]::GetFullPath([string]$manifest.secondaryRecoveryPath).TrimEnd('\') -cne $secondary) { $failures.Add('manifest roots drifted') }
    if ([string]$manifest.bootIdentity.markerSha256 -cne [string]$Preflight.bootIdentity.markerSha256 -or (ConvertTo-CRUWUtcRoundtripString $manifest.bootIdentity.lastBootUpTimeUtc) -cne (ConvertTo-CRUWUtcRoundtripString $Preflight.bootIdentity.lastBootUpTimeUtc)) { $failures.Add('manifest boot identity drifted') }
    $manifestImplementationProperties = @(Get-CRUWPropertyNameArray $manifest.implementation)
    if (
        ($manifestImplementationProperties -join '|') -cne 'producerPerformsDriverMutation|sealedBundleContainsBootCriticalMutation|artifacts' -or
        [bool]$manifest.implementation.producerPerformsDriverMutation -ne [bool]$Preflight.implementation.producerPerformsDriverMutation -or
        [bool]$manifest.implementation.sealedBundleContainsBootCriticalMutation -ne [bool]$Preflight.implementation.sealedBundleContainsBootCriticalMutation -or
        (@($manifest.implementation.artifacts) | ConvertTo-Json -Depth 6 -Compress) -cne (@($Preflight.implementation.artifacts) | ConvertTo-Json -Depth 6 -Compress)
    ) { $failures.Add('manifest implementation v3 identity drifted') }
    $manifestDriverIdentity = Test-CRUWManifestDriverIdentityContract `
        $manifest.driverIdentity $Preflight `
        -SimulationOnly:([bool](Get-CRUWPropertyValue $Adapter 'SimulationOnly' $false))
    if (-not [bool]$manifestDriverIdentity.verified) {
        $failures.Add('manifest driver identity drifted or is incomplete: ' + ($manifestDriverIdentity.failures -join '; '))
    }
    if (-not [bool]$Preflight.secondaryBackupVerified -or -not [bool]$Preflight.secondaryBackup.verified) { $failures.Add('preflight secondary backup gate is false') }
    foreach($flag in @('recomputeEveryListedHash','requirePrimarySecondaryManifestByteEquality','requireSameBootMarker','requireProtectedAcl')) { if(-not [bool](Get-CRUWPropertyValue $manifest.removalValidationContract $flag)){ $failures.Add("manifest contract $flag is false") } }
    if ([bool](Get-CRUWPropertyValue $manifest.removalValidationContract 'trustPreflightJsonWithoutThisManifest' $true)) { $failures.Add('manifest incorrectly permits trusting preflight without the manifest') }
    $required = @($manifest.requiredRelativePaths | ForEach-Object {[string]$_})
    $mandatory = @(
        'driver\cruwblocker.inf','driver\CRUWBlocker.sys','driver\CRUWBlocker.cat',
        'SYSTEM.before.hiv','disk-drivers-before.txt','winre-before.txt','filter-snapshot-before.json',
        'implementation/Prepare-CRUWBlockerRemoval.ps1','implementation/CRUWBlockerPreflight.Core.ps1',
        'implementation/CRUWStateMachine.Common.ps1','implementation/Invoke-CRUWBlockerRemoval.ps1',
        'implementation/Test-CRUWBlockerPostboot.ps1','implementation/Repair-CRUWInterruptedRemoval.ps1',
        'preflight.json'
    )
    if (
        $required.Count -ne $mandatory.Count -or
        @($mandatory | Where-Object { $required -cnotcontains $_ }).Count -gt 0 -or
        @($required | Where-Object { $mandatory -cnotcontains $_ }).Count -gt 0
    ) { $failures.Add('manifest requiredRelativePaths is not the exact mandatory v3 recovery set') }
    $records = @($manifest.files)
    if ([int]$manifest.requiredFileCount -ne $required.Count -or $records.Count -ne $required.Count -or @($required|Sort-Object -Unique).Count -ne $required.Count) { $failures.Add('manifest file cardinality invalid') }
    foreach($relative in $required){
        if([IO.Path]::IsPathRooted($relative) -or $relative -match '(^|[\\/])\.\.([\\/]|$)'){ $failures.Add("unsafe relative path: $relative"); continue }
        $record=@($records|Where-Object{[string]$_.relativePath -ceq $relative})
        if($record.Count -ne 1){$failures.Add("missing/duplicate manifest record: $relative");continue}
        try {
            $p=Resolve-CRUWSafeRelativeFilePath $primary $relative
            $s=Resolve-CRUWSafeRelativeFilePath $secondary $relative
        }
        catch { $failures.Add($_.Exception.Message); continue }
        try {
            if ((Test-CRUWPathHasReparseAncestor $p) -or (Test-CRUWPathHasReparseAncestor $s)) { $failures.Add("reparse-point backup file/ancestor rejected: $relative"); continue }
        }
        catch { $failures.Add("missing/inaccessible backup file or ancestor: $relative"); continue }
        if(-not(Test-Path -LiteralPath $p -PathType Leaf) -or -not(Test-Path -LiteralPath $s -PathType Leaf)){ $failures.Add("missing backup file: $relative");continue }
        $ph=(Get-FileHash -LiteralPath $p -Algorithm SHA256).Hash; $sh=(Get-FileHash -LiteralPath $s -Algorithm SHA256).Hash
        if(-not [bool]$record[0].primaryExists -or -not [bool]$record[0].secondaryExists -or -not [bool]$record[0].hashesMatch -or $ph -ne $sh -or $ph -ine [string]$record[0].primarySha256 -or $sh -ine [string]$record[0].secondarySha256){$failures.Add("hash mismatch: $relative")}
    }
    if(@($records|Where-Object{$required -cnotcontains [string]$_.relativePath}).Count){$failures.Add('unlisted manifest record present')}
    $expectedDriverNames = @('cruwblocker.inf','CRUWBlocker.sys','CRUWBlocker.cat')
    $expectedImplementationNames = @(
        'Prepare-CRUWBlockerRemoval.ps1','CRUWBlockerPreflight.Core.ps1','CRUWStateMachine.Common.ps1',
        'Invoke-CRUWBlockerRemoval.ps1','Test-CRUWBlockerPostboot.ps1','Repair-CRUWInterruptedRemoval.ps1'
    )
    foreach ($sealedRoot in @($primary,$secondary)) {
        foreach ($payloadContract in @(
            [ordered]@{directory='driver';expected=$expectedDriverNames},
            [ordered]@{directory='implementation';expected=$expectedImplementationNames}
        )) {
            $payloadDirectory = Join-Path $sealedRoot $payloadContract.directory
            try {
                if (Test-CRUWPathHasReparseAncestor $payloadDirectory) { throw 'payload directory/reparse ancestor rejected' }
                $payloadItems = @(Get-ChildItem -LiteralPath $payloadDirectory -Force -ErrorAction Stop)
                $payloadFiles = @($payloadItems | Where-Object { -not $_.PSIsContainer } | ForEach-Object { [string]$_.Name })
                $payloadContainers = @($payloadItems | Where-Object { $_.PSIsContainer })
                if (
                    $payloadContainers.Count -ne 0 -or
                    $payloadFiles.Count -ne $payloadContract.expected.Count -or
                    @($payloadContract.expected | Where-Object { $payloadFiles -cnotcontains $_ }).Count -gt 0 -or
                    @($payloadFiles | Where-Object { $payloadContract.expected -cnotcontains $_ }).Count -gt 0
                ) { $failures.Add("sealed $($payloadContract.directory) payload is not the exact physical allowlist") }
            }
            catch { $failures.Add("sealed $($payloadContract.directory) payload inventory failed: $($_.Exception.Message)") }
        }
        try {
            if (Test-CRUWPathHasReparseAncestor $sealedRoot) { throw 'reparse recovery root rejected' }
            $rootItems = @(Get-ChildItem -LiteralPath $sealedRoot -Force -ErrorAction Stop)
            $allowedRootFiles = @(
                'SYSTEM.before.hiv','disk-drivers-before.txt','winre-before.txt','filter-snapshot-before.json',
                'preflight.json','backup-integrity-final.json'
            )
            $unexpectedRootItems = @($rootItems | Where-Object {
                if ($_.PSIsContainer) { return [string]$_.Name -cnotin @('driver','implementation') }
                return [string]$_.Name -cnotin $allowedRootFiles -and [string]$_.Name -notlike 'removal-journal-*'
            })
            if ($unexpectedRootItems.Count -gt 0) { $failures.Add('sealed recovery root contains unlisted physical payload') }
        }
        catch { $failures.Add("sealed recovery root inventory failed: $($_.Exception.Message)") }
        if (
            -not [bool](Get-CRUWPropertyValue $Adapter 'SimulationOnly' $false) -and
            $Adapter.ContainsKey('GetFileSignatureStatus')
        ) {
            foreach ($driverName in @('cruwblocker.inf','CRUWBlocker.sys','CRUWBlocker.cat')) {
                $driverPath = Resolve-CRUWSafeRelativeFilePath $sealedRoot ('driver\' + $driverName)
                $signatureStatus = Invoke-CRUWAdapter $Adapter 'GetFileSignatureStatus' @($driverPath)
                if ([string]$signatureStatus.status -cne 'Valid') {
                    $failures.Add("physical driver payload signature is not Valid: $driverName")
                }
            }
        }
    }
    $driverHashRecords=@($Preflight.driverExport.hashes)
    $exportedSys=@($driverHashRecords|Where-Object{[string]$_.file-ieq'CRUWBlocker.sys'});$exportedCat=@($driverHashRecords|Where-Object{[string]$_.file-ieq'CRUWBlocker.cat'})
    if($exportedSys.Count-ne1-or$exportedCat.Count-ne1-or[string]$exportedSys[0].Hash-ine[string]$manifest.driverIdentity.exportedDriverSha256-or[string]$exportedCat[0].Hash-ine[string]$manifest.driverIdentity.exportedCatalogSha256){$failures.Add('manifest driver/catalog hashes drift from preflight export inventory')}
    foreach ($driverName in @('cruwblocker.inf','CRUWBlocker.sys','CRUWBlocker.cat')) {
        $exportRecord = @($driverHashRecords | Where-Object { [string]$_.file -ieq $driverName })
        $manifestRecord = @($records | Where-Object { [string]$_.relativePath -ieq ('driver\' + $driverName) })
        if (
            $exportRecord.Count -ne 1 -or $manifestRecord.Count -ne 1 -or
            [string]$exportRecord[0].Hash -notmatch '^[A-F0-9]{64}$' -or
            [string]$exportRecord[0].Hash -ine [string]$manifestRecord[0].primarySha256 -or
            [string]$exportRecord[0].Hash -ine [string]$manifestRecord[0].secondarySha256
        ) { $failures.Add("signed driver export hash is not cross-linked to both physical manifest records: $driverName") }
    }
    $exportedInf = @($driverHashRecords | Where-Object { [string]$_.file -ieq 'cruwblocker.inf' })
    if ($exportedInf.Count -ne 1 -or [string]$exportedInf[0].Hash -ine [string]$Preflight.rollbackCapability.exportedInfSha256) {
        $failures.Add('rollback INF capability hash drifts from the signed export inventory')
    }
    $primaryAcl=Invoke-CRUWAdapter $Adapter 'TestProtectedAcl' @($primary); $secondaryAcl=Invoke-CRUWAdapter $Adapter 'TestProtectedAcl' @($secondary)
    if(-not [bool]$primaryAcl.verified -or -not [bool]$secondaryAcl.verified -or -not [bool]$Preflight.protectedAcl.onlySystemAndAdministrators -or -not [bool]$Preflight.protectedAcl.primary.Verified -or -not [bool]$Preflight.protectedAcl.secondary.Verified){$failures.Add('protected ACL verification failed')}
    return [ordered]@{ verified=$failures.Count -eq 0; failures=@($failures); manifest=$manifest; primaryManifestSha256=$primaryManifestHash; secondaryManifestSha256=$secondaryManifestHash; primaryAcl=$primaryAcl; secondaryAcl=$secondaryAcl; recoveryRootTopology=[ordered]@{verified=$rootTopologyValid;primary=$primaryRootEvidence;secondary=$secondaryRootEvidence}; validatedFileCount=$required.Count }
}

function Test-CRUWSingleRecoveryRootIntegrity {
    param(
        [Parameter(Mandatory)] [string] $Root,
        [Parameter(Mandatory)] [ValidateSet('primary','secondary')] [string] $Role,
        [Parameter(Mandatory)] [string] $ExpectedManifestSha256,
        [Parameter(Mandatory)] [hashtable] $Adapter
    )
    $failures = [Collections.Generic.List[string]]::new()
    $rootInput = [string]$Root
    if (
        -not [IO.Path]::IsPathRooted($rootInput) -or
        $rootInput.StartsWith('\\') -or
        $rootInput.StartsWith('\\?\') -or
        $rootInput.StartsWith('\\.\') -or
        $rootInput.IndexOf(':',2) -ge 0
    ) { return [ordered]@{verified=$false;internallyVerified=$false;matchesExpectedAnchor=$false;root=$rootInput;role=$Role;failures=@('single-root path is not a safe local drive path');infPath=$null} }
    $fullRoot = [IO.Path]::GetFullPath($rootInput).TrimEnd('\')
    if ($fullRoot -ine $rootInput.TrimEnd('\')) {
        return [ordered]@{verified=$false;internallyVerified=$false;matchesExpectedAnchor=$false;root=$fullRoot;role=$Role;failures=@('single-root path is not canonical');infPath=$null}
    }
    $simulationOnly = [bool](Get-CRUWPropertyValue $Adapter 'SimulationOnly' $false)
    $expectedPattern = if ($Role -ceq 'primary') {
        '^C:\\Acer-Driver-Audit\\Recovery\\CRUWBlocker-\d{8}-\d{6}-\d{3}$'
    }
    else { '^D:\\Acer-Recovery\\CRUWBlocker-\d{8}-\d{6}-\d{3}$' }
    if (-not $simulationOnly -and $fullRoot -notmatch $expectedPattern) {
        return [ordered]@{verified=$false;internallyVerified=$false;matchesExpectedAnchor=$false;root=$fullRoot;role=$Role;failures=@('single-root path is outside the fixed recovery topology');infPath=$null}
    }
    $manifestPath = Join-Path $fullRoot 'backup-integrity-final.json'
    try {
        if (Test-CRUWPathHasReparseAncestor $manifestPath) {
            return [ordered]@{verified=$false;internallyVerified=$false;matchesExpectedAnchor=$false;root=$fullRoot;role=$Role;failures=@('manifest/root reparse ancestor rejected');infPath=$null}
        }
    }
    catch {
        return [ordered]@{verified=$false;internallyVerified=$false;matchesExpectedAnchor=$false;root=$fullRoot;role=$Role;failures=@('manifest/root missing or inaccessible');infPath=$null}
    }
    if (-not (Test-Path -LiteralPath $manifestPath -PathType Leaf)) {
        return [ordered]@{verified=$false;internallyVerified=$false;matchesExpectedAnchor=$false;root=$fullRoot;role=$Role;failures=@('manifest missing');infPath=$null}
    }
    $manifestHash = (Get-FileHash -LiteralPath $manifestPath -Algorithm SHA256).Hash
    $matchesExpectedAnchor = $manifestHash -ieq $ExpectedManifestSha256
    $manifest = Get-Content -LiteralPath $manifestPath -Raw -Encoding UTF8 | ConvertFrom-Json
    if (
        [int]$manifest.schemaVersion -ne 1 -or
        [string]$manifest.role -cne 'authoritative-removal-preflight-manifest' -or
        -not [bool]$manifest.finalizedBeforeCopy -or
        -not [bool]$manifest.allHashesMatch -or
        -not [bool]$manifest.technicalPreflightPass
    ) { $failures.Add('single-root manifest identity/final gates invalid') }
    $expectedRoot = if ($Role -ceq 'primary') { [string]$manifest.recoveryPath } else { [string]$manifest.secondaryRecoveryPath }
    if ([IO.Path]::GetFullPath($expectedRoot).TrimEnd('\') -cne $fullRoot) { $failures.Add('single-root role/path differs from manifest') }

    $mandatory = @(
        'driver\cruwblocker.inf','driver\CRUWBlocker.sys','driver\CRUWBlocker.cat',
        'SYSTEM.before.hiv','disk-drivers-before.txt','winre-before.txt','filter-snapshot-before.json',
        'implementation/Prepare-CRUWBlockerRemoval.ps1','implementation/CRUWBlockerPreflight.Core.ps1',
        'implementation/CRUWStateMachine.Common.ps1','implementation/Invoke-CRUWBlockerRemoval.ps1',
        'implementation/Test-CRUWBlockerPostboot.ps1','implementation/Repair-CRUWInterruptedRemoval.ps1',
        'preflight.json'
    )
    $required = @($manifest.requiredRelativePaths | ForEach-Object { [string]$_ })
    $records = @($manifest.files)
    if (
        $required.Count -ne $mandatory.Count -or
        @($mandatory | Where-Object { $required -cnotcontains $_ }).Count -gt 0 -or
        @($required | Where-Object { $mandatory -cnotcontains $_ }).Count -gt 0 -or
        [int]$manifest.requiredFileCount -ne $mandatory.Count -or
        $records.Count -ne $mandatory.Count
    ) { $failures.Add('single-root manifest does not contain the exact v3 mandatory set') }
    foreach ($relative in $mandatory) {
        $record = @($records | Where-Object { [string]$_.relativePath -ceq $relative })
        try { $path = Resolve-CRUWSafeRelativeFilePath $fullRoot $relative }
        catch { $failures.Add($_.Exception.Message); continue }
        try {
            if (Test-CRUWPathHasReparseAncestor $path) {
                $failures.Add("reparse-point recovery file/ancestor: $relative")
                continue
            }
        }
        catch {
            $failures.Add("missing/inaccessible recovery file or ancestor: $relative")
            continue
        }
        if ($record.Count -ne 1 -or -not (Test-Path -LiteralPath $path -PathType Leaf)) {
            $failures.Add("missing/ambiguous recovery file: $relative")
            continue
        }
        $expectedHash = if ($Role -ceq 'primary') { [string]$record[0].primarySha256 } else { [string]$record[0].secondarySha256 }
        if (
            $expectedHash -notmatch '^[A-F0-9]{64}$' -or
            -not [bool]$record[0].hashesMatch -or
            (Get-FileHash -LiteralPath $path -Algorithm SHA256).Hash -ine $expectedHash
        ) { $failures.Add("recovery file hash mismatch: $relative") }
    }
    foreach ($payloadContract in @(
        [ordered]@{directory='driver';expected=@('cruwblocker.inf','CRUWBlocker.sys','CRUWBlocker.cat')},
        [ordered]@{directory='implementation';expected=@('Prepare-CRUWBlockerRemoval.ps1','CRUWBlockerPreflight.Core.ps1','CRUWStateMachine.Common.ps1','Invoke-CRUWBlockerRemoval.ps1','Test-CRUWBlockerPostboot.ps1','Repair-CRUWInterruptedRemoval.ps1')}
    )) {
        $payloadDirectory = Join-Path $fullRoot $payloadContract.directory
        try {
            if (Test-CRUWPathHasReparseAncestor $payloadDirectory) { throw 'payload directory/reparse ancestor rejected' }
            $payloadItems = @(Get-ChildItem -LiteralPath $payloadDirectory -Force -ErrorAction Stop)
            $payloadFiles = @($payloadItems | Where-Object { -not $_.PSIsContainer } | ForEach-Object { [string]$_.Name })
            $payloadContainers = @($payloadItems | Where-Object { $_.PSIsContainer })
            if (
                $payloadContainers.Count -ne 0 -or
                $payloadFiles.Count -ne $payloadContract.expected.Count -or
                @($payloadContract.expected | Where-Object { $payloadFiles -cnotcontains $_ }).Count -gt 0 -or
                @($payloadFiles | Where-Object { $payloadContract.expected -cnotcontains $_ }).Count -gt 0
            ) { $failures.Add("single-root $($payloadContract.directory) payload is not the exact physical allowlist") }
        }
        catch { $failures.Add("single-root $($payloadContract.directory) payload inventory failed: $($_.Exception.Message)") }
    }
    try {
        if (Test-CRUWPathHasReparseAncestor $fullRoot) { throw 'reparse recovery root rejected' }
        $rootItems = @(Get-ChildItem -LiteralPath $fullRoot -Force -ErrorAction Stop)
        $allowedRootFiles = @(
            'SYSTEM.before.hiv','disk-drivers-before.txt','winre-before.txt','filter-snapshot-before.json',
            'preflight.json','backup-integrity-final.json'
        )
        $unexpectedRootItems = @($rootItems | Where-Object {
            if ($_.PSIsContainer) { return [string]$_.Name -cnotin @('driver','implementation') }
            return [string]$_.Name -cnotin $allowedRootFiles -and [string]$_.Name -notlike 'removal-journal-*'
        })
        if ($unexpectedRootItems.Count -gt 0) { $failures.Add('single recovery root contains unlisted physical payload') }
    }
    catch { $failures.Add("single recovery root inventory failed: $($_.Exception.Message)") }

    $preflightPath = Join-Path $fullRoot 'preflight.json'
    $preflight = Get-Content -LiteralPath $preflightPath -Raw -Encoding UTF8 | ConvertFrom-Json
    if ([int]$preflight.schemaVersion -ne 3 -or -not [bool]$preflight.technicalPreflightPass) {
        $failures.Add('single-root preflight v3/final gate invalid')
    }
    if (
        (@($manifest.implementation.PSObject.Properties.Name) -join '|') -cne 'producerPerformsDriverMutation|sealedBundleContainsBootCriticalMutation|artifacts' -or
        (@($preflight.implementation.artifacts) | ConvertTo-Json -Depth 6 -Compress) -cne (@($manifest.implementation.artifacts) | ConvertTo-Json -Depth 6 -Compress)
    ) { $failures.Add('single-root implementation contract differs between preflight and manifest') }
    $singleManifestDriverIdentity = Test-CRUWManifestDriverIdentityContract `
        $manifest.driverIdentity $preflight `
        -SimulationOnly:([bool](Get-CRUWPropertyValue $Adapter 'SimulationOnly' $false))
    if (-not [bool]$singleManifestDriverIdentity.verified) {
        $failures.Add('single-root exported driver signature/hash gates invalid: ' + ($singleManifestDriverIdentity.failures -join '; '))
    }
    if (
        -not [bool](Get-CRUWPropertyValue $Adapter 'SimulationOnly' $false) -and
        $Adapter.ContainsKey('GetFileSignatureStatus')
    ) {
        foreach ($driverName in @('cruwblocker.inf','CRUWBlocker.sys','CRUWBlocker.cat')) {
            $driverPath = Resolve-CRUWSafeRelativeFilePath $fullRoot ('driver\' + $driverName)
            $signatureStatus = Invoke-CRUWAdapter $Adapter 'GetFileSignatureStatus' @($driverPath)
            if ([string]$signatureStatus.status -cne 'Valid') {
                $failures.Add("single-root physical driver payload signature is not Valid: $driverName")
            }
        }
    }

    $rootEvidence = Invoke-CRUWAdapter $Adapter 'GetRecoveryRootEvidence' @($fullRoot)
    $expectedMount = if ($Role -ceq 'primary') { 'C:' } else { 'D:' }
    $sealedVolume = @($preflight.storageLayout.volumes | Where-Object {
        (([string]$_.driveLetter).TrimEnd(':').ToUpperInvariant() + ':') -ceq $expectedMount
    })
    if (
        $sealedVolume.Count -ne 1 -or
        ([string]$rootEvidence.mountPoint).ToUpperInvariant() -cne $expectedMount -or
        [int]$rootEvidence.diskNumber -ne [int]$sealedVolume[0].diskNumber -or
        [string]$rootEvidence.deviceInstanceIdSha256 -ine [string]$sealedVolume[0].deviceInstanceIdSha256 -or
        [bool]$rootEvidence.diskReadOnly -or [bool]$rootEvidence.diskOffline -or
        [string]$rootEvidence.diskHealthStatus -ine 'Healthy' -or
        @(ConvertTo-CRUWStringArray $rootEvidence.diskOperationalStatus).Count -ne 1 -or
        @($rootEvidence.diskOperationalStatus) -inotcontains 'Online' -or
        [string]::IsNullOrWhiteSpace([string]$rootEvidence.diskBusType)
    ) { $failures.Add('single-root live topology does not match its sealed healthy physical target') }
    $acl = Invoke-CRUWAdapter $Adapter 'TestProtectedAcl' @($fullRoot)
    if (-not [bool]$acl.verified) { $failures.Add('recovery root ACL is not protected') }
    $internallyVerified = $failures.Count -eq 0
    return [ordered]@{
        verified=$internallyVerified -and $matchesExpectedAnchor;internallyVerified=$internallyVerified;
        matchesExpectedAnchor=$matchesExpectedAnchor;root=$fullRoot;role=$Role;manifestSha256=$manifestHash;
        preflightSha256=(Get-FileHash -LiteralPath $preflightPath -Algorithm SHA256).Hash;
        manifest=$manifest;preflight=$preflight;rootEvidence=$rootEvidence;acl=$acl;failures=@($failures);
        infPath=(Join-Path $fullRoot 'driver\cruwblocker.inf')
    }
}

function Get-CRUWValidatedRollbackInf {
    param(
        [Parameter(Mandatory)] [string] $PrimaryRoot,
        [Parameter(Mandatory)] [string] $SecondaryRoot,
        [Parameter(Mandatory)] [string] $ExpectedManifestSha256,
        [Parameter(Mandatory)] [hashtable] $Adapter,
        [Parameter(Mandatory)] $ExpectedRootTopology,
        [switch] $RequireExactlyOneRoot
    )
    try { $primary = Test-CRUWSingleRecoveryRootIntegrity $PrimaryRoot primary $ExpectedManifestSha256 $Adapter }
    catch { $primary = [ordered]@{ verified=$false;role='primary';failures=@($_.Exception.Message);infPath=$null } }
    try { $secondary = Test-CRUWSingleRecoveryRootIntegrity $SecondaryRoot secondary $ExpectedManifestSha256 $Adapter }
    catch { $secondary = [ordered]@{ verified=$false;role='secondary';failures=@($_.Exception.Message);infPath=$null } }
    $primaryTopology = Invoke-CRUWAdapter $Adapter 'GetRecoveryRootEvidence' @($PrimaryRoot)
    $secondaryTopology = Invoke-CRUWAdapter $Adapter 'GetRecoveryRootEvidence' @($SecondaryRoot)
    $topologyValid = Test-CRUWRecoveryRootTopology $primaryTopology $secondaryTopology $ExpectedRootTopology
    if (-not $topologyValid) { throw 'Rollback backup roots are not on distinct C:/D: physical identities' }
    $validRoots = @(@($primary,$secondary) | Where-Object { [bool]$_.verified })
    if ($RequireExactlyOneRoot -and $validRoots.Count -ne 1) {
        throw "Degraded rollback requires exactly one intact root; observed $($validRoots.Count)"
    }
    $selected = if ([bool]$primary.verified) { $primary } elseif ([bool]$secondary.verified) { $secondary } else { $null }
    if ($null -eq $selected) {
        throw "No intact rollback backup remains. Primary=$($primary.failures -join ', '); Secondary=$($secondary.failures -join ', ')"
    }
    return [ordered]@{ infPath=[string]$selected.infPath;selectedRole=[string]$selected.role;primary=$primary;secondary=$secondary }
}

function Write-CRUWDualJournal {
    param(
        [Parameter(Mandatory)] [string] $PrimaryRoot,
        [Parameter(Mandatory)] [string] $SecondaryRoot,
        [Parameter(Mandatory)] [guid] $OperationId,
        [Parameter(Mandatory)] [ValidateRange(0,999999)] [int] $Sequence,
        [Parameter(Mandatory)] [ValidatePattern('^[A-Z0-9_]+$')] [string] $Stage,
        [AllowNull()] [string] $PreviousPayloadSha256,
        [Parameter(Mandatory)] $Context,
        [Parameter(Mandatory)] [hashtable] $Adapter
    )
    # Journal payload schema v2 is an independent, immutable wire format. It is
    # intentionally distinct from the authoritative preflight schema v3.
    $payload = [ordered]@{ schemaVersion=2; operationId=$OperationId.ToString('D'); sequence=$Sequence; stage=$Stage; recordedAt=([DateTimeOffset](Invoke-CRUWAdapter $Adapter 'GetNow')).ToString('o'); previousPayloadSha256=$PreviousPayloadSha256; context=$Context }
    # Hash immutable canonical bytes, never a deserialized/re-serialized object.
    # PowerShell 5.1 and 7 type ISO timestamps differently during JSON parsing.
    $payloadJson = $payload | ConvertTo-Json -Depth 20 -Compress
    $payloadBytes = [Text.UTF8Encoding]::new($false).GetBytes($payloadJson)
    $payloadSha256 = Get-CRUWBytesSha256 $payloadBytes
    $document = [ordered]@{
        documentType = 'CRUWBlockerRemovalJournal'
        payloadEncoding = 'utf8-base64'
        payloadBase64 = [Convert]::ToBase64String($payloadBytes)
        payloadSha256 = $payloadSha256
    }
    $fileName = 'removal-journal-{0}-{1:D6}-{2}-{3}.json' -f $OperationId.ToString('N'),$Sequence,$Stage,[string]$document.payloadSha256
    $primaryFull = [IO.Path]::GetFullPath($PrimaryRoot).TrimEnd('\')
    $secondaryFull = [IO.Path]::GetFullPath($SecondaryRoot).TrimEnd('\')
    $sequencePrefix = 'removal-journal-{0}-{1:D6}-*.json' -f $OperationId.ToString('N'),$Sequence
    $existing = @(Get-ChildItem -LiteralPath $primaryFull -File -Filter $sequencePrefix) + @(Get-ChildItem -LiteralPath $secondaryFull -File -Filter $sequencePrefix)
    if ($existing.Count -gt 0) { throw "Append-only journal sequence already exists: $Sequence" }
    $primaryPath = Join-Path $primaryFull $fileName
    $secondaryPath = Join-Path $secondaryFull $fileName
    $journalJson = ($document | ConvertTo-Json -Depth 20) + [Environment]::NewLine
    $journalBytes = [Text.UTF8Encoding]::new($false).GetBytes($journalJson)
    Write-CRUWBytesDurableAtomic -LiteralPath $primaryPath -Bytes $journalBytes -Adapter $Adapter -ProtectAcl
    Write-CRUWBytesDurableAtomic -LiteralPath $secondaryPath -Bytes $journalBytes -Adapter $Adapter -ProtectAcl
    $primaryHash = (Get-FileHash -LiteralPath $primaryPath -Algorithm SHA256).Hash
    $secondaryHash = (Get-FileHash -LiteralPath $secondaryPath -Algorithm SHA256).Hash
    $primaryAcl = Invoke-CRUWAdapter $Adapter 'TestProtectedAcl' @($primaryPath)
    $secondaryAcl = Invoke-CRUWAdapter $Adapter 'TestProtectedAcl' @($secondaryPath)
    if ($primaryHash -ne $secondaryHash -or -not [bool]$primaryAcl.verified -or -not [bool]$secondaryAcl.verified) {
        throw 'Dual removal journal byte/hash/ACL verification failed'
    }
    return [ordered]@{
        primaryPath = $primaryPath
        secondaryPath = $secondaryPath
        fileName = $fileName
        payloadSha256 = [string]$document.payloadSha256
        primarySha256 = $primaryHash
        secondarySha256 = $secondaryHash
        primaryAcl = $primaryAcl
        secondaryAcl = $secondaryAcl
        stage = $Stage
        sequence = $Sequence
    }
}

function Write-CRUWSingleJournal {
    param(
        [Parameter(Mandatory)] [string] $Root,
        [Parameter(Mandatory)] [guid] $OperationId,
        [Parameter(Mandatory)] [ValidateRange(0,999999)] [int] $Sequence,
        [Parameter(Mandatory)] [ValidatePattern('^DEGRADED_[A-Z0-9_]+$')] [string] $Stage,
        [AllowNull()] [string] $PreviousPayloadSha256,
        [Parameter(Mandatory)] $Context,
        [Parameter(Mandatory)] [hashtable] $Adapter
    )
    $payload = [ordered]@{
        schemaVersion=2;operationId=$OperationId.ToString('D');sequence=$Sequence;stage=$Stage;
        recordedAt=([DateTimeOffset](Invoke-CRUWAdapter $Adapter 'GetNow')).ToString('o');
        previousPayloadSha256=$PreviousPayloadSha256;context=$Context
    }
    $payloadBytes = [Text.UTF8Encoding]::new($false).GetBytes(($payload | ConvertTo-Json -Depth 20 -Compress))
    $payloadSha256 = Get-CRUWBytesSha256 $payloadBytes
    $document = [ordered]@{
        documentType='CRUWBlockerRemovalJournal';payloadEncoding='utf8-base64';
        payloadBase64=[Convert]::ToBase64String($payloadBytes);payloadSha256=$payloadSha256
    }
    $fileName = 'removal-journal-{0}-{1:D6}-{2}-{3}.json' -f $OperationId.ToString('N'),$Sequence,$Stage,$payloadSha256
    $fullRoot = [IO.Path]::GetFullPath($Root).TrimEnd('\')
    $sequencePrefix = 'removal-journal-{0}-{1:D6}-*.json' -f $OperationId.ToString('N'),$Sequence
    if (@(Get-ChildItem -LiteralPath $fullRoot -File -Filter $sequencePrefix).Count -gt 0) {
        throw "Append-only degraded journal sequence already exists: $Sequence"
    }
    $path = Join-Path $fullRoot $fileName
    $bytes = [Text.UTF8Encoding]::new($false).GetBytes((($document | ConvertTo-Json -Depth 20) + [Environment]::NewLine))
    Write-CRUWBytesDurableAtomic -LiteralPath $path -Bytes $bytes -Adapter $Adapter -ProtectAcl
    $acl = Invoke-CRUWAdapter $Adapter 'TestProtectedAcl' @($path)
    if (-not [bool]$acl.verified) { throw 'Degraded single-root journal ACL verification failed' }
    return [ordered]@{
        singleRootPath=$path;fileName=$fileName;fileSha256=(Get-FileHash -LiteralPath $path -Algorithm SHA256).Hash;
        payloadSha256=$payloadSha256;stage=$Stage;sequence=$Sequence;acl=$acl
    }
}

function Read-CRUWJournalDocument {
    param([Parameter(Mandatory)] [string] $Path)
    $envelope = Get-Content -LiteralPath $Path -Raw -Encoding UTF8 | ConvertFrom-Json
    if (
        [string]$envelope.documentType -cne 'CRUWBlockerRemovalJournal' -or
        [string]$envelope.payloadEncoding -cne 'utf8-base64' -or
        [string]::IsNullOrWhiteSpace([string]$envelope.payloadBase64)
    ) {
        throw 'Journal envelope identity/encoding invalid'
    }
    try { $payloadBytes = [Convert]::FromBase64String([string]$envelope.payloadBase64) }
    catch { throw 'Journal payload Base64 is invalid' }
    $payloadSha256 = Get-CRUWBytesSha256 $payloadBytes
    if ($payloadSha256 -cne [string]$envelope.payloadSha256) {
        throw 'Journal canonical payload byte hash mismatch'
    }
    $payloadJson = [Text.UTF8Encoding]::new($false, $true).GetString($payloadBytes)
    $payload = $payloadJson | ConvertFrom-Json
    return [ordered]@{
        documentType = [string]$envelope.documentType
        payloadEncoding = [string]$envelope.payloadEncoding
        payloadBase64 = [string]$envelope.payloadBase64
        payload = $payload
        payloadSha256 = $payloadSha256
    }
}

function Get-CRUWJournalFileEvidence {
    param(
        [Parameter(Mandatory)] [string] $Path,
        [Parameter(Mandatory)] [guid] $OperationId,
        [Parameter(Mandatory)] [int] $Sequence,
        [hashtable] $Adapter
    )
    $failures = [Collections.Generic.List[string]]::new()
    $fullPath = [IO.Path]::GetFullPath($Path)
    $document = $null
    try { $document = Read-CRUWJournalDocument $fullPath }
    catch { $failures.Add('journal JSON parse failed') }
    $fileHash = if (Test-Path -LiteralPath $fullPath -PathType Leaf) { (Get-FileHash -LiteralPath $fullPath -Algorithm SHA256).Hash } else { $null }
    $acl = if ($null -ne $Adapter -and (Test-Path -LiteralPath $fullPath -PathType Leaf)) {
        Invoke-CRUWAdapter $Adapter 'TestProtectedAcl' @($fullPath)
    }
    else { [ordered]@{ verified = $false } }
    if ($null -ne $document) {
        $expectedName = 'removal-journal-{0}-{1:D6}-{2}-{3}.json' -f $OperationId.ToString('N'),$Sequence,[string]$document.payload.stage,[string]$document.payloadSha256
        if (
            [string]$document.documentType -cne 'CRUWBlockerRemovalJournal' -or
            [string]$document.payload.operationId -cne $OperationId.ToString('D') -or
            [int]$document.payload.sequence -ne $Sequence -or
            (Split-Path -Leaf $fullPath) -cne $expectedName
        ) {
            $failures.Add('journal document/filename/payload identity mismatch')
        }
        if (
            [int]$document.payload.schemaVersion -ne 2 -or
            [int]$document.payload.sequence -lt 0 -or
            [int]$document.payload.sequence -gt 999999 -or
            [string]$document.payload.stage -notmatch '^[A-Z0-9_]+$' -or
            [string]$document.payload.previousPayloadSha256 -notmatch '^(?:[A-Fa-f0-9]{64})?$'
        ) { $failures.Add('journal payload schema/semantic validation failed') }
    }
    if (-not [bool]$acl.verified) { $failures.Add('journal ACL is not protected') }
    return [ordered]@{
        valid = $failures.Count -eq 0
        path = $fullPath
        fileName = Split-Path -Leaf $fullPath
        fileSha256 = $fileHash
        acl = $acl
        document = $document
        failures = @($failures)
    }
}

function Get-CRUWSingleJournalState {
    param(
        [Parameter(Mandatory)] [string] $Root,
        [Parameter(Mandatory)] [guid] $OperationId,
        [Parameter(Mandatory)] [hashtable] $Adapter
    )
    $rootFull = [IO.Path]::GetFullPath($Root).TrimEnd('\')
    $pattern = '^removal-journal-' + [regex]::Escape($OperationId.ToString('N')) + '-(?<sequence>\d{6})-[A-Z0-9_]+-[A-Fa-f0-9]{64}\.json$'
    $files = @(Get-ChildItem -LiteralPath $rootFull -File -Filter ('removal-journal-' + $OperationId.ToString('N') + '-*.json'))
    $recognized = @($files | Where-Object { $_.Name -match $pattern })
    if ($recognized.Count -ne $files.Count -or $recognized.Count -eq 0) {
        return [ordered]@{verified=$false;failures=@('single-root journal contains unrecognized artifacts or is empty');entries=@();evidence=@();nextSequence=0;previousPayloadSha256=$null}
    }
    $sequenceValues = @($recognized | ForEach-Object { if ($_.Name -match $pattern) { [int]$Matches.sequence } } | Sort-Object)
    $failures = [Collections.Generic.List[string]]::new()
    $entries = [Collections.Generic.List[object]]::new()
    $evidence = [Collections.Generic.List[object]]::new()
    $previous = $null
    for ($sequence=0; $sequence -lt $sequenceValues.Count; $sequence++) {
        if ([int]$sequenceValues[$sequence] -ne $sequence) { $failures.Add("single-root journal sequence gap/duplicate at $sequence"); break }
        $matches = @($recognized | Where-Object { $_.Name -like ('removal-journal-{0}-{1:D6}-*.json' -f $OperationId.ToString('N'),$sequence) })
        if ($matches.Count -ne 1) { $failures.Add("single-root journal sequence $sequence is ambiguous"); break }
        $item = Get-CRUWJournalFileEvidence $matches[0].FullName $OperationId $sequence $Adapter
        if (-not [bool]$item.valid -or [string]$item.document.payload.previousPayloadSha256 -cne [string]$previous) {
            $failures.Add("single-root journal hash chain invalid at sequence $sequence")
            break
        }
        $entries.Add($item.document)
        $evidence.Add($item)
        $previous = [string]$item.document.payloadSha256
    }
    return [ordered]@{
        verified=$failures.Count -eq 0 -and $entries.Count -eq $recognized.Count;failures=@($failures);
        entries=@($entries);evidence=@($evidence);nextSequence=$entries.Count;previousPayloadSha256=$previous
    }
}

function Get-CRUWJournalPrefixState {
    param(
        [Parameter(Mandatory)] [string] $PrimaryRoot,
        [Parameter(Mandatory)] [string] $SecondaryRoot,
        [Parameter(Mandatory)] [guid] $OperationId,
        [hashtable] $Adapter,
        [int] $StopAtSequence = -1
    )
    $failures = [Collections.Generic.List[string]]::new()
    $primaryFull = [IO.Path]::GetFullPath($PrimaryRoot).TrimEnd('\')
    $secondaryFull = [IO.Path]::GetFullPath($SecondaryRoot).TrimEnd('\')
    $operationPattern = '^removal-journal-' + [regex]::Escape($OperationId.ToString('N')) + '-(?<sequence>\d{6})-[A-Z0-9_]+-[A-Fa-f0-9]{64}\.json$'
    $primaryFiles = @(Get-ChildItem -LiteralPath $primaryFull -File -Filter ('removal-journal-' + $OperationId.ToString('N') + '-*.json'))
    $secondaryFiles = @(Get-ChildItem -LiteralPath $secondaryFull -File -Filter ('removal-journal-' + $OperationId.ToString('N') + '-*.json'))
    $sequenceValues = @($primaryFiles + $secondaryFiles | ForEach-Object {
        if ($_.Name -match $operationPattern) { [int]$Matches.sequence }
    } | Sort-Object -Unique)
    if ($StopAtSequence -ge 0) { $maximumSequence = $StopAtSequence }
    elseif ($sequenceValues.Count -gt 0) { $maximumSequence = [int]($sequenceValues | Measure-Object -Maximum).Maximum }
    else { $maximumSequence = -1 }

    $previousPayloadHash = $null
    $entries = @()
    $unilateral = $null
    $divergent = $false
    for ($sequence = 0; $sequence -le $maximumSequence; $sequence++) {
        $sequencePrefix = 'removal-journal-{0}-{1:D6}-*.json' -f $OperationId.ToString('N'),$sequence
        $primaryMatches = @($primaryFiles | Where-Object { $_.Name -like $sequencePrefix })
        $secondaryMatches = @($secondaryFiles | Where-Object { $_.Name -like $sequencePrefix })
        if ($primaryMatches.Count -gt 1 -or $secondaryMatches.Count -gt 1) {
            $failures.Add("journal sequence $sequence is ambiguous")
            $divergent = $true
            break
        }
        if ($primaryMatches.Count -eq 0 -and $secondaryMatches.Count -eq 0) {
            $failures.Add("journal sequence $sequence is missing")
            $divergent = $true
            break
        }
        if ($primaryMatches.Count -eq 1 -and $secondaryMatches.Count -eq 1) {
            $primaryEvidence = Get-CRUWJournalFileEvidence $primaryMatches[0].FullName $OperationId $sequence $Adapter
            $secondaryEvidence = Get-CRUWJournalFileEvidence $secondaryMatches[0].FullName $OperationId $sequence $Adapter
            $pairValid =
                [bool]$primaryEvidence.valid -and
                [bool]$secondaryEvidence.valid -and
                $primaryEvidence.fileName -ceq $secondaryEvidence.fileName -and
                $primaryEvidence.fileSha256 -ceq $secondaryEvidence.fileSha256 -and
                [string]$primaryEvidence.document.payload.previousPayloadSha256 -ceq [string]$previousPayloadHash
            if (-not $pairValid) {
                $failures.Add("journal divergence at sequence $sequence")
                $divergent = $true
                break
            }
            $entries += ,$primaryEvidence.document
            $previousPayloadHash = [string]$primaryEvidence.document.payloadSha256
            continue
        }

        $sourceRole = if ($primaryMatches.Count -eq 1) { 'primary' } else { 'secondary' }
        $sourcePath = if ($primaryMatches.Count -eq 1) { $primaryMatches[0].FullName } else { $secondaryMatches[0].FullName }
        $sourceEvidence = Get-CRUWJournalFileEvidence $sourcePath $OperationId $sequence $Adapter
        $tailIsLastSequence = $sequence -eq $maximumSequence
        $linkValid = [bool]$sourceEvidence.valid -and [string]$sourceEvidence.document.payload.previousPayloadSha256 -ceq [string]$previousPayloadHash
        if (-not [bool]$sourceEvidence.valid -or -not $linkValid -or -not $tailIsLastSequence) {
            $failures.Add("unrecoverable unilateral/divergent journal at sequence $sequence")
            $divergent = $true
            break
        }
        $unilateral = [ordered]@{ sequence=$sequence;sourceRole=$sourceRole;sourcePath=$sourcePath;fileName=$sourceEvidence.fileName;document=$sourceEvidence.document }
        break
    }
    return [ordered]@{
        verified = $failures.Count -eq 0 -and $null -eq $unilateral
        failures = @($failures)
        entries = $entries
        commonPrefixLength = $entries.Count
        nextSequence = $entries.Count
        previousPayloadSha256 = $previousPayloadHash
        latestPrimaryPath = if ($entries.Count -gt 0) { @($primaryFiles | Where-Object { $_.Name -like ('removal-journal-{0}-{1:D6}-*.json' -f $OperationId.ToString('N'),($entries.Count-1)) })[0].FullName } else { $null }
        unilateralTail = $unilateral
        divergent = $divergent
    }
}

function Repair-CRUWJournalPrefix {
    param([string]$PrimaryRoot,[string]$SecondaryRoot,[guid]$OperationId,[hashtable]$Adapter)
    $state = Get-CRUWJournalPrefixState $PrimaryRoot $SecondaryRoot $OperationId $Adapter
    if ([bool]$state.divergent) { throw "Journal divergence cannot be reconciled: $($state.failures -join '; ')" }
    # A unilateral tail is forensic evidence of an interrupted commit.  It is
    # deliberately retained and never copied to the other disk: only the
    # committed dual common prefix may drive a later decision.  Recovery must
    # inspect live state and append a new entry after an operator-approved
    # reconciliation; it must not turn the unilateral intent/result into fact.
    return $state
}

function Quarantine-CRUWUnilateralJournalTail {
    param(
        [Parameter(Mandatory)] $PrefixState,
        [Parameter(Mandatory)] [hashtable] $Adapter
    )
    if ($null -eq $PrefixState.unilateralTail) { return $null }
    if ([bool]$PrefixState.divergent) { throw 'Divergent journal cannot be quarantined automatically' }
    $sourcePath = [IO.Path]::GetFullPath([string]$PrefixState.unilateralTail.sourcePath)
    $sourceEvidence = Get-CRUWJournalFileEvidence $sourcePath ([guid]$PrefixState.unilateralTail.document.payload.operationId) ([int]$PrefixState.unilateralTail.sequence) $Adapter
    if (-not [bool]$sourceEvidence.valid) { throw 'Unilateral journal tail failed integrity/ACL validation' }
    $quarantinePath = $sourcePath + '.q'
    if (Test-Path -LiteralPath $quarantinePath) { throw 'Unilateral journal quarantine destination already exists' }
    if (-not [CRUW.NativeFile]::MoveFileEx((ConvertTo-CRUWExtendedPath $sourcePath), (ConvertTo-CRUWExtendedPath $quarantinePath), 0x00000008)) {
        throw [ComponentModel.Win32Exception]::new([Runtime.InteropServices.Marshal]::GetLastWin32Error(), 'Durable unilateral-tail quarantine failed')
    }
    $quarantineAcl = Invoke-CRUWAdapter $Adapter 'TestProtectedAcl' @($quarantinePath)
    $quarantineHash = (Get-FileHash -LiteralPath $quarantinePath -Algorithm SHA256).Hash
    if (-not [bool]$quarantineAcl.verified -or $quarantineHash -cne [string]$sourceEvidence.fileSha256) {
        throw 'Quarantined unilateral journal tail failed hash/ACL verification'
    }
    return [ordered]@{
        sourceRole = [string]$PrefixState.unilateralTail.sourceRole
        sequence = [int]$PrefixState.unilateralTail.sequence
        fileSha256 = $quarantineHash
        quarantinePathSha256 = Get-CRUWStringSha256 $quarantinePath
        acl = $quarantineAcl
    }
}

function Get-CRUWJournalOperationIds {
    param([string]$PrimaryRoot,[string]$SecondaryRoot)
    $pattern = '^removal-journal-(?<operation>[A-Fa-f0-9]{32})-\d{6}-[A-Z0-9_]+-[A-Fa-f0-9]{64}\.json(?:\.q)?$'
    $files = @(Get-ChildItem -LiteralPath $PrimaryRoot -File -Filter 'removal-journal-*') + @(Get-ChildItem -LiteralPath $SecondaryRoot -File -Filter 'removal-journal-*')
    return @($files | ForEach-Object { if ($_.Name -match $pattern) { [guid]$Matches.operation } } | Sort-Object -Unique)
}

function Get-CRUWUnrecognizedJournalArtifacts {
    param([Parameter(Mandatory)] [string] $PrimaryRoot, [Parameter(Mandatory)] [string] $SecondaryRoot)
    $recognized = '^removal-journal-[A-Fa-f0-9]{32}-\d{6}-[A-Z0-9_]+-[A-Fa-f0-9]{64}\.json(?:\.q)?$'
    return @(
        @(Get-ChildItem -LiteralPath $PrimaryRoot -File -Filter 'removal-journal-*') +
        @(Get-ChildItem -LiteralPath $SecondaryRoot -File -Filter 'removal-journal-*') |
        Where-Object { $_.Name -notmatch $recognized } |
        ForEach-Object { [ordered]@{ nameSha256=Get-CRUWStringSha256 $_.Name;pathSha256=Get-CRUWStringSha256 $_.FullName } }
    )
}

function Get-CRUWJournalQuarantineEvidence {
    param(
        [Parameter(Mandatory)] [string] $PrimaryRoot,
        [Parameter(Mandatory)] [string] $SecondaryRoot,
        [Parameter(Mandatory)] [guid] $OperationId,
        [Parameter(Mandatory)] [hashtable] $Adapter
    )
    $pattern = '^removal-journal-' + [regex]::Escape($OperationId.ToString('N')) + '-(?<sequence>\d{6})-[A-Z0-9_]+-[A-Fa-f0-9]{64}\.json\.q$'
    $items = [Collections.Generic.List[object]]::new()
    foreach ($rootRecord in @(
        [ordered]@{ role='primary';root=$PrimaryRoot },
        [ordered]@{ role='secondary';root=$SecondaryRoot }
    )) {
        foreach ($file in @(Get-ChildItem -LiteralPath $rootRecord.root -File -Filter ('removal-journal-' + $OperationId.ToString('N') + '-*.json.q'))) {
            if ($file.Name -notmatch $pattern) { continue }
            $actualHash = (Get-FileHash -LiteralPath $file.FullName -Algorithm SHA256).Hash
            $acl = Invoke-CRUWAdapter $Adapter 'TestProtectedAcl' @($file.FullName)
            $document = $null
            try { $document = Read-CRUWJournalDocument $file.FullName } catch {}
            $documentMatches =
                $null -ne $document -and
                [string]$document.payload.operationId -ceq $OperationId.ToString('D') -and
                [int]$document.payload.sequence -eq [int]$Matches.sequence
            $items.Add([ordered]@{
                valid = [bool]$acl.verified -and $documentMatches
                role = [string]$rootRecord.role
                sequence = [int]$Matches.sequence
                fileSha256 = $actualHash
                path = $file.FullName
                pathSha256 = Get-CRUWStringSha256 $file.FullName
                acl = $acl
                document = $document
            })
        }
    }
    return @($items)
}

function Test-CRUWJournalQuarantineResolution {
    param([Parameter(Mandatory)] $Prefix,[AllowNull()] $Quarantines)
    $quarantines = @($Quarantines)
    $references = @($Prefix.entries | Where-Object {
        [string]$_.payload.stage -in @('RECOVERY_RECONCILIATION','ABORT_TERMINAL','CLEAN_PREBOOT_RECOVERY_REQUIRED')
    } | ForEach-Object {
        $recovery = Get-CRUWPropertyValue $_.payload.context 'recovery'
        Get-CRUWPropertyValue $recovery 'unilateralTail'
    } | Where-Object { $null -ne $_ })
    $unresolved = @($quarantines | Where-Object {
        $quarantine = $_
        -not [bool]$quarantine.valid -or @($references | Where-Object {
            [string]$_.fileSha256 -ceq [string]$quarantine.fileSha256 -and
            [string]$_.sourceRole -ceq [string]$quarantine.role -and
            [int]$_.sequence -eq [int]$quarantine.sequence
        }).Count -ne 1
    })
    $orphanReferences = @($references | Where-Object {
        $reference = $_
        @($quarantines | Where-Object {
            [string]$_.fileSha256 -ceq [string]$reference.fileSha256 -and
            [string]$_.role -ceq [string]$reference.sourceRole -and
            [int]$_.sequence -eq [int]$reference.sequence
        }).Count -ne 1
    })
    return [ordered]@{
        verified = $unresolved.Count -eq 0 -and $orphanReferences.Count -eq 0
        unresolved = $unresolved
        orphanReferences = $orphanReferences
        quarantineCount = $quarantines.Count
        referenceCount = $references.Count
    }
}

function Get-CRUWUnfinishedOperations {
    param(
        [Parameter(Mandatory)] [string] $PrimaryRoot,
        [Parameter(Mandatory)] [string] $SecondaryRoot,
        [Parameter(Mandatory)] [hashtable] $Adapter
    )
    $completedStages = @('ABORT_TERMINAL', 'POSTBOOT_COMPLETE', 'POSTBOOT_SAFE_RESIDUAL')
    $results = [Collections.Generic.List[object]]::new()
    foreach ($operationId in @(Get-CRUWJournalOperationIds $PrimaryRoot $SecondaryRoot)) {
        $prefix = Get-CRUWJournalPrefixState $PrimaryRoot $SecondaryRoot $operationId $Adapter
        $quarantines = @(Get-CRUWJournalQuarantineEvidence $PrimaryRoot $SecondaryRoot $operationId $Adapter)
        $quarantineResolution = Test-CRUWJournalQuarantineResolution $prefix $quarantines
        $latestStage = if ($prefix.entries.Count -gt 0) {
            [string]$prefix.entries[-1].payload.stage
        }
        else { $null }
        $unfinished =
            [bool]$prefix.divergent -or
            $null -ne $prefix.unilateralTail -or
            -not [bool]$quarantineResolution.verified -or
            [string]::IsNullOrWhiteSpace($latestStage) -or
            $latestStage -notin $completedStages
        if ($unfinished) {
            $results.Add([ordered]@{
                operationId = $operationId.ToString('D')
                latestCommittedStage = $latestStage
                commonPrefixLength = [int]$prefix.commonPrefixLength
                hasUnilateralTail = $null -ne $prefix.unilateralTail
                unresolvedQuarantineCount = @($quarantineResolution.unresolved).Count
                divergent = [bool]$prefix.divergent
                prefix = $prefix
            })
        }
    }
    return @($results)
}

function Test-CRUWProbeEvidence {
    param([AllowNull()] $Probes, [string[]] $RequiredMountPoints = @('C:', 'D:'))
    $items = @($Probes)
    $mounts = @($items | ForEach-Object { [string]$_.mountPoint })
    $failed = @($items | Where-Object {
        -not [bool]$_.writeSucceeded -or
        -not [bool]$_.readSucceeded -or
        -not [bool]$_.hashMatches -or
        -not [bool]$_.deleteSucceeded -or
        [string]$_.writeSha256 -notmatch '^[A-Fa-f0-9]{64}$' -or
        [string]$_.readSha256 -notmatch '^[A-Fa-f0-9]{64}$' -or
        [string]$_.writeSha256 -ine [string]$_.readSha256
    })
    return [ordered]@{
        verified =
            $items.Count -eq $RequiredMountPoints.Count -and
            (Test-CRUWEqualSet $mounts $RequiredMountPoints) -and
            $failed.Count -eq 0
        items = $items
        failedMounts = @($failed | ForEach-Object { [string]$_.mountPoint })
    }
}

function Test-CRUWSameBootIdentity {
    param($Actual, $Expected)
    return ((ConvertTo-CRUWUtcRoundtripString $Actual.lastBootUpTimeUtc) -ceq
            (ConvertTo-CRUWUtcRoundtripString $Expected.lastBootUpTimeUtc) -and
        [string]$Actual.operatingSystemBuild -ceq [string]$Expected.operatingSystemBuild -and
        [string]$Actual.markerSha256 -ceq [string]$Expected.markerSha256)
}

function Test-CRUWJournalChain {
    param([string]$TerminalPath,[string]$PrimaryRoot,[string]$SecondaryRoot,[hashtable]$Adapter)
    $terminalFull = [IO.Path]::GetFullPath($TerminalPath)
    $terminal = Read-CRUWJournalDocument $terminalFull
    $operationId = [guid]$terminal.payload.operationId
    $terminalSequence = [int]$terminal.payload.sequence
    $state = Get-CRUWJournalPrefixState $PrimaryRoot $SecondaryRoot $operationId $Adapter $terminalSequence
    $failures = [Collections.Generic.List[string]]::new()
    foreach ($failure in @($state.failures)) { $failures.Add([string]$failure) }
    if ((Split-Path -Parent $terminalFull) -cne [IO.Path]::GetFullPath($PrimaryRoot).TrimEnd('\')) { $failures.Add('terminal journal is not inside authoritative primary root') }
    if ($state.entries.Count -ne ($terminalSequence + 1)) { $failures.Add('terminal sequence is not inside the committed common prefix') }
    if ([string]::IsNullOrWhiteSpace([string]$state.latestPrimaryPath) -or [IO.Path]::GetFullPath([string]$state.latestPrimaryPath) -cne $terminalFull) {
        $failures.Add('supplied terminal path is not the requested chain terminal')
    }
    return [ordered]@{
        verified = $failures.Count -eq 0
        failures = @($failures)
        entries = @($state.entries)
        terminal = $terminal
        terminalPayloadSha256 = [string]$terminal.payloadSha256
        entryCount = @($state.entries).Count
        latestCommittedPrimaryPath = $state.latestPrimaryPath
    }
}

function Test-CRUWNativeStorageServiceDrift {
    param([AllowNull()] $Baseline, [AllowNull()] $Current)
    $baselineItems = @($Baseline)
    $currentItems = @($Current)
    $failures = [Collections.Generic.List[string]]::new()
    if ($baselineItems.Count -ne $currentItems.Count) {
        $failures.Add('native storage service set cardinality drifted')
    }
    foreach ($required in @('partmgr', 'disk', 'mtinvme', 'iaStorAC')) {
        if (@($baselineItems | Where-Object { [string]$_.name -ceq $required }).Count -ne 1) {
            $failures.Add("required baseline native service missing/ambiguous: $required")
        }
    }
    $duplicateBaselineNames = @($baselineItems | Group-Object { [string]$_.name } | Where-Object Count -ne 1)
    $duplicateCurrentNames = @($currentItems | Group-Object { [string]$_.name } | Where-Object Count -ne 1)
    if ($duplicateBaselineNames.Count -gt 0 -or $duplicateCurrentNames.Count -gt 0) {
        $failures.Add('native storage service names are duplicated')
    }
    foreach ($expected in $baselineItems) {
        $match = @($currentItems | Where-Object { [string]$_.name -ceq [string]$expected.name })
        if ($match.Count -ne 1) {
            $failures.Add("native service missing/ambiguous: $($expected.name)")
            continue
        }
        $actual = $match[0]
        foreach ($sample in @($expected,$actual)) {
            if (-not [bool]$sample.binaryPresent -or [string]$sample.binarySignatureStatus -ine 'Valid' -or
                [string]$sample.pathSha256 -notmatch '^[A-Fa-f0-9]{64}$' -or [string]$sample.binarySha256 -notmatch '^[A-Fa-f0-9]{64}$' -or
                [string]$sample.registryImagePathSha256 -notmatch '^[A-Fa-f0-9]{64}$' -or
                -not [bool]$sample.pathUnderSystemDrivers -or -not [bool]$sample.pathBasenameMatchesService -or -not [bool]$sample.registryImageMatchesCimPath -or
                [string]$sample.state -ine 'Running' -or -not [bool]$sample.started -or [string]$sample.status -ine 'OK' -or [string]$sample.startMode -ine 'Boot' -or
                [int]$sample.registry.start -ne 0 -or [int]$sample.registry.type -ne 1 -or [int]$sample.registry.errorControl -lt 1 -or
                [string]::IsNullOrWhiteSpace([string]$sample.registry.group)) {
                $failures.Add("native service binary/signature evidence invalid: $($expected.name)")
            }
        }
        foreach ($field in @('state', 'started', 'status', 'startMode', 'pathSha256', 'binaryPresent', 'binarySha256', 'binarySignatureStatus', 'pathUnderSystemDrivers', 'pathBasenameMatchesService', 'registryImagePathSha256', 'registryImageMatchesCimPath')) {
            if ([string](Get-CRUWPropertyValue $actual $field) -cne [string](Get-CRUWPropertyValue $expected $field)) {
                $failures.Add("native service drift: $($expected.name)/$field")
            }
        }
        foreach ($field in @('start', 'type', 'errorControl', 'group')) {
            if ([string](Get-CRUWPropertyValue $actual.registry $field) -cne [string](Get-CRUWPropertyValue $expected.registry $field)) {
                $failures.Add("native service registry drift: $($expected.name)/$field")
            }
        }
        $actualOverride = Get-CRUWPropertyValue $actual.registry 'startOverride'
        $expectedOverride = Get-CRUWPropertyValue $expected.registry 'startOverride'
        $actualOverrideJson = $actualOverride | ConvertTo-Json -Depth 5 -Compress
        $expectedOverrideJson = $expectedOverride | ConvertTo-Json -Depth 5 -Compress
        if ([string]$actualOverrideJson -cne [string]$expectedOverrideJson) {
            $failures.Add("native service StartOverride drift: $($expected.name)")
        }
    }
    return [ordered]@{ verified = $failures.Count -eq 0; baselineCount = $baselineItems.Count; failures = @($failures) }
}

function Get-CRUWPreflightIdentity {
    param($Preflight, $Manifest, [AllowNull()] [string] $RecoveryRoot = $null)

    if (
        [string]$Preflight.driverExport.publishedName -notmatch '^(?i:oem\d+\.inf)$' -or
        [string]$Preflight.driverExport.originalInf -cne 'cruwblocker.inf'
    ) {
        throw 'driver export package names are not the fixed CRUW OEM/original INF identities'
    }

    $snapshotRelativePath = [string]$Preflight.filterSnapshot.relativePath
    if ($snapshotRelativePath -cne 'filter-snapshot-before.json') {
        throw 'filter snapshot relativePath is not the fixed sealed artifact'
    }
    $identityRoot = if ([string]::IsNullOrWhiteSpace($RecoveryRoot)) {
        [string]$Preflight.recoveryPath
    }
    else { [IO.Path]::GetFullPath($RecoveryRoot).TrimEnd('\') }
    $allowedIdentityRoots = @(
        [IO.Path]::GetFullPath([string]$Preflight.recoveryPath).TrimEnd('\'),
        [IO.Path]::GetFullPath([string]$Preflight.secondaryRecoveryPath).TrimEnd('\')
    )
    if ($allowedIdentityRoots -cnotcontains $identityRoot) {
        throw 'filter snapshot identity root is not one of the two manifest-sealed recovery roots'
    }
    $snapshotPath = Resolve-CRUWSafeRelativeFilePath $identityRoot $snapshotRelativePath
    $snapshotHash = (Get-FileHash -LiteralPath $snapshotPath -Algorithm SHA256).Hash
    if ($snapshotHash -ine [string]$Preflight.filterSnapshot.sha256) { throw 'filter-snapshot-before.json hash mismatch' }
    $filterSnapshot = Get-Content -LiteralPath $snapshotPath -Raw -Encoding UTF8 | ConvertFrom-Json
    $filterName = [string]$Preflight.driverBindingDiscovery.lowerFilter

    $headerMatches =
        [string]$filterSnapshot.bootMarkerSha256 -ceq [string]$Preflight.bootIdentity.markerSha256 -and
        [string]$filterSnapshot.publishedName -ceq [string]$Preflight.driverExport.publishedName -and
        [string]$filterSnapshot.diskDriveClassGuid -ceq '{4D36E967-E325-11CE-BFC1-08002BE10318}' -and
        [string]$Preflight.driverExport.className -ceq 'DiskDrive' -and
        $filterName -ceq 'CRUWBlocker'
    if (-not $headerMatches) { throw 'filter snapshot/preflight identity mismatch' }

    $devices = @($Preflight.devices | ForEach-Object {
        [ordered]@{
            instanceIdSha256 = ([string]$_.instanceIdSha256).ToUpperInvariant()
            inf = ([string]$_.inf).ToLowerInvariant()
            provider = [string]$_.provider
            version = [string]$_.version
            lowerFilters = @(ConvertTo-CRUWStringArray $_.lowerFilters)
            upperFilters = @(ConvertTo-CRUWStringArray $_.upperFilters)
        }
    } | Sort-Object instanceIdSha256)
    $invalidDeviceHashes = @($devices | Where-Object { $_.instanceIdSha256 -notmatch '^[A-F0-9]{64}$' })
    $uniqueDeviceHashes = @($devices | ForEach-Object { $_.instanceIdSha256 } | Sort-Object -Unique)
    if (
        $devices.Count -ne [int]$Preflight.driverBindingDiscovery.expectedTargetDeviceCount -or
        $invalidDeviceHashes.Count -gt 0 -or
        $uniqueDeviceHashes.Count -ne $devices.Count
    ) {
        throw 'hashed target device identity invalid'
    }

    $snapshotDevices = @($filterSnapshot.targetDevices)
    if ($snapshotDevices.Count -ne $devices.Count) { throw 'filter snapshot device count mismatch' }
    foreach ($device in $devices) {
        $matchingSnapshotDevices = @($snapshotDevices | Where-Object {
            ([string]$_.instanceIdSha256).ToUpperInvariant() -ceq $device.instanceIdSha256
        })
        $orderedFiltersMatch =
            $matchingSnapshotDevices.Count -eq 1 -and
            (Test-CRUWEqualOrdered $matchingSnapshotDevices[0].lowerFilters $device.lowerFilters) -and
            (Test-CRUWEqualOrdered $matchingSnapshotDevices[0].upperFilters $device.upperFilters)
        if (-not $orderedFiltersMatch) { throw 'filter snapshot/preflight device filter mismatch' }
    }

    $serviceEvidenceMatches =
        [string]$filterSnapshot.service.name -ceq $filterName -and
        [bool]$filterSnapshot.service.ready -and
        [bool]$filterSnapshot.service.binaryPresent -and
        [bool]$filterSnapshot.service.imagePathVerified -and
        [bool]$filterSnapshot.service.binaryMatchesExport -and
        [int]$filterSnapshot.service.start -eq 0 -and
        [int]$filterSnapshot.service.type -eq 1 -and
        [string]$filterSnapshot.service.exportedDriverSignatureStatus -ieq 'Valid' -and
        [string]$filterSnapshot.service.exportedCatalogSignatureStatus -ieq 'Valid' -and
        [string]$filterSnapshot.service.binarySha256 -ieq [string]$Manifest.driverIdentity.exportedDriverSha256
    if (-not $serviceEvidenceMatches) { throw 'filter service snapshot does not cross-check with manifest' }

    $volumes = @($Preflight.storageLayout.volumes | ForEach-Object {
        [ordered]@{
            mountPoint = ([string]$_.driveLetter).TrimEnd(':').ToUpperInvariant() + ':'
            deviceInstanceIdSha256 = ([string]$_.deviceInstanceIdSha256).ToUpperInvariant()
        }
    } | Sort-Object mountPoint)
    $volumeIds = @($volumes | ForEach-Object { [string]$_.deviceInstanceIdSha256 })
    $volumeMounts = @($volumes | ForEach-Object { [string]$_.mountPoint })
    $deviceIds = @($devices | ForEach-Object { [string]$_.instanceIdSha256 })
    $volumeMappingValid =
        $volumes.Count -eq 2 -and
        (Test-CRUWEqualSet $volumeMounts @('C:', 'D:')) -and
        @($volumeIds | Sort-Object -Unique).Count -eq 2 -and
        @($volumeIds | Where-Object { $deviceIds -cnotcontains $_ }).Count -eq 0
    if (-not $volumeMappingValid) { throw 'sealed C/D volume-to-device identity mapping invalid' }

    $document = [ordered]@{
        publishedName = ([string]$Preflight.driverExport.publishedName).ToLowerInvariant()
        filterName = $filterName
        originalInf = ([string]$Preflight.driverExport.originalInf).ToLowerInvariant()
        provider = [string]$Preflight.driverExport.provider
        className = [string]$Preflight.driverExport.className
        version = [string]$Preflight.driverExport.version
        serviceBinarySha256 = ([string]$Manifest.driverIdentity.exportedDriverSha256).ToUpperInvariant()
        classFilters = [ordered]@{
            lowerFilters = @(ConvertTo-CRUWStringArray $filterSnapshot.classFilters.lowerFilters)
            upperFilters = @(ConvertTo-CRUWStringArray $filterSnapshot.classFilters.upperFilters)
        }
        service = $filterSnapshot.service
        devices = $devices
        volumes = $volumes
    }
    return [ordered]@{ document = $document; sha256 = Get-CRUWObjectSha256 $document }
}

function Get-CRUWStateClassification {
    param(
        $Snapshot,
        $ExpectedIdentity,
        [string[]] $RequiredMountPoints,
        [ValidateSet('Preboot', 'Postboot')]
        [string] $Phase = 'Preboot'
    )

    $expectedIds = @($ExpectedIdentity.devices | ForEach-Object { ([string]$_.instanceIdSha256).ToUpperInvariant() })
    $allDevices = @($Snapshot.devices)
    $targetDevices = @($allDevices | Where-Object {
        $expectedIds -ccontains ([string]$_.instanceIdSha256).ToUpperInvariant()
    })
    $targetIdentityFailures = @($expectedIds | Where-Object {
        $expectedId = $_
        @($targetDevices | Where-Object { ([string]$_.instanceIdSha256).ToUpperInvariant() -ceq $expectedId }).Count -ne 1
    })
    $targetsPresent =
        $expectedIds.Count -eq 2 -and
        $allDevices.Count -eq $expectedIds.Count -and
        $targetDevices.Count -eq $expectedIds.Count -and
        $targetIdentityFailures.Count -eq 0
    $devicesHealthy = $targetsPresent -and @($targetDevices | Where-Object { [string]$_.status -ine 'OK' }).Count -eq 0

    $physicalDisks = @($Snapshot.physicalDisks)
    $unhealthyPhysicalDisks = @($physicalDisks | Where-Object {
        [string]$_.healthStatus -ine 'Healthy' -or
        @(ConvertTo-CRUWStringArray $_.operationalStatus).Count -ne 1 -or
        -not (Test-CRUWEqualSet (ConvertTo-CRUWStringArray $_.operationalStatus) @('OK'))
    })
    $physicalDisksHealthy = $physicalDisks.Count -eq $expectedIds.Count -and $unhealthyPhysicalDisks.Count -eq 0

    $requiredMounts = @($RequiredMountPoints | ForEach-Object { $_.TrimEnd(':').ToUpperInvariant() + ':' } | Sort-Object -Unique)
    $volumes = @($Snapshot.volumes)
    $volumeFailures = [Collections.Generic.List[string]]::new()
    if ($volumes.Count -ne $requiredMounts.Count) { $volumeFailures.Add('volume count') }
    foreach ($requiredMount in $requiredMounts) {
        $matchingVolumes = @($volumes | Where-Object { ([string]$_.mountPoint).ToUpperInvariant() -ceq $requiredMount })
        if ($matchingVolumes.Count -ne 1) {
            $volumeFailures.Add("$requiredMount identity")
            continue
        }
        $volume = $matchingVolumes[0]
        $volumeOperationalValues = @(ConvertTo-CRUWStringArray $volume.operationalStatus)
        $diskOperationalValues = @(ConvertTo-CRUWStringArray $volume.diskOperationalStatus)
        $volumeOperational = $volumeOperationalValues.Count -eq 1 -and (Test-CRUWEqualSet $volumeOperationalValues @('OK'))
        $diskOperational = $diskOperationalValues.Count -eq 1 -and (Test-CRUWEqualSet $diskOperationalValues @('Online'))
        if (
            [string]$volume.healthStatus -ine 'Healthy' -or
            -not $volumeOperational -or
            [bool]$volume.readOnly -or
            [bool]$volume.offline -or
            [string]$volume.fileSystem -ine 'NTFS' -or
            [string]$volume.diskHealthStatus -ine 'Healthy' -or
            -not $diskOperational -or
            [string]$volume.pnpStatus -ine 'OK' -or
            [int]$volume.pnpProblemCode -ne 0
        ) {
            $volumeFailures.Add("$requiredMount health")
        }
    }
    $volumesHealthy = $volumeFailures.Count -eq 0

    $mappedIds = @($volumes | ForEach-Object { ([string]$_.deviceInstanceIdSha256).ToUpperInvariant() })
    $mappedDiskNumbers = @($volumes | ForEach-Object { [int]$_.diskNumber })
    $mappingExact = $true
    $controllerChainExact = $true
    foreach ($expectedVolume in @($ExpectedIdentity.volumes)) {
        $matchingVolumes = @($volumes | Where-Object {
            ([string]$_.mountPoint).ToUpperInvariant() -ceq ([string]$expectedVolume.mountPoint).ToUpperInvariant()
        })
        if (
            $matchingVolumes.Count -ne 1 -or
            ([string]$matchingVolumes[0].deviceInstanceIdSha256).ToUpperInvariant() -cne ([string]$expectedVolume.deviceInstanceIdSha256).ToUpperInvariant()
        ) {
            $mappingExact = $false
        }
        if ($matchingVolumes.Count -eq 1) {
            $requiredControllerService = if ([string]$expectedVolume.mountPoint -ceq 'C:') { 'mtinvme' } else { 'iaStorAC' }
            $oppositeControllerService = if ([string]$expectedVolume.mountPoint -ceq 'C:') { 'iaStorAC' } else { 'mtinvme' }
            $parentServices = @($matchingVolumes[0].parentServiceChain | ForEach-Object { [string]$_.service })
            $parentIds = @($matchingVolumes[0].parentServiceChain | ForEach-Object { [string]$_.instanceIdSha256 } | Where-Object { -not [string]::IsNullOrWhiteSpace($_) })
            if (
                @($parentServices | Where-Object { $_ -ieq $requiredControllerService }).Count -ne 1 -or
                @($parentServices | Where-Object { $_ -ieq $oppositeControllerService }).Count -ne 0 -or
                -not [bool]$matchingVolumes[0].parentChainTerminated -or
                -not [bool]$matchingVolumes[0].parentChainNoCycle -or
                [bool]$matchingVolumes[0].parentChainTruncated -or
                @($parentIds | Sort-Object -Unique).Count -ne $parentIds.Count
            ) { $controllerChainExact = $false }
        }
    }
    $topologyExact =
        $volumesHealthy -and
        $mappingExact -and
        $controllerChainExact -and
        @($mappedIds | Sort-Object -Unique).Count -eq $expectedIds.Count -and
        @($mappedIds | Where-Object { $expectedIds -cnotcontains $_ }).Count -eq 0 -and
        @($mappedDiskNumbers | Sort-Object -Unique).Count -eq $expectedIds.Count

    $instanceFiltersPreserved = $targetsPresent
    $cleanInstanceFilters = $targetsPresent
    foreach ($expectedDevice in @($ExpectedIdentity.devices)) {
        $actualDevices = @($targetDevices | Where-Object {
            ([string]$_.instanceIdSha256).ToUpperInvariant() -ceq ([string]$expectedDevice.instanceIdSha256).ToUpperInvariant()
        })
        if ($actualDevices.Count -ne 1) {
            $instanceFiltersPreserved = $false
            $cleanInstanceFilters = $false
            continue
        }
        $actualDevice = $actualDevices[0]
        $expectedLowerWithoutCruw = Remove-CRUWFilterReference $expectedDevice.lowerFilters $ExpectedIdentity.filterName
        $expectedUpperWithoutCruw = Remove-CRUWFilterReference $expectedDevice.upperFilters $ExpectedIdentity.filterName
        $actualLowerWithoutCruw = Remove-CRUWFilterReference $actualDevice.lowerFilters $ExpectedIdentity.filterName
        $actualUpperWithoutCruw = Remove-CRUWFilterReference $actualDevice.upperFilters $ExpectedIdentity.filterName
        if (
            -not (Test-CRUWEqualOrdered $actualLowerWithoutCruw $expectedLowerWithoutCruw) -or
            -not (Test-CRUWEqualOrdered $actualUpperWithoutCruw $expectedUpperWithoutCruw)
        ) {
            $instanceFiltersPreserved = $false
        }
        if (
            -not (Test-CRUWEqualOrdered $actualDevice.lowerFilters $expectedLowerWithoutCruw) -or
            -not (Test-CRUWEqualOrdered $actualDevice.upperFilters $expectedUpperWithoutCruw)
        ) {
            $cleanInstanceFilters = $false
        }
    }

    $expectedClassLowerWithoutCruw = Remove-CRUWFilterReference $ExpectedIdentity.classFilters.lowerFilters $ExpectedIdentity.filterName
    $expectedClassUpperWithoutCruw = Remove-CRUWFilterReference $ExpectedIdentity.classFilters.upperFilters $ExpectedIdentity.filterName
    $actualClassLowerWithoutCruw = Remove-CRUWFilterReference $Snapshot.classFilters.lowerFilters $ExpectedIdentity.filterName
    $actualClassUpperWithoutCruw = Remove-CRUWFilterReference $Snapshot.classFilters.upperFilters $ExpectedIdentity.filterName
    $classFiltersPreserved =
        (Test-CRUWEqualOrdered $actualClassLowerWithoutCruw $expectedClassLowerWithoutCruw) -and
        (Test-CRUWEqualOrdered $actualClassUpperWithoutCruw $expectedClassUpperWithoutCruw)
    $cleanClassFilters =
        (Test-CRUWEqualOrdered $Snapshot.classFilters.lowerFilters $expectedClassLowerWithoutCruw) -and
        (Test-CRUWEqualOrdered $Snapshot.classFilters.upperFilters $expectedClassUpperWithoutCruw)

    $devicesWithCruwReferences = @($allDevices | Where-Object {
        @(ConvertTo-CRUWStringArray $_.lowerFilters | Where-Object { $_ -ieq $ExpectedIdentity.filterName }).Count -gt 0 -or
        @(ConvertTo-CRUWStringArray $_.upperFilters | Where-Object { $_ -ieq $ExpectedIdentity.filterName }).Count -gt 0
    })
    $classLowerCruwReferences = @(ConvertTo-CRUWStringArray $Snapshot.classFilters.lowerFilters | Where-Object { $_ -ieq $ExpectedIdentity.filterName })
    $classUpperCruwReferences = @(ConvertTo-CRUWStringArray $Snapshot.classFilters.upperFilters | Where-Object { $_ -ieq $ExpectedIdentity.filterName })
    $zeroCruwReferences =
        $allDevices.Count -eq $expectedIds.Count -and
        $devicesWithCruwReferences.Count -eq 0 -and
        $classLowerCruwReferences.Count -eq 0 -and
        $classUpperCruwReferences.Count -eq 0

    $nonNativeTargetDevices = @($targetDevices | Where-Object {
        [string]$_.inf -ine 'disk.inf' -or [string]$_.provider -cne 'Microsoft'
    })
    $nativeDiskDrivers =
        $targetsPresent -and
        [bool]$Snapshot.nativeFallbackPackagePresent -and
        $nonNativeTargetDevices.Count -eq 0

    $packages = @($Snapshot.packages)
    $legacyPackageExact =
        $packages.Count -eq 1 -and
        [string]$packages[0].originalInf -ieq $ExpectedIdentity.originalInf -and
        [string]$packages[0].provider -ceq $ExpectedIdentity.provider -and
        [string]$packages[0].className -ceq $ExpectedIdentity.className -and
        [string]$packages[0].version -ceq $ExpectedIdentity.version
    $legacyPublishedName = if ($legacyPackageExact) { [string]$packages[0].publishedName } else { $null }
    $legacyClassFiltersExact =
        $targetsPresent -and
        (Test-CRUWEqualOrdered $Snapshot.classFilters.lowerFilters $ExpectedIdentity.classFilters.lowerFilters) -and
        (Test-CRUWEqualOrdered $Snapshot.classFilters.upperFilters $ExpectedIdentity.classFilters.upperFilters)

    $legacyDevicesExact = $targetsPresent
    foreach ($expectedDevice in @($ExpectedIdentity.devices)) {
        $actualDevices = @($targetDevices | Where-Object {
            ([string]$_.instanceIdSha256).ToUpperInvariant() -ceq ([string]$expectedDevice.instanceIdSha256).ToUpperInvariant()
        })
        if ($actualDevices.Count -ne 1) {
            $legacyDevicesExact = $false
            continue
        }
        $actualDevice = $actualDevices[0]
        if (
            [string]$actualDevice.inf -ine $legacyPublishedName -or
            [string]$actualDevice.provider -cne $expectedDevice.provider -or
            [string]$actualDevice.version -cne $expectedDevice.version -or
            -not (Test-CRUWEqualOrdered $actualDevice.lowerFilters $expectedDevice.lowerFilters) -or
            -not (Test-CRUWEqualOrdered $actualDevice.upperFilters $expectedDevice.upperFilters)
        ) {
            $legacyDevicesExact = $false
        }
    }

    $actualServiceImage = ([string]$Snapshot.service.imagePath).Replace('/', '\').Trim()
    $expectedServiceImage = ([string]$ExpectedIdentity.service.imagePath).Replace('/', '\').Trim()
    $legacyServiceReady =
        [bool]$Snapshot.service.exists -and
        [string]$Snapshot.service.state -ieq 'Running' -and
        [int]$Snapshot.service.start -eq 0 -and
        [int]$Snapshot.service.type -eq 1 -and
        [bool]$Snapshot.service.binaryPresent -and
        [string]$Snapshot.service.binarySha256 -ieq $ExpectedIdentity.serviceBinarySha256 -and
        $actualServiceImage -ieq $expectedServiceImage

    $residualPackageKnown = $packages.Count -eq 0 -or $legacyPackageExact
    $serviceFullyAbsent = -not [bool]$Snapshot.service.exists -and -not [bool]$Snapshot.service.binaryPresent
    $residualServiceKnown = $serviceFullyAbsent -or $legacyServiceReady

    $healthy = $devicesHealthy -and $physicalDisksHealthy -and $volumesHealthy -and $topologyExact
    $legacyIntact =
        $healthy -and
        $legacyPackageExact -and
        $legacyServiceReady -and
        $legacyClassFiltersExact -and
        $legacyDevicesExact
    $cleanPreboot =
        $healthy -and
        $instanceFiltersPreserved -and
        $classFiltersPreserved -and
        $cleanInstanceFilters -and
        $cleanClassFilters -and
        $zeroCruwReferences -and
        $nativeDiskDrivers -and
        $residualPackageKnown -and
        $residualServiceKnown
    $cleanPostboot =
        $cleanPreboot -and
        $packages.Count -eq 0 -and
        -not [bool]$Snapshot.service.exists -and
        -not [bool]$Snapshot.service.binaryPresent

    $classification = if (-not $healthy) {
        'BROKEN'
    }
    elseif ($legacyIntact) {
        'LEGACY_INTACT'
    }
    elseif (-not $instanceFiltersPreserved -or -not $classFiltersPreserved) {
        'BROKEN'
    }
    elseif ($Phase -eq 'Preboot' -and $cleanPreboot) {
        'CLEAN_PREBOOT'
    }
    elseif ($Phase -eq 'Postboot' -and $cleanPostboot) {
        'CLEAN'
    }
    elseif ($zeroCruwReferences -and -not $nativeDiskDrivers) {
        'BROKEN'
    }
    else {
        'TRANSITION'
    }

    return [ordered]@{
        classification = $classification
        healthy = $healthy
        gates = [ordered]@{
            exactlyTwoDiskDevices = $allDevices.Count -eq 2
            targetDevicesPresent = $targetsPresent
            deviceHealthy = $devicesHealthy
            physicalHealthy = $physicalDisksHealthy
            volumesHealthy = $volumesHealthy
            topologyExact = $topologyExact
            controllerParentChainsExact = $controllerChainExact
            instanceFiltersPreserved = $instanceFiltersPreserved
            classFiltersPreserved = $classFiltersPreserved
            cleanInstanceFilters = $cleanInstanceFilters
            cleanClassFilters = $cleanClassFilters
            zeroCruwReferences = $zeroCruwReferences
            nativeDiskDrivers = $nativeDiskDrivers
            nativeFallbackPackagePresent = [bool]$Snapshot.nativeFallbackPackagePresent
            legacyPackageExact = $legacyPackageExact
            legacyPublishedName = $legacyPublishedName
            legacyServiceReady = $legacyServiceReady
            residualPackageKnown = $residualPackageKnown
            residualServiceKnown = $residualServiceKnown
            legacyFiltersExact = $legacyClassFiltersExact
            legacyDevicesExact = $legacyDevicesExact
            cleanPreboot = $cleanPreboot
            cleanPostboot = $cleanPostboot
        }
    }
}
