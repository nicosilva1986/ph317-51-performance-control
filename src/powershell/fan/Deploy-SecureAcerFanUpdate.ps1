[CmdletBinding()]
param(
    [string] $Stage = $PSScriptRoot,
    [switch] $ValidateOnly
)

Set-StrictMode -Version Latest
$ErrorActionPreference = 'Stop'
$stage = [IO.Path]::GetFullPath($Stage)
$deploymentRoot = 'C:\ProgramData\AcerAdaptiveFanDeployments'
$deployResultPath = 'C:\Acer-Driver-Audit\secure-fan-deploy.json'
$expected = [ordered]@{
    controller = '5085665924B28D210240A8767DE17E7CE2B3CD510F97787D239D160454476F16'
    config = 'B32BDEF1B120F40A979A3BD313ED11558E98582E90A1AD4B866E49898A48CED5'
    watchdog = 'B67CCF9B168E55379201789991EE2E3E028EED4F51FCD416085FA0AF49B94D8B'
    installer = '1281684F05E9A70D8F775840CB19A4265FB161B648693191A200CA31B1A8FF48'
}
$artifactMap = [ordered]@{
    controller = 'AcerAdaptiveFanController.ps1'
    config = 'fan-controller-config.json'
    watchdog = 'AcerFanWatchdog.ps1'
    installer = 'Secure-Install-AcerFanController.ps1'
}

function Get-TrustedPwshPath {
    $candidate = Join-Path $PSHOME 'pwsh.exe'
    if (-not (Test-Path -LiteralPath $candidate -PathType Leaf)) { throw "Trusted pwsh.exe was not found: $candidate" }
    $resolved = [IO.Path]::GetFullPath((Resolve-Path -LiteralPath $candidate).Path)
    $programFiles = [IO.Path]::GetFullPath([Environment]::GetFolderPath('ProgramFiles')).TrimEnd('\') + '\'
    if (-not $resolved.StartsWith($programFiles, [StringComparison]::OrdinalIgnoreCase)) { throw "Refusing pwsh.exe outside Program Files: $resolved" }
    $signature = Get-AuthenticodeSignature -FilePath $resolved
    if ($signature.Status -ne [Management.Automation.SignatureStatus]::Valid -or
        [string]$signature.SignerCertificate.Subject -notmatch '(^|,\s*)O=Microsoft Corporation(,|$)') {
        throw "pwsh.exe does not have a valid Microsoft signature: $resolved"
    }
    return $resolved
}

function Test-IsAdministrator {
    return ([Security.Principal.WindowsPrincipal][Security.Principal.WindowsIdentity]::GetCurrent()).IsInRole(
        [Security.Principal.WindowsBuiltInRole]::Administrator
    )
}

function Assert-SupportedHardware {
    $computer = Get-CimInstance -ClassName Win32_ComputerSystem
    if ([string]$computer.Manufacturer -notmatch '^Acer\b' -or [string]$computer.Model -notmatch '(?i)\bPH317-51\b') {
        throw "Unsupported hardware. Expected Acer PH317-51; detected '$($computer.Manufacturer) $($computer.Model)'."
    }
}

function New-SecureDirectoryAcl {
    $acl = [Security.AccessControl.DirectorySecurity]::new()
    $acl.SetAccessRuleProtection($true, $false)
    $system = [Security.Principal.SecurityIdentifier]::new('S-1-5-18')
    $administrators = [Security.Principal.SecurityIdentifier]::new('S-1-5-32-544')
    $users = [Security.Principal.SecurityIdentifier]::new('S-1-5-32-545')
    $inherit = [Security.AccessControl.InheritanceFlags]'ContainerInherit, ObjectInherit'
    $none = [Security.AccessControl.PropagationFlags]::None
    $allow = [Security.AccessControl.AccessControlType]::Allow
    $acl.SetOwner($system)
    [void]$acl.AddAccessRule([Security.AccessControl.FileSystemAccessRule]::new($system, 'FullControl', $inherit, $none, $allow))
    [void]$acl.AddAccessRule([Security.AccessControl.FileSystemAccessRule]::new($administrators, 'FullControl', $inherit, $none, $allow))
    [void]$acl.AddAccessRule([Security.AccessControl.FileSystemAccessRule]::new($users, 'ReadAndExecute', $inherit, $none, $allow))
    return $acl
}

function New-SecureFileAcl {
    $acl = [Security.AccessControl.FileSecurity]::new()
    $acl.SetAccessRuleProtection($true, $false)
    $system = [Security.Principal.SecurityIdentifier]::new('S-1-5-18')
    $administrators = [Security.Principal.SecurityIdentifier]::new('S-1-5-32-544')
    $users = [Security.Principal.SecurityIdentifier]::new('S-1-5-32-545')
    $noneInheritance = [Security.AccessControl.InheritanceFlags]::None
    $nonePropagation = [Security.AccessControl.PropagationFlags]::None
    $allow = [Security.AccessControl.AccessControlType]::Allow
    $acl.SetOwner($system)
    [void]$acl.AddAccessRule([Security.AccessControl.FileSystemAccessRule]::new($system, 'FullControl', $noneInheritance, $nonePropagation, $allow))
    [void]$acl.AddAccessRule([Security.AccessControl.FileSystemAccessRule]::new($administrators, 'FullControl', $noneInheritance, $nonePropagation, $allow))
    [void]$acl.AddAccessRule([Security.AccessControl.FileSystemAccessRule]::new($users, 'ReadAndExecute', $noneInheritance, $nonePropagation, $allow))
    return $acl
}

function Convert-IdentityToSid {
    param([Parameter(Mandatory)] $Identity)
    if ($Identity -is [Security.Principal.SecurityIdentifier]) { return $Identity.Value }
    if ($Identity -is [string]) { $Identity = [Security.Principal.NTAccount]::new($Identity) }
    return $Identity.Translate([Security.Principal.SecurityIdentifier]).Value
}

function Test-StrictAcl {
    param([Parameter(Mandatory)] [string] $Path)
    try {
        $acl = Get-Acl -LiteralPath $Path
        if ((Convert-IdentityToSid $acl.Owner) -ne 'S-1-5-18') { return $false }
        $allowedSids = @('S-1-5-18', 'S-1-5-32-544', 'S-1-5-32-545')
        $seen = @{}
        foreach ($rule in @($acl.Access)) {
            $sid = Convert-IdentityToSid $rule.IdentityReference
            if ($sid -notin $allowedSids -or $rule.AccessControlType -ne [Security.AccessControl.AccessControlType]::Allow) { return $false }
            if (-not $seen.ContainsKey($sid)) { $seen[$sid] = 0 }
            $seen[$sid] = $seen[$sid] -bor [int]$rule.FileSystemRights
        }
        foreach ($sid in $allowedSids) { if (-not $seen.ContainsKey($sid)) { return $false } }
        # Modify is a composite that includes read bits; checking it in the mask
        # would falsely classify a read/execute ACE as writable.
        $writeMask = [int]([Security.AccessControl.FileSystemRights]'Write, Delete, DeleteSubdirectoriesAndFiles, ChangePermissions, TakeOwnership')
        if (($seen['S-1-5-32-545'] -band $writeMask) -ne 0) { return $false }
        return $true
    }
    catch { return $false }
}

function Assert-ArtifactHashes {
    param([Parameter(Mandatory)] [string] $Root)
    foreach ($key in $artifactMap.Keys) {
        $path = Join-Path $Root $artifactMap[$key]
        if (-not (Test-Path -LiteralPath $path -PathType Leaf)) { throw "Release artifact is missing: $path" }
        $actual = (Get-FileHash -LiteralPath $path -Algorithm SHA256).Hash
        if ($actual -ne [string]$expected[$key]) { throw "Pinned SHA256 mismatch for $($artifactMap[$key])." }
    }
}

function Assert-ParsedPowerShell {
    param([Parameter(Mandatory)] [string] $Path)
    $tokens = $null
    $errors = $null
    [void][Management.Automation.Language.Parser]::ParseFile($Path, [ref]$tokens, [ref]$errors)
    if ($errors.Count -ne 0) { throw "PowerShell parse error in ${Path}: $($errors.Message -join '; ')" }
}

$trustedPwsh = Get-TrustedPwshPath
if ($ValidateOnly) {
    Assert-ArtifactHashes -Root $stage
    foreach ($name in @('AcerAdaptiveFanController.ps1', 'AcerFanWatchdog.ps1', 'Secure-Install-AcerFanController.ps1')) {
        Assert-ParsedPowerShell -Path (Join-Path $stage $name)
    }
    [ordered]@{ status = 'VALID'; stage = $stage; expected = $expected } | ConvertTo-Json -Depth 5
    exit 0
}
if (-not (Test-IsAdministrator)) {
    $process = Start-Process -FilePath $trustedPwsh -Verb RunAs -WindowStyle Hidden -ArgumentList @(
        '-NoLogo', '-NoProfile', '-NonInteractive', '-ExecutionPolicy', 'Bypass', '-File', ('"' + $PSCommandPath + '"'),
        '-Stage', ('"' + $stage + '"')
    ) -Wait -PassThru
    exit $process.ExitCode
}

try {
    Assert-SupportedHardware
    Assert-ArtifactHashes -Root $stage
    foreach ($name in @('AcerAdaptiveFanController.ps1', 'AcerFanWatchdog.ps1', 'Secure-Install-AcerFanController.ps1')) {
        Assert-ParsedPowerShell -Path (Join-Path $stage $name)
    }

    New-Item -ItemType Directory -Path $deploymentRoot -Force | Out-Null
    Set-Acl -LiteralPath $deploymentRoot -AclObject (New-SecureDirectoryAcl)
    $packageName = (Get-Date).ToString('yyyyMMdd-HHmmss') + '-' + [guid]::NewGuid().ToString('N').Substring(0, 8)
    $protectedStage = Join-Path $deploymentRoot $packageName
    New-Item -ItemType Directory -Path $protectedStage -Force | Out-Null
    Set-Acl -LiteralPath $protectedStage -AclObject (New-SecureDirectoryAcl)
    foreach ($name in $artifactMap.Values) {
        $destination = Join-Path $protectedStage $name
        Copy-Item -LiteralPath (Join-Path $stage $name) -Destination $destination -Force
        Set-Acl -LiteralPath $destination -AclObject (New-SecureFileAcl)
    }
    $hashManifest = Join-Path $protectedStage 'expected-hashes.json'
    ([ordered]@{ generatedAt = (Get-Date).ToString('o'); controller = $expected.controller; config = $expected.config; watchdog = $expected.watchdog; installer = $expected.installer } | ConvertTo-Json) |
        Set-Content -LiteralPath $hashManifest -Encoding utf8
    Set-Acl -LiteralPath $hashManifest -AclObject (New-SecureFileAcl)
    Assert-ArtifactHashes -Root $protectedStage
    foreach ($item in @(Get-ChildItem -LiteralPath $protectedStage -Force)) {
        if (-not (Test-StrictAcl -Path $item.FullName)) { throw "Protected staging ACL failed: $($item.FullName)" }
    }
    if (-not (Test-StrictAcl -Path $protectedStage)) { throw 'Protected staging directory ACL failed.' }

    $installer = Join-Path $protectedStage 'Secure-Install-AcerFanController.ps1'
    $installerStdout = Join-Path $protectedStage 'installer.stdout.json'
    $installerStderr = Join-Path $protectedStage 'installer.stderr.txt'
    foreach ($capturePath in @($installerStdout, $installerStderr)) {
        New-Item -ItemType File -Path $capturePath -Force | Out-Null
        Set-Acl -LiteralPath $capturePath -AclObject (New-SecureFileAcl)
    }
    $process = Start-Process -FilePath $trustedPwsh -WindowStyle Hidden -ArgumentList @(
        '-NoLogo', '-NoProfile', '-NonInteractive', '-ExecutionPolicy', 'Bypass', '-File', ('"' + $installer + '"'),
        '-Source', ('"' + $protectedStage + '"'), '-ExpectedHashesPath', ('"' + $hashManifest + '"')
    ) -RedirectStandardOutput $installerStdout -RedirectStandardError $installerStderr -Wait -PassThru
    if ($process.ExitCode -ne 0) {
        $stdout = if (Test-Path -LiteralPath $installerStdout) { ([string](Get-Content -LiteralPath $installerStdout -Raw)).Trim() } else { '' }
        $stderr = if (Test-Path -LiteralPath $installerStderr) { ([string](Get-Content -LiteralPath $installerStderr -Raw)).Trim() } else { '' }
        throw "Secure installer exited $($process.ExitCode). stdout: $stdout stderr: $stderr"
    }

    $deployResult = [ordered]@{ checkedAt = (Get-Date).ToString('o'); status = 'PASS'; deploymentPackage = $protectedStage; installerExitCode = $process.ExitCode }
    $deployResult | ConvertTo-Json -Depth 5 | Set-Content -LiteralPath $deployResultPath -Encoding utf8
    $deployResult | ConvertTo-Json -Depth 5
    exit 0
}
catch {
    $deployResult = [ordered]@{ checkedAt = (Get-Date).ToString('o'); status = 'FAILED'; error = $_.Exception.Message }
    try { $deployResult | ConvertTo-Json -Depth 5 | Set-Content -LiteralPath $deployResultPath -Encoding utf8 } catch { }
    $deployResult | ConvertTo-Json -Depth 5
    exit 1
}
