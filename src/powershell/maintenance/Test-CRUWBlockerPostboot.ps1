[CmdletBinding()]
param(
    [Parameter(Mandatory)] [string] $RebootAuthorizedCheckpointPath,
    [Parameter(Mandatory)] [switch] $OffMachineRecoveryKeyConfirmed,
    [Parameter(Mandatory)] [switch] $PhysicalConsoleAccessConfirmed,
    [Parameter(Mandatory)] [switch] $ConfirmResumeBitLockerOnExit,
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
        throw 'Postboot validator must run from the fixed C: recovery topology'
    }
    $bootstrapAdapter = if ($SkipAcl) { $TestAdapter } else { $null }
    $currentAnchorBase = if ($SkipAcl) { $rootFull } else { 'C:\Acer-Driver-Audit' }
    $currentAnchor = Add-CRUWBootstrapAnchorChain $rootFull $currentAnchorBase 'C:' -Adapter $bootstrapAdapter
    if (-not [bool]$currentAnchor.complete) { throw 'Postboot primary recovery root could not be fully anchored' }
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
    if (-not [bool]$secondaryAnchor.complete) { throw 'Postboot secondary recovery root could not be fully anchored' }
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

function Test-CRUWReadOnlySameBootWaiting {
    param(
        [Parameter(Mandatory)] [string] $CheckpointPath,
        [Parameter(Mandatory)] [hashtable] $Adapter
    )
    $passSummaries = [Collections.Generic.List[object]]::new()
    $encryptedMounts = @('C:')
    try {
        foreach ($pass in 1..2) {
            $terminalPath = [IO.Path]::GetFullPath($CheckpointPath)
            $primaryRoot = Split-Path -Parent $terminalPath
            $terminalFileSha256 = (Get-FileHash -LiteralPath $terminalPath -Algorithm SHA256).Hash
            $authorized = Read-CRUWJournalDocument $terminalPath
            if ([string]$authorized.payload.stage -cne 'REBOOT_AUTHORIZED') { throw 'terminal stage is not REBOOT_AUTHORIZED' }
            $removal = $authorized.payload.context
            $preflightPath = [IO.Path]::GetFullPath([string]$removal.preflight.path)
            if ($preflightPath -cne (Join-Path $primaryRoot 'preflight.json')) { throw 'preflight is not the fixed sibling' }
            $preflightFileSha256 = (Get-FileHash -LiteralPath $preflightPath -Algorithm SHA256).Hash
            if ($preflightFileSha256 -ine [string]$removal.preflight.sha256) { throw 'preflight hash differs from authorized context' }
            $preflight = Get-Content -LiteralPath $preflightPath -Raw -Encoding UTF8 | ConvertFrom-Json
            $secondaryRoot = [string]$preflight.secondaryRecoveryPath
            if (@(Get-CRUWUnrecognizedJournalArtifacts $primaryRoot $secondaryRoot).Count -gt 0) { throw 'unrecognized journal artifact' }
            $integrity = Test-CRUWBackupIntegrity $preflight $preflightPath $Adapter
            if (-not [bool]$integrity.verified) { throw "backup integrity failed: $($integrity.failures -join '; ')" }
            if ([string]$integrity.primaryManifestSha256 -ine [string]$removal.preflight.integrityManifestSha256) { throw 'manifest hash differs from authorized context' }
            $seal = Test-CRUWImplementationSeal $integrity $preflight $primaryRoot $PSCommandPath
            if (-not [bool]$seal.verified) { throw "implementation seal failed: $($seal.failures -join '; ')" }
            $identity = Get-CRUWPreflightIdentity $preflight $integrity.manifest
            if (
                [string]$removal.targetIdentitySha256 -cne [string]$identity.sha256 -or
                (Get-CRUWObjectSha256 $removal.targetIdentity) -cne [string]$identity.sha256
            ) { throw 'target identity differs from sealed preflight' }
            $operationId = [guid]$authorized.payload.operationId
            $prefix = Get-CRUWJournalPrefixState $primaryRoot $secondaryRoot $operationId $Adapter
            if ([bool]$prefix.divergent -or $null -ne $prefix.unilateralTail -or -not [bool]$prefix.verified) { throw 'journal common prefix is not exact and dual' }
            $authorizedIndex = [int]$authorized.payload.sequence
            if (
                $prefix.commonPrefixLength -ne ($authorizedIndex + 1) -or
                [string]$prefix.entries[-1].payload.stage -cne 'REBOOT_AUTHORIZED' -or
                [string]$prefix.entries[-1].payloadSha256 -cne [string]$authorized.payloadSha256
            ) { throw 'REBOOT_AUTHORIZED is not the exact committed dual terminal' }
            $quarantines = @(Get-CRUWJournalQuarantineEvidence $primaryRoot $secondaryRoot $operationId $Adapter)
            if (-not [bool](Test-CRUWJournalQuarantineResolution $prefix $quarantines).verified) { throw 'quarantine evidence is unresolved' }
            $boot = Invoke-CRUWAdapter $Adapter 'GetBootIdentity'
            if (-not (Test-CRUWSameBootIdentity $boot $removal.mutationBoot)) { throw 'current boot is not the authorized same boot' }
            $mounts = @($removal.requiredMountPoints | ForEach-Object { [string]$_ })
            $snapshot = Invoke-CRUWAdapter $Adapter 'GetStorageSnapshot' @($identity.document.publishedName,$identity.document.filterName,$mounts,$identity.document)
            $state = Get-CRUWStateClassification $snapshot $identity.document $mounts Preboot
            if ([string]$state.classification -cne 'CLEAN_PREBOOT') { throw 'live state is not exact CLEAN_PREBOOT' }
            $native = Test-CRUWNativeStorageServiceDrift $removal.nativeStorageServicesBaseline $snapshot.nativeStorageServices
            if (-not [bool]$native.verified) { throw 'native storage services drifted' }
            $pending = Invoke-CRUWAdapter $Adapter 'GetPendingRebootState'
            if ([bool]$pending.detected) { throw 'pending reboot detected' }
            $ac = Invoke-CRUWAdapter $Adapter 'GetAcPowerState'
            if (-not [bool]$ac.online) { throw 'AC power is not online' }
            $readiness = Invoke-CRUWAdapter $Adapter 'GetRecoveryReadiness'
            if (-not (Test-CRUWRecoveryReadiness $readiness $preflight)) { throw 'sealed recovery readiness drifted' }
            $events = @(Invoke-CRUWAdapter $Adapter 'GetCriticalEventsSince' @([DateTimeOffset]$removal.deleteDriver.startedAt))
            if ($events.Count -ne 0) { throw 'storage warning/error/critical event observed' }
            $encryptedMounts = @(Get-CRUWEncryptedMountPoints $preflight)
            $bitLocker = Get-CRUWBitLockerInventoryEvidence $Adapter $encryptedMounts COffOthersOn
            if (-not [bool]$bitLocker.verified) { throw 'bounded BitLocker suspension is not exact' }
            $stableReadiness = [ordered]@{
                winReEnabled=[bool]$readiness.winReEnabled
                winReLocationPresent=[bool]$readiness.winReLocationPresent
                winReLocationSha256=[string]$readiness.winReLocationSha256
                restorePointPresent=[bool]$readiness.restorePointPresent
                recentRestorePointPresent=[bool]$readiness.recentRestorePointPresent
                latestRestorePointSequenceNumber=[long]$readiness.latestRestorePointSequenceNumber
            }
            $stableEventsSha256 = Get-CRUWStringSha256 (ConvertTo-Json -InputObject @($events) -Depth 4 -Compress)
            $passSummaries.Add([ordered]@{
                terminalFileSha256=$terminalFileSha256;terminalPayloadSha256=[string]$authorized.payloadSha256;
                preflightFileSha256=$preflightFileSha256;primaryManifestSha256=[string]$integrity.primaryManifestSha256;
                secondaryManifestSha256=[string]$integrity.secondaryManifestSha256;prefixLength=[int]$prefix.commonPrefixLength;
                bootMarkerSha256=[string]$boot.markerSha256;targetIdentitySha256=[string]$identity.sha256;
                stateSha256=Get-CRUWObjectSha256 $state;nativeSha256=Get-CRUWObjectSha256 $native;
                pendingSha256=Get-CRUWObjectSha256 $pending;acSha256=Get-CRUWObjectSha256 $ac;
                readinessSha256=Get-CRUWObjectSha256 $stableReadiness;eventsSha256=$stableEventsSha256;
                bitLockerSha256=Get-CRUWObjectSha256 $bitLocker
            })
        }
        if ((Get-CRUWObjectSha256 $passSummaries[0]) -cne (Get-CRUWObjectSha256 $passSummaries[1])) {
            throw 'two read-only validation passes were not byte/identity stable'
        }
        return [ordered]@{verified=$true;failures=@();encryptedMounts=$encryptedMounts;summary=$passSummaries[1]}
    }
    catch {
        return [ordered]@{verified=$false;failures=@($_.Exception.Message);encryptedMounts=$encryptedMounts;summary=$null}
    }
}

$adapter = $null
try {
    $bootstrapTerminalPath = [IO.Path]::GetFullPath($RebootAuthorizedCheckpointPath)
    $bootstrapPrimaryRoot = Split-Path -Parent $bootstrapTerminalPath
    trap {
        Close-CRUWBootstrapAnchorChains
        throw
    }
    Assert-CRUWSealedBootstrap -PrimaryRoot $bootstrapPrimaryRoot -EntryRole 'postboot-validator' -SkipAcl $TestMode.IsPresent
    . (Join-Path $PSScriptRoot 'CRUWStateMachine.Common.ps1')

    $confirmed =
        $OffMachineRecoveryKeyConfirmed.IsPresent -and
        $PhysicalConsoleAccessConfirmed.IsPresent -and
        $ConfirmResumeBitLockerOnExit.IsPresent
    if (-not $confirmed) { throw 'All postboot confirmations are required' }
    if ($TestMode.IsPresent -ne ($null -ne $TestAdapter)) {
        throw 'TestMode and TestAdapter must be supplied together'
    }
    $adapter = if ($TestMode) { $TestAdapter } else { New-CRUWNativeAdapter }
    if (-not [bool](Invoke-CRUWAdapter $adapter 'IsAdministrator')) {
        throw 'Administrator context required'
    }
}
catch {
    $initializationError = $_
    throw $initializationError
}
$mutexHandle = $null
try {
    $mutexHandle = Invoke-CRUWAdapter $adapter 'EnterOperationMutex'
}
catch {
    $mutexError = $_
    $sameBootWaitProof = Test-CRUWReadOnlySameBootWaiting $RebootAuthorizedCheckpointPath $adapter
    if ([bool]$sameBootWaitProof.verified) {
        [ordered]@{
            operationId=(Read-CRUWJournalDocument $RebootAuthorizedCheckpointPath).payload.operationId
            classification='WAIT_FOR_ACTIVE_WRITER'
            storageSafe=$true
            removalComplete=$false
            safetyComplete=$false
            bitLockerProtected=$false
            failedGates=@()
            terminalCheckpoint=$null
            journalHealthy=$true
            operatorActionRequired='DO NOT REBOOT while another state-machine owner holds the mutex. Retry after the active writer exits; no journal or protection state was changed.'
        }
        Close-CRUWBootstrapAnchorChains
        return
    }
    [ordered]@{
        operationId=$null;classification='CONCURRENT_STATE_UNKNOWN';storageSafe=$false;removalComplete=$false;
        maintenanceComplete=$false;safetyComplete=$false;bitLockerProtected=$false;
        failedGates=@('operationMutexUnavailable','sameBootWaitingProof');terminalCheckpoint=$null;journalHealthy=$false;
        operatorActionRequired="DO NOT REBOOT. Another state-machine owner may be mutating storage; retry only after the mutex is available. Read-only proof: $($sameBootWaitProof.failures -join '; ')"
    }
    Close-CRUWBootstrapAnchorChains
    return
}
$mustProtectOnExit = $true
$protectionHandled = $false
$removal = $null
$emergencyMounts = @('C:')
$sameBootValidated = $false
try {
    $terminalPath = [IO.Path]::GetFullPath($RebootAuthorizedCheckpointPath)
    $terminalRoot = [IO.Path]::GetPathRoot($terminalPath)
    if (-not $TestMode -and $terminalRoot -cne 'C:\') {
        throw 'Postboot authorization must be a fixed local C: recovery path'
    }
    if ($terminalPath.StartsWith('\\')) { throw 'UNC authorization paths are rejected' }
    if (-not (Test-Path -LiteralPath $terminalPath -PathType Leaf)) {
        throw 'REBOOT_AUTHORIZED checkpoint missing'
    }
    if ((Get-Item -LiteralPath $terminalPath -Force).Attributes -band [IO.FileAttributes]::ReparsePoint) {
        throw 'Reparse-point authorization checkpoint rejected'
    }
    $terminalAcl = Invoke-CRUWAdapter $adapter 'TestProtectedAcl' @($terminalPath)
    if (-not [bool]$terminalAcl.verified) { throw 'Authorization checkpoint ACL is not protected' }
    $authorized = Read-CRUWJournalDocument $terminalPath
    if ([string]$authorized.payload.stage -cne 'REBOOT_AUTHORIZED') {
        throw 'Only a REBOOT_AUTHORIZED checkpoint is accepted'
    }
    # Once a syntactically valid authorization stage has been accepted, every
    # failure defaults to restoring C: protection. The only exception is a
    # fully validated same-boot WAITING result below.
    $mustProtectOnExit = $true

    $primaryRoot = Split-Path -Parent $terminalPath
    $expectedPreflightPath = Join-Path $primaryRoot 'preflight.json'
    $removal = $authorized.payload.context
    $preflightPath = [IO.Path]::GetFullPath([string]$removal.preflight.path)
    if ($preflightPath -cne $expectedPreflightPath) {
        throw 'Journal preflight path is not the fixed sibling preflight.json'
    }
    $untrustedPreflight = Get-Content -LiteralPath $preflightPath -Raw -Encoding UTF8 | ConvertFrom-Json
    $secondaryRoot = [string]$untrustedPreflight.secondaryRecoveryPath
    $operationId = [guid]$authorized.payload.operationId
    if (@(Get-CRUWUnrecognizedJournalArtifacts $primaryRoot $secondaryRoot).Count -gt 0) {
        throw 'Unrecognized removal-journal artifacts require manual forensic review'
    }
    $appendAllowed = $false
    $journalHealthy = $true
    $journalState = $null
    $failedGates = [Collections.Generic.List[string]]::new()
    # Result DTO schema v2 is independent from the consumed preflight schema v3.
    $post = [ordered]@{
        schemaVersion = 2
        removalTerminalSha256 = [string]$authorized.payloadSha256
        removal = $removal
        offMachineRecoveryKeyConfirmed = $true
        physicalConsoleAccessConfirmed = $true
        rebootPerformedByScript = $false
        registryOrServiceDeletionPerformedByScript = $false
        diagnosticFailure = $null
        bitLocker = [ordered]@{
            resumeAttempted = $false
            protected = $false
            secretRecorded = $false
        }
    }
    $checkpoint = {
        param([string] $Stage)
        if (-not $appendAllowed -or $null -eq $journalState) {
            throw 'Postboot journal append is not authorized yet'
        }
        try {
            $entry = Write-CRUWDualJournal $primaryRoot $secondaryRoot $operationId $journalState.sequence $Stage $journalState.previous $post $adapter
            Set-CRUWPropertyValue $post lastDualCommit ([ordered]@{
                sequence=[int]$entry.sequence;stage=[string]$entry.stage;payloadSha256=[string]$entry.payloadSha256;
                primaryFileSha256=[string]$entry.primarySha256;secondaryFileSha256=[string]$entry.secondarySha256;
                primaryPathSha256=Get-CRUWStringSha256 ([string]$entry.primaryPath);
                secondaryPathSha256=Get-CRUWStringSha256 ([string]$entry.secondaryPath)
            })
            $journalState.sequence++
            $journalState.previous = [string]$entry.payloadSha256
            $journalState.terminal = $entry
            return $entry
        }
        catch {
            $journalHealthy = $false
            throw
        }
    }

    try {
        $preflightUnchanged =
            (Test-Path -LiteralPath $preflightPath -PathType Leaf) -and
            (Get-FileHash -LiteralPath $preflightPath -Algorithm SHA256).Hash -ieq [string]$removal.preflight.sha256
        if (-not $preflightUnchanged) { throw 'Authoritative preflight missing or changed' }

        $preflight = Get-Content -LiteralPath $preflightPath -Raw -Encoding UTF8 | ConvertFrom-Json
        if ([IO.Path]::GetFullPath([string]$preflight.recoveryPath).TrimEnd('\') -cne $primaryRoot.TrimEnd('\')) {
            throw 'Authorized checkpoint is outside the sealed primary recovery root'
        }
        $integrity = Test-CRUWBackupIntegrity $preflight $preflightPath $adapter
        if (-not [bool]$integrity.verified) {
            throw "Backup revalidation failed: $($integrity.failures -join '; ')"
        }
        $implementationSeal = Test-CRUWImplementationSeal $integrity $preflight $primaryRoot $PSCommandPath
        if (-not [bool]$implementationSeal.verified) { throw "Running postboot implementation is not sealed: $($implementationSeal.failures -join '; ')" }
        $emergencyMounts = @(Get-CRUWEncryptedMountPoints $preflight)
        $sealedIdentity = Get-CRUWPreflightIdentity $preflight $integrity.manifest
        $identityMatches =
            [string]$sealedIdentity.sha256 -ceq [string]$removal.targetIdentitySha256 -and
            (Get-CRUWObjectSha256 $removal.targetIdentity) -ceq [string]$removal.targetIdentitySha256
        if (-not $identityMatches) { throw 'Journal target identity does not match sealed preflight identity' }

        $authorizedChain = Test-CRUWJournalChain $terminalPath $primaryRoot $secondaryRoot $adapter
        if (-not [bool]$authorizedChain.verified) {
            throw "Original REBOOT_AUTHORIZED chain invalid: $($authorizedChain.failures -join '; ')"
        }

        $prefix = Get-CRUWJournalPrefixState $primaryRoot $secondaryRoot $operationId $adapter
        if ([bool]$prefix.divergent -or $null -ne $prefix.unilateralTail) {
            throw 'Preserved unilateral/divergent journal tail requires diagnostic recovery'
        }
        $authorizedIndex = [int]$authorized.payload.sequence
        if ($prefix.commonPrefixLength -le $authorizedIndex) {
            throw 'REBOOT_AUTHORIZED is not in the committed common prefix'
        }
        if ([string]$prefix.entries[$authorizedIndex].payloadSha256 -cne [string]$authorized.payloadSha256) {
            throw 'Committed REBOOT_AUTHORIZED identity changed'
        }
        $quarantines = @(Get-CRUWJournalQuarantineEvidence $primaryRoot $secondaryRoot $operationId $adapter)
        $quarantineResolution = Test-CRUWJournalQuarantineResolution $prefix $quarantines
        if (-not [bool]$quarantineResolution.verified) {
            throw 'Postboot journal has unresolved or ambiguously referenced quarantined evidence'
        }

        $initialBoot = Invoke-CRUWAdapter $adapter 'GetBootIdentity'
        if ([string]$initialBoot.markerSha256 -ceq [string]$removal.mutationBoot.markerSha256) {
            $sameBootWaitProof = Test-CRUWReadOnlySameBootWaiting $terminalPath $adapter
            if (-not [bool]$sameBootWaitProof.verified) {
                throw "Same-boot WAITING proof failed: $($sameBootWaitProof.failures -join '; ')"
            }
            $waitingMounts = @($removal.requiredMountPoints | ForEach-Object { [string]$_ })
            $waitingProbes = Test-CRUWProbeEvidence @($waitingMounts | ForEach-Object {
                Invoke-CRUWAdapter $adapter 'ProbeVolume' @($_)
            }) $waitingMounts
            if (-not [bool]$waitingProbes.verified) { throw 'Same-boot C/D write/read/hash/delete probes failed' }
            $sameBootValidated = $true
            $mustProtectOnExit = $false
            $protectionHandled = $true
            [ordered]@{
                operationId = [string]$authorized.payload.operationId
                classification = 'WAITING_FOR_REBOOT'
                storageSafe = $true
                removalComplete = $false
                safetyComplete = $false
                bitLockerProtected = $false
                failedGates = @()
                terminalCheckpoint = $null
                journalHealthy = $true
                operatorActionRequired = 'Perform the already-authorized manual reboot; journal and BitLocker suspension were left unchanged.'
            }
            return
        }

        # Never append before proving that the authorized manual reboot occurred.
        $boot = $initialBoot
        $deleteCompleted = [DateTimeOffset]$removal.deleteDriver.completedAt
        $deleteEvidenceStarted = [DateTimeOffset]$removal.deleteDriver.startedAt
        $differentBoot = [string]$boot.markerSha256 -cne [string]$removal.mutationBoot.markerSha256
        $sameBuild = [string]$boot.operatingSystemBuild -ceq [string]$removal.mutationBoot.operatingSystemBuild
        $bootAfterDelete = [DateTimeOffset](ConvertTo-CRUWUtcRoundtripString $boot.lastBootUpTimeUtc) -gt $deleteCompleted
        if (-not ($differentBoot -and $sameBuild -and $bootAfterDelete)) {
            throw 'Postboot requires a different, later boot on the same OS build; journal was not appended'
        }

        $latestCommittedStage = [string]$prefix.entries[-1].payload.stage
        if ($latestCommittedStage -in @('POSTBOOT_STABILITY_PENDING','POSTBOOT_SAFE_RESIDUAL','POSTBOOT_PROTECTED_DIAGNOSTIC_HOLD')) {
            $terminalContext = Get-CRUWPropertyValue $prefix.entries[-1].payload 'context' $null
            $encryptedMounts = @(Get-CRUWEncryptedMountPoints $preflight)
            $idempotentBitLocker = Get-CRUWBitLockerInventoryEvidence $adapter $encryptedMounts AllOn
            if (-not [bool]$idempotentBitLocker.verified) {
                Invoke-CRUWAdapter $adapter 'ResumeBitLocker' @('C:') | Out-Null
                $idempotentBitLocker = Get-CRUWBitLockerInventoryEvidence $adapter $encryptedMounts AllOn
            }
            if (-not [bool]$idempotentBitLocker.verified) {
                throw 'Idempotent postboot replay could not verify BitLocker Protection On'
            }
            $protectionHandled = $true
            $idempotentSafe = $latestCommittedStage -in @('POSTBOOT_STABILITY_PENDING','POSTBOOT_SAFE_RESIDUAL')
            $idempotentClassification = if ($latestCommittedStage -ceq 'POSTBOOT_STABILITY_PENDING') { 'CLEAN' } elseif ($idempotentSafe) { 'TRANSITION' } else { 'BROKEN' }
            $idempotentStorageSafe = $idempotentSafe
            $idempotentRemovalComplete = $latestCommittedStage -ceq 'POSTBOOT_STABILITY_PENDING'
            $idempotentFailedGates = @()
            $idempotentOperatorAction = if ($latestCommittedStage -ceq 'POSTBOOT_STABILITY_PENDING') {
                'Removal is storage-safe but maintenance is not complete. Perform a later distinct stable MANUAL reboot; this draft intentionally does not yet restore the sealed original recovery posture.'
            }
            else { 'No new journal entry: prior postboot hold is idempotent and BitLocker Protection On is verified.' }
            if ($latestCommittedStage -ceq 'POSTBOOT_PROTECTED_DIAGNOSTIC_HOLD') {
                $contextClassification = [string](Get-CRUWPropertyValue $terminalContext 'classification' '')
                if ($contextClassification -in @('CLEAN','TRANSITION','BROKEN')) {
                    $idempotentClassification = $contextClassification
                }
                $idempotentStorageSafe = [bool](Get-CRUWPropertyValue $terminalContext 'storageSafe' $false)
                $idempotentRemovalComplete = [bool](Get-CRUWPropertyValue $terminalContext 'removalComplete' $false)
                $idempotentFailedGates = @(
                    Get-CRUWPropertyValue $terminalContext 'failedGates' @() |
                        ForEach-Object { [string]$_ } |
                        Where-Object { -not [string]::IsNullOrWhiteSpace($_) }
                )
                if ($idempotentFailedGates.Count -eq 0) {
                    $idempotentFailedGates = @('priorDiagnosticCauseUnavailable')
                }
                $idempotentOperatorAction = [string](Get-CRUWPropertyValue $terminalContext 'operatorActionRequired' '')
                if ([string]::IsNullOrWhiteSpace($idempotentOperatorAction)) {
                    $idempotentOperatorAction = "DO NOT REBOOT. Prior protected diagnostic hold remains unresolved. Failed: $($idempotentFailedGates -join ', ')"
                }
            }
            [ordered]@{
                operationId = $operationId.ToString('D')
                classification = $idempotentClassification
                storageSafe = $idempotentStorageSafe
                removalComplete = $idempotentRemovalComplete
                maintenanceComplete = $false
                safetyComplete = $idempotentSafe
                bitLockerProtected = $true
                failedGates = @($idempotentFailedGates)
                terminalCheckpoint = $null
                journalHealthy = $true
                operatorActionRequired = $idempotentOperatorAction
            }
            return
        }

        $journalState = [ordered]@{
            sequence = [int]$prefix.nextSequence
            previous = [string]$prefix.previousPayloadSha256
            terminal = $null
        }
        $appendAllowed = $true
        $post.checkedAt = ([DateTimeOffset](Invoke-CRUWAdapter $adapter 'GetNow')).ToString('o')
        $post.boot = $boot
        & $checkpoint POSTBOOT_ATTEMPT_INTENT | Out-Null

        $identity = $removal.targetIdentity
        $mounts = @($removal.requiredMountPoints | ForEach-Object { [string]$_ })
        $encryptedMounts = @(Get-CRUWEncryptedMountPoints $preflight)
        $snapshot = Invoke-CRUWAdapter $adapter 'GetStorageSnapshot' @([string]$identity.publishedName, [string]$identity.filterName, $mounts, $identity)
        $state = Get-CRUWStateClassification $snapshot $identity $mounts Postboot
        $nativeDrift = Test-CRUWNativeStorageServiceDrift $removal.nativeStorageServicesBaseline $snapshot.nativeStorageServices
        $events = @(Invoke-CRUWAdapter $adapter 'GetCriticalEventsSince' @($deleteEvidenceStarted))
        $pending = Invoke-CRUWAdapter $adapter 'GetPendingRebootState'
        $readiness = Invoke-CRUWAdapter $adapter 'GetRecoveryReadiness'
        $probes = @($mounts | ForEach-Object { Invoke-CRUWAdapter $adapter 'ProbeVolume' @($_) })
        $probeEvidence = Test-CRUWProbeEvidence $probes $mounts
        $bitLockerBeforeStates = @($encryptedMounts | ForEach-Object { Invoke-CRUWAdapter $adapter 'GetBitLockerState' @($_) })
        $bitLockerBeforeSuspended = Test-CRUWBitLockerInventoryStates $bitLockerBeforeStates $encryptedMounts COffOthersOn
        $bitLockerBeforeProtected = Test-CRUWBitLockerInventoryStates $bitLockerBeforeStates $encryptedMounts AllOn
        $bitLockerBefore = [ordered]@{
            verified = [bool]$bitLockerBeforeSuspended.verified -or [bool]$bitLockerBeforeProtected.verified
            suspended = $bitLockerBeforeSuspended
            alreadyProtected = $bitLockerBeforeProtected
            states = $bitLockerBeforeStates
        }
        $deleteArguments = @($removal.deleteDriver.result.arguments)
        $storageSafe = [bool]$state.gates.cleanPreboot -and [bool]$state.gates.nativeDiskDrivers -and [bool]$state.gates.zeroCruwReferences
        $removalComplete = [bool]$state.gates.cleanPostboot

        $requiredStages = @(
            'PREPARED','SUSPEND_INTENT','SUSPEND_LIVE_GATE','SUSPEND_RESULT',
            'DELETE_INTENT','DELETE_LIVE_GATE','DELETE_RESULT','SNAPSHOT_CLASSIFIED',
            'FINAL_AUTHORIZATION_INTENT','REBOOT_AUTHORIZED'
        )
        $actualStages = @($authorizedChain.entries | ForEach-Object { [string]$_.payload.stage })
        $subsequenceIndex = 0
        foreach ($actualStage in $actualStages) {
            if ($subsequenceIndex -lt $requiredStages.Count -and $actualStage -ceq $requiredStages[$subsequenceIndex]) {
                $subsequenceIndex++
            }
        }
        $authorizationStageSubsequence = $subsequenceIndex -eq $requiredStages.Count
        $gates = [ordered]@{
            originalAuthorizationChain = [bool]$authorizedChain.verified
            requiredAuthorizationStageSubsequence = $authorizationStageSubsequence
            backupHashesAndAcl = [bool]$integrity.verified
            differentLaterBootSameBuild = $differentBoot -and $sameBuild -and $bootAfterDelete
            pendingRebootClear = -not [bool]$pending.detected
            sealedRecoveryReadiness = Test-CRUWRecoveryReadiness $readiness $preflight
            storageSafeNativeDriversNoReferences = $storageSafe
            exactTwoDiskTopology = [bool]$state.gates.exactlyTwoDiskDevices -and [bool]$state.gates.topologyExact
            orderedInstanceAndClassFiltersPreserved = [bool]$state.gates.instanceFiltersPreserved -and [bool]$state.gates.classFiltersPreserved
            nativeStorageServicesNoDrift = [bool]$nativeDrift.verified
            cAndDWriteReadHashDelete = [bool]$probeEvidence.verified
            noStorageWarningsErrorsOrCriticalEvents = $events.Count -eq 0
            bitLockerInventoryExpected = [bool]$bitLockerBefore.verified
            exactDeleteContract =
                $deleteArguments.Count -eq 3 -and
                [string]$deleteArguments[0] -ceq '/delete-driver' -and
                [string]$deleteArguments[1] -ceq [string]$identity.publishedName -and
                [string]$deleteArguments[2] -ceq '/uninstall' -and
                [int]$removal.deleteDriver.result.exitCode -in @(0,3010) -and
                (
                    ([int]$removal.deleteDriver.result.exitCode -eq 0 -and [string]$removal.deleteDriver.exitCodePolicy -ceq 'SUCCESS') -or
                    ([int]$removal.deleteDriver.result.exitCode -eq 3010 -and [string]$removal.deleteDriver.exitCodePolicy -ceq 'SUCCESS_REBOOT_REQUIRED')
                )
        }
        foreach ($gate in $gates.GetEnumerator()) {
            if (-not [bool]$gate.Value) { $failedGates.Add([string]$gate.Key) }
        }
        $post.storage = [ordered]@{ state=$state;snapshot=$snapshot;nativeServiceDrift=$nativeDrift }
        $post.events = [ordered]@{ since=$deleteEvidenceStarted.ToString('o');items=$events }
        $post.pendingReboot = $pending
        $post.recoveryReadiness = $readiness
        $post.probes = $probeEvidence
        $post.gates = $gates
        $post.storageSafe = $storageSafe
        $post.removalComplete = $removalComplete
        $post.bitLocker.before = $bitLockerBefore
        & $checkpoint POSTBOOT_OBSERVATION_RESULT | Out-Null
    }
    catch {
        $post.diagnosticFailure = $_.Exception.Message
        if ($failedGates.Count -eq 0) { $failedGates.Add('postbootDiagnosticFailure') }
    }
    finally {
        # Protection On is the unconditional exit invariant. Red diagnostics
        # create a hold, but never justify leaving the OS volume suspended.
        if (-not $sameBootValidated) {
        try {
            $encryptedMountsAtExit = @($emergencyMounts)
            $currentBitLocker = Get-CRUWBitLockerInventoryEvidence $adapter $encryptedMountsAtExit AllOn
            $post.bitLocker.beforeResume = $currentBitLocker
            if ([bool]$currentBitLocker.verified) {
                $post.bitLocker.protected = $true
                $post.bitLocker.alreadyProtected = $true
            }
            else {
                if ($appendAllowed -and $journalHealthy) {
                    try { & $checkpoint POSTBOOT_RESUME_INTENT | Out-Null }
                    catch { $post.bitLocker.resumeIntentJournalError = $_.Exception.Message }
                }
                $post.bitLocker.resumeAttempted = $true
                Invoke-CRUWAdapter $adapter 'ResumeBitLocker' @('C:') | Out-Null
                $afterResume = Get-CRUWBitLockerInventoryEvidence $adapter $encryptedMountsAtExit AllOn
                $post.bitLocker.afterResume = $afterResume
                $post.bitLocker.protected = [bool]$afterResume.verified
                if ($appendAllowed -and $journalHealthy) {
                    try { & $checkpoint POSTBOOT_RESUME_RESULT | Out-Null }
                    catch { $post.bitLocker.resumeResultJournalError = $_.Exception.Message }
                }
            }
        }
        catch {
            $post.bitLocker.protectionError = $_.Exception.Message
            $post.bitLocker.protected = $false
        }
        $protectionHandled = [bool]$post.bitLocker.protected
        }
    }

    if (-not [bool]$post.bitLocker.protected) { $failedGates.Add('bitLockerProtectionOnAtExit') }
    $storageSafeResult = [bool](Get-CRUWPropertyValue $post 'storageSafe' $false)
    $removalCompleteResult = [bool](Get-CRUWPropertyValue $post 'removalComplete' $false)
    $safetyComplete = $failedGates.Count -eq 0 -and [bool]$post.bitLocker.protected
    $classification = if ($safetyComplete -and $removalCompleteResult) {
        'CLEAN'
    }
    elseif ($safetyComplete -and $storageSafeResult) { 'TRANSITION' }
    else { 'BROKEN' }
    $post.safetyComplete = $safetyComplete
    $post.classification = $classification
    $post.failedGates = @($failedGates)
    $post.diagnosticHold = -not $safetyComplete
    $post.operatorActionRequired = if ($safetyComplete -and $removalCompleteResult) {
        'Removal is storage-safe but maintenance is not complete. Perform a later distinct stable MANUAL reboot; this draft intentionally does not yet restore the sealed original recovery posture.'
    }
    elseif ($safetyComplete) {
        'Storage is safe and BitLocker is On; exact unreferenced residuals require separate cleanup review.'
    }
    else {
        "Diagnostic hold; BitLocker protection was still forced On. Failed: $($failedGates -join ', ')"
    }

    $terminalStage = if (-not $safetyComplete) {
        'POSTBOOT_PROTECTED_DIAGNOSTIC_HOLD'
    }
    elseif ($removalCompleteResult) { 'POSTBOOT_STABILITY_PENDING' }
    else { 'POSTBOOT_SAFE_RESIDUAL' }
    if ($appendAllowed -and $journalHealthy) {
        try { & $checkpoint $terminalStage | Out-Null }
        catch {
            $journalHealthy = $false
            $post.journalTerminalError = $_.Exception.Message
        }
    }

    $result = [ordered]@{
        operationId = $operationId.ToString('D')
        classification = $classification
        storageSafe = $storageSafeResult
        removalComplete = $removalCompleteResult
        maintenanceComplete = $false
        safetyComplete = $safetyComplete
        bitLockerProtected = [bool]$post.bitLocker.protected
        failedGates = @($failedGates)
        terminalCheckpoint = if ($null -ne $journalState) { $journalState.terminal } else { $null }
        journalHealthy = $journalHealthy
        operatorActionRequired = $post.operatorActionRequired
    }
    $result
    if (-not $safetyComplete) {
        $protectionError = Get-CRUWPropertyValue $post.bitLocker 'protectionError' ''
        throw "Postboot diagnostic hold; BitLockerProtected=$($post.bitLocker.protected); Failed=$($failedGates -join ', '); Diagnostic=$($post.diagnosticFailure); ProtectionError=$protectionError"
    }
}
finally {
    try {
        if ($mustProtectOnExit -and -not $protectionHandled) {
            try {
                $emergencyState = Get-CRUWBitLockerInventoryEvidence $adapter @($emergencyMounts) AllOn
                if (-not [bool]$emergencyState.verified) {
                    Invoke-CRUWAdapter $adapter 'ResumeBitLocker' @('C:') | Out-Null
                    $emergencyState = Get-CRUWBitLockerInventoryEvidence $adapter @($emergencyMounts) AllOn
                }
                if (-not [bool]$emergencyState.verified) {
                    throw 'Emergency postboot BitLocker Protection On verification failed'
                }
            }
            catch {
                Write-Error -ErrorAction Continue ('CRITICAL: emergency postboot BitLocker protection failed: ' + $_.Exception.Message)
            }
        }
        Invoke-CRUWAdapter $adapter 'ExitOperationMutex' @($mutexHandle) | Out-Null
    }
    finally { Close-CRUWBootstrapAnchorChains }
}
