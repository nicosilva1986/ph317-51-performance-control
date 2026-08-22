[CmdletBinding()]
param(
    [string] $Root = 'C:\ProgramData\AcerAdaptiveFanControl',
    [string] $PrimaryTaskName = 'Acer Adaptive Fan Control',
    [ValidateRange(5, 300)]
    [int] $HeartbeatMaximumAgeSeconds = 15,
    [ValidateRange(0, 60)]
    [int] $MaximumFutureSkewSeconds = 5,
    [switch] $ProbeOnly
)

Set-StrictMode -Version Latest
$ErrorActionPreference = 'Stop'
$statusPath = Join-Path $Root 'adaptive-fan-status.json'
$manifestPath = Join-Path $Root 'integrity.json'
$logPath = Join-Path $Root 'watchdog.jsonl'
$controllerLogPath = Join-Path $Root 'adaptive-fan.jsonl'
$controllerPath = Join-Path $Root 'AcerAdaptiveFanController.ps1'
$configPath = Join-Path $Root 'fan-controller-config.json'
$watchdogPath = Join-Path $Root 'AcerFanWatchdog.ps1'

function Write-WatchdogEvent {
    param([string] $Event, [string] $Detail = '')
    try {
        if (Test-Path -LiteralPath $logPath) {
            $item = Get-Item -LiteralPath $logPath
            if ($item.Length -ge 1048576) { Move-Item -LiteralPath $logPath -Destination "$logPath.1" -Force }
        }
        $record = [ordered]@{ timestamp = (Get-Date).ToString('o'); event = $Event; detail = $Detail }
        [IO.File]::AppendAllText($logPath, (($record | ConvertTo-Json -Compress) + [Environment]::NewLine), [Text.UTF8Encoding]::new($false))
    }
    catch {
        # Logging must never disable the thermal safety path.
    }
}

function Assert-SupportedHardware {
    $computer = Get-CimInstance -ClassName Win32_ComputerSystem
    if ([string]$computer.Manufacturer -notmatch '^Acer\b' -or [string]$computer.Model -notmatch '(?i)\bPH317-51\b') {
        throw "Unsupported hardware. Expected Acer PH317-51; detected '$($computer.Manufacturer) $($computer.Model)'."
    }
}

function Set-EmergencyMax {
    Assert-SupportedHardware
    $gaming = Get-CimInstance -Namespace 'root\wmi' -ClassName AcerGamingFunction | Select-Object -First 1
    if (-not $gaming) { throw 'AcerGamingFunction is unavailable.' }
    $behavior = Invoke-CimMethod -InputObject $gaming -MethodName SetGamingFanBehavior -Arguments @{ gmInput = [uint64]0x00820009 }
    $cpu = Invoke-CimMethod -InputObject $gaming -MethodName SetGamingFanSpeed -Arguments @{ gmInput = [uint64]0x00006401 }
    $gpu = Invoke-CimMethod -InputObject $gaming -MethodName SetGamingFanSpeed -Arguments @{ gmInput = [uint64]0x00006404 }
    if ([uint32]$behavior.gmOutput -ne 0 -or [uint32]$cpu.gmOutput -ne 0 -or [uint32]$gpu.gmOutput -ne 0) {
        throw 'Firmware rejected watchdog MAX request.'
    }
}

function Get-IntegrityState {
    $result = [ordered]@{ valid = $false; detail = ''; config = $null }
    try {
        if (-not (Test-Path -LiteralPath $manifestPath)) { throw 'Integrity manifest is missing.' }
        $manifest = Get-Content -LiteralPath $manifestPath -Raw | ConvertFrom-Json
        $checks = @(
            @{ name = 'controller'; path = $controllerPath },
            @{ name = 'config'; path = $configPath },
            @{ name = 'watchdog'; path = $watchdogPath }
        )
        foreach ($check in $checks) {
            $property = $manifest.PSObject.Properties[$check.name]
            if ($null -eq $property -or [string]::IsNullOrWhiteSpace([string]$property.Value)) {
                throw "Integrity manifest property is missing: $($check.name)"
            }
            $expected = [string]$property.Value
            if ($expected -notmatch '^[0-9A-Fa-f]{64}$') { throw "Invalid SHA256 in manifest: $($check.name)" }
            if (-not (Test-Path -LiteralPath $check.path -PathType Leaf)) { throw "Protected artifact is missing: $($check.path)" }
            $actual = (Get-FileHash -LiteralPath $check.path -Algorithm SHA256).Hash
            if ($actual -ne $expected) { throw "SHA256 mismatch: $($check.name)" }
        }
        $configuration = Get-Content -LiteralPath $configPath -Raw | ConvertFrom-Json
        $minimumRpmProperty = $configuration.PSObject.Properties['minimumMaxRpm']
        if ($null -eq $minimumRpmProperty) { throw 'minimumMaxRpm is absent from the protected configuration.' }
        $minimumRpm = [int]$minimumRpmProperty.Value
        if ($minimumRpm -lt 1000 -or $minimumRpm -gt 10000) { throw 'minimumMaxRpm is outside its safety range.' }
        $result.valid = $true
        $result.detail = 'OK'
        $result.config = $configuration
    }
    catch {
        $result.detail = $_.Exception.Message
    }
    return [pscustomobject]$result
}

function Get-PrimaryStatusHealth {
    param([Parameter(Mandatory)] $Configuration)

    $result = [ordered]@{ valid = $false; detail = ''; status = $null; ageSeconds = $null }
    try {
        if (-not (Test-Path -LiteralPath $statusPath -PathType Leaf)) { throw 'Primary heartbeat is missing.' }
        $status = Get-Content -LiteralPath $statusPath -Raw | ConvertFrom-Json
        foreach ($name in @('updatedAt', 'state', 'status', 'fanBehaviorBitmap')) {
            if ($null -eq $status.PSObject.Properties[$name]) { throw "Primary heartbeat property is missing: $name" }
        }
        $updated = [datetimeoffset]::MinValue
        if (-not [datetimeoffset]::TryParse([string]$status.updatedAt, [Globalization.CultureInfo]::InvariantCulture, [Globalization.DateTimeStyles]::RoundtripKind, [ref]$updated)) {
            throw 'Primary heartbeat timestamp is malformed.'
        }
        $ageSeconds = ([datetimeoffset]::Now - $updated).TotalSeconds
        $result.ageSeconds = [math]::Round($ageSeconds, 3)
        if ($ageSeconds -gt $HeartbeatMaximumAgeSeconds) { throw "Primary heartbeat is stale by $([math]::Round($ageSeconds,1)) seconds." }
        if ($ageSeconds -lt -$MaximumFutureSkewSeconds) { throw "Primary heartbeat is $([math]::Round(-$ageSeconds,1)) seconds in the future." }
        if ([string]$status.status -ne 'HEALTHY_VERIFIED') { throw "Primary health code is $([string]$status.status)." }

        $state = [string]$status.state
        if ($state -notin @('AUTO', 'MAX')) { throw "Primary state is invalid: $state" }
        $mode = ([uint32]$status.fanBehaviorBitmap -shr 8) -band 3
        if ($state -eq 'AUTO') {
            if ($mode -ne 1) { throw "AUTO state does not match firmware mode $mode." }
        }
        else {
            foreach ($name in @('cpuFanRpm', 'gpuFanRpm')) {
                if ($null -eq $status.PSObject.Properties[$name]) { throw "MAX heartbeat property is missing: $name" }
            }
            if ($mode -ne 2) { throw "MAX state does not match firmware mode $mode." }
            $minimumRpm = [int]$Configuration.minimumMaxRpm
            if ([int]$status.cpuFanRpm -lt $minimumRpm -or [int]$status.gpuFanRpm -lt $minimumRpm) {
                throw "MAX fan RPM is below $minimumRpm."
            }
        }
        $result.valid = $true
        $result.detail = 'OK'
        $result.status = $status
    }
    catch {
        $result.detail = $_.Exception.Message
    }
    return [pscustomobject]$result
}

function Test-PrimaryTaskDefinition {
    param([Parameter(Mandatory)] $Task)
    try {
        if ([string]$Task.Principal.UserId -ne 'SYSTEM') { return $false }
        if (@($Task.Actions).Count -ne 1) { return $false }
        $expectedPwsh = [IO.Path]::GetFullPath((Join-Path $PSHOME 'pwsh.exe'))
        $actualPwsh = [IO.Path]::GetFullPath([string]$Task.Actions.Execute)
        if ($actualPwsh -ne $expectedPwsh) { return $false }
        $arguments = [string]$Task.Actions.Arguments
        foreach ($requiredPath in @($controllerPath, $configPath, $controllerLogPath, $statusPath)) {
            if ($arguments.IndexOf($requiredPath, [StringComparison]::OrdinalIgnoreCase) -lt 0) { return $false }
        }
        return $true
    }
    catch {
        return $false
    }
}

function Register-TrustedPrimaryTask {
    $pwshPath = [IO.Path]::GetFullPath((Join-Path $PSHOME 'pwsh.exe'))
    $arguments = "-NoLogo -NoProfile -NonInteractive -ExecutionPolicy Bypass -WindowStyle Hidden -File `"$controllerPath`" -ConfigPath `"$configPath`" -LogPath `"$controllerLogPath`" -StatusPath `"$statusPath`""
    $action = New-ScheduledTaskAction -Execute $pwshPath -Argument $arguments -WorkingDirectory $Root
    $trigger = New-ScheduledTaskTrigger -AtStartup
    $principal = New-ScheduledTaskPrincipal -UserId 'SYSTEM' -LogonType ServiceAccount -RunLevel Highest
    $settings = New-ScheduledTaskSettingsSet -AllowStartIfOnBatteries -DontStopIfGoingOnBatteries -StartWhenAvailable -RestartCount 255 -RestartInterval (New-TimeSpan -Minutes 1) -ExecutionTimeLimit ([TimeSpan]::Zero) -MultipleInstances IgnoreNew
    Register-ScheduledTask -TaskName $PrimaryTaskName -Action $action -Trigger $trigger -Principal $principal -Settings $settings -Description 'Authoritative adaptive Acer PH317-51 fan control.' -Force | Out-Null
}

function Invoke-EmergencyRecovery {
    param([string] $Reason)
    $maxError = ''
    try { Set-EmergencyMax } catch { $maxError = $_.Exception.Message }

    $task = $null
    try { $task = Get-ScheduledTask -TaskName $PrimaryTaskName -ErrorAction SilentlyContinue } catch { }
    try {
        if ($task -and $task.State -eq 'Running') { Stop-ScheduledTask -TaskName $PrimaryTaskName }
        if (-not $task -or -not (Test-PrimaryTaskDefinition -Task $task)) {
            Register-TrustedPrimaryTask
        }
        Start-ScheduledTask -TaskName $PrimaryTaskName
    }
    catch {
        $restartError = $_.Exception.Message
        Write-WatchdogEvent 'primary_recovery_error' "$Reason; MAX error: $maxError; restart error: $restartError"
        return
    }
    Write-WatchdogEvent 'primary_restarted' "$Reason; MAX error: $maxError"
}

$integrityState = Get-IntegrityState
if ($ProbeOnly) {
    $health = if ($integrityState.valid) { Get-PrimaryStatusHealth -Configuration $integrityState.config } else { [pscustomobject]@{ valid = $false; detail = 'Integrity invalid; status not trusted.'; status = $null; ageSeconds = $null } }
    [ordered]@{ integrity = $integrityState; health = $health } | ConvertTo-Json -Depth 8
    if ($integrityState.valid -and $health.valid) { exit 0 }
    exit 1
}

$createdNew = $false
$mutex = [Threading.Mutex]::new($true, 'Global\AcerAdaptiveFanWatchdog', [ref]$createdNew)
if (-not $createdNew) { exit 0 }

try {
    Write-WatchdogEvent 'watchdog_started'
    while ($true) {
        try {
            $integrityState = Get-IntegrityState
            if (-not $integrityState.valid) {
                $maxError = ''
                try { Set-EmergencyMax } catch { $maxError = $_.Exception.Message }
                try { Stop-ScheduledTask -TaskName $PrimaryTaskName -ErrorAction SilentlyContinue } catch { }
                Write-WatchdogEvent 'integrity_failure_max_left_active' "$($integrityState.detail); MAX error: $maxError"
                Start-Sleep -Seconds 20
                continue
            }

            $task = Get-ScheduledTask -TaskName $PrimaryTaskName -ErrorAction SilentlyContinue
            $health = Get-PrimaryStatusHealth -Configuration $integrityState.config
            $taskDefinitionValid = $task -and (Test-PrimaryTaskDefinition -Task $task)
            if ($task -and -not $taskDefinitionValid) {
                Invoke-EmergencyRecovery -Reason 'Primary task definition was altered.'
                continue
            }
            $taskHealthy = $taskDefinitionValid -and $task.State -eq 'Running'
            if (-not $taskHealthy -or -not $health.valid) {
                $taskState = if ($task) { [string]$task.State } else { 'MISSING' }
                Invoke-EmergencyRecovery -Reason "Task state: $taskState; task definition valid: $taskDefinitionValid; heartbeat: $($health.detail)"
            }
        }
        catch {
            Invoke-EmergencyRecovery -Reason "Unhandled watchdog loop error: $($_.Exception.Message)"
        }
        Start-Sleep -Seconds 10
    }
}
finally {
    try { $mutex.ReleaseMutex() } catch { }
    $mutex.Dispose()
}
