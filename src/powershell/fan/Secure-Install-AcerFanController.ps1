[CmdletBinding()]
param(
    [Parameter(Mandatory)]
    [string] $Source,
    [Parameter(Mandatory)]
    [string] $ExpectedHashesPath
)

Set-StrictMode -Version Latest
$ErrorActionPreference = 'Stop'

$taskName = 'Acer Adaptive Fan Control'
$watchdogTaskName = 'Acer Adaptive Fan Watchdog'
$target = 'C:\ProgramData\AcerAdaptiveFanControl'
$diagnosticTarget = 'C:\Acer-Driver-Audit\FanControl'
$resultPath = 'C:\Acer-Driver-Audit\secure-fan-installation.json'
$controllerName = 'AcerAdaptiveFanController.ps1'
$configName = 'fan-controller-config.json'
$watchdogName = 'AcerFanWatchdog.ps1'
$artifactNames = @($controllerName, $configName, $watchdogName)
$installationId = (Get-Date).ToString('yyyyMMdd-HHmmss') + '-' + [guid]::NewGuid().ToString('N').Substring(0, 8)
$backupRoot = Join-Path 'C:\ProgramData\AcerAdaptiveFanControl-Rollback' $installationId
$deploymentStarted = [datetimeoffset]::Now
$taskSnapshots = @{}
$backupCreated = $false
$operationalMutationStarted = $false
$result = [ordered]@{
    installationId = $installationId
    installedAt = $null
    securePath = $target
    backupPath = $backupRoot
    taskState = $null
    watchdogState = $null
    controllerStatus = $null
    aclVerified = $false
    hashesVerified = $false
    rollbackAttempted = $false
    rollbackSucceeded = $false
    error = $null
    status = 'FAILED'
}

function Get-TrustedPwshPath {
    $candidate = Join-Path $PSHOME 'pwsh.exe'
    if (-not (Test-Path -LiteralPath $candidate -PathType Leaf)) { throw "Trusted pwsh.exe was not found under PSHOME: $candidate" }
    $resolved = [IO.Path]::GetFullPath((Resolve-Path -LiteralPath $candidate).Path)
    $programFiles = [IO.Path]::GetFullPath([Environment]::GetFolderPath('ProgramFiles')).TrimEnd('\') + '\'
    if (-not $resolved.StartsWith($programFiles, [StringComparison]::OrdinalIgnoreCase)) {
        throw "Refusing pwsh.exe outside Program Files: $resolved"
    }
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

function Protect-DirectoryTree {
    param([Parameter(Mandatory)] [string] $Path)
    Set-Acl -LiteralPath $Path -AclObject (New-SecureDirectoryAcl)
    foreach ($directory in @(Get-ChildItem -LiteralPath $Path -Directory -Recurse -Force -ErrorAction Stop)) {
        Set-Acl -LiteralPath $directory.FullName -AclObject (New-SecureDirectoryAcl)
    }
    foreach ($file in @(Get-ChildItem -LiteralPath $Path -File -Recurse -Force -ErrorAction Stop)) {
        Set-Acl -LiteralPath $file.FullName -AclObject (New-SecureFileAcl)
    }
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
        $fullControl = [int][Security.AccessControl.FileSystemRights]::FullControl
        if (($seen['S-1-5-18'] -band $fullControl) -ne $fullControl) { return $false }
        if (($seen['S-1-5-32-544'] -band $fullControl) -ne $fullControl) { return $false }
        # Do not include Modify here: that composite right also contains read/execute bits
        # and would incorrectly reject the intended Users:(RX) rule.
        $writeMask = [int]([Security.AccessControl.FileSystemRights]'Write, Delete, DeleteSubdirectoriesAndFiles, ChangePermissions, TakeOwnership')
        if (($seen['S-1-5-32-545'] -band $writeMask) -ne 0) { return $false }
        return $true
    }
    catch {
        return $false
    }
}

function Test-StrictAclTree {
    param([Parameter(Mandatory)] [string] $Path)
    if (-not (Test-StrictAcl -Path $Path)) { return $false }
    foreach ($item in @(Get-ChildItem -LiteralPath $Path -Recurse -Force -ErrorAction Stop)) {
        if (-not (Test-StrictAcl -Path $item.FullName)) { return $false }
    }
    return $true
}

function Set-EmergencyMax {
    Assert-SupportedHardware
    $gaming = Get-CimInstance -Namespace 'root\wmi' -ClassName AcerGamingFunction | Select-Object -First 1
    if (-not $gaming) { throw 'AcerGamingFunction is unavailable.' }
    $behavior = Invoke-CimMethod -InputObject $gaming -MethodName SetGamingFanBehavior -Arguments @{ gmInput = [uint64]0x00820009 }
    $cpu = Invoke-CimMethod -InputObject $gaming -MethodName SetGamingFanSpeed -Arguments @{ gmInput = [uint64]0x00006401 }
    $gpu = Invoke-CimMethod -InputObject $gaming -MethodName SetGamingFanSpeed -Arguments @{ gmInput = [uint64]0x00006404 }
    if ([uint32]$behavior.gmOutput -ne 0 -or [uint32]$cpu.gmOutput -ne 0 -or [uint32]$gpu.gmOutput -ne 0) {
        throw 'Firmware rejected installer MAX request.'
    }
}

function Assert-ParsedPowerShell {
    param([Parameter(Mandatory)] [string] $Path)
    $tokens = $null
    $errors = $null
    [void][Management.Automation.Language.Parser]::ParseFile($Path, [ref]$tokens, [ref]$errors)
    if ($errors.Count -ne 0) { throw "PowerShell parse error in ${Path}: $($errors.Message -join '; ')" }
}

function Assert-ExpectedArtifacts {
    param([Parameter(Mandatory)] [string] $ResolvedSource, [Parameter(Mandatory)] [string] $ManifestPath)
    if (-not (Test-Path -LiteralPath $ManifestPath -PathType Leaf)) { throw "Expected hash manifest is missing: $ManifestPath" }
    $expected = Get-Content -LiteralPath $ManifestPath -Raw | ConvertFrom-Json
    foreach ($name in @($controllerName, $configName, $watchdogName, 'Secure-Install-AcerFanController.ps1')) {
        $propertyName = switch ($name) {
            $controllerName { 'controller' }
            $configName { 'config' }
            $watchdogName { 'watchdog' }
            default { 'installer' }
        }
        $property = $expected.PSObject.Properties[$propertyName]
        if ($null -eq $property -or [string]$property.Value -notmatch '^[0-9A-Fa-f]{64}$') { throw "Invalid expected SHA256: $propertyName" }
        $path = Join-Path $ResolvedSource $name
        if (-not (Test-Path -LiteralPath $path -PathType Leaf)) { throw "Staged artifact is missing: $path" }
        if ((Get-FileHash -LiteralPath $path -Algorithm SHA256).Hash -ne [string]$property.Value) { throw "Staged SHA256 mismatch: $name" }
    }
    Assert-ParsedPowerShell -Path (Join-Path $ResolvedSource $controllerName)
    Assert-ParsedPowerShell -Path (Join-Path $ResolvedSource $watchdogName)
    Assert-ParsedPowerShell -Path (Join-Path $ResolvedSource 'Secure-Install-AcerFanController.ps1')
    return $expected
}

function Get-TaskSnapshot {
    param([Parameter(Mandatory)] [string] $Name)
    $task = Get-ScheduledTask -TaskName $Name -ErrorAction SilentlyContinue
    if (-not $task) { return [pscustomobject]@{ exists = $false; state = 'MISSING'; xml = $null } }
    return [pscustomobject]@{ exists = $true; state = [string]$task.State; xml = Export-ScheduledTask -TaskName $Name }
}

function Restore-TaskSnapshot {
    param([Parameter(Mandatory)] [string] $Name, [Parameter(Mandatory)] $Snapshot)
    Stop-ScheduledTask -TaskName $Name -ErrorAction SilentlyContinue
    if ($Snapshot.exists) {
        Register-ScheduledTask -TaskName $Name -Xml ([string]$Snapshot.xml) -Force | Out-Null
        if ([string]$Snapshot.state -eq 'Running') { Start-ScheduledTask -TaskName $Name }
    }
    else {
        Unregister-ScheduledTask -TaskName $Name -Confirm:$false -ErrorAction SilentlyContinue
    }
}

function Copy-DirectoryContents {
    param([Parameter(Mandatory)] [string] $From, [Parameter(Mandatory)] [string] $To)
    New-Item -ItemType Directory -Path $To -Force | Out-Null
    foreach ($item in @(Get-ChildItem -LiteralPath $From -Force -ErrorAction Stop)) {
        Copy-Item -LiteralPath $item.FullName -Destination (Join-Path $To $item.Name) -Recurse -Force
    }
}

function Test-TaskDefinition {
    param([Parameter(Mandatory)] $Task, [Parameter(Mandatory)] [string] $ExpectedScript, [Parameter(Mandatory)] [string[]] $RequiredPaths, [Parameter(Mandatory)] [string] $PwshPath)
    if ([string]$Task.Principal.UserId -ne 'SYSTEM' -or @($Task.Actions).Count -ne 1) { return $false }
    if ([IO.Path]::GetFullPath([string]$Task.Actions.Execute) -ne [IO.Path]::GetFullPath($PwshPath)) { return $false }
    $arguments = [string]$Task.Actions.Arguments
    if ($arguments.IndexOf($ExpectedScript, [StringComparison]::OrdinalIgnoreCase) -lt 0) { return $false }
    foreach ($path in $RequiredPaths) {
        if ($arguments.IndexOf($path, [StringComparison]::OrdinalIgnoreCase) -lt 0) { return $false }
    }
    return $true
}

$trustedPwsh = Get-TrustedPwshPath
if (-not (Test-IsAdministrator)) {
    $process = Start-Process -FilePath $trustedPwsh -Verb RunAs -WindowStyle Hidden -ArgumentList @(
        '-NoLogo', '-NoProfile', '-NonInteractive', '-ExecutionPolicy', 'Bypass', '-File', ('"' + $PSCommandPath + '"'),
        '-Source', ('"' + $Source + '"'), '-ExpectedHashesPath', ('"' + $ExpectedHashesPath + '"')
    ) -Wait -PassThru
    exit $process.ExitCode
}

try {
    Assert-SupportedHardware
    $resolvedSource = [IO.Path]::GetFullPath((Resolve-Path -LiteralPath $Source).Path)
    $allowedSourceRoot = [IO.Path]::GetFullPath('C:\ProgramData\AcerAdaptiveFanDeployments').TrimEnd('\') + '\'
    if (-not ($resolvedSource.TrimEnd('\') + '\').StartsWith($allowedSourceRoot, [StringComparison]::OrdinalIgnoreCase)) {
        throw "Installer source is outside the protected deployment root: $resolvedSource"
    }
    $resolvedExpected = [IO.Path]::GetFullPath((Resolve-Path -LiteralPath $ExpectedHashesPath).Path)
    if (-not $resolvedExpected.StartsWith($resolvedSource.TrimEnd('\') + '\', [StringComparison]::OrdinalIgnoreCase)) {
        throw 'Expected hash manifest must be inside the protected source directory.'
    }
    if (-not (Test-StrictAclTree -Path $resolvedSource)) { throw 'Protected deployment source failed strict recursive ACL verification.' }
    $expected = Assert-ExpectedArtifacts -ResolvedSource $resolvedSource -ManifestPath $resolvedExpected

    $validationOutput = & $trustedPwsh -NoLogo -NoProfile -NonInteractive -ExecutionPolicy Bypass -File (Join-Path $resolvedSource $controllerName) -ConfigPath (Join-Path $resolvedSource $configName) -ValidateOnly
    if ($LASTEXITCODE -ne 0 -or [string]::IsNullOrWhiteSpace(($validationOutput -join ''))) { throw 'Controller configuration validation failed.' }

    $taskSnapshots[$taskName] = Get-TaskSnapshot -Name $taskName
    $taskSnapshots[$watchdogTaskName] = Get-TaskSnapshot -Name $watchdogTaskName
    New-Item -ItemType Directory -Path $backupRoot -Force | Out-Null
    Set-Acl -LiteralPath $backupRoot -AclObject (New-SecureDirectoryAcl)
    if (Test-Path -LiteralPath $target) {
        foreach ($name in @($controllerName, $configName, $watchdogName, 'integrity.json')) {
            $existingArtifact = Join-Path $target $name
            if (Test-Path -LiteralPath $existingArtifact -PathType Leaf) {
                Copy-Item -LiteralPath $existingArtifact -Destination (Join-Path $backupRoot $name) -Force
            }
        }
    }
    Protect-DirectoryTree -Path $backupRoot
    $backupCreated = $true

    # Enter the safest firmware state before either guardian is stopped.
    Set-EmergencyMax
    $operationalMutationStarted = $true
    Stop-ScheduledTask -TaskName $watchdogTaskName -ErrorAction SilentlyContinue
    Stop-ScheduledTask -TaskName $taskName -ErrorAction SilentlyContinue
    Start-Sleep -Seconds 2

    New-Item -ItemType Directory -Path $target -Force | Out-Null
    Set-Acl -LiteralPath $target -AclObject (New-SecureDirectoryAcl)
    foreach ($name in $artifactNames) {
        Copy-Item -LiteralPath (Join-Path $resolvedSource $name) -Destination (Join-Path $target $name) -Force
    }
    $integrity = [ordered]@{
        schemaVersion = 2
        generatedAt = (Get-Date).ToString('o')
        controller = [string]$expected.controller
        config = [string]$expected.config
        watchdog = [string]$expected.watchdog
    }
    $integrity | ConvertTo-Json | Set-Content -LiteralPath (Join-Path $target 'integrity.json') -Encoding utf8
    Protect-DirectoryTree -Path $target

    $controller = Join-Path $target $controllerName
    $config = Join-Path $target $configName
    $watchdog = Join-Path $target $watchdogName
    $log = Join-Path $target 'adaptive-fan.jsonl'
    $status = Join-Path $target 'adaptive-fan-status.json'
    $controllerArguments = "-NoLogo -NoProfile -NonInteractive -ExecutionPolicy Bypass -WindowStyle Hidden -File `"$controller`" -ConfigPath `"$config`" -LogPath `"$log`" -StatusPath `"$status`""
    $watchdogArguments = "-NoLogo -NoProfile -NonInteractive -ExecutionPolicy Bypass -WindowStyle Hidden -File `"$watchdog`" -Root `"$target`" -PrimaryTaskName `"$taskName`""
    $trigger = New-ScheduledTaskTrigger -AtStartup
    $principal = New-ScheduledTaskPrincipal -UserId 'SYSTEM' -LogonType ServiceAccount -RunLevel Highest
    $settings = New-ScheduledTaskSettingsSet -AllowStartIfOnBatteries -DontStopIfGoingOnBatteries -StartWhenAvailable -RestartCount 255 -RestartInterval (New-TimeSpan -Minutes 1) -ExecutionTimeLimit ([TimeSpan]::Zero) -MultipleInstances IgnoreNew
    $controllerAction = New-ScheduledTaskAction -Execute $trustedPwsh -Argument $controllerArguments -WorkingDirectory $target
    $watchdogAction = New-ScheduledTaskAction -Execute $trustedPwsh -Argument $watchdogArguments -WorkingDirectory $target
    Register-ScheduledTask -TaskName $taskName -Action $controllerAction -Trigger $trigger -Principal $principal -Settings $settings -Description 'Authoritative adaptive Acer PH317-51 fan control.' -Force | Out-Null
    Register-ScheduledTask -TaskName $watchdogTaskName -Action $watchdogAction -Trigger $trigger -Principal $principal -Settings $settings -Description 'Integrity and heartbeat watchdog for Acer adaptive fan control.' -Force | Out-Null
    Start-ScheduledTask -TaskName $taskName
    Start-ScheduledTask -TaskName $watchdogTaskName

    $deadline = [datetimeoffset]::Now.AddSeconds(60)
    $consecutiveHealthy = 0
    $lastFailure = 'No heartbeat was observed.'
    while ([datetimeoffset]::Now -lt $deadline) {
        try {
            $task = Get-ScheduledTask -TaskName $taskName
            $watchdogTask = Get-ScheduledTask -TaskName $watchdogTaskName
            if ($task.State -ne 'Running' -or $watchdogTask.State -ne 'Running') { throw "Task states are $($task.State)/$($watchdogTask.State)." }
            if (-not (Test-TaskDefinition -Task $task -ExpectedScript $controller -RequiredPaths @($config, $status) -PwshPath $trustedPwsh)) { throw 'Primary task definition mismatch.' }
            if (-not (Test-TaskDefinition -Task $watchdogTask -ExpectedScript $watchdog -RequiredPaths @($target, $taskName) -PwshPath $trustedPwsh)) { throw 'Watchdog task definition mismatch.' }
            $liveStatus = Get-Content -LiteralPath $status -Raw | ConvertFrom-Json
            $updated = [datetimeoffset]::Parse([string]$liveStatus.updatedAt, [Globalization.CultureInfo]::InvariantCulture)
            $age = ([datetimeoffset]::Now - $updated).TotalSeconds
            if ($updated -lt $deploymentStarted.AddSeconds(-1) -or $age -gt 10 -or $age -lt -5) { throw 'Controller heartbeat timestamp is outside the verification window.' }
            if ([string]$liveStatus.status -ne 'HEALTHY_VERIFIED' -or [string]$liveStatus.state -ne 'MAX') { throw "Controller health is $($liveStatus.status)/$($liveStatus.state)." }
            $mode = ([uint32]$liveStatus.fanBehaviorBitmap -shr 8) -band 3
            $minimumRpm = [int](Get-Content -LiteralPath $config -Raw | ConvertFrom-Json).minimumMaxRpm
            if ($mode -ne 2 -or [int]$liveStatus.cpuFanRpm -lt $minimumRpm -or [int]$liveStatus.gpuFanRpm -lt $minimumRpm) { throw 'MAX firmware readback is not verified.' }
            if (-not (Test-StrictAclTree -Path $target)) { throw 'Operational tree ACL verification failed.' }
            foreach ($name in $artifactNames) {
                $propertyName = switch ($name) { $controllerName { 'controller' }; $configName { 'config' }; default { 'watchdog' } }
                if ((Get-FileHash -LiteralPath (Join-Path $target $name) -Algorithm SHA256).Hash -ne [string]$expected.$propertyName) { throw "Installed hash mismatch: $name" }
            }
            $consecutiveHealthy++
            $result.controllerStatus = $liveStatus
            if ($consecutiveHealthy -ge 2) { break }
        }
        catch {
            $lastFailure = $_.Exception.Message
            $consecutiveHealthy = 0
        }
        Start-Sleep -Seconds 2
    }
    if ($consecutiveHealthy -lt 2) { throw "Bounded installation verification failed: $lastFailure" }

    $result.taskState = [string](Get-ScheduledTask -TaskName $taskName).State
    $result.watchdogState = [string](Get-ScheduledTask -TaskName $watchdogTaskName).State
    $result.aclVerified = Test-StrictAclTree -Path $target
    $result.hashesVerified = $true
    $result.installedAt = (Get-Date).ToString('o')
    $result.status = 'PASS'

    # Keep a secured diagnostics/recovery copy after the operational release is proven.
    New-Item -ItemType Directory -Path $diagnosticTarget -Force | Out-Null
    Set-Acl -LiteralPath $diagnosticTarget -AclObject (New-SecureDirectoryAcl)
    foreach ($name in $artifactNames) { Copy-Item -LiteralPath (Join-Path $target $name) -Destination (Join-Path $diagnosticTarget $name) -Force }
    Protect-DirectoryTree -Path $diagnosticTarget
}
catch {
    $result.error = $_.Exception.Message
    $result.rollbackAttempted = $true
    try { Set-EmergencyMax } catch { }
    try {
        if ($operationalMutationStarted) {
            Stop-ScheduledTask -TaskName $watchdogTaskName -ErrorAction SilentlyContinue
            Stop-ScheduledTask -TaskName $taskName -ErrorAction SilentlyContinue
            if ($backupCreated -and (Test-Path -LiteralPath $backupRoot)) {
                New-Item -ItemType Directory -Path $target -Force | Out-Null
                Copy-DirectoryContents -From $backupRoot -To $target
                Protect-DirectoryTree -Path $target
            }
            if ($taskSnapshots.ContainsKey($taskName)) { Restore-TaskSnapshot -Name $taskName -Snapshot $taskSnapshots[$taskName] }
            if ($taskSnapshots.ContainsKey($watchdogTaskName)) { Restore-TaskSnapshot -Name $watchdogTaskName -Snapshot $taskSnapshots[$watchdogTaskName] }
        }
        try { Set-EmergencyMax } catch { }
        $result.rollbackSucceeded = $true
    }
    catch {
        $result.error = "$($result.error) | Rollback error: $($_.Exception.Message)"
    }
}
finally {
    try {
        $result | ConvertTo-Json -Depth 10 | Set-Content -LiteralPath $resultPath -Encoding utf8
        Set-Acl -LiteralPath $resultPath -AclObject (New-SecureFileAcl)
        if (Test-Path -LiteralPath $target -PathType Container) {
            $trustedResultPath = Join-Path $target 'secure-fan-installation.json'
            $result | ConvertTo-Json -Depth 10 | Set-Content -LiteralPath $trustedResultPath -Encoding utf8
            Set-Acl -LiteralPath $trustedResultPath -AclObject (New-SecureFileAcl)
        }
    }
    catch { }
    $result | ConvertTo-Json -Depth 10
}

if ($result.status -eq 'PASS') { exit 0 }
exit 1
