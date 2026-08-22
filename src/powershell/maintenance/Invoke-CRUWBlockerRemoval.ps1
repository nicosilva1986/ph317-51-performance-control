[CmdletBinding()]
param(
    [Parameter(Mandatory)]
    [string] $PreflightPath,
    [Parameter(Mandatory)]
    [ValidateSet('REMOVE-CRUWBLOCKER-WITHOUT-FORCE')]
    [string] $ConfirmationPhrase,
    [Parameter(Mandatory)]
    [switch] $OffMachineRecoveryKeyConfirmed,
    [Parameter(Mandatory)]
    [switch] $PhysicalConsoleAccessConfirmed,
    [Parameter(Mandatory)]
    [switch] $ManualRebootWindowConfirmed,
    [Parameter(Mandatory)]
    [switch] $ConfirmBootCriticalDriverRemoval,
    [ValidateRange(5, 60)]
    [int] $MaxPreflightAgeMinutes = 15,
    [switch] $TestMode,
    [hashtable] $TestAdapter
)

Set-StrictMode -Version Latest
$ErrorActionPreference = 'Stop'

$script:CRUWBootstrapAnchorSets = [Collections.Generic.List[object]]::new()

function Initialize-CRUWBootstrapAnchorNative {
    if ('CRUWConsumerDirectoryAnchorNative' -as [type]) { return }
    Add-Type -TypeDefinition @'
using System;
using System.ComponentModel;
using System.Runtime.InteropServices;
using Microsoft.Win32.SafeHandles;

public sealed class CRUWConsumerDirectoryAnchorRecord : IDisposable
{
    public string Path { get; private set; }
    public string Identity { get; private set; }
    public SafeFileHandle Handle { get; private set; }

    internal CRUWConsumerDirectoryAnchorRecord(string path, string identity, SafeFileHandle handle)
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

public static class CRUWConsumerDirectoryAnchorNative
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
        string fileName, uint desiredAccess, uint shareMode, IntPtr securityAttributes,
        uint creationDisposition, uint flagsAndAttributes, IntPtr templateFile);

    [DllImport("kernel32.dll", SetLastError = true)]
    [return: MarshalAs(UnmanagedType.Bool)]
    private static extern bool GetFileInformationByHandle(
        SafeFileHandle file, out BY_HANDLE_FILE_INFORMATION information);

    public static CRUWConsumerDirectoryAnchorRecord Open(string path)
    {
        SafeFileHandle handle = CreateFileW(
            path, FILE_READ_ATTRIBUTES | DELETE, FILE_SHARE_READ | FILE_SHARE_WRITE,
            IntPtr.Zero, OPEN_EXISTING,
            FILE_FLAG_BACKUP_SEMANTICS | FILE_FLAG_OPEN_REPARSE_POINT, IntPtr.Zero);
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
        return new CRUWConsumerDirectoryAnchorRecord(path, identity, handle);
    }
}
'@
}

function Enter-CRUWBootstrapAnchorChain {
    param(
        [Parameter(Mandatory)] [string] $DirectoryPath,
        [Parameter(Mandatory)] [string] $AnchorBasePath,
        [Parameter(Mandatory)] [ValidatePattern('^[A-Za-z]:$')] [string] $ExpectedDrive,
        [switch] $AllowMissing,
        [AllowNull()] [hashtable] $Adapter
    )
    if ($null -ne $Adapter) {
        if (-not $Adapter.ContainsKey('EnterPathAnchors')) { throw 'Test adapter lacks EnterPathAnchors' }
        return & $Adapter.EnterPathAnchors $DirectoryPath $AnchorBasePath $ExpectedDrive $AllowMissing.IsPresent
    }

    if ($DirectoryPath -notmatch '^[A-Za-z]:\\' -or $DirectoryPath.Substring(2) -match ':') {
        throw 'Recovery anchor path must be local and must not contain an alternate data stream'
    }
    $fullPath = [IO.Path]::GetFullPath($DirectoryPath).TrimEnd('\')
    $baseFull = [IO.Path]::GetFullPath($AnchorBasePath).TrimEnd('\')
    $expectedRoot = $ExpectedDrive.ToUpperInvariant() + '\'
    if (
        -not [string]::Equals([IO.Path]::GetPathRoot($fullPath),$expectedRoot,[StringComparison]::OrdinalIgnoreCase) -or
        -not [string]::Equals([IO.Path]::GetPathRoot($baseFull),$expectedRoot,[StringComparison]::OrdinalIgnoreCase) -or
        (
            -not [string]::Equals($fullPath,$baseFull,[StringComparison]::OrdinalIgnoreCase) -and
            -not $fullPath.StartsWith($baseFull + '\',[StringComparison]::OrdinalIgnoreCase)
        )
    ) { throw 'Recovery anchor path is outside its fixed dedicated parent' }

    Initialize-CRUWBootstrapAnchorNative
    $anchors = [Collections.Generic.List[object]]::new()
    try {
        $paths = [Collections.Generic.List[string]]::new()
        $paths.Add($baseFull)
        if (-not [string]::Equals($fullPath,$baseFull,[StringComparison]::OrdinalIgnoreCase)) {
            $current = $baseFull
            foreach ($component in @($fullPath.Substring($baseFull.Length + 1).Split([char]'\') | Where-Object { $_.Length -gt 0 })) {
                $current = Join-Path $current $component
                $paths.Add($current)
            }
        }
        foreach ($path in $paths) {
            try { $item = Get-Item -LiteralPath $path -Force -ErrorAction Stop }
            catch [Management.Automation.ItemNotFoundException] {
                if ($AllowMissing) { return [ordered]@{complete=$false;anchors=@($anchors.ToArray());simulated=$false} }
                throw
            }
            catch [Management.Automation.DriveNotFoundException] {
                if ($AllowMissing) { return [ordered]@{complete=$false;anchors=@($anchors.ToArray());simulated=$false} }
                throw
            }
            if (-not $item.PSIsContainer -or ($item.Attributes -band [IO.FileAttributes]::ReparsePoint)) {
                throw "Recovery anchor component is not an exact non-reparse directory: $path"
            }
            $anchor = [CRUWConsumerDirectoryAnchorNative]::Open([IO.Path]::GetFullPath($path).TrimEnd('\'))
            $anchors.Add($anchor)
            $itemAfter = Get-Item -LiteralPath $path -Force -ErrorAction Stop
            if (-not $itemAfter.PSIsContainer -or ($itemAfter.Attributes -band [IO.FileAttributes]::ReparsePoint)) {
                throw "Recovery anchor component changed while opening: $path"
            }
        }
        return [ordered]@{complete=$true;anchors=@($anchors.ToArray());simulated=$false}
    }
    catch {
        for ($index=$anchors.Count-1; $index -ge 0; $index--) { $anchors[$index].Dispose() }
        throw
    }
}

function Add-CRUWBootstrapAnchorChain {
    param(
        [Parameter(Mandatory)] [string] $DirectoryPath,
        [Parameter(Mandatory)] [string] $AnchorBasePath,
        [Parameter(Mandatory)] [string] $ExpectedDrive,
        [switch] $AllowMissing,
        [AllowNull()] [hashtable] $Adapter
    )
    $set = Enter-CRUWBootstrapAnchorChain $DirectoryPath $AnchorBasePath $ExpectedDrive -AllowMissing:$AllowMissing.IsPresent -Adapter $Adapter
    $script:CRUWBootstrapAnchorSets.Add($set)
    return $set
}

function Close-CRUWBootstrapAnchorChains {
    for ($setIndex=$script:CRUWBootstrapAnchorSets.Count-1; $setIndex -ge 0; $setIndex--) {
        $set = $script:CRUWBootstrapAnchorSets[$setIndex]
        if ([bool]$set.simulated) {
            if ($null -ne $TestAdapter -and $TestAdapter.ContainsKey('ExitPathAnchors')) {
                & $TestAdapter.ExitPathAnchors $set | Out-Null
            }
        }
        else {
            $anchors = @($set.anchors)
            for ($anchorIndex=$anchors.Count-1; $anchorIndex -ge 0; $anchorIndex--) {
                if ($null -ne $anchors[$anchorIndex]) { $anchors[$anchorIndex].Dispose() }
            }
        }
    }
    $script:CRUWBootstrapAnchorSets.Clear()
}


function Assert-CRUWSealedBootstrap {
    param(
        [Parameter(Mandatory)] [string] $PrimaryRoot,
        [Parameter(Mandatory)] [string] $EntryRole,
        [Parameter(Mandatory)] [bool] $SkipAcl
    )
    $rootInput = [string]$PrimaryRoot
    if (
        -not [IO.Path]::IsPathRooted($rootInput) -or
        $rootInput.StartsWith('\\') -or
        $rootInput.StartsWith('\\?\') -or
        $rootInput.StartsWith('\\.\') -or
        $rootInput.IndexOf(':',2) -ge 0
    ) { throw 'Sealed bootstrap root must be a local drive path without device syntax or alternate streams' }
    $rootFull = [IO.Path]::GetFullPath($rootInput).TrimEnd('\')
    if ($rootFull -ine $rootInput.TrimEnd('\')) { throw 'Sealed bootstrap root must already be canonical' }
    if (-not $SkipAcl -and $rootFull -notmatch '^C:\\Acer-Driver-Audit\\Recovery\\CRUWBlocker-\d{8}-\d{6}-\d{3}$') {
        throw 'Removal executor must run from the fixed C: recovery topology'
    }
    $bootstrapAdapter = if ($SkipAcl) { $TestAdapter } else { $null }
    $currentAnchorBase = if ($SkipAcl) { $rootFull } else { 'C:\Acer-Driver-Audit' }
    $currentAnchor = Add-CRUWBootstrapAnchorChain $rootFull $currentAnchorBase 'C:' -Adapter $bootstrapAdapter
    if (-not [bool]$currentAnchor.complete) { throw 'Primary recovery root could not be fully anchored' }
    $assertNoReparsePath = {
        param([Parameter(Mandatory)] [string] $CandidatePath)
        $fullCandidate = [IO.Path]::GetFullPath($CandidatePath).TrimEnd('\')
        $driveRoot = [IO.Path]::GetPathRoot($fullCandidate)
        if ($driveRoot -notmatch '^[A-Za-z]:\\$') { throw 'Bootstrap path is not on a local drive' }
        $currentPath = $driveRoot
        $rootItem = Get-Item -LiteralPath $currentPath -Force -ErrorAction Stop
        if ($rootItem.Attributes -band [IO.FileAttributes]::ReparsePoint) { throw "Bootstrap drive root is a reparse point: $driveRoot" }
        $relative = $fullCandidate.Substring($driveRoot.Length).Trim('\')
        foreach ($component in @($relative -split '\\')) {
            if ([string]::IsNullOrWhiteSpace($component) -or $component -in @('.','..') -or $component.Contains(':')) {
                throw 'Bootstrap path contains an unsafe component'
            }
            $nextPath = Join-Path $currentPath $component
            $item = Get-Item -LiteralPath $nextPath -Force -ErrorAction Stop
            if ($item.Attributes -band [IO.FileAttributes]::ReparsePoint) { throw "Bootstrap reparse component rejected: $nextPath" }
            $resolved = [IO.Path]::GetFullPath($item.FullName).TrimEnd('\')
            $expected = [IO.Path]::GetFullPath($nextPath).TrimEnd('\')
            if (-not [string]::Equals($resolved,$expected,[StringComparison]::OrdinalIgnoreCase)) {
                throw "Bootstrap component resolved outside its lexical path: $nextPath"
            }
            $currentPath = $expected
        }
    }
    $implementationRoot = [IO.Path]::GetFullPath((Join-Path $rootFull 'implementation')).TrimEnd('\')
    $actualScriptRoot = [IO.Path]::GetFullPath($PSScriptRoot).TrimEnd('\')
    if (-not [string]::Equals($actualScriptRoot,$implementationRoot,[StringComparison]::OrdinalIgnoreCase)) {
        throw 'Entrypoint must execute from the sealed primary implementation directory'
    }
    if ($rootFull.StartsWith('\\')) { throw 'UNC sealed implementation roots are rejected' }

    $contract = @(
        [ordered]@{role='preflight-producer';relativePath='implementation/Prepare-CRUWBlockerRemoval.ps1';capable=$false},
        [ordered]@{role='preflight-core';relativePath='implementation/CRUWBlockerPreflight.Core.ps1';capable=$false},
        [ordered]@{role='state-machine-common';relativePath='implementation/CRUWStateMachine.Common.ps1';capable=$true},
        [ordered]@{role='removal-executor';relativePath='implementation/Invoke-CRUWBlockerRemoval.ps1';capable=$true},
        [ordered]@{role='interruption-repair';relativePath='implementation/Repair-CRUWInterruptedRemoval.ps1';capable=$true},
        [ordered]@{role='postboot-validator';relativePath='implementation/Test-CRUWBlockerPostboot.ps1';capable=$true}
    )
    $expectedEntry = @($contract | Where-Object { $_.role -ceq $EntryRole })
    if ($expectedEntry.Count -ne 1 -or [IO.Path]::GetFileName($PSCommandPath) -cne [IO.Path]::GetFileName($expectedEntry[0].relativePath)) {
        throw 'Entrypoint role/name does not match the sealed v3 contract'
    }

    $manifestPath = Join-Path $rootFull 'backup-integrity-final.json'
    $preflightPath = Join-Path $rootFull 'preflight.json'
    $commonPath = Join-Path $implementationRoot 'CRUWStateMachine.Common.ps1'
    $bootstrapPaths = @($rootFull,$implementationRoot,$manifestPath,$preflightPath,$commonPath,$PSCommandPath)
    foreach ($path in $bootstrapPaths) {
        & $assertNoReparsePath $path
        if (-not (Test-Path -LiteralPath $path)) { throw "Sealed bootstrap path missing: $path" }
    }
    if (-not $SkipAcl) {
        foreach ($path in $bootstrapPaths) {
            $acl = Get-Acl -LiteralPath $path -ErrorAction Stop
            if (-not $acl.AreAccessRulesProtected) { throw "Sealed bootstrap ACL inherits: $path" }
            try { $owner = ([Security.Principal.NTAccount]$acl.Owner).Translate([Security.Principal.SecurityIdentifier]).Value }
            catch { $owner = [string]$acl.Owner }
            if ($owner -cne 'S-1-5-18') { throw "Sealed bootstrap owner is not SYSTEM: $path" }
            $seenAclSids = @{}
            foreach ($rule in @($acl.Access)) {
                try { $sid = $rule.IdentityReference.Translate([Security.Principal.SecurityIdentifier]).Value }
                catch { $sid = [string]$rule.IdentityReference }
                $fullControl =
                    ([Security.AccessControl.FileSystemRights]$rule.FileSystemRights -band [Security.AccessControl.FileSystemRights]::FullControl) -eq
                    [Security.AccessControl.FileSystemRights]::FullControl
                if ($sid -notin @('S-1-5-18','S-1-5-32-544') -or [string]$rule.AccessControlType -cne 'Allow' -or -not $fullControl) {
                    throw "Sealed bootstrap ACL contains an unauthorized rule: $path"
                }
                $seenAclSids[$sid] = $true
            }
            if ($seenAclSids.Count -ne 2 -or -not $seenAclSids.ContainsKey('S-1-5-18') -or -not $seenAclSids.ContainsKey('S-1-5-32-544')) {
                throw "Sealed bootstrap ACL lacks exact SYSTEM and Administrators FullControl rules: $path"
            }
        }
    }

    $manifestBytes = [IO.File]::ReadAllBytes($manifestPath)
    $manifest = [Text.UTF8Encoding]::new($false,$true).GetString($manifestBytes) | ConvertFrom-Json
    if ([int]$manifest.schemaVersion -ne 1 -or [string]$manifest.role -cne 'authoritative-removal-preflight-manifest') {
        throw 'Sealed bootstrap manifest identity invalid'
    }
    $manifestPrimaryInput = [string]$manifest.recoveryPath
    $manifestSecondaryInput = [string]$manifest.secondaryRecoveryPath
    foreach ($candidate in @($manifestPrimaryInput,$manifestSecondaryInput)) {
        if (
            -not [IO.Path]::IsPathRooted($candidate) -or
            $candidate.StartsWith('\\') -or
            $candidate.StartsWith('\\?\') -or
            $candidate.StartsWith('\\.\') -or
            $candidate.IndexOf(':',2) -ge 0
        ) { throw 'Manifest recovery roots must be local drive paths without device syntax or alternate streams' }
        $canonical = [IO.Path]::GetFullPath($candidate).TrimEnd('\')
        if ($canonical -ine $candidate.TrimEnd('\')) { throw 'Manifest recovery roots must already be canonical' }
    }
    $manifestPrimaryRoot = [IO.Path]::GetFullPath($manifestPrimaryInput).TrimEnd('\')
    $manifestSecondaryRoot = [IO.Path]::GetFullPath($manifestSecondaryInput).TrimEnd('\')
    if ($manifestPrimaryRoot -ine $rootFull -or $manifestPrimaryRoot -ieq $manifestSecondaryRoot) {
        throw 'Manifest recovery root topology does not match the running primary root'
    }
    if (-not $SkipAcl) {
        if (
            $manifestPrimaryRoot -notmatch '^C:\\Acer-Driver-Audit\\Recovery\\CRUWBlocker-\d{8}-\d{6}-\d{3}$' -or
            $manifestSecondaryRoot -notmatch '^D:\\Acer-Recovery\\CRUWBlocker-\d{8}-\d{6}-\d{3}$' -or
            (Split-Path -Leaf $manifestPrimaryRoot) -cne (Split-Path -Leaf $manifestSecondaryRoot)
        ) { throw 'Manifest recovery roots do not match the fixed C:/D: topology' }
    }
    $secondaryAnchorBase = if ($SkipAcl) { $manifestSecondaryRoot } else { 'D:\Acer-Recovery' }
    $secondaryAnchor = Add-CRUWBootstrapAnchorChain $manifestSecondaryRoot $secondaryAnchorBase 'D:' -Adapter $bootstrapAdapter
    if (-not [bool]$secondaryAnchor.complete) { throw 'Secondary recovery root could not be fully anchored' }
    if (-not $SkipAcl) {
        foreach ($peerPath in @($manifestSecondaryRoot,(Join-Path $manifestSecondaryRoot 'backup-integrity-final.json'))) {
            & $assertNoReparsePath $peerPath
            if (-not (Test-Path -LiteralPath $peerPath)) { throw "Sealed secondary bootstrap path missing: $peerPath" }
            $acl = Get-Acl -LiteralPath $peerPath -ErrorAction Stop
            if (-not $acl.AreAccessRulesProtected) { throw "Sealed secondary bootstrap ACL inherits: $peerPath" }
            try { $owner = ([Security.Principal.NTAccount]$acl.Owner).Translate([Security.Principal.SecurityIdentifier]).Value }
            catch { $owner = [string]$acl.Owner }
            if ($owner -cne 'S-1-5-18') { throw "Sealed secondary bootstrap owner is not SYSTEM: $peerPath" }
            $seenAclSids = @{}
            foreach ($rule in @($acl.Access)) {
                try { $sid = $rule.IdentityReference.Translate([Security.Principal.SecurityIdentifier]).Value }
                catch { $sid = [string]$rule.IdentityReference }
                $fullControl =
                    ([Security.AccessControl.FileSystemRights]$rule.FileSystemRights -band [Security.AccessControl.FileSystemRights]::FullControl) -eq
                    [Security.AccessControl.FileSystemRights]::FullControl
                if ($sid -notin @('S-1-5-18','S-1-5-32-544') -or [string]$rule.AccessControlType -cne 'Allow' -or -not $fullControl) {
                    throw "Sealed secondary bootstrap ACL contains an unauthorized rule: $peerPath"
                }
                $seenAclSids[$sid] = $true
            }
            if ($seenAclSids.Count -ne 2 -or -not $seenAclSids.ContainsKey('S-1-5-18') -or -not $seenAclSids.ContainsKey('S-1-5-32-544')) {
                throw "Sealed secondary bootstrap ACL lacks exact SYSTEM and Administrators FullControl rules: $peerPath"
            }
        }
    }
    $secondaryManifestPath = Join-Path $manifestSecondaryRoot 'backup-integrity-final.json'
    if (-not (Test-Path -LiteralPath $secondaryManifestPath -PathType Leaf) -or
        (Get-FileHash -LiteralPath $secondaryManifestPath -Algorithm SHA256).Hash -ine (Get-FileHash -LiteralPath $manifestPath -Algorithm SHA256).Hash) {
        throw 'Sealed bootstrap requires byte-identical primary and secondary manifests'
    }
    $artifacts = @($manifest.implementation.artifacts)
    if (
        (@($manifest.implementation.PSObject.Properties.Name) -join '|') -cne 'producerPerformsDriverMutation|sealedBundleContainsBootCriticalMutation|artifacts' -or
        [bool]$manifest.implementation.producerPerformsDriverMutation -or
        -not [bool]$manifest.implementation.sealedBundleContainsBootCriticalMutation -or
        $artifacts.Count -ne $contract.Count
    ) { throw 'Sealed bootstrap implementation header/cardinality invalid' }
    for ($index=0; $index -lt $contract.Count; $index++) {
        $artifact = $artifacts[$index]
        $expected = $contract[$index]
        if (
            (@($artifact.PSObject.Properties.Name) -join '|') -cne 'role|relativePath|sha256|driverMutationCapable' -or
            [string]$artifact.role -cne [string]$expected.role -or
            [string]$artifact.relativePath -cne [string]$expected.relativePath -or
            [bool]$artifact.driverMutationCapable -ne [bool]$expected.capable -or
            [string]$artifact.sha256 -notmatch '^[A-F0-9]{64}$'
        ) { throw "Sealed bootstrap artifact contract invalid at index $index" }
    }
    foreach ($role in @('state-machine-common',$EntryRole)) {
        $artifact = @($artifacts | Where-Object { [string]$_.role -ceq $role })
        if ($artifact.Count -ne 1) { throw "Sealed bootstrap artifact missing: $role" }
        $path = if ($role -ceq 'state-machine-common') { $commonPath } else { $PSCommandPath }
        $hash = (Get-FileHash -LiteralPath $path -Algorithm SHA256).Hash
        if ($hash -ine [string]$artifact[0].sha256) { throw "Running sealed artifact hash mismatch: $role" }
        $record = @($manifest.files | Where-Object { [string]$_.relativePath -ceq [string]$artifact[0].relativePath })
        if ($record.Count -ne 1 -or -not [bool]$record[0].hashesMatch -or $hash -ine [string]$record[0].primarySha256) {
            throw "Manifest file record mismatch for running artifact: $role"
        }
    }
    $preflightRecord = @($manifest.files | Where-Object { [string]$_.relativePath -ceq 'preflight.json' })
    if ($preflightRecord.Count -ne 1 -or -not [bool]$preflightRecord[0].hashesMatch -or
        (Get-FileHash -LiteralPath $preflightPath -Algorithm SHA256).Hash -ine [string]$preflightRecord[0].primarySha256) {
        throw 'Sealed bootstrap preflight hash record invalid'
    }
    $preflight = Get-Content -LiteralPath $preflightPath -Raw -Encoding UTF8 | ConvertFrom-Json
    if ([int]$preflight.schemaVersion -ne 3 -or
        (@($preflight.implementation.artifacts) | ConvertTo-Json -Depth 6 -Compress) -cne ($artifacts | ConvertTo-Json -Depth 6 -Compress)) {
        throw 'Sealed bootstrap preflight v3 implementation differs from manifest'
    }
}

$bootstrapPrimaryRoot = Split-Path -Parent ([IO.Path]::GetFullPath($PreflightPath))
trap {
    Close-CRUWBootstrapAnchorChains
    throw
}
Assert-CRUWSealedBootstrap -PrimaryRoot $bootstrapPrimaryRoot -EntryRole 'removal-executor' -SkipAcl $TestMode.IsPresent
. (Join-Path $PSScriptRoot 'CRUWStateMachine.Common.ps1')

$allConfirmations =
    $OffMachineRecoveryKeyConfirmed.IsPresent -and
    $PhysicalConsoleAccessConfirmed.IsPresent -and
    $ManualRebootWindowConfirmed.IsPresent -and
    $ConfirmBootCriticalDriverRemoval.IsPresent
if (-not $allConfirmations) { throw 'All boot-critical confirmations must be explicitly true' }
if ($TestMode.IsPresent -ne ($null -ne $TestAdapter)) { throw 'TestMode and TestAdapter must be supplied together' }

$adapter = if ($TestMode) { $TestAdapter } else { New-CRUWNativeAdapter }
if (-not [bool](Invoke-CRUWAdapter $adapter 'IsAdministrator')) { throw 'Already-elevated Administrator context is required' }

$preflightFull = [IO.Path]::GetFullPath($PreflightPath)
if (-not (Test-Path -LiteralPath $preflightFull -PathType Leaf)) { throw 'Preflight missing' }
$preflight = Get-Content -LiteralPath $preflightFull -Raw -Encoding UTF8 | ConvertFrom-Json
$integrity = Test-CRUWBackupIntegrity $preflight $preflightFull $adapter
if (-not [bool]$integrity.verified) { throw "Backup integrity failed: $($integrity.failures -join '; ')" }
$implementationSeal = Test-CRUWImplementationSeal $integrity $preflight ([string]$preflight.recoveryPath) $PSCommandPath
if (-not [bool]$implementationSeal.verified) { throw "Running implementation is not sealed: $($implementationSeal.failures -join '; ')" }

$now = [DateTimeOffset](Invoke-CRUWAdapter $adapter 'GetNow')
$checked = [DateTimeOffset]$preflight.checkedAt
$boot = Invoke-CRUWAdapter $adapter 'GetBootIdentity'
$preflightBootUtc = ConvertTo-CRUWUtcRoundtripString $preflight.bootIdentity.lastBootUpTimeUtc
$currentBootUtc = ConvertTo-CRUWUtcRoundtripString $boot.lastBootUpTimeUtc
$recomputedMarker = Get-CRUWStringSha256 ($preflightBootUtc + '|' + [string]$preflight.bootIdentity.operatingSystemBuild)
$sameBootTime = $currentBootUtc -ceq $preflightBootUtc
$sameBootBuild = [string]$boot.operatingSystemBuild -ceq [string]$preflight.bootIdentity.operatingSystemBuild
$sameBootMarker = [string]$boot.markerSha256 -ceq [string]$preflight.bootIdentity.markerSha256
$sameBootRecomputed = $recomputedMarker -ceq [string]$preflight.bootIdentity.markerSha256
$sameBoot = $sameBootTime -and $sameBootBuild -and $sameBootMarker -and $sameBootRecomputed
$ageMinutes = ($now - $checked).TotalMinutes

$rollbackCapability = Get-CRUWPropertyValue $preflight 'rollbackCapability'
$rollbackCapabilityEvidence = Test-CRUWRollbackCapabilityContract $rollbackCapability $preflight -SimulationOnly:$TestMode.IsPresent
$gates = [ordered]@{
    schemaVersion3 = [int]$preflight.schemaVersion -eq 3
    technicalPass = [bool]$preflight.technicalPreflightPass
    fresh = $ageMinutes -ge 0 -and $ageMinutes -le $MaxPreflightAgeMinutes
    sameBootTime = $sameBootTime
    sameBootBuild = $sameBootBuild
    sameBootMarker = $sameBootMarker
    sameBootRecomputed = $sameBootRecomputed
    sameBootContract = $sameBoot -and [bool]$preflight.bootIdentity.verified -and [bool]$preflight.bootIdentity.removalMustMatchThisBoot
    preflightPendingRebootClear = -not [bool]$preflight.pendingReboot.detected
    noPriorMutation = -not [bool]$preflight.driverMutationPerformed -and -not [bool]$preflight.mutationPerformed
    bitLockerReady = [bool]$preflight.bitLocker.readyForBoundedSuspension -and [bool]$preflight.bitLocker.allEncryptedMountedVolumesRecoverable -and -not [bool]$preflight.bitLocker.secretRecorded
    twoTargetDisks = [bool]$preflight.driverBindingDiscovery.exactlyTwoPresentDiskDrives -and [bool]$preflight.driverBindingDiscovery.exactlyTwoTargetBindings
    filtersCaptured = [bool]$preflight.filterSnapshot.deviceAndClassUpperAndLowerFiltersCaptured -and [bool]$preflight.filterSnapshot.serviceReady
    layout = [bool]$preflight.storageLayout.verified -and [int]$preflight.storageLayout.distinctPhysicalDiskCount -eq 2
    fallback = [bool]$preflight.fallbackDriver.verified
    signatures = [bool]$preflight.driverExport.signaturesValid
    rollbackCapabilityExact = [bool]$rollbackCapabilityEvidence.verified
    backupAndAcl = [bool]$integrity.verified
    implementationSeal = [bool]$implementationSeal.verified
}
$failedGates = @($gates.GetEnumerator() | Where-Object { -not [bool]$_.Value } | ForEach-Object Key)
if ($failedGates.Count -gt 0) { throw "Preflight v3 ineligible: $($failedGates -join ', ')" }

$identity = Get-CRUWPreflightIdentity $preflight $integrity.manifest
$mounts = @($preflight.storageLayout.volumes | ForEach-Object { ([string]$_.driveLetter).TrimEnd(':').ToUpperInvariant() + ':' })
if ($mounts.Count -ne 2 -or -not (Test-CRUWEqualSet $mounts @('C:', 'D:'))) { throw 'Sealed layout must be exactly C: and D:' }
$encryptedMounts = @(Get-CRUWEncryptedMountPoints $preflight)

$primaryRoot = [string]$preflight.recoveryPath
$secondaryRoot = [string]$preflight.secondaryRecoveryPath
$mutexHandle = Invoke-CRUWAdapter $adapter 'EnterOperationMutex'
try {
$unknownJournalArtifacts = @(Get-CRUWUnrecognizedJournalArtifacts $primaryRoot $secondaryRoot)
if ($unknownJournalArtifacts.Count -gt 0) { throw 'Unrecognized removal-journal artifacts require manual forensic review' }
$unfinished = @(Get-CRUWUnfinishedOperations $primaryRoot $secondaryRoot $adapter)
if ($unfinished.Count -gt 0) {
    throw "An unfinished removal operation already exists; use the recovery entrypoint: $($unfinished.operationId -join ', ')"
}

$before = Invoke-CRUWAdapter $adapter 'GetStorageSnapshot' @($identity.document.publishedName, $identity.document.filterName, $mounts, $identity.document)
$beforeState = Get-CRUWStateClassification $before $identity.document $mounts Preboot
$beforePackages = @($before.packages)
$initialPublishedExact =
    $beforePackages.Count -eq 1 -and
    [string]$beforePackages[0].publishedName -ieq $identity.document.publishedName -and
    @($before.devices | Where-Object { [string]$_.inf -ine $identity.document.publishedName }).Count -eq 0
if ([string]$beforeState.classification -cne 'LEGACY_INTACT' -or -not $initialPublishedExact) {
    throw 'Initial live state no longer exactly matches sealed legacy package/bindings'
}
$rollbackBaselineReadback = Test-CRUWRollbackLiveReadback $before $rollbackCapability
$gates.rollbackBaselineLiveReadbackExact = [bool]$rollbackBaselineReadback.verified
$gates.rollbackFilterSnapshotPackageEvidence =
    [string](Get-CRUWPropertyValue $identity.document.service 'exportedInfSignatureStatus') -ceq 'Valid' -and
    [bool](Get-CRUWPropertyValue $identity.document.service 'knownPackageHashesVerified' $false)
if (-not [bool]$rollbackBaselineReadback.verified) {
    throw "Initial CRUW service configuration differs from the sealed rollback target: $($rollbackBaselineReadback.failedGates -join ', ')"
}
if (-not [bool]$gates.rollbackFilterSnapshotPackageEvidence) {
    throw 'Filter snapshot does not seal valid INF signature and known-package hash evidence'
}

$nativeBaseline = @($before.nativeStorageServices)
$baselineNativeEvidence = Test-CRUWNativeStorageServiceDrift $nativeBaseline $nativeBaseline
if (-not [bool]$baselineNativeEvidence.verified) { throw "Native storage service baseline invalid: $($baselineNativeEvidence.failures -join '; ')" }
$acBefore = Invoke-CRUWAdapter $adapter 'GetAcPowerState'
if (-not [bool]$acBefore.online) { throw 'Live AC power is required' }
$bitLockerBefore = Get-CRUWBitLockerInventoryEvidence $adapter $encryptedMounts AllOn
if (-not [bool]$bitLockerBefore.verified) { throw 'Encrypted-volume BitLocker inventory is not ready' }
$pendingBeforePrepared = Invoke-CRUWAdapter $adapter 'GetPendingRebootState'
if ([bool]$pendingBeforePrepared.detected) { throw 'Live pending reboot appeared before transaction preparation' }

$operationId = [guid]::NewGuid()
$context = [ordered]@{
    preflight = [ordered]@{
        path = $preflightFull
        sha256 = (Get-FileHash -LiteralPath $preflightFull -Algorithm SHA256).Hash
        integrityManifestSha256 = $integrity.primaryManifestSha256
        gates = $gates
    }
    confirmation = [ordered]@{
        phrase = $ConfirmationPhrase
        offMachineKey = $true
        physicalConsole = $true
        manualRebootWindow = $true
    }
    mutationBoot = $boot
    targetIdentity = $identity.document
    targetIdentitySha256 = $identity.sha256
    requiredMountPoints = $mounts
    encryptedMountPoints = $encryptedMounts
    acBefore = $acBefore
    before = [ordered]@{ state = $beforeState; snapshot = $before }
    nativeStorageServicesBaseline = $nativeBaseline
    pendingBeforePrepared = $pendingBeforePrepared
    rollbackCapability = [ordered]@{contract=$rollbackCapability;validation=$rollbackCapabilityEvidence;baselineLiveReadback=$rollbackBaselineReadback}
    bitLocker = [ordered]@{
        before = $bitLockerBefore
        requestedRebootCount = 2
        suspendVerified = $false
        resumeOnAbortVerified = $false
        secretRecorded = $false
    }
    deleteDriver = $null
    deleteIntentContract = [ordered]@{
        executable = 'pnputil.exe'
        arguments = @('/delete-driver', [string]$identity.document.publishedName, '/uninstall')
        repeatAfterAmbiguousIntent = $false
    }
    immediate = $null
    prebootProbes = $null
    nativeServiceNoDrift = $false
    rollback = $null
    final = $null
    mutationAccepted = $false
    pnputilWarning = $null
    rebootPerformedByScript = $false
    registryOrServiceDeletionPerformedByScript = $false
    operatorActionRequired = 'DO NOT REBOOT unless a terminal REBOOT_AUTHORIZED checkpoint exists.'
}
$journalState = [ordered]@{
    sequence = 0
    previous = $null
    checkpoints = [Collections.ArrayList]::new()
    terminal = $null
    healthy = $true
}
$checkpoint = {
    param([string] $Stage)
    try {
        $entry = Write-CRUWDualJournal $primaryRoot $secondaryRoot $operationId $journalState.sequence $Stage $journalState.previous $context $adapter
        Set-CRUWPropertyValue $context lastDualCommit ([ordered]@{
            sequence=[int]$entry.sequence;stage=[string]$entry.stage;payloadSha256=[string]$entry.payloadSha256;
            primaryFileSha256=[string]$entry.primarySha256;secondaryFileSha256=[string]$entry.secondarySha256;
            primaryPathSha256=Get-CRUWStringSha256 ([string]$entry.primaryPath);
            secondaryPathSha256=Get-CRUWStringSha256 ([string]$entry.secondaryPath)
        })
        [void]$journalState.checkpoints.Add($entry)
        $journalState.previous = $entry.payloadSha256
        $journalState.sequence++
        $journalState.terminal = $entry
        return $entry
    }
    catch {
        $journalState.healthy = $false
        throw
    }
}

$captureLiveMutationGate = {
    param(
        [Parameter(Mandatory)]
        [ValidateSet('AllOn','COffOthersOn')]
        [string] $ExpectedBitLockerMode
    )
    $freshIntegrity = Test-CRUWBackupIntegrity $preflight $preflightFull $adapter
    $freshSeal = if ([bool]$freshIntegrity.verified) {
        Test-CRUWImplementationSeal $freshIntegrity $preflight $primaryRoot $PSCommandPath
    }
    else { [ordered]@{verified=$false;failures=@('backup integrity failed before implementation seal')} }
    $freshBoot = Invoke-CRUWAdapter $adapter 'GetBootIdentity'
    $freshPending = Invoke-CRUWAdapter $adapter 'GetPendingRebootState'
    $freshAc = Invoke-CRUWAdapter $adapter 'GetAcPowerState'
    $freshSnapshot = Invoke-CRUWAdapter $adapter 'GetStorageSnapshot' @(
        $identity.document.publishedName,
        $identity.document.filterName,
        $mounts,
        $identity.document
    )
    $freshState = Get-CRUWStateClassification $freshSnapshot $identity.document $mounts Preboot
    $freshPackages = @($freshSnapshot.packages)
    $freshPublishedExact =
        $freshPackages.Count -eq 1 -and
        [string]$freshPackages[0].publishedName -ieq $identity.document.publishedName -and
        @($freshSnapshot.devices | Where-Object { [string]$_.inf -ine $identity.document.publishedName }).Count -eq 0
    $freshNative = Test-CRUWNativeStorageServiceDrift $nativeBaseline $freshSnapshot.nativeStorageServices
    $freshRollbackReadback = Test-CRUWRollbackLiveReadback $freshSnapshot $rollbackCapability
    $freshProbes = @($mounts | ForEach-Object { Invoke-CRUWAdapter $adapter 'ProbeVolume' @($_) })
    $freshProbeEvidence = Test-CRUWProbeEvidence $freshProbes $mounts
    $freshEvents = @(Invoke-CRUWAdapter $adapter 'GetCriticalEventsSince' @([DateTimeOffset]$preflight.checkedAt))
    $freshReadiness = Invoke-CRUWAdapter $adapter 'GetRecoveryReadiness'
    $freshBitLocker = Get-CRUWBitLockerInventoryEvidence $adapter $encryptedMounts $ExpectedBitLockerMode
    $freshGates = [ordered]@{
        backupIntegrityAndAcl = [bool]$freshIntegrity.verified
        implementationSeal = [bool]$freshSeal.verified
        sameExactBoot = Test-CRUWSameBootIdentity $freshBoot $boot
        pendingRebootClear = -not [bool]$freshPending.detected
        acPowerOnline = [bool]$freshAc.online
        legacyIntact = [string]$freshState.classification -ceq 'LEGACY_INTACT'
        exactPublishedPackageAndBindings = [bool]$freshPublishedExact
        nativeStorageServicesNoDrift = [bool]$freshNative.verified
        rollbackServiceBaselineExact = [bool]$freshRollbackReadback.verified
        cAndDWriteReadHashDelete = [bool]$freshProbeEvidence.verified
        noStorageWarningsErrorsOrCriticalEvents = $freshEvents.Count -eq 0
        sealedRecoveryReadiness = Test-CRUWRecoveryReadiness $freshReadiness $preflight
        bitLockerExpectedState = [bool]$freshBitLocker.verified
    }
    $freshFailures = @($freshGates.GetEnumerator() | Where-Object { -not [bool]$_.Value } | ForEach-Object Key)
    return [ordered]@{
        verified = $freshFailures.Count -eq 0
        expectedBitLockerMode = $ExpectedBitLockerMode
        gates = $freshGates
        failedGates = $freshFailures
        integrity = [ordered]@{
            verified=[bool]$freshIntegrity.verified
            primaryManifestSha256=[string]$freshIntegrity.primaryManifestSha256
            secondaryManifestSha256=[string]$freshIntegrity.secondaryManifestSha256
            failures=@($freshIntegrity.failures)
        }
        implementationSeal = $freshSeal
        boot = $freshBoot
        pending = $freshPending
        acPower = $freshAc
        state = $freshState
        snapshot = $freshSnapshot
        nativeServiceDrift = $freshNative
        rollbackServiceReadback = $freshRollbackReadback
        probes = [ordered]@{evidence=$freshProbeEvidence;items=$freshProbes}
        events = $freshEvents
        recoveryReadiness = $freshReadiness
        bitLocker = $freshBitLocker
    }
}

& $checkpoint PREPARED | Out-Null
$suspendAttempted = $false
$deleteAttempted = $false
$rollbackAttempted = $false
$rollbackExitCodeSafe = $true
$resumeAttempted = $false
$authorized = $false
$failure = $null
$delete = $null

try {
    & $checkpoint SUSPEND_INTENT | Out-Null
    $suspendLiveGate = & $captureLiveMutationGate AllOn
    $context.suspendLiveGate = $suspendLiveGate
    $context.pendingAtSuspend = $suspendLiveGate.pending
    $context.acAtSuspend = $suspendLiveGate.acPower
    & $checkpoint SUSPEND_LIVE_GATE | Out-Null
    if (-not [bool]$suspendLiveGate.verified) {
        throw "Fresh pre-suspension gates failed: $($suspendLiveGate.failedGates -join ', ')"
    }

    $suspendAttempted = $true
    Invoke-CRUWAdapter $adapter 'SuspendBitLocker' @('C:', 2) | Out-Null
    $afterSuspend = Get-CRUWBitLockerInventoryEvidence $adapter $encryptedMounts COffOthersOn
    $context.bitLocker.afterSuspend = $afterSuspend
    $context.bitLocker.suspendVerified = [bool]$afterSuspend.verified
    & $checkpoint SUSPEND_RESULT | Out-Null
    if (-not [bool]$context.bitLocker.suspendVerified) { throw 'BitLocker suspension not verified' }

    $context.deleteSetupApiBefore = Invoke-CRUWAdapter $adapter 'GetSetupApiEvidence'
    & $checkpoint DELETE_INTENT | Out-Null
    $deleteLiveGate = & $captureLiveMutationGate COffOthersOn
    $context.deleteLiveGate = $deleteLiveGate
    $context.pendingAtDelete = $deleteLiveGate.pending
    $context.acAtDelete = $deleteLiveGate.acPower
    & $checkpoint DELETE_LIVE_GATE | Out-Null
    if (-not [bool]$deleteLiveGate.verified) {
        throw "Fresh pre-delete gates failed: $($deleteLiveGate.failedGates -join ', ')"
    }

    $deleteAttempted = $true
    $deleteStarted = [DateTimeOffset](Invoke-CRUWAdapter $adapter 'GetNow')
    $delete = Invoke-CRUWAdapter $adapter 'DeleteDriver' @($identity.document.publishedName)
    $deleteEnded = [DateTimeOffset](Invoke-CRUWAdapter $adapter 'GetNow')
    $deleteArguments = @($delete.arguments)
    $deleteContractValid =
        [string]$delete.executable -ceq 'pnputil.exe' -and
        $deleteArguments.Count -eq 3 -and
        [string]$deleteArguments[0] -ceq '/delete-driver' -and
        [string]$deleteArguments[1] -ceq $identity.document.publishedName -and
        [string]$deleteArguments[2] -ceq '/uninstall'
    if (-not $deleteContractValid) { throw 'Delete adapter violated exact contract' }
    $context.deleteDriver = [ordered]@{
        startedAt = $deleteStarted.ToString('o')
        completedAt = $deleteEnded.ToString('o')
        result = $delete
        setupApiEvidence = Invoke-CRUWAdapter $adapter 'GetSetupApiEvidence'
        exitCodePolicy = switch ([int]$delete.exitCode) {
            0 { 'SUCCESS' }
            3010 { 'SUCCESS_REBOOT_REQUIRED' }
            259 { 'NO_MATCHING_OR_BETTER_DRIVER_BLOCKED' }
            1641 { 'UNEXPECTED_REBOOT_INITIATED_BLOCKED' }
            default { 'UNRECOGNIZED_EXIT_BLOCKED' }
        }
    }
    & $checkpoint DELETE_RESULT | Out-Null

    $immediateSnapshot = Invoke-CRUWAdapter $adapter 'GetStorageSnapshot' @($identity.document.publishedName, $identity.document.filterName, $mounts, $identity.document)
    $immediateState = Get-CRUWStateClassification $immediateSnapshot $identity.document $mounts Preboot
    $context.immediate = [ordered]@{ state = $immediateState; snapshot = $immediateSnapshot }
    & $checkpoint SNAPSHOT_CLASSIFIED | Out-Null

    if ([int]$delete.exitCode -notin @(0,3010)) {
        throw "PnPUtil delete exit code $([int]$delete.exitCode) is not authorization-safe; live state is diagnostic evidence only"
    }

    if ([string]$immediateState.classification -notin @('CLEAN_PREBOOT', 'LEGACY_INTACT')) {
        $rollbackBackup = Get-CRUWValidatedRollbackInf $primaryRoot $secondaryRoot $integrity.primaryManifestSha256 $adapter $integrity.recoveryRootTopology
        $context.rollbackBackupValidation = $rollbackBackup
        $context.rollbackSetupApiBefore = Invoke-CRUWAdapter $adapter 'GetSetupApiEvidence'
        & $checkpoint ROLLBACK_INTENT | Out-Null
        $rollbackAttempted = $true
        $rollbackResult = Invoke-CRUWAdapter $adapter 'ReinstallBackupDriver' @($rollbackBackup.infPath)
        $rollbackArguments = @($rollbackResult.arguments)
        $rollbackContractValid =
            [string]$rollbackResult.executable -ceq 'pnputil.exe' -and
            $rollbackArguments.Count -eq 3 -and
            [string]$rollbackArguments[0] -ceq '/add-driver' -and
            [string]$rollbackArguments[1] -ceq [string]$rollbackBackup.infPath -and
            [string]$rollbackArguments[2] -ceq '/install'
        if (-not $rollbackContractValid) { throw 'Rollback adapter violated exact contract' }

        $rolledSnapshot = Invoke-CRUWAdapter $adapter 'GetStorageSnapshot' @($identity.document.publishedName, $identity.document.filterName, $mounts, $identity.document)
        $rolledState = Get-CRUWStateClassification $rolledSnapshot $identity.document $mounts Preboot
        $rolledLiveReadback = Test-CRUWRollbackLiveReadback $rolledSnapshot $rollbackCapability
        $rollbackExitCodeSafe = [int]$rollbackResult.exitCode -in @(0,3010)
        $rollbackExitCodePolicy = switch ([int]$rollbackResult.exitCode) {
            0 { 'SUCCESS' }; 3010 { 'SUCCESS_REBOOT_REQUIRED' }; 259 { 'NO_MATCHING_OR_BETTER_DRIVER_BLOCKED' }
            1641 { 'UNEXPECTED_REBOOT_INITIATED_BLOCKED' }; default { 'UNRECOGNIZED_EXIT_BLOCKED' }
        }
        $context.rollback = [ordered]@{
            result=$rollbackResult;setupApiEvidence=(Invoke-CRUWAdapter $adapter 'GetSetupApiEvidence');
            exitCodePolicy=$rollbackExitCodePolicy;state=$rolledState;snapshot=$rolledSnapshot;liveReadback=$rolledLiveReadback
        }
        $context.final = $context.rollback
        & $checkpoint ROLLBACK_RESULT | Out-Null
        if (-not $rollbackExitCodeSafe -or [string]$rolledState.classification -cne 'LEGACY_INTACT' -or -not [bool]$rolledLiveReadback.verified) {
            throw "Rollback did not restore full LEGACY_INTACT: $($rolledState.classification)"
        }
    }
    else {
        $context.final = $context.immediate
    }

    if ([string]$context.final.state.classification -cne 'CLEAN_PREBOOT') {
        throw "Removal did not reach CLEAN_PREBOOT: $($context.final.state.classification)"
    }

    & $checkpoint FINAL_AUTHORIZATION_INTENT | Out-Null

    # This is intentionally a fresh, all-source recapture immediately before
    # the only checkpoint that permits a manual reboot.
    $finalPending = Invoke-CRUWAdapter $adapter 'GetPendingRebootState'
    $finalBitLocker = Get-CRUWBitLockerInventoryEvidence $adapter $encryptedMounts COffOthersOn
    $finalAc = Invoke-CRUWAdapter $adapter 'GetAcPowerState'
    $finalIntegrity = Test-CRUWBackupIntegrity $preflight $preflightFull $adapter
    $finalBoot = Invoke-CRUWAdapter $adapter 'GetBootIdentity'
    $finalSnapshot = Invoke-CRUWAdapter $adapter 'GetStorageSnapshot' @($identity.document.publishedName, $identity.document.filterName, $mounts, $identity.document)
    $finalState = Get-CRUWStateClassification $finalSnapshot $identity.document $mounts Preboot
    $finalNativeDrift = Test-CRUWNativeStorageServiceDrift $nativeBaseline $finalSnapshot.nativeStorageServices
    $finalProbes = @($mounts | ForEach-Object { Invoke-CRUWAdapter $adapter 'ProbeVolume' @($_) })
    $finalProbeEvidence = Test-CRUWProbeEvidence $finalProbes $mounts
    $finalEvents = @(Invoke-CRUWAdapter $adapter 'GetCriticalEventsSince' @($deleteStarted))
    $finalRecoveryReadiness = Invoke-CRUWAdapter $adapter 'GetRecoveryReadiness'
    $finalChain = Test-CRUWJournalChain $journalState.terminal.primaryPath $primaryRoot $secondaryRoot $adapter

    $finalGates = [ordered]@{
        journalCommonPrefix = [bool]$finalChain.verified
        pendingRebootClear = -not [bool]$finalPending.detected
        bitLockerSuspendedBounded = [bool]$finalBitLocker.verified
        acPowerOnline = [bool]$finalAc.online
        backupIntegrityAndAcl = [bool]$finalIntegrity.verified
        sameExactBoot = Test-CRUWSameBootIdentity $finalBoot $boot
        cleanPreboot = [string]$finalState.classification -ceq 'CLEAN_PREBOOT'
        nativeStorageServicesNoDrift = [bool]$finalNativeDrift.verified
        cAndDWriteReadHashDelete = [bool]$finalProbeEvidence.verified
        noStorageWarningsErrorsOrCriticalEvents = $finalEvents.Count -eq 0
        sealedRecoveryReadiness = Test-CRUWRecoveryReadiness $finalRecoveryReadiness $preflight
    }
    $failedFinalGates = @($finalGates.GetEnumerator() | Where-Object { -not [bool]$_.Value } | ForEach-Object Key)
    $context.final = [ordered]@{ state=$finalState; snapshot=$finalSnapshot }
    $context.prebootProbes = [ordered]@{ allGreen=[bool]$finalProbeEvidence.verified; probes=$finalProbes }
    $context.nativeServiceNoDrift = [bool]$finalNativeDrift.verified
    $context.nativeServiceDrift = $finalNativeDrift
    $context.bootStable = [bool]$finalGates.sameExactBoot
    $context.finalAuthorization = [ordered]@{
        gates = $finalGates
        failedGates = $failedFinalGates
        pending = $finalPending
        bitLocker = $finalBitLocker
        acPower = $finalAc
        backupIntegrity = $finalIntegrity
        boot = $finalBoot
        state = $finalState
        snapshot = $finalSnapshot
        nativeServiceDrift = $finalNativeDrift
        probes = $finalProbeEvidence
        events = $finalEvents
        recoveryReadiness = $finalRecoveryReadiness
        journal = [ordered]@{
            verified = [bool]$finalChain.verified
            failures = @($finalChain.failures)
            entryCount = [int]$finalChain.entryCount
            terminalPayloadSha256 = [string]$finalChain.terminalPayloadSha256
            latestCommittedPathSha256 = Get-CRUWStringSha256 ([string]$finalChain.latestCommittedPrimaryPath)
        }
    }
    if ($failedFinalGates.Count -gt 0) {
        throw "Final reboot authorization gates failed: $($failedFinalGates -join ', ')"
    }

    # Commit-live gate: no slow diagnostic work is permitted after this
    # recapture and before the append-only REBOOT_AUTHORIZED checkpoint.
    $commitPending = Invoke-CRUWAdapter $adapter 'GetPendingRebootState'
    $commitAc = Invoke-CRUWAdapter $adapter 'GetAcPowerState'
    $commitBoot = Invoke-CRUWAdapter $adapter 'GetBootIdentity'
    $commitBitLocker = Get-CRUWBitLockerInventoryEvidence $adapter $encryptedMounts COffOthersOn
    $commitLiveGates = [ordered]@{
        pendingRebootClear = -not [bool]$commitPending.detected
        acPowerOnline = [bool]$commitAc.online
        sameExactBoot = Test-CRUWSameBootIdentity $commitBoot $boot
        bitLockerSuspendedBounded = [bool]$commitBitLocker.verified
    }
    $commitLiveFailed = @($commitLiveGates.GetEnumerator() | Where-Object { -not [bool]$_.Value } | ForEach-Object Key)
    Set-CRUWPropertyValue $context.finalAuthorization commitLive ([ordered]@{
        gates=$commitLiveGates;failedGates=$commitLiveFailed;pending=$commitPending;
        acPower=$commitAc;boot=$commitBoot;bitLocker=$commitBitLocker
    })
    if ($commitLiveFailed.Count -gt 0) {
        throw "Commit-live reboot authorization gates failed: $($commitLiveFailed -join ', ')"
    }

    if ([int]$delete.exitCode -eq 3010) {
        $context.pnputilWarning = 'pnputil exited 3010 (success; reboot required); exact CLEAN_PREBOOT and all live gates independently verified'
    }
    $context.mutationAccepted = $true
    $context.safeExit = $true
    $context.operatorActionRequired = 'Perform exactly one deliberate MANUAL reboot, then pass this REBOOT_AUTHORIZED checkpoint to postboot validation.'
    & $checkpoint REBOOT_AUTHORIZED | Out-Null
    $authorized = $true
}
catch {
    $failure = $_.Exception.Message
    $context.failure = $failure
}

if (-not $authorized) {
    $recoveryFailures = [Collections.Generic.List[string]]::new()

    if ($deleteAttempted) {
        $knownFinalState = if ($null -eq $context.final) { '' } else { [string](Get-CRUWPropertyValue $context.final.state 'classification' '') }
        if ($knownFinalState -notin @('LEGACY_INTACT', 'CLEAN_PREBOOT')) {
            try {
                $observedSnapshot = Invoke-CRUWAdapter $adapter 'GetStorageSnapshot' @($identity.document.publishedName, $identity.document.filterName, $mounts, $identity.document)
                $observedState = Get-CRUWStateClassification $observedSnapshot $identity.document $mounts Preboot
                $context.abortObserved = [ordered]@{ state = $observedState; snapshot = $observedSnapshot }
                $context.final = $context.abortObserved
                if ([bool]$journalState.healthy) { & $checkpoint ABORT_SNAPSHOT | Out-Null }

                if ([string]$observedState.classification -notin @('LEGACY_INTACT', 'CLEAN_PREBOOT')) {
                    if ($rollbackAttempted) { throw 'A rollback was already attempted and live state is still mixed' }
                    if (-not [bool]$journalState.healthy) { throw 'Journal unavailable; rollback mutation refused' }

                    $rollbackBackup = Get-CRUWValidatedRollbackInf $primaryRoot $secondaryRoot $integrity.primaryManifestSha256 $adapter $integrity.recoveryRootTopology
                    $context.rollbackBackupValidation = $rollbackBackup
                    $context.rollbackSetupApiBefore = Invoke-CRUWAdapter $adapter 'GetSetupApiEvidence'
                    & $checkpoint ROLLBACK_INTENT | Out-Null
                    $rollbackAttempted = $true
                    $rollbackResult = Invoke-CRUWAdapter $adapter 'ReinstallBackupDriver' @($rollbackBackup.infPath)
                    $rollbackArguments = @($rollbackResult.arguments)
                    $rollbackContractValid =
                        [string]$rollbackResult.executable -ceq 'pnputil.exe' -and
                        $rollbackArguments.Count -eq 3 -and
                        [string]$rollbackArguments[0] -ceq '/add-driver' -and
                        [string]$rollbackArguments[1] -ceq [string]$rollbackBackup.infPath -and
                        [string]$rollbackArguments[2] -ceq '/install'
                    if (-not $rollbackContractValid) { throw 'Rollback adapter violated exact contract' }

                    $rolledSnapshot = Invoke-CRUWAdapter $adapter 'GetStorageSnapshot' @($identity.document.publishedName, $identity.document.filterName, $mounts, $identity.document)
                    $rolledState = Get-CRUWStateClassification $rolledSnapshot $identity.document $mounts Preboot
                    $rolledLiveReadback = Test-CRUWRollbackLiveReadback $rolledSnapshot $rollbackCapability
                    $rollbackExitCodeSafe = [int]$rollbackResult.exitCode -in @(0,3010)
                    $rollbackExitCodePolicy = switch ([int]$rollbackResult.exitCode) {
                        0 { 'SUCCESS' }; 3010 { 'SUCCESS_REBOOT_REQUIRED' }; 259 { 'NO_MATCHING_OR_BETTER_DRIVER_BLOCKED' }
                        1641 { 'UNEXPECTED_REBOOT_INITIATED_BLOCKED' }; default { 'UNRECOGNIZED_EXIT_BLOCKED' }
                    }
                    $context.rollback = [ordered]@{
                        result=$rollbackResult;setupApiEvidence=(Invoke-CRUWAdapter $adapter 'GetSetupApiEvidence');
                        exitCodePolicy=$rollbackExitCodePolicy;state=$rolledState;snapshot=$rolledSnapshot;liveReadback=$rolledLiveReadback
                    }
                    $context.final = $context.rollback
                    & $checkpoint ROLLBACK_RESULT | Out-Null
                    if (-not $rollbackExitCodeSafe -or [string]$rolledState.classification -cne 'LEGACY_INTACT' -or -not [bool]$rolledLiveReadback.verified) {
                        throw "Rollback did not restore full LEGACY_INTACT: $($rolledState.classification)"
                    }
                }
            }
            catch {
                $recoveryFailures.Add('rollback/observation: ' + $_.Exception.Message)
            }
        }
    }

    if ($suspendAttempted) {
        if ([bool]$journalState.healthy) {
            try { & $checkpoint RESUME_INTENT | Out-Null }
            catch {
                $context.bitLocker.emergencyResumeWithoutDurableIntent = $true
                $recoveryFailures.Add('resume intent journal: ' + $_.Exception.Message)
            }
        }
        else {
            $context.bitLocker.emergencyResumeWithoutDurableIntent = $true
        }

        $resumeAttempted = $true
        try { Invoke-CRUWAdapter $adapter 'ResumeBitLocker' @('C:') | Out-Null }
        catch { $recoveryFailures.Add('Resume-BitLocker: ' + $_.Exception.Message) }
        try {
            $bitLockerAtExit = Get-CRUWBitLockerInventoryEvidence $adapter $encryptedMounts AllOn
            $context.bitLocker.atExit = $bitLockerAtExit
            $context.bitLocker.resumeOnAbortVerified = [bool]$bitLockerAtExit.verified
        }
        catch { $recoveryFailures.Add('BitLocker exit verification: ' + $_.Exception.Message) }
        if ([bool]$journalState.healthy) {
            try { & $checkpoint RESUME_RESULT | Out-Null }
            catch { $recoveryFailures.Add('resume result journal: ' + $_.Exception.Message) }
        }
    }

    $abortSafetySnapshot = if ($null -ne $context.final) { $context.final.snapshot } else { $before }
    $abortSafetyState = if ($null -ne $context.final) {
        $context.final.state
    }
    else {
        Get-CRUWStateClassification $before $identity.document $mounts Preboot
    }
    try {
        $abortProbes = @($mounts | ForEach-Object { Invoke-CRUWAdapter $adapter 'ProbeVolume' @($_) })
        $abortProbeEvidence = Test-CRUWProbeEvidence $abortProbes $mounts
    }
    catch {
        $abortProbeEvidence = [ordered]@{ verified=$false;items=@();error=$_.Exception.Message }
        $recoveryFailures.Add('abort probes: ' + $_.Exception.Message)
    }
    try { $abortNativeDrift = Test-CRUWNativeStorageServiceDrift $nativeBaseline $abortSafetySnapshot.nativeStorageServices }
    catch {
        $abortNativeDrift = [ordered]@{ verified=$false;failures=@($_.Exception.Message) }
        $recoveryFailures.Add('abort native drift: ' + $_.Exception.Message)
    }
    try { $abortBootStable = Test-CRUWSameBootIdentity (Invoke-CRUWAdapter $adapter 'GetBootIdentity') $boot }
    catch {
        $abortBootStable = $false
        $recoveryFailures.Add('abort boot identity: ' + $_.Exception.Message)
    }
    try {
        $abortBitLocker = Get-CRUWBitLockerInventoryEvidence $adapter $encryptedMounts AllOn
        if (-not [bool]$abortBitLocker.verified) {
            $resumeAttempted = $true
            Invoke-CRUWAdapter $adapter 'ResumeBitLocker' @('C:') | Out-Null
            $abortBitLocker = Get-CRUWBitLockerInventoryEvidence $adapter $encryptedMounts AllOn
        }
    }
    catch {
        $abortBitLocker = [ordered]@{ verified=$false;error=$_.Exception.Message }
        $recoveryFailures.Add('abort BitLocker inventory: ' + $_.Exception.Message)
    }
    $context.abortSafety = [ordered]@{
        state = $abortSafetyState
        probes = $abortProbeEvidence
        nativeServiceDrift = $abortNativeDrift
        sameBoot = $abortBootStable
    }
    $finalClassification = [string](Get-CRUWPropertyValue $abortSafetyState 'classification' '')
    $observedStackSafe =
        [bool]$abortProbeEvidence.verified -and
        [bool]$abortNativeDrift.verified -and
        [bool]$abortBootStable
    $legacyTerminalSafe =
        $finalClassification -ceq 'LEGACY_INTACT' -and
        $observedStackSafe -and
        [bool]$abortBitLocker.verified -and
        $rollbackExitCodeSafe
    $cleanRecoverySafe = $finalClassification -ceq 'CLEAN_PREBOOT' -and $observedStackSafe -and [bool]$abortBitLocker.verified
    $context.recoveryFailures = @($recoveryFailures)
    $context.mutationAccepted = $false
    $context.safeExit = $legacyTerminalSafe -or $cleanRecoverySafe
    $context.abortSafety.bitLocker = $abortBitLocker
    $context.operatorActionRequired = if ($legacyTerminalSafe) {
        'DO NOT REBOOT. Verified LEGACY_INTACT and BitLocker Protection On; removal attempt is terminally aborted.'
    }
    elseif ($cleanRecoverySafe) {
        'DO NOT REBOOT. CLEAN_PREBOOT is protected but still requires the interruption-repair entrypoint to authorize or roll back.'
    }
    else {
        'DO NOT REBOOT. Recovery is incomplete; use the interruption-repair entrypoint from the sealed bundle.'
    }
    if ([bool]$journalState.healthy) {
        $abortStage = if ($legacyTerminalSafe) { 'ABORT_TERMINAL' } elseif ($cleanRecoverySafe) { 'CLEAN_PREBOOT_RECOVERY_REQUIRED' } else { 'RECOVERY_BLOCKED' }
        try { & $checkpoint $abortStage | Out-Null }
        catch {
            $recoveryFailures.Add('abort terminal journal: ' + $_.Exception.Message)
            $context.recoveryFailures = @($recoveryFailures)
        }
    }
}

$result = [ordered]@{
    operationId = $operationId.ToString('D')
    authorized = $authorized
    terminalCheckpoint = $journalState.terminal
    checkpointCount = $journalState.checkpoints.Count
    journalHealthy = [bool]$journalState.healthy
    failure = $failure
    operatorActionRequired = $context.operatorActionRequired
}
$result
if (-not $authorized) {
    throw "Removal aborted safely=$($context.safeExit). $($context.operatorActionRequired) Failure=$failure"
}
}
finally {
    try {
        if ($null -ne $mutexHandle) {
            if (-not $authorized) {
                try {
                    $finalEmergencyProtection = Get-CRUWBitLockerInventoryEvidence $adapter $encryptedMounts AllOn
                    if (-not [bool]$finalEmergencyProtection.verified) {
                        Invoke-CRUWAdapter $adapter 'ResumeBitLocker' @('C:') | Out-Null
                        $finalEmergencyProtection = Get-CRUWBitLockerInventoryEvidence $adapter $encryptedMounts AllOn
                    }
                    if (-not [bool]$finalEmergencyProtection.verified) { throw 'Final emergency Protection On verification failed' }
                }
                catch { Write-Error -ErrorAction Continue ('CRITICAL: final emergency BitLocker protection failed: ' + $_.Exception.Message) }
            }
            Invoke-CRUWAdapter $adapter 'ExitOperationMutex' @($mutexHandle) | Out-Null
        }
    }
    finally { Close-CRUWBootstrapAnchorChains }
}
