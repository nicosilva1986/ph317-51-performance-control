[CmdletBinding()]
param(
    [Parameter(Mandatory)] [string] $PreflightPath,
    [Parameter(Mandatory)] [guid] $OperationId,
    [Parameter(Mandatory)]
    [ValidateSet('RECOVER-CRUW-WITHOUT-REPLAYING-DELETE')]
    [string] $ConfirmationPhrase,
    [Parameter(Mandatory)] [switch] $OffMachineRecoveryKeyConfirmed,
    [Parameter(Mandatory)] [switch] $PhysicalConsoleAccessConfirmed,
    [Parameter(Mandatory)] [switch] $ConfirmNoDeleteReplay,
    [ValidateRange(5, 120)] [int] $MaxPreflightAgeMinutes = 60,
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
    if (-not $SkipAcl -and $rootFull -notmatch '^(?:C:\\Acer-Driver-Audit\\Recovery|D:\\Acer-Recovery)\\CRUWBlocker-\d{8}-\d{6}-\d{3}$') {
        throw 'Recovery entrypoint must run from a fixed C: or D: recovery topology'
    }
    $bootstrapAdapter = if ($SkipAcl) { $TestAdapter } else { $null }
    $currentExpectedDrive = if ($SkipAcl -or $rootFull.StartsWith('C:\',[StringComparison]::OrdinalIgnoreCase)) { 'C:' } else { 'D:' }
    $currentAnchorBase = if ($SkipAcl) {
        $rootFull
    }
    elseif ($currentExpectedDrive -ceq 'C:') { 'C:\Acer-Driver-Audit' }
    else { 'D:\Acer-Recovery' }
    $currentAnchor = Add-CRUWBootstrapAnchorChain $rootFull $currentAnchorBase $currentExpectedDrive -Adapter $bootstrapAdapter
    if (-not [bool]$currentAnchor.complete) { throw 'Running recovery root could not be fully anchored' }
    $assertNoReparsePath = {
        param(
            [Parameter(Mandatory)] [string] $CandidatePath,
            [bool] $AllowMissing = $false
        )
        $fullCandidate = [IO.Path]::GetFullPath($CandidatePath).TrimEnd('\')
        $driveRoot = [IO.Path]::GetPathRoot($fullCandidate)
        if ($driveRoot -notmatch '^[A-Za-z]:\\$') { throw 'Bootstrap path is not on a local drive' }
        $currentPath = $driveRoot
        try { $rootItem = Get-Item -LiteralPath $currentPath -Force -ErrorAction Stop }
        catch [Management.Automation.DriveNotFoundException] { if ($AllowMissing) { return $false }; throw }
        catch [Management.Automation.ItemNotFoundException] { if ($AllowMissing) { return $false }; throw }
        if ($rootItem.Attributes -band [IO.FileAttributes]::ReparsePoint) { throw "Bootstrap drive root is a reparse point: $driveRoot" }
        $relative = $fullCandidate.Substring($driveRoot.Length).Trim('\')
        foreach ($component in @($relative -split '\\')) {
            if ([string]::IsNullOrWhiteSpace($component) -or $component -in @('.','..') -or $component.Contains(':')) {
                throw 'Bootstrap path contains an unsafe component'
            }
            $nextPath = Join-Path $currentPath $component
            try { $item = Get-Item -LiteralPath $nextPath -Force -ErrorAction Stop }
            catch [Management.Automation.ItemNotFoundException] { if ($AllowMissing) { return $false }; throw }
            if ($item.Attributes -band [IO.FileAttributes]::ReparsePoint) { throw "Bootstrap reparse component rejected: $nextPath" }
            $resolved = [IO.Path]::GetFullPath($item.FullName).TrimEnd('\')
            $expected = [IO.Path]::GetFullPath($nextPath).TrimEnd('\')
            if (-not [string]::Equals($resolved,$expected,[StringComparison]::OrdinalIgnoreCase)) {
                throw "Bootstrap component resolved outside its lexical path: $nextPath"
            }
            $currentPath = $expected
        }
        return $true
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
        [void](& $assertNoReparsePath $path $false)
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
    if ($manifestPrimaryRoot -ieq $manifestSecondaryRoot) { throw 'Manifest recovery roots must be distinct' }
    if (-not $SkipAcl -and (
        $manifestPrimaryRoot -notmatch '^C:\\Acer-Driver-Audit\\Recovery\\CRUWBlocker-\d{8}-\d{6}-\d{3}$' -or
        $manifestSecondaryRoot -notmatch '^D:\\Acer-Recovery\\CRUWBlocker-\d{8}-\d{6}-\d{3}$' -or
        (Split-Path -Leaf $manifestPrimaryRoot) -cne (Split-Path -Leaf $manifestSecondaryRoot)
    )) { throw 'Manifest recovery roots do not match the fixed C:/D: topology' }
    $rootRole = if ($rootFull -ceq $manifestPrimaryRoot) { 'primary' } elseif ($rootFull -ceq $manifestSecondaryRoot) { 'secondary' } else { $null }
    if ($null -eq $rootRole) { throw 'Running recovery root is not a manifest-declared primary or secondary root' }
    $counterpartRoot = if ($rootRole -ceq 'primary') { $manifestSecondaryRoot } else { $manifestPrimaryRoot }
    $counterpartManifestPath = Join-Path $counterpartRoot 'backup-integrity-final.json'
    $counterpartExpectedDrive = if ($rootRole -ceq 'primary') { 'D:' } else { 'C:' }
    $counterpartAnchorBase = if ($SkipAcl) {
        $counterpartRoot
    }
    elseif ($counterpartExpectedDrive -ceq 'C:') { 'C:\Acer-Driver-Audit' }
    else { 'D:\Acer-Recovery' }
    $counterpartAnchor = Add-CRUWBootstrapAnchorChain $counterpartRoot $counterpartAnchorBase $counterpartExpectedDrive -AllowMissing -Adapter $bootstrapAdapter
    $counterpartRootAvailable = [bool]$counterpartAnchor.complete -and [bool](& $assertNoReparsePath $counterpartRoot $true)
    $counterpartManifestAvailable = if ($counterpartRootAvailable) {
        [bool](& $assertNoReparsePath $counterpartManifestPath $true)
    }
    else { $false }
    if (-not $SkipAcl -and $counterpartRootAvailable) {
        $counterpartAclPaths = @($counterpartRoot)
        if ($counterpartManifestAvailable) { $counterpartAclPaths += $counterpartManifestPath }
        foreach ($peerPath in $counterpartAclPaths) {
            $acl = Get-Acl -LiteralPath $peerPath -ErrorAction Stop
            if (-not $acl.AreAccessRulesProtected) { throw "Sealed counterpart bootstrap ACL inherits: $peerPath" }
            try { $owner = ([Security.Principal.NTAccount]$acl.Owner).Translate([Security.Principal.SecurityIdentifier]).Value }
            catch { $owner = [string]$acl.Owner }
            if ($owner -cne 'S-1-5-18') { throw "Sealed counterpart bootstrap owner is not SYSTEM: $peerPath" }
            $seenAclSids = @{}
            foreach ($rule in @($acl.Access)) {
                try { $sid = $rule.IdentityReference.Translate([Security.Principal.SecurityIdentifier]).Value }
                catch { $sid = [string]$rule.IdentityReference }
                $fullControl =
                    ([Security.AccessControl.FileSystemRights]$rule.FileSystemRights -band [Security.AccessControl.FileSystemRights]::FullControl) -eq
                    [Security.AccessControl.FileSystemRights]::FullControl
                if ($sid -notin @('S-1-5-18','S-1-5-32-544') -or [string]$rule.AccessControlType -cne 'Allow' -or -not $fullControl) {
                    throw "Sealed counterpart bootstrap ACL contains an unauthorized rule: $peerPath"
                }
                $seenAclSids[$sid] = $true
            }
            if ($seenAclSids.Count -ne 2 -or -not $seenAclSids.ContainsKey('S-1-5-18') -or -not $seenAclSids.ContainsKey('S-1-5-32-544')) {
                throw "Sealed counterpart bootstrap ACL lacks exact SYSTEM and Administrators FullControl rules: $peerPath"
            }
        }
    }
    $manifestSha256 = (Get-FileHash -LiteralPath $manifestPath -Algorithm SHA256).Hash
    $counterpartManifestMatched =
        $counterpartManifestAvailable -and
        (Get-FileHash -LiteralPath $counterpartManifestPath -Algorithm SHA256).Hash -ieq $manifestSha256
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
        $recordHash = if ($record.Count -eq 1) {
            if ($rootRole -ceq 'primary') { [string]$record[0].primarySha256 } else { [string]$record[0].secondarySha256 }
        }
        else { $null }
        if ($record.Count -ne 1 -or -not [bool]$record[0].hashesMatch -or $hash -ine $recordHash) {
            throw "Manifest file record mismatch for running artifact: $role"
        }
    }
    $preflightRecord = @($manifest.files | Where-Object { [string]$_.relativePath -ceq 'preflight.json' })
    $preflightRecordHash = if ($preflightRecord.Count -eq 1) {
        if ($rootRole -ceq 'primary') { [string]$preflightRecord[0].primarySha256 } else { [string]$preflightRecord[0].secondarySha256 }
    }
    else { $null }
    if ($preflightRecord.Count -ne 1 -or -not [bool]$preflightRecord[0].hashesMatch -or
        (Get-FileHash -LiteralPath $preflightPath -Algorithm SHA256).Hash -ine $preflightRecordHash) {
        throw 'Sealed bootstrap preflight hash record invalid'
    }
    $preflight = Get-Content -LiteralPath $preflightPath -Raw -Encoding UTF8 | ConvertFrom-Json
    if ([int]$preflight.schemaVersion -ne 3 -or
        (@($preflight.implementation.artifacts) | ConvertTo-Json -Depth 6 -Compress) -cne ($artifacts | ConvertTo-Json -Depth 6 -Compress)) {
        throw 'Sealed bootstrap preflight v3 implementation differs from manifest'
    }
    return [ordered]@{
        root=$rootFull;rootRole=$rootRole;counterpartRoot=$counterpartRoot;
        manifestSha256=$manifestSha256;preflightSha256=(Get-FileHash -LiteralPath $preflightPath -Algorithm SHA256).Hash;
        counterpartManifestMatched=[bool]$counterpartManifestMatched
    }
}

$adapter = $null
try {
    $bootstrapCurrentRoot = Split-Path -Parent ([IO.Path]::GetFullPath($PreflightPath))
    trap {
        Close-CRUWBootstrapAnchorChains
        throw
    }
    $bootstrapEvidence = Assert-CRUWSealedBootstrap -PrimaryRoot $bootstrapCurrentRoot -EntryRole 'interruption-repair' -SkipAcl $TestMode.IsPresent
    . (Join-Path $PSScriptRoot 'CRUWStateMachine.Common.ps1')

    $confirmed =
        $OffMachineRecoveryKeyConfirmed.IsPresent -and
        $PhysicalConsoleAccessConfirmed.IsPresent -and
        $ConfirmNoDeleteReplay.IsPresent
    if (-not $confirmed) { throw 'All interrupted-operation recovery confirmations are required' }
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

function Invoke-CRUWDegradedRollbackOnly {
    param(
        [Parameter(Mandatory)] [string] $CurrentRoot,
        [Parameter(Mandatory)] [ValidateSet('primary','secondary')] [string] $CurrentRole,
        [Parameter(Mandatory)] [string] $CurrentPreflightPath,
        [Parameter(Mandatory)] [guid] $CurrentOperationId,
        [Parameter(Mandatory)] [hashtable] $CurrentAdapter,
        [Parameter(Mandatory)] [string] $CurrentScriptPath,
        [Parameter(Mandatory)] $CurrentBootstrapEvidence
    )
    $currentRootFull = [IO.Path]::GetFullPath($CurrentRoot).TrimEnd('\')
    $preflight = Get-Content -LiteralPath $CurrentPreflightPath -Raw -Encoding UTF8 | ConvertFrom-Json
    $otherRole = if ($CurrentRole -ceq 'primary') { 'secondary' } else { 'primary' }
    $otherRoot = if ($CurrentRole -ceq 'primary') { [string]$preflight.secondaryRecoveryPath } else { [string]$preflight.recoveryPath }
    $emergencyMounts = @('C:')
    $journalState = $null
    $context = $null
    $completedSafe = $false
    $diagnosticProtected = $false
    $failure = $null

    $checkpoint = {
        param([Parameter(Mandatory)] [string] $Stage)
        if ($null -eq $journalState) { throw 'Degraded journal is not initialized' }
        $entry = Write-CRUWSingleJournal $currentRootFull $CurrentOperationId $journalState.sequence $Stage $journalState.previous $context $CurrentAdapter
        $journalState.sequence++
        $journalState.previous = [string]$entry.payloadSha256
        $journalState.terminal = $entry
        return $entry
    }

    try {
        $singleChain = Get-CRUWSingleJournalState $currentRootFull $CurrentOperationId $CurrentAdapter
        if (-not [bool]$singleChain.verified) {
            throw "Surviving-root journal chain is invalid: $($singleChain.failures -join '; ')"
        }
        $journalState = [ordered]@{
            sequence=[int]$singleChain.nextSequence
            previous=[string]$singleChain.previousPayloadSha256
            terminal=$null
        }

        $anchor = $null
        for ($entryIndex=$singleChain.entries.Count-1; $entryIndex -ge 1; $entryIndex--) {
            $attestation = Get-CRUWPropertyValue $singleChain.entries[$entryIndex].payload.context 'lastDualCommit'
            if ($null -eq $attestation) { continue }
            $anchorSequence = [int](Get-CRUWPropertyValue $attestation 'sequence' -1)
            if ($anchorSequence -lt 0 -or $anchorSequence -ge $entryIndex) { continue }
            $anchorDocument = $singleChain.entries[$anchorSequence]
            $anchorEvidence = $singleChain.evidence[$anchorSequence]
            $roleFileHash = if ($CurrentRole -ceq 'primary') {
                [string](Get-CRUWPropertyValue $attestation 'primaryFileSha256')
            }
            else { [string](Get-CRUWPropertyValue $attestation 'secondaryFileSha256') }
            if (
                [string]$attestation.payloadSha256 -ceq [string]$anchorDocument.payloadSha256 -and
                [string]$attestation.stage -ceq [string]$anchorDocument.payload.stage -and
                $roleFileHash -ceq [string]$anchorEvidence.fileSha256
            ) {
                $anchor = [ordered]@{
                    attestingSequence=$entryIndex
                    sequence=$anchorSequence
                    payloadSha256=[string]$anchorDocument.payloadSha256
                    fileSha256=[string]$anchorEvidence.fileSha256
                    context=$anchorDocument.payload.context
                }
                break
            }
        }
        if ($null -eq $anchor) {
            throw 'No surviving entry attests a prior verified dual checkpoint; rollback mutation is forbidden'
        }
        $context = $anchor.context
        $contextPreflight = Get-CRUWPropertyValue $context 'preflight'
        if (
            [string]$contextPreflight.sha256 -ine [string]$CurrentBootstrapEvidence.preflightSha256 -or
            [string]$contextPreflight.integrityManifestSha256 -ine [string]$CurrentBootstrapEvidence.manifestSha256
        ) { throw 'Surviving root differs from the last previously dual preflight/manifest anchors' }

        $currentIntegrity = Test-CRUWSingleRecoveryRootIntegrity $currentRootFull $CurrentRole $contextPreflight.integrityManifestSha256 $CurrentAdapter
        $otherIntegrity = Test-CRUWSingleRecoveryRootIntegrity $otherRoot $otherRole $contextPreflight.integrityManifestSha256 $CurrentAdapter
        if (-not [bool]$currentIntegrity.verified) {
            throw "Running survivor is not a complete sealed v3 root: $($currentIntegrity.failures -join '; ')"
        }
        if ([bool]$otherIntegrity.internallyVerified) {
            throw 'Counterpart root is internally intact (matching or divergent); degraded mutation is forbidden until dual reconciliation'
        }
        $implementationSeal = Test-CRUWImplementationSeal ([ordered]@{manifest=$currentIntegrity.manifest}) $currentIntegrity.preflight $currentRootFull $CurrentScriptPath
        if (-not [bool]$implementationSeal.verified) {
            throw "Running survivor implementation is not sealed: $($implementationSeal.failures -join '; ')"
        }
        $identity = Get-CRUWPreflightIdentity $currentIntegrity.preflight $currentIntegrity.manifest $currentRootFull
        if (
            [string]$context.targetIdentitySha256 -cne [string]$identity.sha256 -or
            (Get-CRUWObjectSha256 $context.targetIdentity) -cne [string]$identity.sha256
        ) { throw 'Surviving journal target identity differs from sealed v3 evidence' }

        $mounts = @($context.requiredMountPoints | ForEach-Object { [string]$_ })
        $encryptedMounts = @(Get-CRUWEncryptedMountPoints $currentIntegrity.preflight)
        $emergencyMounts = $encryptedMounts
        $boot = Invoke-CRUWAdapter $CurrentAdapter 'GetBootIdentity'
        $sameBoot = Test-CRUWSameBootIdentity $boot $context.mutationBoot
        $ac = Invoke-CRUWAdapter $CurrentAdapter 'GetAcPowerState'
        $snapshot = Invoke-CRUWAdapter $CurrentAdapter 'GetStorageSnapshot' @($identity.document.publishedName,$identity.document.filterName,$mounts,$identity.document)
        $state = Get-CRUWStateClassification $snapshot $identity.document $mounts Preboot
        $nativeBaseline = @($context.nativeStorageServicesBaseline)
        $entryBitLockerStates = @($encryptedMounts | ForEach-Object { Invoke-CRUWAdapter $CurrentAdapter 'GetBitLockerState' @($_) })
        $entryBitLockerAllOn = Test-CRUWBitLockerInventoryStates $entryBitLockerStates $encryptedMounts AllOn
        $entryBitLockerSuspended = Test-CRUWBitLockerInventoryStates $entryBitLockerStates $encryptedMounts COffOthersOn
        if (-not ([bool]$entryBitLockerAllOn.verified -or [bool]$entryBitLockerSuspended.verified)) {
            throw 'Degraded recovery entry BitLocker inventory is neither exact AllOn nor bounded COffOthersOn'
        }
        Set-CRUWPropertyValue $context degradedRecovery ([ordered]@{
            mode='SINGLE_ROOT_ROLLBACK_ONLY';survivorRole=$CurrentRole;
            survivorRootSha256=Get-CRUWStringSha256 $currentRootFull;otherRootSha256=Get-CRUWStringSha256 $otherRoot;
            priorDualAnchor=[ordered]@{sequence=$anchor.sequence;payloadSha256=$anchor.payloadSha256;fileSha256=$anchor.fileSha256};
            noDelete=$true;noRebootAuthorization=$true;entryState=$state;sameBoot=$sameBoot;ac=$ac;
            entryBitLocker=[ordered]@{allOn=$entryBitLockerAllOn;suspended=$entryBitLockerSuspended}
        })

        $existingTerminal = @($singleChain.entries | Where-Object {
            [string]$_.payload.stage -ceq 'DEGRADED_ROLLBACK_PROTECTED_TERMINAL'
        })
        if ($existingTerminal.Count -gt 0) {
            $legacy = [string]$state.classification -ceq 'LEGACY_INTACT'
            $probes = Test-CRUWProbeEvidence @($mounts | ForEach-Object { Invoke-CRUWAdapter $CurrentAdapter 'ProbeVolume' @($_) }) $mounts
            $native = Test-CRUWNativeStorageServiceDrift $nativeBaseline $snapshot.nativeStorageServices
            $allOn = Get-CRUWBitLockerInventoryEvidence $CurrentAdapter $encryptedMounts AllOn
            if (-not ($legacy -and [bool]$probes.verified -and [bool]$native.verified -and [bool]$allOn.verified)) {
                throw 'Degraded terminal replay no longer satisfies protected LEGACY_INTACT gates'
            }
            return [ordered]@{
                operationId=$CurrentOperationId.ToString('D');authorized=$false;completedSafe=$true;
                diagnosticProtected=$false;deleteReplayed=$false;journalHealthy=$true;
                terminalCheckpoint=$null;failure=$null;recoveryFailures=@();degradedMode=$true;idempotent=$true
            }
        }

        if (-not $sameBoot) {
            Set-CRUWPropertyValue $context safeExit $false
            & $checkpoint DEGRADED_DIAGNOSTIC_HOLD | Out-Null
            $diagnosticProtected = $true
            return [ordered]@{
                operationId=$CurrentOperationId.ToString('D');authorized=$false;completedSafe=$false;
                diagnosticProtected=$true;deleteReplayed=$false;journalHealthy=$true;
                terminalCheckpoint=$journalState.terminal;failure='Boot changed without dual REBOOT_AUTHORIZED';recoveryFailures=@();degradedMode=$true
            }
        }
        if (-not [bool]$ac.online) { throw 'AC power is required for degraded rollback-only recovery' }

        if ([string]$state.classification -notin @('LEGACY_INTACT','CLEAN_PREBOOT','TRANSITION')) {
            throw "Degraded rollback refuses BROKEN/unknown storage state: $($state.classification)"
        }
        if ([string]$state.classification -ne 'LEGACY_INTACT') {
            $rollbackCapability = Get-CRUWPropertyValue $currentIntegrity.preflight 'rollbackCapability'
            $rollbackCapabilityEvidence = Test-CRUWRollbackCapabilityContract $rollbackCapability $currentIntegrity.preflight -SimulationOnly:$TestMode.IsPresent
            if (-not [bool]$rollbackCapabilityEvidence.verified) {
                throw 'Automatic rollback is blocked: sealed evidence does not prove exact CRUW service configuration restoration'
            }
            $context.degradedRecovery.rollbackCapability = [ordered]@{contract=$rollbackCapability;validation=$rollbackCapabilityEvidence}
            $anchoredEntries = @($singleChain.entries | Where-Object { [int]$_.payload.sequence -le [int]$anchor.sequence })
            $deleteIntentEntries = @($anchoredEntries | Where-Object { [string]$_.payload.stage -ceq 'DELETE_INTENT' })
            $deleteGateEntries = @($anchoredEntries | Where-Object { [string]$_.payload.stage -ceq 'DELETE_LIVE_GATE' })
            if ($deleteIntentEntries.Count -ne 1 -or $deleteGateEntries.Count -ne 1) {
                throw 'Degraded rollback lacks one previously dual DELETE_INTENT/DELETE_LIVE_GATE proof'
            }
            $deleteGateContext = $deleteGateEntries[0].payload.context
            $deleteGateEvidence = Get-CRUWPropertyValue $deleteGateContext 'deleteLiveGate'
            $deleteIntentContract = Get-CRUWPropertyValue $deleteGateContext 'deleteIntentContract'
            $deleteIntentArguments = @(Get-CRUWPropertyValue $deleteIntentContract 'arguments')
            $sealedPreDeletePendingClear =
                [bool](Get-CRUWPropertyValue (Get-CRUWPropertyValue $deleteGateEvidence 'gates') 'pendingRebootClear' $false) -and
                -not [bool](Get-CRUWPropertyValue (Get-CRUWPropertyValue $deleteGateContext 'pendingAtDelete') 'detected' $true) -and
                [string](Get-CRUWPropertyValue $deleteIntentContract 'executable') -ceq 'pnputil.exe' -and
                $deleteIntentArguments.Count -eq 3 -and
                [string]$deleteIntentArguments[0] -ceq '/delete-driver' -and
                [string]$deleteIntentArguments[1] -ceq [string]$identity.document.publishedName -and
                [string]$deleteIntentArguments[2] -ceq '/uninstall'
            if (-not $sealedPreDeletePendingClear) {
                throw 'Degraded rollback lacks a sealed pre-delete pending-clear and exact-intent proof'
            }
            $pending = Invoke-CRUWAdapter $CurrentAdapter 'GetPendingRebootState'
            $context.degradedRecovery.preDeleteProof = [ordered]@{
                intentPayloadSha256=[string]$deleteIntentEntries[0].payloadSha256
                liveGatePayloadSha256=[string]$deleteGateEntries[0].payloadSha256
                sealedPendingClear=$true
                currentPending=$pending
            }
            $readiness = Invoke-CRUWAdapter $CurrentAdapter 'GetRecoveryReadiness'
            if (-not (Test-CRUWRecoveryReadiness $readiness $currentIntegrity.preflight)) { throw 'Sealed recovery readiness drift blocks degraded rollback' }
            $eventSinceValue = Get-CRUWPropertyValue (Get-CRUWPropertyValue $context 'deleteDriver') 'startedAt' (Get-CRUWPropertyValue $deleteIntentEntries[0].payload 'recordedAt' $currentIntegrity.preflight.checkedAt)
            $events = @(Invoke-CRUWAdapter $CurrentAdapter 'GetCriticalEventsSince' @([DateTimeOffset]$eventSinceValue))
            if ($events.Count -ne 0) { throw 'Storage warning/error/critical events block degraded rollback' }
            $preMutationProbes = Test-CRUWProbeEvidence @($mounts | ForEach-Object { Invoke-CRUWAdapter $CurrentAdapter 'ProbeVolume' @($_) }) $mounts
            $preMutationNative = Test-CRUWNativeStorageServiceDrift $nativeBaseline $snapshot.nativeStorageServices
            if (-not ([bool]$preMutationProbes.verified -and [bool]$preMutationNative.verified)) {
                throw 'Pre-mutation probe/native no-drift gates block degraded rollback'
            }
            $context.degradedRecovery.setupApiBefore = Invoke-CRUWAdapter $CurrentAdapter 'GetSetupApiEvidence'

            # Commit-live recapture occurs immediately before the durable intent.
            $commitPending = Invoke-CRUWAdapter $CurrentAdapter 'GetPendingRebootState'
            $commitAc = Invoke-CRUWAdapter $CurrentAdapter 'GetAcPowerState'
            $commitBoot = Invoke-CRUWAdapter $CurrentAdapter 'GetBootIdentity'
            $revalidated = Test-CRUWSingleRecoveryRootIntegrity $currentRootFull $CurrentRole $contextPreflight.integrityManifestSha256 $CurrentAdapter
            $commitSnapshot = Invoke-CRUWAdapter $CurrentAdapter 'GetStorageSnapshot' @($identity.document.publishedName,$identity.document.filterName,$mounts,$identity.document)
            $commitState = Get-CRUWStateClassification $commitSnapshot $identity.document $mounts Preboot
            $commitBitLockerStates = @($encryptedMounts | ForEach-Object { Invoke-CRUWAdapter $CurrentAdapter 'GetBitLockerState' @($_) })
            $commitBitLockerAllOn = Test-CRUWBitLockerInventoryStates $commitBitLockerStates $encryptedMounts AllOn
            $commitBitLockerSuspended = Test-CRUWBitLockerInventoryStates $commitBitLockerStates $encryptedMounts COffOthersOn
            $commitGates = [ordered]@{
                sealedPreDeletePendingClear=$sealedPreDeletePendingClear;acOnline=[bool]$commitAc.online;
                sameBoot=Test-CRUWSameBootIdentity $commitBoot $context.mutationBoot;
                survivorIntegrity=[bool]$revalidated.verified;
                stateStillRollbackEligible=[string]$commitState.classification -in @('CLEAN_PREBOOT','TRANSITION');
                bitLockerInventoryKnown=[bool]$commitBitLockerAllOn.verified -or [bool]$commitBitLockerSuspended.verified
            }
            $commitFailures = @($commitGates.GetEnumerator() | Where-Object { -not [bool]$_.Value } | ForEach-Object Key)
            $context.degradedRecovery.commitLive = [ordered]@{
                gates=$commitGates;failures=$commitFailures;pending=$commitPending;ac=$commitAc;boot=$commitBoot;
                state=$commitState;bitLocker=[ordered]@{allOn=$commitBitLockerAllOn;suspended=$commitBitLockerSuspended}
            }
            if ($commitFailures.Count -gt 0) { throw "Degraded commit-live gates failed: $($commitFailures -join ', ')" }
            & $checkpoint DEGRADED_ROLLBACK_INTENT | Out-Null
            $rollback = Invoke-CRUWAdapter $CurrentAdapter 'ReinstallBackupDriver' @($revalidated.infPath)
            $arguments = @($rollback.arguments)
            $rollbackContract =
                [string]$rollback.executable -ceq 'pnputil.exe' -and
                $arguments.Count -eq 3 -and
                [string]$arguments[0] -ceq '/add-driver' -and
                [string]$arguments[1] -ceq [string]$revalidated.infPath -and
                [string]$arguments[2] -ceq '/install' -and
                [int]$rollback.exitCode -in @(0,3010)
            $rolledSnapshot = Invoke-CRUWAdapter $CurrentAdapter 'GetStorageSnapshot' @($identity.document.publishedName,$identity.document.filterName,$mounts,$identity.document)
            $rolledState = Get-CRUWStateClassification $rolledSnapshot $identity.document $mounts Preboot
            $rolledLiveReadback = Test-CRUWRollbackLiveReadback $rolledSnapshot $rollbackCapability
            $context.degradedRecovery.rollback = [ordered]@{
                result=$rollback;contractVerified=$rollbackContract;setupApiAfter=(Invoke-CRUWAdapter $CurrentAdapter 'GetSetupApiEvidence');
                state=$rolledState;snapshot=$rolledSnapshot;exactServiceReadback=$rolledLiveReadback
            }
            & $checkpoint DEGRADED_ROLLBACK_RESULT | Out-Null
            if (-not $rollbackContract -or [string]$rolledState.classification -cne 'LEGACY_INTACT' -or -not [bool]$rolledLiveReadback.verified) {
                throw 'Degraded add/install did not return 0/3010 and restore exact LEGACY_INTACT service readback'
            }
            $snapshot = $rolledSnapshot
            $state = $rolledState
        }

        $allOn = Get-CRUWBitLockerInventoryEvidence $CurrentAdapter $encryptedMounts AllOn
        if (-not [bool]$allOn.verified) {
            Invoke-CRUWAdapter $CurrentAdapter 'ResumeBitLocker' @('C:') | Out-Null
            $allOn = Get-CRUWBitLockerInventoryEvidence $CurrentAdapter $encryptedMounts AllOn
        }
        $probes = Test-CRUWProbeEvidence @($mounts | ForEach-Object { Invoke-CRUWAdapter $CurrentAdapter 'ProbeVolume' @($_) }) $mounts
        $native = Test-CRUWNativeStorageServiceDrift $nativeBaseline $snapshot.nativeStorageServices
        $finalBoot = Test-CRUWSameBootIdentity (Invoke-CRUWAdapter $CurrentAdapter 'GetBootIdentity') $context.mutationBoot
        $finalPending = Invoke-CRUWAdapter $CurrentAdapter 'GetPendingRebootState'
        $safe =
            [string]$state.classification -ceq 'LEGACY_INTACT' -and
            [bool]$allOn.verified -and [bool]$probes.verified -and [bool]$native.verified -and $finalBoot
        $context.degradedRecovery.final = [ordered]@{state=$state;bitLocker=$allOn;probes=$probes;native=$native;sameBoot=$finalBoot;pending=$finalPending}
        $context.safeExit = $safe
        if (-not $safe) { throw 'Degraded rollback final LEGACY/probe/native/boot/BitLocker gates failed' }
        if ([bool]$finalPending.detected) {
            $context.safeExit = $false
            $context.operatorActionRequired = 'DO NOT REBOOT. Rollback restored exact LEGACY_INTACT and BitLocker is On, but pending-reboot evidence remains and requires revalidation.'
            & $checkpoint DEGRADED_PENDING_DIAGNOSTIC_HOLD | Out-Null
            $diagnosticProtected = $true
            return [ordered]@{
                operationId=$CurrentOperationId.ToString('D');authorized=$false;completedSafe=$false;
                diagnosticProtected=$true;deleteReplayed=$false;journalHealthy=$true;
                terminalCheckpoint=$journalState.terminal;failure='Pending reboot remains after rollback';recoveryFailures=@();degradedMode=$true
            }
        }
        & $checkpoint DEGRADED_ROLLBACK_PROTECTED_TERMINAL | Out-Null
        $completedSafe = $true
        return [ordered]@{
            operationId=$CurrentOperationId.ToString('D');authorized=$false;completedSafe=$true;
            diagnosticProtected=$false;deleteReplayed=$false;journalHealthy=$true;
            terminalCheckpoint=$journalState.terminal;failure=$null;recoveryFailures=@();degradedMode=$true
        }
    }
    catch {
        $failure = $_.Exception.Message
        if ($null -ne $context -and $null -ne $journalState) {
            try {
                Set-CRUWPropertyValue $context safeExit $false
                Set-CRUWPropertyValue $context degradedFailure $failure
                & $checkpoint DEGRADED_DIAGNOSTIC_HOLD | Out-Null
                $diagnosticProtected = $true
            }
            catch {}
        }
        throw
    }
    finally {
        $protected = Get-CRUWBitLockerInventoryEvidence $CurrentAdapter $emergencyMounts AllOn
        if (-not [bool]$protected.verified) {
            Invoke-CRUWAdapter $CurrentAdapter 'ResumeBitLocker' @('C:') | Out-Null
            $protected = Get-CRUWBitLockerInventoryEvidence $CurrentAdapter $emergencyMounts AllOn
        }
        if (-not [bool]$protected.verified) { throw 'Degraded recovery exit could not verify BitLocker Protection On' }
    }
}

$mutexHandle = $null
try {
    $mutexHandle = Invoke-CRUWAdapter $adapter 'EnterOperationMutex'
}
catch {
    Close-CRUWBootstrapAnchorChains
    [ordered]@{
        operationId=$OperationId.ToString('D');authorized=$false;completedSafe=$false;
        diagnosticProtected=$false;deleteReplayed=$false;journalHealthy=$false;terminalCheckpoint=$null;
        failure='Operation mutex unavailable';recoveryFailures=@();degradedMode=$false;
        operatorActionRequired='DO NOT REBOOT. Another state-machine owner may be mutating storage; retry only after the mutex is available.'
    }
    return
}
$authorized = $false
$protectionHandled = $false
$emergencyMounts = @('C:')
try {
    $preflightFull = [IO.Path]::GetFullPath($PreflightPath)
    $preflight = Get-Content -LiteralPath $preflightFull -Raw -Encoding UTF8 | ConvertFrom-Json
    $primaryRoot = [string]$preflight.recoveryPath
    $secondaryRoot = [string]$preflight.secondaryRecoveryPath
    $emergencyMounts = @(Get-CRUWEncryptedMountPoints $preflight)
    $completedSafe = $false
    $diagnosticProtected = $false
    $appendAllowed = $false
    $journalHealthy = $true
    $journalState = $null
    $context = $null
    $failure = $null
    $recoveryFailures = [Collections.Generic.List[string]]::new()

    $dualIntegrityProbe = $null
    try { $dualIntegrityProbe = Test-CRUWBackupIntegrity $preflight $preflightFull $adapter }
    catch { $dualIntegrityProbe = [ordered]@{verified=$false;failures=@($_.Exception.Message)} }
    if (-not [bool]$dualIntegrityProbe.verified) {
        $degradedResult = Invoke-CRUWDegradedRollbackOnly `
            -CurrentRoot $bootstrapEvidence.root `
            -CurrentRole $bootstrapEvidence.rootRole `
            -CurrentPreflightPath $preflightFull `
            -CurrentOperationId $OperationId `
            -CurrentAdapter $adapter `
            -CurrentScriptPath $PSCommandPath `
            -CurrentBootstrapEvidence $bootstrapEvidence
        $protectionHandled = $true
        $degradedResult
        return
    }
    if (@(Get-CRUWUnrecognizedJournalArtifacts $primaryRoot $secondaryRoot).Count -gt 0) {
        throw 'Unrecognized removal-journal artifacts require manual forensic review'
    }

    $checkpoint = {
        param([string] $Stage)
        if (-not $appendAllowed -or $null -eq $journalState) {
            throw 'Recovery journal append is not authorized'
        }
        try {
            $entry = Write-CRUWDualJournal $primaryRoot $secondaryRoot $OperationId $journalState.sequence $Stage $journalState.previous $context $adapter
            Set-CRUWPropertyValue $context lastDualCommit ([ordered]@{
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
        $integrity = Test-CRUWBackupIntegrity $preflight $preflightFull $adapter
        $dualIntegrityVerified = [bool]$integrity.verified
        if (-not $dualIntegrityVerified) {
            $recoverableIntegrityFailures = @($integrity.failures | Where-Object {
                [string]$_ -match '^(hash mismatch|missing backup file): '
            })
            $integrityCoreTrusted =
                [string]$integrity.primaryManifestSha256 -ceq [string]$integrity.secondaryManifestSha256 -and
                [bool]$integrity.primaryAcl.verified -and
                [bool]$integrity.secondaryAcl.verified -and
                [bool]$integrity.recoveryRootTopology.verified -and
                $recoverableIntegrityFailures.Count -eq @($integrity.failures).Count
            if (-not $integrityCoreTrusted) {
                throw "Recovery backup integrity failed outside single-root fallback scope: $($integrity.failures -join '; ')"
            }
        }
        $implementationSeal = Test-CRUWImplementationSeal $integrity $preflight $primaryRoot $PSCommandPath
        if (-not [bool]$implementationSeal.verified) { throw "Running recovery implementation is not sealed: $($implementationSeal.failures -join '; ')" }
        $identity = Get-CRUWPreflightIdentity $preflight $integrity.manifest
        $mounts = @($identity.document.volumes | ForEach-Object { [string]$_.mountPoint })
        $encryptedMounts = @(Get-CRUWEncryptedMountPoints $preflight)
        $emergencyMounts = $encryptedMounts
        $now = [DateTimeOffset](Invoke-CRUWAdapter $adapter 'GetNow')
        $preflightAge = ($now - [DateTimeOffset]$preflight.checkedAt).TotalMinutes
        $boot = Invoke-CRUWAdapter $adapter 'GetBootIdentity'
        $sameBoot = Test-CRUWSameBootIdentity $boot $preflight.bootIdentity

        $prefix = Repair-CRUWJournalPrefix $primaryRoot $secondaryRoot $OperationId $adapter
        if ([bool]$prefix.divergent) {
            throw 'No non-divergent committed journal prefix is available'
        }
        if ($null -eq $prefix.unilateralTail -and $prefix.commonPrefixLength -gt 0) {
            $latestCommittedStage = [string]$prefix.entries[-1].payload.stage
            $closedStages = @('ABORT_TERMINAL','POSTBOOT_COMPLETE','POSTBOOT_STABILITY_PENDING','POSTBOOT_SAFE_RESIDUAL','POSTBOOT_PROTECTED_DIAGNOSTIC_HOLD')
            if ($latestCommittedStage -in $closedStages) {
                $quarantines = @(Get-CRUWJournalQuarantineEvidence $primaryRoot $secondaryRoot $OperationId $adapter)
                $quarantineResolution = Test-CRUWJournalQuarantineResolution $prefix $quarantines
                if (-not [bool]$quarantineResolution.verified) {
                    throw 'Closed operation has unresolved quarantined journal evidence'
                }
                $closedBitLocker = Get-CRUWBitLockerInventoryEvidence $adapter $encryptedMounts AllOn
                if (-not [bool]$closedBitLocker.verified) {
                    Invoke-CRUWAdapter $adapter 'ResumeBitLocker' @('C:') | Out-Null
                    $closedBitLocker = Get-CRUWBitLockerInventoryEvidence $adapter $encryptedMounts AllOn
                }
                if (-not [bool]$closedBitLocker.verified) { throw 'Closed-operation replay could not verify BitLocker Protection On' }
                $terminalContext = Get-CRUWPropertyValue $prefix.entries[-1].payload 'context' $null
                $completedSafe = $latestCommittedStage -in @('ABORT_TERMINAL','POSTBOOT_COMPLETE','POSTBOOT_STABILITY_PENDING','POSTBOOT_SAFE_RESIDUAL')
                $diagnosticProtected = $latestCommittedStage -ceq 'POSTBOOT_PROTECTED_DIAGNOSTIC_HOLD'
                $stabilityPending = $latestCommittedStage -ceq 'POSTBOOT_STABILITY_PENDING'
                $removalComplete = if ($latestCommittedStage -in @('POSTBOOT_COMPLETE','POSTBOOT_STABILITY_PENDING')) {
                    $true
                }
                else { [bool](Get-CRUWPropertyValue $terminalContext 'removalComplete' $false) }
                $maintenanceComplete = $latestCommittedStage -ceq 'POSTBOOT_COMPLETE'
                $operatorAction = [string](Get-CRUWPropertyValue $terminalContext 'operatorActionRequired' '')
                if ([string]::IsNullOrWhiteSpace($operatorAction)) {
                    $operatorAction = switch ($latestCommittedStage) {
                        'POSTBOOT_STABILITY_PENDING' { 'Removal is storage-safe but maintenance is not complete. Perform a later distinct stable MANUAL reboot; this draft intentionally does not yet restore the sealed original recovery posture.' }
                        'POSTBOOT_PROTECTED_DIAGNOSTIC_HOLD' { 'DO NOT REBOOT. Prior protected diagnostic hold remains unresolved.' }
                        'POSTBOOT_SAFE_RESIDUAL' { 'Storage is safe; residual cleanup remains a separate reviewed action.' }
                        'POSTBOOT_COMPLETE' { 'Maintenance is complete; no further action is required.' }
                        default { 'Removal was aborted safely; no authorized reboot is pending.' }
                    }
                }
                $protectionHandled = $true
                [ordered]@{
                    operationId=$OperationId.ToString('D');authorized=$false;completedSafe=$completedSafe;
                    diagnosticProtected=$diagnosticProtected;deleteReplayed=$false;journalHealthy=$true;
                    removalComplete=$removalComplete;maintenanceComplete=$maintenanceComplete;stabilityPending=$stabilityPending;
                    operatorActionRequired=$operatorAction;terminalCheckpoint=$null;failure=$null;recoveryFailures=@();idempotentStage=$latestCommittedStage
                }
                return
            }
        }
        $seq0Quarantines = @(Get-CRUWJournalQuarantineEvidence $primaryRoot $secondaryRoot $OperationId $adapter | Where-Object {
            [bool]$_.valid -and [int]$_.sequence -eq 0 -and [string]$_.document.payload.stage -ceq 'PREPARED'
        })
        if ($null -ne $prefix.unilateralTail -and $seq0Quarantines.Count -gt 0) { throw 'Active and quarantined seq0 tails coexist ambiguously' }
        $seq0PreparedEvidence =
            ($null -ne $prefix.unilateralTail -and [int]$prefix.unilateralTail.sequence -eq 0 -and [string]$prefix.unilateralTail.document.payload.stage -ceq 'PREPARED') -or
            $seq0Quarantines.Count -eq 1
        if (
            $prefix.commonPrefixLength -eq 0 -and
            $seq0PreparedEvidence
        ) {
            # PREPARED is written before any suspension/mutation. A unilateral
            # seq0 therefore proves the mutating try block never began.
            $seq0Snapshot = Invoke-CRUWAdapter $adapter 'GetStorageSnapshot' @($identity.document.publishedName, $identity.document.filterName, $mounts, $identity.document)
            $seq0State = Get-CRUWStateClassification $seq0Snapshot $identity.document $mounts Preboot
            $seq0BitLocker = Get-CRUWBitLockerInventoryEvidence $adapter $encryptedMounts AllOn
            $seq0Native = Test-CRUWNativeStorageServiceDrift $seq0Snapshot.nativeStorageServices $seq0Snapshot.nativeStorageServices
            $seq0Probes = Test-CRUWProbeEvidence @($mounts | ForEach-Object { Invoke-CRUWAdapter $adapter 'ProbeVolume' @($_) }) $mounts
            if (
                [string]$seq0State.classification -cne 'LEGACY_INTACT' -or
                -not [bool]$seq0BitLocker.verified -or
                -not [bool]$seq0Native.verified -or
                -not [bool]$seq0Probes.verified -or
                -not $sameBoot
            ) { throw 'Unilateral PREPARED seq0 does not match the guaranteed no-mutation live state' }
            $seq0Quarantine = if ($null -ne $prefix.unilateralTail) {
                Quarantine-CRUWUnilateralJournalTail $prefix $adapter
            }
            else {
                [ordered]@{
                    sourceRole=[string]$seq0Quarantines[0].role;sequence=0;fileSha256=[string]$seq0Quarantines[0].fileSha256;
                    quarantinePathSha256=[string]$seq0Quarantines[0].pathSha256;acl=$seq0Quarantines[0].acl
                }
            }
            $prefix = Repair-CRUWJournalPrefix $primaryRoot $secondaryRoot $OperationId $adapter
            if (-not [bool]$prefix.verified -or $prefix.commonPrefixLength -ne 0) { throw 'Seq0 quarantine did not restore an empty committed prefix' }
            $context = [ordered]@{
                preflight=[ordered]@{path=$preflightFull;sha256=(Get-FileHash -LiteralPath $preflightFull -Algorithm SHA256).Hash;integrityManifestSha256=$integrity.primaryManifestSha256}
                mutationBoot=$boot;targetIdentity=$identity.document;targetIdentitySha256=$identity.sha256;
                requiredMountPoints=$mounts;encryptedMountPoints=$encryptedMounts;nativeStorageServicesBaseline=@($seq0Snapshot.nativeStorageServices);
                recovery=[ordered]@{sourceOperationId=$OperationId.ToString('D');noDeleteReplay=$true;unilateralTail=$seq0Quarantine;seq0NoMutationProof=[ordered]@{state=$seq0State;bitLocker=$seq0BitLocker;native=$seq0Native;probes=$seq0Probes;sameBoot=$sameBoot}};
                mutationAccepted=$false;safeExit=$true;operatorActionRequired='DO NOT REBOOT; unilateral PREPARED was safely closed without mutation.'
            }
            $journalState = [ordered]@{sequence=0;previous=$null;terminal=$null}
            $appendAllowed = $true
            & $checkpoint ABORT_TERMINAL | Out-Null
            $completedSafe = $true
            $protectionHandled = $true
            [ordered]@{operationId=$OperationId.ToString('D');authorized=$false;completedSafe=$true;diagnosticProtected=$false;deleteReplayed=$false;journalHealthy=$true;terminalCheckpoint=$journalState.terminal;failure=$null;recoveryFailures=@()}
            return
        }
        if ($prefix.commonPrefixLength -eq 0) { throw 'Committed journal prefix is empty and has no valid unilateral PREPARED evidence' }
        $removalEntries = @($prefix.entries | Where-Object {
            $null -ne (Get-CRUWPropertyValue $_.payload.context 'targetIdentity')
        })
        if ($removalEntries.Count -eq 0) { throw 'Committed prefix has no sealed removal context' }
        $context = $removalEntries[-1].payload.context
        if (
            [string]$context.targetIdentitySha256 -cne [string]$identity.sha256 -or
            (Get-CRUWObjectSha256 $context.targetIdentity) -cne [string]$identity.sha256
        ) {
            throw 'Interrupted journal target identity differs from sealed preflight'
        }
        $currentPreflightSha256 = (Get-FileHash -LiteralPath $preflightFull -Algorithm SHA256).Hash
        if (
            [string]$context.preflight.sha256 -ine $currentPreflightSha256 -or
            [string]$context.preflight.integrityManifestSha256 -ine [string]$integrity.primaryManifestSha256
        ) {
            throw 'Interrupted journal preflight/manifest anchors differ from the last committed dual context'
        }

        # Live state is captured before a unilateral tail is quarantined.  The
        # tail never asserts whether the associated effect occurred.
        $liveSnapshot = Invoke-CRUWAdapter $adapter 'GetStorageSnapshot' @($identity.document.publishedName, $identity.document.filterName, $mounts, $identity.document)
        $liveState = Get-CRUWStateClassification $liveSnapshot $identity.document $mounts Preboot
        $bitLockerEntryStates = @($encryptedMounts | ForEach-Object { Invoke-CRUWAdapter $adapter 'GetBitLockerState' @($_) })
        $bitLockerAllOnAtEntry = Test-CRUWBitLockerInventoryStates $bitLockerEntryStates $encryptedMounts AllOn
        $bitLockerSuspendedAtEntry = Test-CRUWBitLockerInventoryStates $bitLockerEntryStates $encryptedMounts COffOthersOn
        if (-not ([bool]$bitLockerAllOnAtEntry.verified -or [bool]$bitLockerSuspendedAtEntry.verified)) { throw 'Encrypted-volume BitLocker entry inventory is unknown' }
        $bitLockerAtEntry = [ordered]@{states=$bitLockerEntryStates;allOn=$bitLockerAllOnAtEntry;suspended=$bitLockerSuspendedAtEntry}
        Set-CRUWPropertyValue $context recovery ([ordered]@{
            confirmationPhrase = $ConfirmationPhrase
            noDeleteReplay = $true
            sourceOperationId = $OperationId.ToString('D')
            liveStateBeforeJournalReconciliation = $liveState
            liveSnapshotBeforeJournalReconciliation = $liveSnapshot
            bitLockerAtEntry = $bitLockerAtEntry
            preflightAgeMinutes = $preflightAge
            sameBoot = $sameBoot
            dualIntegrityVerified = $dualIntegrityVerified
            integrityFailures = @($integrity.failures)
            unilateralTail = $null
        })

        $existingQuarantines = @(Get-CRUWJournalQuarantineEvidence $primaryRoot $secondaryRoot $OperationId $adapter)
        $knownReconciledHashes = @($prefix.entries | ForEach-Object {
            $priorRecovery = Get-CRUWPropertyValue $_.payload.context 'recovery'
            $priorTail = Get-CRUWPropertyValue $priorRecovery 'unilateralTail'
            [string](Get-CRUWPropertyValue $priorTail 'fileSha256' '')
        } | Where-Object { -not [string]::IsNullOrWhiteSpace($_) })
        $unresolvedQuarantines = @($existingQuarantines | Where-Object {
            -not [bool]$_.valid -or $knownReconciledHashes -notcontains [string]$_.fileSha256
        })
        if ($unresolvedQuarantines.Count -gt 1) {
            throw 'Multiple unresolved quarantined journal tails are ambiguous'
        }
        if ($unresolvedQuarantines.Count -eq 1) {
            if (-not [bool]$unresolvedQuarantines[0].valid) { throw 'Quarantined journal tail failed hash/ACL validation' }
            $context.recovery.unilateralTail = $unresolvedQuarantines[0]
        }
        if ($null -ne $prefix.unilateralTail) {
            if ($unresolvedQuarantines.Count -gt 0) { throw 'Both active and quarantined unilateral journal tails exist' }
            $context.recovery.unilateralTail = Quarantine-CRUWUnilateralJournalTail $prefix $adapter
            $prefix = Repair-CRUWJournalPrefix $primaryRoot $secondaryRoot $OperationId $adapter
        }
        if (-not [bool]$prefix.verified) { throw 'Committed journal prefix is not writable after reconciliation' }
        $journalState = [ordered]@{
            sequence = [int]$prefix.nextSequence
            previous = [string]$prefix.previousPayloadSha256
            terminal = $null
        }
        $appendAllowed = $true
        & $checkpoint RECOVERY_RECONCILIATION | Out-Null
        # The immutable reconciliation entry owns the sole quarantine reference.
        # Later checkpoints must not duplicate it through the mutable context.
        $context.recovery.unilateralTail = $null

        # Recovery after an already-recorded mutation must not be stranded by
        # wall-clock age. Sealed integrity, exact boot identity, and fresh live
        # gates are the authority for any recovery mutation.
        $sameBootForMutation = $sameBoot
        $nativeBaseline = @($context.nativeStorageServicesBaseline)
        $preservedDeleteExitCode = Get-CRUWPropertyValue (Get-CRUWPropertyValue $context.deleteDriver 'result') 'exitCode' $null
        $deleteResultAuthorizationSafe =
            $null -ne $preservedDeleteExitCode -and
            [int]$preservedDeleteExitCode -in @(0,3010)
        if (-not $sameBoot) {
            $unexpectedProbes = Test-CRUWProbeEvidence @($mounts | ForEach-Object { Invoke-CRUWAdapter $adapter 'ProbeVolume' @($_) }) $mounts
            $unexpectedNative = Test-CRUWNativeStorageServiceDrift $nativeBaseline $liveSnapshot.nativeStorageServices
            $unexpectedEvents = @(Invoke-CRUWAdapter $adapter 'GetCriticalEventsSince' @([DateTimeOffset]$preflight.checkedAt))
            $unexpectedPending = Invoke-CRUWAdapter $adapter 'GetPendingRebootState'
            $unexpectedReadiness = Invoke-CRUWAdapter $adapter 'GetRecoveryReadiness'
            $context.recovery.unexpectedBoot = [ordered]@{
                state=$liveState;probes=$unexpectedProbes;native=$unexpectedNative;events=$unexpectedEvents;
                pending=$unexpectedPending;readiness=$unexpectedReadiness;rollbackAttempted=$false;rebootAuthorized=$false
            }
            $currentBitLocker = Get-CRUWBitLockerInventoryEvidence $adapter $encryptedMounts AllOn
            if (-not [bool]$currentBitLocker.verified) {
                & $checkpoint RECOVERY_RESUME_INTENT | Out-Null
                Invoke-CRUWAdapter $adapter 'ResumeBitLocker' @('C:') | Out-Null
            }
            $bitLockerOn = Get-CRUWBitLockerInventoryEvidence $adapter $encryptedMounts AllOn
            if (-not [bool]$bitLockerOn.verified) { throw 'Unexpected-boot recovery could not verify BitLocker Protection On' }
            $context.recovery.bitLockerAtExit = $bitLockerOn
            & $checkpoint POSTBOOT_PROTECTED_DIAGNOSTIC_HOLD | Out-Null
            $diagnosticProtected = $true
        }
        elseif ([string]$liveState.classification -ceq 'LEGACY_INTACT') {
            $legacyProbes = Test-CRUWProbeEvidence @($mounts | ForEach-Object { Invoke-CRUWAdapter $adapter 'ProbeVolume' @($_) }) $mounts
            $legacyNative = Test-CRUWNativeStorageServiceDrift $nativeBaseline $liveSnapshot.nativeStorageServices
            if (-not ([bool]$legacyProbes.verified -and [bool]$legacyNative.verified -and $sameBoot)) {
                throw 'Live legacy state failed probe/native/boot recovery gates'
            }
            $context.recovery.legacySafety = [ordered]@{ probes=$legacyProbes;native=$legacyNative;sameBoot=$sameBoot }
            if (-not [bool]$bitLockerAllOnAtEntry.verified) {
                & $checkpoint RECOVERY_RESUME_INTENT | Out-Null
                Invoke-CRUWAdapter $adapter 'ResumeBitLocker' @('C:') | Out-Null
            }
            $bitLockerOn = Get-CRUWBitLockerInventoryEvidence $adapter $encryptedMounts AllOn
            if (-not [bool]$bitLockerOn.verified) { throw 'BitLocker Protection On was not verified' }
            $legacyPending = Invoke-CRUWAdapter $adapter 'GetPendingRebootState'
            $context.recovery.bitLockerAtExit = $bitLockerOn
            $context.recovery.pendingAtLegacyExit = $legacyPending
            if ([bool]$legacyPending.detected) {
                $context.safeExit = $false
                $context.operatorActionRequired = 'DO NOT REBOOT. Exact LEGACY_INTACT and BitLocker On are verified, but pending-reboot evidence remains and requires revalidation.'
                & $checkpoint PENDING_DIAGNOSTIC_HOLD | Out-Null
                $diagnosticProtected = $true
            }
            else {
                $context.safeExit = $true
                & $checkpoint ABORT_TERMINAL | Out-Null
                $completedSafe = $true
            }
        }
        elseif (
            [string]$liveState.classification -ceq 'CLEAN_PREBOOT' -and
            $dualIntegrityVerified -and
            $deleteResultAuthorizationSafe
        ) {
            if (-not $sameBootForMutation) { throw 'CLEAN_PREBOOT recovery authorization requires the exact same boot' }
            $currentBitLocker = $bitLockerSuspendedAtEntry
            if ([bool]$bitLockerAllOnAtEntry.verified) {
                $acAtRecoverySuspend = Invoke-CRUWAdapter $adapter 'GetAcPowerState'
                if (-not [bool]$acAtRecoverySuspend.online) { throw 'AC power is required before recovered suspension' }
                & $checkpoint RECOVERY_SUSPEND_INTENT | Out-Null
                Invoke-CRUWAdapter $adapter 'SuspendBitLocker' @('C:', 2) | Out-Null
                $currentBitLocker = Get-CRUWBitLockerInventoryEvidence $adapter $encryptedMounts COffOthersOn
                $context.recovery.bitLockerAfterSuspend = $currentBitLocker
                & $checkpoint RECOVERY_SUSPEND_RESULT | Out-Null
            }
            if (-not [bool]$currentBitLocker.verified) {
                throw 'Bounded BitLocker suspension was not verified during recovery'
            }

            if ($null -eq $context.deleteDriver) {
                $deleteIntentEntries = @($prefix.entries | Where-Object { [string]$_.payload.stage -ceq 'DELETE_INTENT' })
                if ($deleteIntentEntries.Count -ne 1) { throw 'CLEAN_PREBOOT recovery requires exactly one committed DELETE_INTENT' }
                $sealedIntentArguments = @($context.deleteIntentContract.arguments)
                if ($sealedIntentArguments.Count -ne 3 -or [string]$sealedIntentArguments[1] -cne [string]$identity.document.publishedName) {
                    throw 'Committed delete intent contract is missing or ambiguous'
                }
                $intentAt = ConvertTo-CRUWUtcRoundtripString $deleteIntentEntries[0].payload.recordedAt
                $observedAt = ([DateTimeOffset](Invoke-CRUWAdapter $adapter 'GetNow')).ToString('o')
                $context.deleteDriver = [ordered]@{
                    startedAt = $intentAt
                    completedAt = $observedAt
                    resultObserved = $false
                    result = [ordered]@{
                        executable = 'pnputil.exe'
                        arguments = $sealedIntentArguments
                        exitCode = $null
                        output = 'Result unavailable after interrupted intent; CLEAN_PREBOOT independently observed.'
                    }
                }
            }
            & $checkpoint FINAL_AUTHORIZATION_INTENT | Out-Null
            $pending = Invoke-CRUWAdapter $adapter 'GetPendingRebootState'
            $finalBitLocker = Get-CRUWBitLockerInventoryEvidence $adapter $encryptedMounts COffOthersOn
            $finalAc = Invoke-CRUWAdapter $adapter 'GetAcPowerState'
            $finalIntegrity = Test-CRUWBackupIntegrity $preflight $preflightFull $adapter
            $finalBoot = Invoke-CRUWAdapter $adapter 'GetBootIdentity'
            $finalSnapshot = Invoke-CRUWAdapter $adapter 'GetStorageSnapshot' @($identity.document.publishedName, $identity.document.filterName, $mounts, $identity.document)
            $finalState = Get-CRUWStateClassification $finalSnapshot $identity.document $mounts Preboot
            $finalNative = Test-CRUWNativeStorageServiceDrift $nativeBaseline $finalSnapshot.nativeStorageServices
            $finalProbes = Test-CRUWProbeEvidence @($mounts | ForEach-Object { Invoke-CRUWAdapter $adapter 'ProbeVolume' @($_) }) $mounts
            $eventSince = [DateTimeOffset]$context.deleteDriver.startedAt
            $events = @(Invoke-CRUWAdapter $adapter 'GetCriticalEventsSince' @($eventSince))
            $readiness = Invoke-CRUWAdapter $adapter 'GetRecoveryReadiness'
            $chain = Test-CRUWJournalChain $journalState.terminal.primaryPath $primaryRoot $secondaryRoot $adapter
            $gates = [ordered]@{
                journalCommonPrefix = [bool]$chain.verified
                pendingRebootClear = -not [bool]$pending.detected
                bitLockerSuspendedBounded = [bool]$finalBitLocker.verified
                acPowerOnline = [bool]$finalAc.online
                backupIntegrityAndAcl = [bool]$finalIntegrity.verified
                sameExactBoot = Test-CRUWSameBootIdentity $finalBoot $boot
                cleanPreboot = [string]$finalState.classification -ceq 'CLEAN_PREBOOT'
                nativeStorageServicesNoDrift = [bool]$finalNative.verified
                cAndDWriteReadHashDelete = [bool]$finalProbes.verified
                noStorageWarningsErrorsOrCriticalEvents = $events.Count -eq 0
                sealedRecoveryReadiness = Test-CRUWRecoveryReadiness $readiness $preflight
            }
            $failed = @($gates.GetEnumerator() | Where-Object { -not [bool]$_.Value } | ForEach-Object Key)
            Set-CRUWPropertyValue $context final ([ordered]@{ state=$finalState;snapshot=$finalSnapshot })
            Set-CRUWPropertyValue $context finalAuthorization ([ordered]@{
                gates=$gates;failedGates=$failed;pending=$pending;bitLocker=$finalBitLocker;acPower=$finalAc;
                backupIntegrity=$finalIntegrity;boot=$finalBoot;state=$finalState;snapshot=$finalSnapshot;
                nativeServiceDrift=$finalNative;probes=$finalProbes;events=$events;recoveryReadiness=$readiness;
                journal=[ordered]@{verified=[bool]$chain.verified;failures=@($chain.failures);entryCount=[int]$chain.entryCount;terminalPayloadSha256=[string]$chain.terminalPayloadSha256}
            })
            if ($failed.Count -gt 0) { throw "Recovered CLEAN_PREBOOT authorization gates failed: $($failed -join ', ')" }
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
                throw "Recovered commit-live authorization gates failed: $($commitLiveFailed -join ', ')"
            }
            $context.mutationAccepted = $true
            $context.operatorActionRequired = 'Perform exactly one deliberate MANUAL reboot; no reboot was performed by this script.'
            & $checkpoint REBOOT_AUTHORIZED | Out-Null
            $authorized = $true
        }
        else {
            if (-not $sameBootForMutation) { throw 'Mixed-state rollback requires the exact same boot' }
            $rollbackCapability = Get-CRUWPropertyValue $preflight 'rollbackCapability'
            $rollbackCapabilityEvidence = Test-CRUWRollbackCapabilityContract $rollbackCapability $preflight -SimulationOnly:$TestMode.IsPresent
            if (-not [bool]$rollbackCapabilityEvidence.verified) {
                throw 'Automatic rollback is blocked: sealed evidence does not prove exact CRUW service configuration restoration'
            }
            $context.recovery.rollbackCapability = [ordered]@{contract=$rollbackCapability;validation=$rollbackCapabilityEvidence}
            $deleteIntentEntries = @($prefix.entries | Where-Object { [string]$_.payload.stage -ceq 'DELETE_INTENT' })
            $deleteGateEntries = @($prefix.entries | Where-Object { [string]$_.payload.stage -ceq 'DELETE_LIVE_GATE' })
            if ($deleteIntentEntries.Count -ne 1 -or $deleteGateEntries.Count -ne 1) {
                throw 'Rollback lacks one committed DELETE_INTENT/DELETE_LIVE_GATE proof'
            }
            $deleteGateContext = $deleteGateEntries[0].payload.context
            $deleteGateEvidence = Get-CRUWPropertyValue $deleteGateContext 'deleteLiveGate'
            $deleteIntentContract = Get-CRUWPropertyValue $deleteGateContext 'deleteIntentContract'
            $deleteIntentArguments = @(Get-CRUWPropertyValue $deleteIntentContract 'arguments')
            $sealedPreDeletePendingClear =
                [bool](Get-CRUWPropertyValue (Get-CRUWPropertyValue $deleteGateEvidence 'gates') 'pendingRebootClear' $false) -and
                -not [bool](Get-CRUWPropertyValue (Get-CRUWPropertyValue $deleteGateContext 'pendingAtDelete') 'detected' $true) -and
                [string](Get-CRUWPropertyValue $deleteIntentContract 'executable') -ceq 'pnputil.exe' -and
                $deleteIntentArguments.Count -eq 3 -and
                [string]$deleteIntentArguments[0] -ceq '/delete-driver' -and
                [string]$deleteIntentArguments[1] -ceq [string]$identity.document.publishedName -and
                [string]$deleteIntentArguments[2] -ceq '/uninstall'
            if (-not $sealedPreDeletePendingClear) {
                throw 'Rollback lacks sealed pre-delete pending-clear and exact-intent proof'
            }
            $acAtRollback = Invoke-CRUWAdapter $adapter 'GetAcPowerState'
            if (-not [bool]$acAtRollback.online) { throw 'AC power is required before rollback' }
            $pendingAtRollback = Invoke-CRUWAdapter $adapter 'GetPendingRebootState'
            $readinessAtRollback = Invoke-CRUWAdapter $adapter 'GetRecoveryReadiness'
            $eventSinceValue = Get-CRUWPropertyValue (Get-CRUWPropertyValue $context 'deleteDriver') 'startedAt' (Get-CRUWPropertyValue $deleteIntentEntries[0].payload 'recordedAt' $preflight.checkedAt)
            $eventsAtRollback = @(Invoke-CRUWAdapter $adapter 'GetCriticalEventsSince' @([DateTimeOffset]$eventSinceValue))
            $probesAtRollback = Test-CRUWProbeEvidence @($mounts | ForEach-Object { Invoke-CRUWAdapter $adapter 'ProbeVolume' @($_) }) $mounts
            $nativeAtRollback = Test-CRUWNativeStorageServiceDrift $nativeBaseline $liveSnapshot.nativeStorageServices
            if (
                -not (Test-CRUWRecoveryReadiness $readinessAtRollback $preflight) -or
                $eventsAtRollback.Count -ne 0 -or
                -not [bool]$probesAtRollback.verified -or
                -not [bool]$nativeAtRollback.verified
            ) { throw 'Fresh readiness/event/probe/native gates block rollback' }
            $rollbackBackup = Get-CRUWValidatedRollbackInf $primaryRoot $secondaryRoot $integrity.primaryManifestSha256 $adapter $integrity.recoveryRootTopology -RequireExactlyOneRoot:(-not $dualIntegrityVerified)
            $context.recovery.rollbackBackupValidation = $rollbackBackup
            $context.recovery.rollbackSetupApiBefore = Invoke-CRUWAdapter $adapter 'GetSetupApiEvidence'
            $commitRollbackBoot = Invoke-CRUWAdapter $adapter 'GetBootIdentity'
            $commitRollbackAc = Invoke-CRUWAdapter $adapter 'GetAcPowerState'
            $commitRollbackPending = Invoke-CRUWAdapter $adapter 'GetPendingRebootState'
            $commitRollbackSnapshot = Invoke-CRUWAdapter $adapter 'GetStorageSnapshot' @($identity.document.publishedName,$identity.document.filterName,$mounts,$identity.document)
            $commitRollbackState = Get-CRUWStateClassification $commitRollbackSnapshot $identity.document $mounts Preboot
            $commitRollbackGates = [ordered]@{
                sealedPreDeletePendingClear=$sealedPreDeletePendingClear
                acPowerOnline=[bool]$commitRollbackAc.online
                sameExactBoot=Test-CRUWSameBootIdentity $commitRollbackBoot $boot
                stateStillRollbackEligible=[string]$commitRollbackState.classification -in @('TRANSITION','BROKEN','CLEAN_PREBOOT')
            }
            $commitRollbackFailures = @($commitRollbackGates.GetEnumerator() | Where-Object { -not [bool]$_.Value } | ForEach-Object Key)
            $context.recovery.rollbackLiveGate = [ordered]@{
                gates=$commitRollbackGates;failedGates=$commitRollbackFailures;preDeletePendingClear=$true;
                pendingBeforeRollback=$pendingAtRollback;pendingCommit=$commitRollbackPending;ac=$commitRollbackAc;boot=$commitRollbackBoot;state=$commitRollbackState
            }
            if ($commitRollbackFailures.Count -gt 0) { throw "Rollback commit-live gates failed: $($commitRollbackFailures -join ', ')" }
            & $checkpoint ROLLBACK_INTENT | Out-Null
            $rollback = Invoke-CRUWAdapter $adapter 'ReinstallBackupDriver' @($rollbackBackup.infPath)
            $rollbackSetupApiEvidence = Invoke-CRUWAdapter $adapter 'GetSetupApiEvidence'
            $arguments = @($rollback.arguments)
            if (
                [string]$rollback.executable -cne 'pnputil.exe' -or
                $arguments.Count -ne 3 -or
                [string]$arguments[0] -cne '/add-driver' -or
                [string]$arguments[1] -cne [string]$rollbackBackup.infPath -or
                [string]$arguments[2] -cne '/install'
            ) { throw 'Rollback adapter violated exact add-driver contract' }
            $rolledSnapshot = Invoke-CRUWAdapter $adapter 'GetStorageSnapshot' @($identity.document.publishedName, $identity.document.filterName, $mounts, $identity.document)
            $rolledState = Get-CRUWStateClassification $rolledSnapshot $identity.document $mounts Preboot
            $rolledLiveReadback = Test-CRUWRollbackLiveReadback $rolledSnapshot $rollbackCapability
            $rolledProbes = Test-CRUWProbeEvidence @($mounts | ForEach-Object { Invoke-CRUWAdapter $adapter 'ProbeVolume' @($_) }) $mounts
            $rolledNative = Test-CRUWNativeStorageServiceDrift $nativeBaseline $rolledSnapshot.nativeStorageServices
            $rolledBoot = Test-CRUWSameBootIdentity (Invoke-CRUWAdapter $adapter 'GetBootIdentity') $boot
            $rollbackExitCodeAllowed = [int]$rollback.exitCode -in @(0,3010)
            $rollbackExitCodePolicy = switch ([int]$rollback.exitCode) {
                0 { 'SUCCESS' }
                3010 { 'SUCCESS_REBOOT_REQUIRED' }
                259 { 'NO_MATCHING_OR_BETTER_DRIVER_BLOCKED' }
                1641 { 'UNEXPECTED_REBOOT_INITIATED_BLOCKED' }
                default { 'UNRECOGNIZED_EXIT_BLOCKED' }
            }
            $context.rollback = [ordered]@{
                result=$rollback;setupApiEvidence=$rollbackSetupApiEvidence;
                exitCodePolicy=$rollbackExitCodePolicy;state=$rolledState;snapshot=$rolledSnapshot;
                probes=$rolledProbes;native=$rolledNative;sameBoot=$rolledBoot;exactServiceReadback=$rolledLiveReadback
            }
            & $checkpoint ROLLBACK_RESULT | Out-Null
            if (
                -not $rollbackExitCodeAllowed -or
                [string]$rolledState.classification -cne 'LEGACY_INTACT' -or
                -not [bool]$rolledLiveReadback.verified -or
                -not [bool]$rolledProbes.verified -or
                -not [bool]$rolledNative.verified -or
                -not $rolledBoot
            ) { throw 'Rollback did not restore fully verified LEGACY_INTACT' }
            Set-CRUWPropertyValue $context final $context.rollback
            $currentBitLocker = Get-CRUWBitLockerInventoryEvidence $adapter $encryptedMounts AllOn
            if (-not [bool]$currentBitLocker.verified) {
                & $checkpoint RECOVERY_RESUME_INTENT | Out-Null
                Invoke-CRUWAdapter $adapter 'ResumeBitLocker' @('C:') | Out-Null
            }
            $bitLockerOn = Get-CRUWBitLockerInventoryEvidence $adapter $encryptedMounts AllOn
            if (-not [bool]$bitLockerOn.verified) { throw 'BitLocker Protection On was not verified after rollback' }
            $pendingAfterRollback = Invoke-CRUWAdapter $adapter 'GetPendingRebootState'
            $context.recovery.bitLockerAtExit = $bitLockerOn
            $context.recovery.pendingAfterRollback = $pendingAfterRollback
            if ([bool]$pendingAfterRollback.detected) {
                $context.safeExit = $false
                $context.operatorActionRequired = 'DO NOT REBOOT. Rollback restored exact LEGACY_INTACT and BitLocker is On, but pending-reboot evidence remains and requires revalidation.'
                & $checkpoint PENDING_DIAGNOSTIC_HOLD | Out-Null
                $diagnosticProtected = $true
            }
            else {
                $context.safeExit = $true
                & $checkpoint ABORT_TERMINAL | Out-Null
                $completedSafe = $true
            }
        }
    }
    catch {
        $failure = $_.Exception.Message
        if ($null -ne $context) { Set-CRUWPropertyValue $context recoveryFailure $failure }
    }
    finally {
        if (-not $authorized -and -not $protectionHandled) {
            $bitLockerExit = $null
            try {
                $bitLockerExit = Get-CRUWBitLockerInventoryEvidence $adapter $emergencyMounts AllOn
                if (-not [bool]$bitLockerExit.verified) {
                    if ($appendAllowed -and $journalHealthy) {
                        try { & $checkpoint RECOVERY_RESUME_INTENT | Out-Null } catch { $recoveryFailures.Add($_.Exception.Message) }
                    }
                    Invoke-CRUWAdapter $adapter 'ResumeBitLocker' @('C:') | Out-Null
                    $bitLockerExit = Get-CRUWBitLockerInventoryEvidence $adapter $emergencyMounts AllOn
                }
                if (-not [bool]$bitLockerExit.verified) {
                    $recoveryFailures.Add('BitLocker Protection On not verified at recovery exit')
                }
                if ($null -ne $context) { Set-CRUWPropertyValue $context recoveryBitLockerAtExit $bitLockerExit }
            }
            catch { $recoveryFailures.Add('Emergency BitLocker resume: ' + $_.Exception.Message) }
            $protectionHandled = $null -ne $bitLockerExit -and [bool]$bitLockerExit.verified
        }
    }

    if (-not $authorized -and -not $completedSafe -and -not $diagnosticProtected -and $appendAllowed -and $journalHealthy) {
        try { & $checkpoint RECOVERY_BLOCKED | Out-Null } catch { $journalHealthy = $false }
    }
    $result = [ordered]@{
        operationId = $OperationId.ToString('D')
        authorized = $authorized
        completedSafe = $completedSafe
        diagnosticProtected = $diagnosticProtected
        deleteReplayed = $false
        journalHealthy = $journalHealthy
        terminalCheckpoint = if ($null -ne $journalState) { $journalState.terminal } else { $null }
        failure = $failure
        recoveryFailures = @($recoveryFailures)
    }
    $result
    if (-not ($authorized -or $completedSafe -or $diagnosticProtected)) {
        throw "Interrupted removal recovery blocked. Failure=$failure; Recovery=$($recoveryFailures -join '; ')"
    }
}
finally {
    try {
        if (-not $authorized -and -not $protectionHandled) {
            try {
                $emergencyState = Get-CRUWBitLockerInventoryEvidence $adapter $emergencyMounts AllOn
                if (-not [bool]$emergencyState.verified) {
                    Invoke-CRUWAdapter $adapter 'ResumeBitLocker' @('C:') | Out-Null
                    $emergencyState = Get-CRUWBitLockerInventoryEvidence $adapter $emergencyMounts AllOn
                }
                if (-not [bool]$emergencyState.verified) { throw 'Emergency recovery BitLocker verification failed' }
            }
            catch { Write-Error -ErrorAction Continue ('CRITICAL: emergency recovery protection failed: ' + $_.Exception.Message) }
        }
        Invoke-CRUWAdapter $adapter 'ExitOperationMutex' @($mutexHandle) | Out-Null
    }
    finally { Close-CRUWBootstrapAnchorChains }
}
