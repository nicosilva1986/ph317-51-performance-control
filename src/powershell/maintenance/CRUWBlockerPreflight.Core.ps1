function Get-CruwPropertyValue {
    param(
        [AllowNull()] $InputObject,
        [Parameter(Mandatory)] [string] $Name
    )

    if ($null -eq $InputObject) { return $null }
    $property = $InputObject.PSObject.Properties[$Name]
    if ($null -eq $property) { return $null }
    return $property.Value
}

function Test-CruwStringEqual {
    param(
        [AllowNull()] $Left,
        [AllowNull()] $Right
    )

    return [string]::Equals([string]$Left, [string]$Right, [StringComparison]::OrdinalIgnoreCase)
}

function Test-CruwLatestRestorePointMatch {
    [CmdletBinding()]
    param(
        [Parameter(Mandatory)] [AllowEmptyCollection()] [object[]] $UsableNamedRestore,
        [Parameter(Mandatory)] [AllowEmptyCollection()] [object[]] $LatestRestore
    )

    if ($UsableNamedRestore.Count -ne 1 -or $LatestRestore.Count -ne 1) {
        return $false
    }

    $usableSequence = Get-CruwPropertyValue -InputObject $UsableNamedRestore[0] -Name 'SequenceNumber'
    $latestSequence = Get-CruwPropertyValue -InputObject $LatestRestore[0] -Name 'SequenceNumber'
    if ($null -eq $usableSequence -or $null -eq $latestSequence) {
        return $false
    }

    return [long]$usableSequence -gt 0 -and [long]$usableSequence -eq [long]$latestSequence
}

function Get-CruwLatestRestorePointBySequence {
    [CmdletBinding()]
    param(
        [Parameter(Mandatory)] [AllowEmptyCollection()] [object[]] $RestorePoints
    )

    $valid = @($RestorePoints | Where-Object {
        $sequenceText = [string](Get-CruwPropertyValue -InputObject $_ -Name 'SequenceNumber')
        $sequence = 0L
        [long]::TryParse($sequenceText, [ref]$sequence) -and $sequence -gt 0
    })
    if ($valid.Count -eq 0) { return }
    $maximumSequence = [long](($valid | ForEach-Object {
        [long](Get-CruwPropertyValue -InputObject $_ -Name 'SequenceNumber')
    } | Measure-Object -Maximum).Maximum)
    $maximumRecords = @($valid | Where-Object {
        [long](Get-CruwPropertyValue -InputObject $_ -Name 'SequenceNumber') -eq $maximumSequence
    })
    if ($maximumRecords.Count -ne 1) { return }
    return $maximumRecords[0]
}

function Get-CruwSha256Text {
    param([Parameter(Mandatory)] [string] $Text)

    $sha = [Security.Cryptography.SHA256]::Create()
    try {
        $bytes = [Text.Encoding]::UTF8.GetBytes($Text)
        return ([BitConverter]::ToString($sha.ComputeHash($bytes))).Replace('-', '')
    }
    finally {
        $sha.Dispose()
    }
}

function Get-CruwCanonicalWinReLocationSha256 {
    [CmdletBinding()]
    param([Parameter(Mandatory)] [string] $Location)

    $canonical = $Location.Trim().Replace('/', '\').TrimEnd('\').ToLowerInvariant()
    if ($canonical -notmatch '^\\\\\?\\globalroot\\device\\harddisk\d+\\partition\d+\\recovery\\windowsre$') {
        throw 'WinRE location is not an exact canonical GLOBALROOT recovery path'
    }
    return Get-CruwSha256Text -Text $canonical
}

function ConvertTo-CruwCanonicalServiceImagePath {
    [CmdletBinding()]
    param([Parameter(Mandatory)] [string] $ImagePath)

    $trimmed = $ImagePath.Trim().Replace('/', '\')
    if ($trimmed -notmatch '(?i)^(?:\\SystemRoot\\)?System32\\drivers\\CRUWBlocker\.sys$') {
        throw 'CRUWBlocker ImagePath is not one of the two exact Windows system-root forms'
    }
    return '\SystemRoot\System32\drivers\CRUWBlocker.sys'
}

function Assert-CruwLocalRecoveryPathBeforeWrite {
    [CmdletBinding()]
    param(
        [Parameter(Mandatory)] [string] $CandidatePath,
        [Parameter(Mandatory)] [string] $AllowedBasePath,
        [Parameter(Mandatory)] [ValidatePattern('^[A-Za-z]:$')] [string] $ExpectedDrive,
        [switch] $RequireFinalLeafFile
    )

    foreach ($rawPath in @($CandidatePath, $AllowedBasePath)) {
        if ($rawPath -notmatch '^[A-Za-z]:\\' -or $rawPath.Substring(2) -match ':') {
            throw "Recovery path must be a local drive path without an alternate data stream: $rawPath"
        }
    }

    $candidate = [IO.Path]::GetFullPath($CandidatePath).TrimEnd('\')
    $allowedBase = [IO.Path]::GetFullPath($AllowedBasePath).TrimEnd('\')
    $expectedRoot = $ExpectedDrive.ToUpperInvariant() + '\'
    if (-not [string]::Equals([IO.Path]::GetPathRoot($candidate), $expectedRoot, [StringComparison]::OrdinalIgnoreCase) -or
        -not [string]::Equals([IO.Path]::GetPathRoot($allowedBase), $expectedRoot, [StringComparison]::OrdinalIgnoreCase)) {
        throw "Recovery path is not rooted on expected local drive $ExpectedDrive"
    }
    if (-not $candidate.StartsWith($allowedBase + '\', [StringComparison]::OrdinalIgnoreCase)) {
        throw "Recovery path escapes its fixed local parent: $candidate"
    }

    $current = $expectedRoot
    $relativeComponents = @($candidate.Substring($expectedRoot.Length).Split([char]'\') | Where-Object { $_.Length -gt 0 })
    for ($componentIndex = 0; $componentIndex -lt $relativeComponents.Count; $componentIndex++) {
        $component = $relativeComponents[$componentIndex]
        $current = Join-Path $current $component
        if (-not (Test-Path -LiteralPath $current)) {
            break
        }
        $item = Get-Item -LiteralPath $current -Force -ErrorAction Stop
        if (($item.Attributes -band [IO.FileAttributes]::ReparsePoint) -ne 0) {
            throw "Recovery path contains a reparse-point component: $current"
        }
        $isFinalComponent = $componentIndex -eq ($relativeComponents.Count - 1)
        if (-not $item.PSIsContainer -and -not ($RequireFinalLeafFile -and $isFinalComponent)) {
            throw "Recovery path ancestor is not a directory: $current"
        }
    }

    if ($RequireFinalLeafFile) {
        $leaf = Get-Item -LiteralPath $candidate -Force -ErrorAction Stop
        if ($leaf.PSIsContainer -or ($leaf.Attributes -band [IO.FileAttributes]::ReparsePoint) -ne 0) {
            throw "Recovery path final leaf is not an exact non-reparse file: $candidate"
        }
    }

    return $candidate
}

function Initialize-CruwDirectoryAnchorNative {
    if ('CruwDirectoryAnchorNative' -as [type]) { return }

    Add-Type -TypeDefinition @'
using System;
using System.ComponentModel;
using System.Runtime.InteropServices;
using Microsoft.Win32.SafeHandles;

public sealed class CruwDirectoryAnchorRecord : IDisposable
{
    public string Path { get; private set; }
    public string Identity { get; private set; }
    public SafeFileHandle Handle { get; private set; }

    internal CruwDirectoryAnchorRecord(string path, string identity, SafeFileHandle handle)
    {
        Path = path;
        Identity = identity;
        Handle = handle;
    }

    public void Dispose()
    {
        if (Handle != null) { Handle.Dispose(); }
    }
}

public static class CruwDirectoryAnchorNative
{
    private const uint FILE_READ_ATTRIBUTES = 0x00000080;
    private const uint DELETE = 0x00010000;
    private const uint FILE_SHARE_READ = 0x00000001;
    private const uint FILE_SHARE_WRITE = 0x00000002;
    private const uint OPEN_EXISTING = 3;
    private const uint FILE_FLAG_OPEN_REPARSE_POINT = 0x00200000;
    private const uint FILE_FLAG_BACKUP_SEMANTICS = 0x02000000;
    private const uint FILE_ATTRIBUTE_DIRECTORY = 0x00000010;
    private const uint FILE_ATTRIBUTE_REPARSE_POINT = 0x00000400;

    [StructLayout(LayoutKind.Sequential)]
    private struct BY_HANDLE_FILE_INFORMATION
    {
        public uint FileAttributes;
        public System.Runtime.InteropServices.ComTypes.FILETIME CreationTime;
        public System.Runtime.InteropServices.ComTypes.FILETIME LastAccessTime;
        public System.Runtime.InteropServices.ComTypes.FILETIME LastWriteTime;
        public uint VolumeSerialNumber;
        public uint FileSizeHigh;
        public uint FileSizeLow;
        public uint NumberOfLinks;
        public uint FileIndexHigh;
        public uint FileIndexLow;
    }

    [DllImport("kernel32.dll", CharSet = CharSet.Unicode, SetLastError = true)]
    private static extern SafeFileHandle CreateFileW(
        string fileName,
        uint desiredAccess,
        uint shareMode,
        IntPtr securityAttributes,
        uint creationDisposition,
        uint flagsAndAttributes,
        IntPtr templateFile);

    [DllImport("kernel32.dll", SetLastError = true)]
    [return: MarshalAs(UnmanagedType.Bool)]
    private static extern bool GetFileInformationByHandle(
        SafeFileHandle file,
        out BY_HANDLE_FILE_INFORMATION information);

    public static CruwDirectoryAnchorRecord Open(string path)
    {
        SafeFileHandle handle = CreateFileW(
            path,
            FILE_READ_ATTRIBUTES | DELETE,
            FILE_SHARE_READ | FILE_SHARE_WRITE,
            IntPtr.Zero,
            OPEN_EXISTING,
            FILE_FLAG_BACKUP_SEMANTICS | FILE_FLAG_OPEN_REPARSE_POINT,
            IntPtr.Zero);
        if (handle.IsInvalid)
        {
            int error = Marshal.GetLastWin32Error();
            handle.Dispose();
            throw new Win32Exception(error, "Could not anchor recovery directory without FILE_SHARE_DELETE");
        }

        BY_HANDLE_FILE_INFORMATION information;
        if (!GetFileInformationByHandle(handle, out information))
        {
            int error = Marshal.GetLastWin32Error();
            handle.Dispose();
            throw new Win32Exception(error, "Could not read anchored recovery directory identity");
        }
        if ((information.FileAttributes & FILE_ATTRIBUTE_DIRECTORY) == 0 ||
            (information.FileAttributes & FILE_ATTRIBUTE_REPARSE_POINT) != 0)
        {
            handle.Dispose();
            throw new InvalidOperationException("Recovery anchor is not an exact non-reparse directory");
        }

        ulong fileIndex = ((ulong)information.FileIndexHigh << 32) | information.FileIndexLow;
        string identity = information.VolumeSerialNumber.ToString("X8") + ":" + fileIndex.ToString("X16");
        return new CruwDirectoryAnchorRecord(path, identity, handle);
    }
}
'@
}

function Enter-CruwDirectoryAnchorChain {
    [CmdletBinding()]
    param(
        [Parameter(Mandatory)] [string] $DirectoryPath,
        [Parameter(Mandatory)] [string] $AnchorBasePath,
        [Parameter(Mandatory)] [ValidatePattern('^[A-Za-z]:$')] [string] $ExpectedDrive
    )

    if ($DirectoryPath -notmatch '^[A-Za-z]:\\' -or $DirectoryPath.Substring(2) -match ':') {
        throw 'Recovery anchor path must be a local drive path without an alternate data stream'
    }
    $fullPath = [IO.Path]::GetFullPath($DirectoryPath).TrimEnd('\')
    $baseFull = [IO.Path]::GetFullPath($AnchorBasePath).TrimEnd('\')
    $expectedRoot = $ExpectedDrive.ToUpperInvariant() + '\'
    if (-not [string]::Equals([IO.Path]::GetPathRoot($fullPath), $expectedRoot, [StringComparison]::OrdinalIgnoreCase) -or
        -not [string]::Equals([IO.Path]::GetPathRoot($baseFull), $expectedRoot, [StringComparison]::OrdinalIgnoreCase) -or
        (-not [string]::Equals($fullPath, $baseFull, [StringComparison]::OrdinalIgnoreCase) -and
            -not $fullPath.StartsWith($baseFull + '\', [StringComparison]::OrdinalIgnoreCase))) {
        throw "Recovery anchor path is not rooted on expected drive $ExpectedDrive"
    }

    Initialize-CruwDirectoryAnchorNative
    $anchors = [Collections.Generic.List[object]]::new()
    try {
        $pathsToAnchor = [Collections.Generic.List[string]]::new()
        $pathsToAnchor.Add($baseFull)
        if (-not [string]::Equals($fullPath, $baseFull, [StringComparison]::OrdinalIgnoreCase)) {
            $current = $baseFull
            $components = @($fullPath.Substring($baseFull.Length + 1).Split([char]'\') | Where-Object { $_.Length -gt 0 })
            foreach ($component in $components) {
                $current = Join-Path $current $component
                $pathsToAnchor.Add($current)
            }
        }
        foreach ($current in $pathsToAnchor) {
            $item = Get-Item -LiteralPath $current -Force -ErrorAction Stop
            if (-not $item.PSIsContainer -or ($item.Attributes -band [IO.FileAttributes]::ReparsePoint) -ne 0) {
                throw "Recovery anchor component is not an exact non-reparse directory: $current"
            }
            $anchor = [CruwDirectoryAnchorNative]::Open([IO.Path]::GetFullPath($current).TrimEnd('\'))
            $anchors.Add($anchor)
            $itemAfter = Get-Item -LiteralPath $current -Force -ErrorAction Stop
            if (-not $itemAfter.PSIsContainer -or ($itemAfter.Attributes -band [IO.FileAttributes]::ReparsePoint) -ne 0) {
                throw "Recovery anchor component changed while it was opened: $current"
            }
        }
        return @($anchors.ToArray())
    }
    catch {
        foreach ($anchor in @($anchors)) { $anchor.Dispose() }
        throw
    }
}

function Exit-CruwDirectoryAnchorChain {
    [CmdletBinding()]
    param([Parameter(Mandatory)] [AllowEmptyCollection()] [object[]] $Anchors)

    for ($index = $Anchors.Count - 1; $index -ge 0; $index--) {
        if ($null -ne $Anchors[$index]) { $Anchors[$index].Dispose() }
    }
}

function Get-CruwSetupApiPromotionEvidence {
    [CmdletBinding()]
    param(
        [Parameter(Mandatory)] [string] $InfDirectory,
        [string] $ExactPhrase = "Updated service 'cruwblocker' to be boot start."
    )

    $directory = Get-Item -LiteralPath $InfDirectory -Force -ErrorAction Stop
    if (-not $directory.PSIsContainer -or ($directory.Attributes -band [IO.FileAttributes]::ReparsePoint) -ne 0) {
        throw 'SetupAPI evidence directory must be a non-reparse directory'
    }

    $evidence = @()
    $logs = @(Get-ChildItem -LiteralPath $directory.FullName -File -Force -ErrorAction Stop | Where-Object {
        $_.Name -cmatch '^setupapi\.dev\.\d{8}_\d{6}\.log$'
    } | Sort-Object Name)
    foreach ($log in $logs) {
        if (($log.Attributes -band [IO.FileAttributes]::ReparsePoint) -ne 0) {
            throw "SetupAPI evidence log must not be a reparse point: $($log.Name)"
        }
        $hashBefore = [string](Get-FileHash -LiteralPath $log.FullName -Algorithm SHA256 -ErrorAction Stop).Hash
        $matches = @(Select-String -LiteralPath $log.FullName -SimpleMatch -Pattern $ExactPhrase -ErrorAction Stop)
        $itemAfter = Get-Item -LiteralPath $log.FullName -Force -ErrorAction Stop
        $hashAfter = [string](Get-FileHash -LiteralPath $log.FullName -Algorithm SHA256 -ErrorAction Stop).Hash
        if (-not [string]::Equals($hashBefore, $hashAfter, [StringComparison]::OrdinalIgnoreCase) -or
            [long]$log.Length -ne [long]$itemAfter.Length) {
            throw "SetupAPI evidence log changed while it was inspected: $($log.Name)"
        }
        if ($matches.Count -gt 0) {
            $evidence += [pscustomobject]@{
                FileName = [string]$log.Name
                Sha256 = $hashAfter
                Length = [long]$itemAfter.Length
                MatchCount = [int]$matches.Count
            }
        }
    }
    return @($evidence)
}

function Get-CruwRollbackCapabilityContract {
    [CmdletBinding()]
    param(
        [Parameter(Mandatory)] [string] $InfText,
        [Parameter(Mandatory)] [bool] $ExportedPackageVerified,
        [Parameter(Mandatory)] [string] $ExportedInfSha256,
        [Parameter(Mandatory)] $LiveService,
        [Parameter(Mandatory)] [AllowEmptyCollection()] [object[]] $PromotionEvidence
    )

    $failures = [Collections.Generic.List[string]]::new()
    $readInfValue = {
        param([string] $SectionName, [string] $KeyName)

        $sectionPattern = '(?ims)^\s*\[' + [regex]::Escape($SectionName) + '\]\s*\r?\n(?<body>.*?)(?=^\s*\[|\z)'
        $sectionMatches = [regex]::Matches($InfText, $sectionPattern)
        if ($sectionMatches.Count -ne 1) { return $null }
        $body = $sectionMatches[0].Groups['body'].Value
        $keyPattern = '(?im)^\s*' + [regex]::Escape($KeyName) + '\s*=\s*(?<value>[^;\r\n]+?)\s*(?:;.*)?$'
        $keyMatches = [regex]::Matches($body, $keyPattern)
        if ($keyMatches.Count -ne 1) { return $null }
        return $keyMatches[0].Groups['value'].Value.Trim()
    }

    $addService = & $readInfValue 'CRUWBlocker_install.NT.Services' 'AddService'
    $addServiceParts = if ($null -ne $addService) { @([string]$addService -split ',' | ForEach-Object { $_.Trim() }) } else { @() }
    $serviceName = if ($addServiceParts.Count -eq 3) { $addServiceParts[0] } else { $null }
    $addServiceFlags = if ($addServiceParts.Count -eq 3) { $addServiceParts[1] } else { $null }
    $serviceSection = if ($addServiceParts.Count -eq 3) { $addServiceParts[2] } else { $null }
    if (-not (Test-CruwStringEqual $serviceName 'CRUWBlocker') -or
        $null -eq $addServiceFlags -or $addServiceFlags.Length -ne 0 -or
        -not (Test-CruwStringEqual $serviceSection 'CRUWBlocker_ServiceInstallSection')) {
        $failures.Add('INF AddService does not identify the exact zero-flags CRUWBlocker service section')
    }

    $servicesInclude = & $readInfValue 'CRUWBlocker_install.NT.Services' 'Include'
    $servicesNeeds = & $readInfValue 'CRUWBlocker_install.NT.Services' 'Needs'
    if (-not (Test-CruwStringEqual $servicesInclude 'disk.inf') -or
        -not (Test-CruwStringEqual $servicesNeeds 'disk_install.NT.Services')) {
        $failures.Add('INF service install does not inherit the exact Microsoft disk service contract')
    }

    $serviceTypeText = if ($null -ne $serviceSection) { & $readInfValue $serviceSection 'ServiceType' } else { $null }
    $startTypeText = if ($null -ne $serviceSection) { & $readInfValue $serviceSection 'StartType' } else { $null }
    $errorControlText = if ($null -ne $serviceSection) { & $readInfValue $serviceSection 'ErrorControl' } else { $null }
    $serviceBinary = if ($null -ne $serviceSection) { & $readInfValue $serviceSection 'ServiceBinary' } else { $null }
    $loadOrderGroup = if ($null -ne $serviceSection) { & $readInfValue $serviceSection 'LoadOrderGroup' } else { $null }
    $serviceType = 0
    $startType = 0
    $errorControl = 0
    $serviceTypeParsed = [int]::TryParse([string]$serviceTypeText, [ref]$serviceType)
    $startTypeParsed = [int]::TryParse([string]$startTypeText, [ref]$startType)
    $errorControlParsed = [int]::TryParse([string]$errorControlText, [ref]$errorControl)
    $infExact = (Test-CruwStringEqual $serviceName 'CRUWBlocker') -and
        $null -ne $addServiceFlags -and $addServiceFlags.Length -eq 0 -and
        (Test-CruwStringEqual $serviceSection 'CRUWBlocker_ServiceInstallSection') -and
        (Test-CruwStringEqual $servicesInclude 'disk.inf') -and
        (Test-CruwStringEqual $servicesNeeds 'disk_install.NT.Services') -and
        $serviceTypeParsed -and $serviceType -eq 1 -and
        $startTypeParsed -and $startType -eq 3 -and
        $errorControlParsed -and $errorControl -eq 1 -and
        (Test-CruwStringEqual $serviceBinary '%12%\CRUWBlocker.sys') -and
        (Test-CruwStringEqual $loadOrderGroup 'Pnp Filter')
    if (-not $infExact) {
        $failures.Add('Exported INF service contract is not the exact expected demand-start CRUW disk-filter definition')
    }

    $liveStart = Get-CruwPropertyValue -InputObject $LiveService -Name 'Start'
    $liveType = Get-CruwPropertyValue -InputObject $LiveService -Name 'Type'
    $liveErrorControl = Get-CruwPropertyValue -InputObject $LiveService -Name 'ErrorControl'
    $liveGroup = Get-CruwPropertyValue -InputObject $LiveService -Name 'Group'
    $liveImagePath = Get-CruwPropertyValue -InputObject $LiveService -Name 'ImagePath'
    $liveState = Get-CruwPropertyValue -InputObject $LiveService -Name 'State'
    $liveStartOverrideAbsent = Get-CruwPropertyValue -InputObject $LiveService -Name 'StartOverrideAbsent'
    $canonicalLiveImagePath = $null
    try { $canonicalLiveImagePath = ConvertTo-CruwCanonicalServiceImagePath -ImagePath ([string]$liveImagePath) }
    catch { $canonicalLiveImagePath = $null }
    $liveExact = $null -ne $liveStart -and $null -ne $liveType -and $null -ne $liveErrorControl -and
        -not [string]::IsNullOrWhiteSpace([string]$liveGroup) -and
        -not [string]::IsNullOrWhiteSpace([string]$liveImagePath) -and
        -not [string]::IsNullOrWhiteSpace([string]$liveState) -and
        [int]$liveStart -eq 0 -and [int]$liveType -eq 1 -and [int]$liveErrorControl -eq 1 -and
        (Test-CruwStringEqual $liveGroup 'Pnp Filter') -and
        (Test-CruwStringEqual $canonicalLiveImagePath '\SystemRoot\System32\drivers\CRUWBlocker.sys') -and
        $liveStartOverrideAbsent -eq $true -and
        (Test-CruwStringEqual $liveState 'Running')
    if (-not $liveExact) {
        $failures.Add('Current CRUWBlocker service is not sealed in the exact legacy boot-start running configuration')
    }

    $promotionEvidenceExact = $PromotionEvidence.Count -gt 0
    $promotionObservationCount = 0
    $sanitizedPromotionEvidence = @($PromotionEvidence | ForEach-Object {
        $fileName = [string](Get-CruwPropertyValue -InputObject $_ -Name 'FileName')
        $sha256 = [string](Get-CruwPropertyValue -InputObject $_ -Name 'Sha256')
        $length = [long](Get-CruwPropertyValue -InputObject $_ -Name 'Length')
        $matchCount = [int](Get-CruwPropertyValue -InputObject $_ -Name 'MatchCount')
        if ($fileName -cnotmatch '^setupapi\.dev\.\d{8}_\d{6}\.log$' -or
            $sha256 -cnotmatch '^[A-F0-9]{64}$' -or $length -le 0 -or $matchCount -le 0) {
            $promotionEvidenceExact = $false
        }
        $promotionObservationCount += $matchCount
        [ordered]@{ fileName = $fileName; sha256 = $sha256; length = $length; matchCount = $matchCount }
    })
    if (-not $promotionEvidenceExact -or $promotionObservationCount -le 0) {
        $failures.Add('Stable archived SetupAPI boot-start promotion evidence is unavailable')
    }
    if (-not $ExportedPackageVerified -or $ExportedInfSha256 -cnotmatch '^[A-F0-9]{64}$') {
        $failures.Add('Exported rollback package is not fully signed and hash-sealed')
    }

    $exactTargetSealed = $infExact -and $liveExact
    $automaticRollbackEligible = $ExportedPackageVerified -and
        $ExportedInfSha256 -cmatch '^[A-F0-9]{64}$' -and
        $exactTargetSealed -and $promotionEvidenceExact -and $promotionObservationCount -gt 0
    return [pscustomobject][ordered]@{
        automaticRollbackEligible = $automaticRollbackEligible
        exactServiceConfigurationTargetSealed = $exactTargetSealed
        errorControlAndGroupSealed = $infExact -and $liveExact
        postAddExactLiveReadbackMandatory = $true
        setupApiTextIsAuthority = $false
        restorationGuaranteed = $false
        exportedPackageVerified = $ExportedPackageVerified
        exportedInfSha256 = $ExportedInfSha256
        infServiceName = $serviceName
        infServiceType = if ($serviceTypeParsed) { $serviceType } else { $null }
        infStartType = if ($startTypeParsed) { $startType } else { $null }
        infErrorControl = if ($errorControlParsed) { $errorControl } else { $null }
        infServiceBinary = $serviceBinary
        infLoadOrderGroup = $loadOrderGroup
        sealedLiveStart = $liveStart
        sealedLiveType = $liveType
        sealedLiveErrorControl = $liveErrorControl
        sealedLiveGroup = $liveGroup
        sealedLiveImagePathRaw = $liveImagePath
        sealedLiveImagePathCanonical = $canonicalLiveImagePath
        sealedLiveState = $liveState
        sealedLiveStartOverrideAbsent = $liveStartOverrideAbsent -eq $true
        bootPromotionObservationCount = $promotionObservationCount
        diagnosticPromotionEvidenceSealed = $promotionEvidenceExact -and $promotionObservationCount -gt 0
        promotionEvidence = $sanitizedPromotionEvidence
        failures = @($failures)
    }
}

function Get-CruwImplementationArtifactContract {
    [CmdletBinding()]
    param(
        [Parameter(Mandatory)] [string] $SourceDirectory,
        [Parameter(Mandatory)] [string] $ProducerPath
    )

    $directorySeparators = [char[]]@([IO.Path]::DirectorySeparatorChar, [IO.Path]::AltDirectorySeparatorChar)
    $resolvedSourceDirectory = [IO.Path]::GetFullPath($SourceDirectory).TrimEnd($directorySeparators)
    $resolvedProducerPath = [IO.Path]::GetFullPath($ProducerPath)
    $resolvedProducerDirectory = [IO.Path]::GetDirectoryName($resolvedProducerPath).TrimEnd($directorySeparators)
    if (-not [string]::Equals($resolvedSourceDirectory, $resolvedProducerDirectory, [StringComparison]::OrdinalIgnoreCase)) {
        throw 'The CRUW preflight producer and required implementation artifacts must be siblings'
    }
    if (-not [string]::Equals(
        [IO.Path]::GetFileName($resolvedProducerPath),
        'Prepare-CRUWBlockerRemoval.ps1',
        [StringComparison]::OrdinalIgnoreCase
    )) {
        throw 'The CRUW preflight producer path does not identify Prepare-CRUWBlockerRemoval.ps1'
    }

    $definitions = @(
        [pscustomobject]@{ fileName = 'Prepare-CRUWBlockerRemoval.ps1'; role = 'preflight-producer'; driverMutationCapable = $false },
        [pscustomobject]@{ fileName = 'CRUWBlockerPreflight.Core.ps1'; role = 'preflight-core'; driverMutationCapable = $false },
        [pscustomobject]@{ fileName = 'CRUWStateMachine.Common.ps1'; role = 'state-machine-common'; driverMutationCapable = $true },
        [pscustomobject]@{ fileName = 'Invoke-CRUWBlockerRemoval.ps1'; role = 'removal-executor'; driverMutationCapable = $true },
        [pscustomobject]@{ fileName = 'Repair-CRUWInterruptedRemoval.ps1'; role = 'interruption-repair'; driverMutationCapable = $true },
        [pscustomobject]@{ fileName = 'Test-CRUWBlockerPostboot.ps1'; role = 'postboot-validator'; driverMutationCapable = $true }
    )

    $artifacts = @($definitions | ForEach-Object {
        $definition = $_
        $sourcePath = if ($definition.role -eq 'preflight-producer') {
            $resolvedProducerPath
        }
        else {
            Join-Path $resolvedSourceDirectory $definition.fileName
        }
        if (-not (Test-Path -LiteralPath $sourcePath -PathType Leaf)) {
            throw "Required CRUW implementation artifact is missing: $($definition.fileName)"
        }
        $sourceItem = Get-Item -LiteralPath $sourcePath -Force -ErrorAction Stop
        if (($sourceItem.Attributes -band [IO.FileAttributes]::ReparsePoint) -ne 0) {
            throw "Required CRUW implementation artifact must not be a reparse point: $($definition.fileName)"
        }

        $tokens = $null
        $parseErrors = $null
        [void][Management.Automation.Language.Parser]::ParseFile(
            $sourcePath,
            [ref]$tokens,
            [ref]$parseErrors
        )
        if (@($parseErrors).Count -gt 0) {
            $parseFailure = @($parseErrors | ForEach-Object { $_.Message }) -join '; '
            throw "Required CRUW implementation artifact failed PowerShell parsing: $($definition.fileName): $parseFailure"
        }

        $sha256 = [string](Get-FileHash -LiteralPath $sourcePath -Algorithm SHA256 -ErrorAction Stop).Hash
        if ($sha256 -notmatch '^[A-Fa-f0-9]{64}$') {
            throw "Required CRUW implementation artifact did not produce a SHA-256 hash: $($definition.fileName)"
        }
        [pscustomobject][ordered]@{
            role = [string]$definition.role
            relativePath = 'implementation/' + [string]$definition.fileName
            sha256 = $sha256.ToUpperInvariant()
            driverMutationCapable = [bool]$definition.driverMutationCapable
        }
    })

    return [pscustomobject][ordered]@{
        producerPerformsDriverMutation = $false
        sealedBundleContainsBootCriticalMutation = @($artifacts | Where-Object { $_.driverMutationCapable }).Count -gt 0
        artifacts = $artifacts
    }
}

function Assert-CruwImplementationArtifactFileHashes {
    [CmdletBinding()]
    param(
        [Parameter(Mandatory)] $ImplementationContract,
        [Parameter(Mandatory)] [object[]] $FileVerification
    )

    foreach ($artifact in @($ImplementationContract.artifacts)) {
        $artifactRelativePath = [string]$artifact.relativePath
        $matchingFiles = @($FileVerification | Where-Object {
            [string]::Equals(
                [string](Get-CruwPropertyValue -InputObject $_ -Name 'relativePath'),
                $artifactRelativePath,
                [StringComparison]::Ordinal
            )
        })
        if ($matchingFiles.Count -ne 1) {
            throw "Implementation artifact must resolve to exactly one backup verification record: $artifactRelativePath"
        }

        $file = $matchingFiles[0]
        $primarySha256 = [string](Get-CruwPropertyValue -InputObject $file -Name 'primarySha256')
        $secondarySha256 = [string](Get-CruwPropertyValue -InputObject $file -Name 'secondarySha256')
        if (-not [bool](Get-CruwPropertyValue -InputObject $file -Name 'primaryExists') -or
            -not [bool](Get-CruwPropertyValue -InputObject $file -Name 'secondaryExists') -or
            -not [bool](Get-CruwPropertyValue -InputObject $file -Name 'hashesMatch') -or
            -not [string]::Equals($primarySha256, [string]$artifact.sha256, [StringComparison]::OrdinalIgnoreCase) -or
            -not [string]::Equals($secondarySha256, [string]$artifact.sha256, [StringComparison]::OrdinalIgnoreCase)) {
            throw "Implementation artifact backup hashes do not match the sealed contract: $artifactRelativePath"
        }
    }
    return $true
}

function Assert-CruwDriverPayloadFileHashes {
    [CmdletBinding()]
    param(
        [Parameter(Mandatory)] [object[]] $DriverExportHashes,
        [Parameter(Mandatory)] [object[]] $FileVerification,
        [Parameter(Mandatory)] [string] $ExportedInfSha256,
        [Parameter(Mandatory)] [string] $ExportedDriverSha256,
        [Parameter(Mandatory)] [string] $ExportedCatalogSha256
    )

    $expected = [ordered]@{
        'cruwblocker.inf' = $ExportedInfSha256
        'CRUWBlocker.sys' = $ExportedDriverSha256
        'CRUWBlocker.cat' = $ExportedCatalogSha256
    }
    if ($DriverExportHashes.Count -ne $expected.Count) {
        throw 'Driver export hash contract must contain exactly three records'
    }

    foreach ($entry in $expected.GetEnumerator()) {
        $fileName = [string]$entry.Key
        $expectedSha256 = [string]$entry.Value
        if ($expectedSha256 -cnotmatch '^[A-F0-9]{64}$') {
            throw "Driver export identity hash is not an uppercase SHA-256: $fileName"
        }
        $exportRecords = @($DriverExportHashes | Where-Object {
            [string]::Equals([string](Get-CruwPropertyValue -InputObject $_ -Name 'file'), $fileName, [StringComparison]::Ordinal)
        })
        if ($exportRecords.Count -ne 1 -or
            -not [string]::Equals(
                [string](Get-CruwPropertyValue -InputObject $exportRecords[0] -Name 'Hash'),
                $expectedSha256,
                [StringComparison]::OrdinalIgnoreCase
            )) {
            throw "Driver export metadata does not match the signed identity hash: $fileName"
        }

        $relativePath = 'driver\' + $fileName
        $fileRecords = @($FileVerification | Where-Object {
            [string]::Equals([string](Get-CruwPropertyValue -InputObject $_ -Name 'relativePath'), $relativePath, [StringComparison]::Ordinal)
        })
        if ($fileRecords.Count -ne 1) {
            throw "Driver payload must resolve to exactly one backup verification record: $relativePath"
        }
        $fileRecord = $fileRecords[0]
        if (-not [bool](Get-CruwPropertyValue -InputObject $fileRecord -Name 'primaryExists') -or
            -not [bool](Get-CruwPropertyValue -InputObject $fileRecord -Name 'secondaryExists') -or
            -not [bool](Get-CruwPropertyValue -InputObject $fileRecord -Name 'hashesMatch') -or
            -not [string]::Equals([string](Get-CruwPropertyValue -InputObject $fileRecord -Name 'primarySha256'), $expectedSha256, [StringComparison]::OrdinalIgnoreCase) -or
            -not [string]::Equals([string](Get-CruwPropertyValue -InputObject $fileRecord -Name 'secondarySha256'), $expectedSha256, [StringComparison]::OrdinalIgnoreCase)) {
            throw "Driver payload bytes no longer match the signed and hash-sealed export: $relativePath"
        }
    }
    return $true
}

function Assert-CruwExactRecoveryTree {
    [CmdletBinding()]
    param(
        [Parameter(Mandatory)] [string] $RootPath,
        [Parameter(Mandatory)] [string[]] $RequiredRelativeFiles
    )

    $root = Get-Item -LiteralPath $RootPath -Force -ErrorAction Stop
    if (-not $root.PSIsContainer -or ($root.Attributes -band [IO.FileAttributes]::ReparsePoint) -ne 0) {
        throw 'Recovery root must be a non-reparse directory'
    }
    $rootFull = [IO.Path]::GetFullPath($root.FullName).TrimEnd('\')
    $normalizedRequired = @($RequiredRelativeFiles | ForEach-Object {
        $relative = ([string]$_).Replace('/', '\').TrimStart('\')
        if ([string]::IsNullOrWhiteSpace($relative) -or
            [IO.Path]::IsPathRooted($relative) -or
            $relative -match '(^|\\)\.\.(\\|$)' -or
            $relative -match ':') {
            throw "Required recovery-tree path is not a safe relative file path: $_"
        }
        $relative
    })
    $requiredSet = [Collections.Generic.HashSet[string]]::new([StringComparer]::Ordinal)
    foreach ($relative in $normalizedRequired) {
        if (-not $requiredSet.Add($relative)) { throw 'Required recovery-tree file contract contains a duplicate path' }
    }

    $allowedDirectories = [Collections.Generic.List[string]]::new()
    foreach ($relativeFile in $normalizedRequired) {
        $parent = [IO.Path]::GetDirectoryName($relativeFile)
        while (-not [string]::IsNullOrWhiteSpace($parent)) {
            if ($allowedDirectories -cnotcontains $parent) { $allowedDirectories.Add($parent) }
            $parent = [IO.Path]::GetDirectoryName($parent)
        }
    }

    $foundFiles = [Collections.Generic.List[string]]::new()
    $foundDirectories = [Collections.Generic.List[string]]::new()
    $pendingDirectories = [Collections.Generic.Queue[string]]::new()
    $pendingDirectories.Enqueue($rootFull)
    while ($pendingDirectories.Count -gt 0) {
        $directoryPath = $pendingDirectories.Dequeue()
        foreach ($item in @(Get-ChildItem -LiteralPath $directoryPath -Force -ErrorAction Stop)) {
            if (($item.Attributes -band [IO.FileAttributes]::ReparsePoint) -ne 0) {
                throw "Recovery tree contains a reparse point: $($item.FullName)"
            }
            $itemFull = [IO.Path]::GetFullPath($item.FullName)
            if (-not $itemFull.StartsWith($rootFull + '\', [StringComparison]::OrdinalIgnoreCase)) {
                throw 'Recovery-tree enumeration escaped the exact root'
            }
            $relative = $itemFull.Substring($rootFull.Length + 1)
            if ($item.PSIsContainer) {
                if ($allowedDirectories -cnotcontains $relative) {
                    throw "Recovery tree contains an unexpected directory: $relative"
                }
                $foundDirectories.Add($relative)
                $pendingDirectories.Enqueue($itemFull)
            }
            else {
                if ($normalizedRequired -cnotcontains $relative) {
                    throw "Recovery tree contains an unexpected file: $relative"
                }
                $streams = @(Get-Item -LiteralPath $itemFull -Stream * -ErrorAction Stop)
                if ($streams.Count -ne 1 -or [string]$streams[0].Stream -cne ':$DATA') {
                    throw "Recovery payload contains an alternate data stream: $relative"
                }
                $foundFiles.Add($relative)
            }
        }
    }
    if ($foundFiles.Count -ne $normalizedRequired.Count -or
        @($normalizedRequired | Where-Object { $foundFiles -cnotcontains $_ }).Count -gt 0 -or
        $foundDirectories.Count -ne $allowedDirectories.Count -or
        @($allowedDirectories | Where-Object { $foundDirectories -cnotcontains $_ }).Count -gt 0) {
        throw 'Recovery tree does not contain the exact required physical file and directory set'
    }
    return $true
}

function Resolve-CruwDriverIdentity {
    [CmdletBinding()]
    param(
        [Parameter(Mandatory)] [object[]] $DiskBindings,
        [Parameter(Mandatory)] [object[]] $DriverPackages,
        [string] $ExpectedFilter = 'CRUWBlocker',
        [string] $ExpectedOriginalInf = 'cruwblocker.inf',
        [string] $ExpectedProvider = 'CRU Acquisition Group, LLC',
        [string] $ExpectedClass = 'DiskDrive',
        [string] $ExpectedVersion = '1.2.1.1'
    )

    $targetBindings = @($DiskBindings | Where-Object {
        $filters = @(Get-CruwPropertyValue -InputObject $_ -Name 'LowerFilters')
        @($filters | Where-Object { Test-CruwStringEqual $_ $ExpectedFilter }).Count -gt 0
    })
    if ($targetBindings.Count -eq 0) {
        throw "No present disk binding contains the expected lower filter '$ExpectedFilter'"
    }

    $publishedNames = @($targetBindings | ForEach-Object {
        [string](Get-CruwPropertyValue -InputObject $_ -Name 'PublishedName')
    } | Where-Object { -not [string]::IsNullOrWhiteSpace($_) } | Sort-Object -Unique)
    if ($publishedNames.Count -ne 1) {
        throw "Target bindings do not resolve to exactly one published driver package: $($publishedNames -join ', ')"
    }
    $publishedName = $publishedNames[0]
    if ($publishedName -notmatch '(?i)^oem\d+\.inf$') {
        throw "Resolved published driver name is not an OEM INF: $publishedName"
    }

    $packageBindings = @($DiskBindings | Where-Object {
        Test-CruwStringEqual (Get-CruwPropertyValue -InputObject $_ -Name 'PublishedName') $publishedName
    })
    if ($packageBindings.Count -ne $targetBindings.Count) {
        throw "At least one disk bound to $publishedName does not expose the $ExpectedFilter lower filter"
    }

    foreach ($binding in $targetBindings) {
        $status = Get-CruwPropertyValue -InputObject $binding -Name 'Status'
        $provider = Get-CruwPropertyValue -InputObject $binding -Name 'Provider'
        $className = Get-CruwPropertyValue -InputObject $binding -Name 'ClassName'
        $version = Get-CruwPropertyValue -InputObject $binding -Name 'Version'
        if (-not (Test-CruwStringEqual $status 'OK')) { throw "A target disk binding is not healthy: $status" }
        if (-not (Test-CruwStringEqual $provider $ExpectedProvider)) { throw "Unexpected target device provider: $provider" }
        if (-not (Test-CruwStringEqual $className $ExpectedClass)) { throw "Unexpected target device class: $className" }
        if (-not (Test-CruwStringEqual $version $ExpectedVersion)) { throw "Unexpected target device driver version: $version" }
    }

    $matchingPackages = @($DriverPackages | Where-Object {
        Test-CruwStringEqual (Get-CruwPropertyValue -InputObject $_ -Name 'PublishedName') $publishedName
    })
    if ($matchingPackages.Count -ne 1) {
        throw "Published package $publishedName did not resolve to exactly one online driver package"
    }
    $package = $matchingPackages[0]
    $originalInf = [IO.Path]::GetFileName([string](Get-CruwPropertyValue -InputObject $package -Name 'OriginalInf'))
    $packageProvider = Get-CruwPropertyValue -InputObject $package -Name 'Provider'
    $packageClass = Get-CruwPropertyValue -InputObject $package -Name 'ClassName'
    $packageVersion = Get-CruwPropertyValue -InputObject $package -Name 'Version'
    if (-not (Test-CruwStringEqual $originalInf $ExpectedOriginalInf)) { throw "Unexpected original INF: $originalInf" }
    if (-not (Test-CruwStringEqual $packageProvider $ExpectedProvider)) { throw "Unexpected driver package provider: $packageProvider" }
    if (-not (Test-CruwStringEqual $packageClass $ExpectedClass)) { throw "Unexpected driver package class: $packageClass" }
    if (-not (Test-CruwStringEqual $packageVersion $ExpectedVersion)) { throw "Unexpected driver package version: $packageVersion" }

    return [pscustomobject]@{
        PublishedName = $publishedName
        OriginalInf = $originalInf
        Provider = [string]$packageProvider
        ClassName = [string]$packageClass
        Version = [string]$packageVersion
        Filter = $ExpectedFilter
        TargetBindings = $targetBindings
    }
}

function Test-CruwVolumeLayout {
    [CmdletBinding()]
    param(
        [Parameter(Mandatory)] [object[]] $VolumeLayouts,
        [Parameter(Mandatory)] [string[]] $TargetDeviceInstanceIds,
        [string[]] $RequiredDriveLetters = @('C', 'D')
    )

    $failures = [Collections.Generic.List[string]]::new()
    $requiredLayouts = @()
    foreach ($letter in $RequiredDriveLetters) {
        $matches = @($VolumeLayouts | Where-Object {
            Test-CruwStringEqual (Get-CruwPropertyValue -InputObject $_ -Name 'DriveLetter') $letter
        })
        if ($matches.Count -ne 1) {
            $failures.Add("Drive $letter must resolve to exactly one layout record")
            continue
        }
        $layout = $matches[0]
        $requiredLayouts += $layout
        if (-not [bool](Get-CruwPropertyValue -InputObject $layout -Name 'Mounted')) { $failures.Add("Drive $letter is not mounted") }
        if ([bool](Get-CruwPropertyValue -InputObject $layout -Name 'IsOffline')) { $failures.Add("Drive $letter is on an offline disk") }
        if ([bool](Get-CruwPropertyValue -InputObject $layout -Name 'IsReadOnly')) { $failures.Add("Drive $letter is on a read-only disk") }
        if (-not (Test-CruwStringEqual (Get-CruwPropertyValue -InputObject $layout -Name 'DiskHealth') 'Healthy')) { $failures.Add("Drive $letter disk is not healthy") }
        if (-not (Test-CruwStringEqual (Get-CruwPropertyValue -InputObject $layout -Name 'VolumeHealth') 'Healthy')) { $failures.Add("Drive $letter volume is not healthy") }
        $diskOperationalStatus = @(Get-CruwPropertyValue -InputObject $layout -Name 'DiskOperationalStatus')
        if ($diskOperationalStatus.Count -ne 1 -or -not (Test-CruwStringEqual $diskOperationalStatus[0] 'Online')) { $failures.Add("Drive $letter disk operational status is not exactly Online") }
        $volumeOperationalStatus = @(Get-CruwPropertyValue -InputObject $layout -Name 'VolumeOperationalStatus')
        if ($volumeOperationalStatus.Count -ne 1 -or -not (Test-CruwStringEqual $volumeOperationalStatus[0] 'OK')) { $failures.Add("Drive $letter volume operational status is not exactly OK") }
        if ([string]::IsNullOrWhiteSpace([string](Get-CruwPropertyValue -InputObject $layout -Name 'FileSystem'))) { $failures.Add("Drive $letter has no mounted filesystem") }
        if ([string]::IsNullOrWhiteSpace([string](Get-CruwPropertyValue -InputObject $layout -Name 'DeviceInstanceId'))) { $failures.Add("Drive $letter could not be mapped to a PnP disk") }
    }

    $diskNumbers = @($requiredLayouts | ForEach-Object { [string](Get-CruwPropertyValue -InputObject $_ -Name 'DiskNumber') } | Sort-Object -Unique)
    if ($diskNumbers.Count -ne $RequiredDriveLetters.Count) {
        $failures.Add('Required recovery volumes are not on distinct physical disks')
    }

    $layoutIds = @($requiredLayouts | ForEach-Object {
        [string](Get-CruwPropertyValue -InputObject $_ -Name 'DeviceInstanceId')
    } | Where-Object { -not [string]::IsNullOrWhiteSpace($_) } | Sort-Object -Unique)
    $targetIds = @($TargetDeviceInstanceIds | Where-Object { -not [string]::IsNullOrWhiteSpace($_) } | Sort-Object -Unique)
    if ($layoutIds.Count -ne $targetIds.Count -or @($layoutIds | Where-Object { $candidate = $_; @($targetIds | Where-Object { Test-CruwStringEqual $_ $candidate }).Count -eq 0 }).Count -gt 0) {
        $failures.Add('The CRUWBlocker-bound devices do not exactly match the C: and D: physical disks')
    }

    return [pscustomobject]@{
        Verified = $failures.Count -eq 0
        RequiredDriveLetters = $RequiredDriveLetters
        DistinctPhysicalDiskCount = $diskNumbers.Count
        Failures = @($failures)
    }
}

function Test-CruwFallbackReadiness {
    [CmdletBinding()]
    param(
        [Parameter(Mandatory)] [bool] $DiskInfFilePresent,
        [Parameter(Mandatory)] [bool] $DiskInfPackageVerified,
        [Parameter(Mandatory)] [object[]] $DeviceChecks,
        [int] $ExpectedDeviceCount = 2
    )

    $failures = [Collections.Generic.List[string]]::new()
    if (-not $DiskInfFilePresent) { $failures.Add('Windows INF\disk.inf is missing') }
    if (-not $DiskInfPackageVerified) { $failures.Add('The Microsoft DiskDrive disk.inf package was not verified') }
    if ($DeviceChecks.Count -ne $ExpectedDeviceCount) { $failures.Add("Fallback evidence was not collected for exactly $ExpectedDeviceCount devices") }
    foreach ($check in $DeviceChecks) {
        if ([int](Get-CruwPropertyValue -InputObject $check -Name 'ExitCode') -ne 0) { $failures.Add('PnP fallback inventory returned a non-zero exit code') }
        if (-not [bool](Get-CruwPropertyValue -InputObject $check -Name 'DiskInfPresent')) { $failures.Add('disk.inf is not listed as a matching driver for a target disk') }
    }
    return [pscustomobject]@{ Verified = $failures.Count -eq 0; Failures = @($failures) }
}

function Set-CruwProtectedRecoveryAcl {
    [CmdletBinding()]
    param([Parameter(Mandatory)] [string] $Path)

    $administrators = [Security.Principal.SecurityIdentifier]::new('S-1-5-32-544')
    $system = [Security.Principal.SecurityIdentifier]::new('S-1-5-18')
    $inheritance = [Security.AccessControl.InheritanceFlags]::ContainerInherit -bor [Security.AccessControl.InheritanceFlags]::ObjectInherit
    $propagation = [Security.AccessControl.PropagationFlags]::None
    $allow = [Security.AccessControl.AccessControlType]::Allow
    $full = [Security.AccessControl.FileSystemRights]::FullControl
    $acl = [Security.AccessControl.DirectorySecurity]::new()
    $acl.SetAccessRuleProtection($true, $false)
    $acl.SetOwner($system)
    [void]$acl.AddAccessRule([Security.AccessControl.FileSystemAccessRule]::new($system, $full, $inheritance, $propagation, $allow))
    [void]$acl.AddAccessRule([Security.AccessControl.FileSystemAccessRule]::new($administrators, $full, $inheritance, $propagation, $allow))
    Set-Acl -LiteralPath $Path -AclObject $acl
}

function Set-CruwProtectedFileAcl {
    [CmdletBinding()]
    param([Parameter(Mandatory)] [string] $Path)

    $administrators = [Security.Principal.SecurityIdentifier]::new('S-1-5-32-544')
    $system = [Security.Principal.SecurityIdentifier]::new('S-1-5-18')
    $allow = [Security.AccessControl.AccessControlType]::Allow
    $full = [Security.AccessControl.FileSystemRights]::FullControl
    $acl = [Security.AccessControl.FileSecurity]::new()
    $acl.SetAccessRuleProtection($true, $false)
    $acl.SetOwner($system)
    [void]$acl.AddAccessRule([Security.AccessControl.FileSystemAccessRule]::new($system, $full, $allow))
    [void]$acl.AddAccessRule([Security.AccessControl.FileSystemAccessRule]::new($administrators, $full, $allow))
    Set-Acl -LiteralPath $Path -AclObject $acl
}

function Set-CruwProtectedRecoveryTreeAcl {
    [CmdletBinding()]
    param([Parameter(Mandatory)] [string] $Path)

    Set-CruwProtectedRecoveryAcl -Path $Path
    $children = @(Get-ChildItem -LiteralPath $Path -Recurse -Force -ErrorAction Stop | Sort-Object { $_.FullName.Length })
    foreach ($child in $children) {
        if ($child.PSIsContainer) { Set-CruwProtectedRecoveryAcl -Path $child.FullName }
        else { Set-CruwProtectedFileAcl -Path $child.FullName }
    }
}

function Test-CruwProtectedRecoveryAcl {
    [CmdletBinding()]
    param(
        [Parameter(Mandatory)] [string] $Path,
        [switch] $Recurse
    )

    $allowedSids = @('S-1-5-18', 'S-1-5-32-544')
    $failures = [Collections.Generic.List[string]]::new()
    $items = @((Get-Item -LiteralPath $Path -ErrorAction Stop))
    if ($Recurse) { $items += @(Get-ChildItem -LiteralPath $Path -Recurse -Force -ErrorAction Stop) }
    foreach ($item in $items) {
        $acl = Get-Acl -LiteralPath $item.FullName
        $seenSids = @{}
        if (-not $acl.AreAccessRulesProtected) { $failures.Add("ACL inheritance is still enabled on $($item.Name)") }
        try { $ownerSid = ([Security.Principal.NTAccount]$acl.Owner).Translate([Security.Principal.SecurityIdentifier]).Value }
        catch {
            try { $ownerSid = ([Security.Principal.SecurityIdentifier]$acl.Owner).Value }
            catch { $ownerSid = [string]$acl.Owner }
        }
        if ($ownerSid -ne 'S-1-5-18') { $failures.Add("Owner is not SYSTEM on $($item.Name)") }
        foreach ($rule in @($acl.Access)) {
            try { $sid = $rule.IdentityReference.Translate([Security.Principal.SecurityIdentifier]).Value }
            catch { $sid = [string]$rule.IdentityReference }
            $seenSids[$sid] = $true
            if ($allowedSids -notcontains $sid) { $failures.Add("Unauthorized ACL identity $sid on $($item.Name)") }
            if ($rule.AccessControlType -ne [Security.AccessControl.AccessControlType]::Allow) { $failures.Add("Non-Allow ACL entry on $($item.Name)") }
            if (($rule.FileSystemRights -band [Security.AccessControl.FileSystemRights]::FullControl) -ne [Security.AccessControl.FileSystemRights]::FullControl) {
                $failures.Add("Non-FullControl ACL entry on $($item.Name)")
            }
        }
        foreach ($requiredSid in $allowedSids) {
            if (-not $seenSids.ContainsKey($requiredSid)) {
                $failures.Add("Required ACL identity $requiredSid is missing on $($item.Name)")
            }
        }
    }
    return [pscustomobject]@{
        Verified = $failures.Count -eq 0
        CheckedItemCount = $items.Count
        RequiredOwnerSid = 'S-1-5-18'
        AllowedAccessSids = $allowedSids
        EveryItemAclProtected = $failures.Count -eq 0
        Failures = @($failures)
    }
}
