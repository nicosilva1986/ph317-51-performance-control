[CmdletBinding()]
param(
    [string] $Root = 'C:\ProgramData\AcerAdaptiveFanControl',
    [string] $PrimaryTaskName = 'Acer Adaptive Fan Control',
    [ValidateRange(5, 300)]
    [int] $HeartbeatMaximumAgeSeconds = 15,
    [ValidateRange(0, 60)]
    [int] $MaximumFutureSkewSeconds = 5,
    [switch] $ProbeOnly,
    [ValidateRange(0, 1000)]
    [int] $ProbePreviousPendingCount = 0,
    [ValidateRange(0, 3600)]
    [double] $ProbePendingElapsedSeconds = 0
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
$watchdogPollSeconds = 10

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
        $verifyProperty = $configuration.PSObject.Properties['verifyMaxAfterSeconds']
        if ($null -eq $verifyProperty) { throw 'verifyMaxAfterSeconds is absent from the protected configuration.' }
        $verifyRaw = [double]$verifyProperty.Value
        $verifySeconds = [int]$verifyRaw
        if ($verifyRaw -ne $verifySeconds -or $verifySeconds -lt 1 -or $verifySeconds -gt 300) {
            throw 'verifyMaxAfterSeconds is outside its safety range.'
        }
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

    $result = [ordered]@{ valid = $false; disposition = 'FATAL'; detail = ''; status = $null; ageSeconds = $null }
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
        $state = [string]$status.state
        if ($state -notin @('AUTO', 'MAX')) { throw "Primary state is invalid: $state" }
        $mode = ([uint32]$status.fanBehaviorBitmap -shr 8) -band 3
        $healthCode = [string]$status.status
        $result.status = $status
        if ($healthCode -eq 'REASSERT_PENDING') {
            foreach ($name in @('cpuFanRpm', 'gpuFanRpm')) {
                $rpmProperty = $status.PSObject.Properties[$name]
                if ($null -eq $rpmProperty -or $null -eq $rpmProperty.Value -or [int]$rpmProperty.Value -lt 0) {
                    throw "REASSERT_PENDING heartbeat has invalid $name."
                }
            }
            $result.disposition = 'REASSERT_PENDING'
            $result.detail = "Primary $state transition is awaiting verified mode/RPM; observed mode $mode."
            return [pscustomobject]$result
        }
        if ($healthCode -ne 'HEALTHY_VERIFIED') { throw "Primary health code is $healthCode." }

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
        $result.disposition = 'HEALTHY_VERIFIED'
        $result.detail = 'OK'
    }
    catch {
        $result.detail = $_.Exception.Message
    }
    return [pscustomobject]$result
}

function Get-HeartbeatRecoveryDecision {
    param(
        [Parameter(Mandatory)]
        [ValidateSet('HEALTHY_VERIFIED', 'REASSERT_PENDING', 'FATAL')]
        [string] $Disposition,
        [ValidateRange(0, 1000)]
        [int] $PreviousPendingCount,
        [ValidateRange(0, 3600)]
        [double] $PendingElapsedSeconds,
        [ValidateRange(1, 300)]
        [int] $VerifyMaxAfterSeconds
    )

    if ($Disposition -eq 'HEALTHY_VERIFIED') {
        return [pscustomobject]@{ action = 'NONE'; nextPendingCount = 0; resetWindow = $true }
    }
    if ($Disposition -eq 'FATAL') {
        return [pscustomobject]@{ action = 'MAX_AND_RESTART'; nextPendingCount = 0; resetWindow = $true }
    }

    $nextCount = $PreviousPendingCount + 1
    $action = if ($nextCount -ge 2 -and $PendingElapsedSeconds -ge $VerifyMaxAfterSeconds) {
        'MAX_AND_RESTART'
    }
    else {
        'MAX_ONLY'
    }
    return [pscustomobject]@{ action = $action; nextPendingCount = $nextCount; resetWindow = $false }
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
    $health = if ($integrityState.valid) {
        Get-PrimaryStatusHealth -Configuration $integrityState.config
    }
    else {
        [pscustomobject]@{ valid = $false; disposition = 'FATAL'; detail = 'Integrity invalid; status not trusted.'; status = $null; ageSeconds = $null }
    }
    $verifySeconds = if ($integrityState.valid) { [int]$integrityState.config.verifyMaxAfterSeconds } else { 1 }
    $decision = if ($integrityState.valid) {
        Get-HeartbeatRecoveryDecision -Disposition $health.disposition -PreviousPendingCount $ProbePreviousPendingCount `
            -PendingElapsedSeconds $ProbePendingElapsedSeconds -VerifyMaxAfterSeconds $verifySeconds
    }
    else {
        [pscustomobject]@{ action = 'MAX_AND_STOP'; nextPendingCount = 0; resetWindow = $true }
    }
    [ordered]@{ integrity = $integrityState; health = $health; decision = $decision; verifyMaxAfterSeconds = $verifySeconds } | ConvertTo-Json -Depth 8
    if ($integrityState.valid -and $health.valid) { exit 0 }
    exit 1
}

$createdNew = $false
$mutex = [Threading.Mutex]::new($true, 'Global\AcerAdaptiveFanWatchdog', [ref]$createdNew)
if (-not $createdNew) { exit 0 }

try {
    Write-WatchdogEvent 'watchdog_started'
    $pendingCount = 0
    $pendingClock = [Diagnostics.Stopwatch]::new()
    while ($true) {
        try {
            $integrityState = Get-IntegrityState
            if (-not $integrityState.valid) {
                $pendingCount = 0
                $pendingClock.Reset()
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
                $pendingCount = 0
                $pendingClock.Reset()
                Invoke-EmergencyRecovery -Reason 'Primary task definition was altered.'
            }
            else {
                $taskHealthy = $taskDefinitionValid -and $task.State -eq 'Running'
                $taskState = if ($task) { [string]$task.State } else { 'MISSING' }
                if (-not $taskHealthy) {
                    $pendingCount = 0
                    $pendingClock.Reset()
                    Invoke-EmergencyRecovery -Reason "Task state: $taskState; task definition valid: $taskDefinitionValid; heartbeat: $($health.detail)"
                }
                elseif ($health.disposition -eq 'REASSERT_PENDING') {
                    if ($pendingCount -eq 0) { $pendingClock.Restart() }
                    $pendingElapsed = $pendingClock.Elapsed.TotalSeconds
                    $decision = Get-HeartbeatRecoveryDecision -Disposition $health.disposition -PreviousPendingCount $pendingCount `
                        -PendingElapsedSeconds $pendingElapsed -VerifyMaxAfterSeconds ([int]$integrityState.config.verifyMaxAfterSeconds)
                    $pendingCount = [int]$decision.nextPendingCount
                    if ($decision.action -eq 'MAX_ONLY') {
                        try {
                            Set-EmergencyMax
                            Write-WatchdogEvent 'reassert_pending_max_requested' "count=$pendingCount; elapsedSeconds=$([math]::Round($pendingElapsed,1)); verifySeconds=$([int]$integrityState.config.verifyMaxAfterSeconds)"
                        }
                        catch {
                            $pendingCount = 0
                            $pendingClock.Reset()
                            Invoke-EmergencyRecovery -Reason "REASSERT_PENDING MAX request failed: $($_.Exception.Message)"
                        }
                    }
                    else {
                        Write-WatchdogEvent 'reassert_pending_restart_threshold' "count=$pendingCount; elapsedSeconds=$([math]::Round($pendingElapsed,1)); verifySeconds=$([int]$integrityState.config.verifyMaxAfterSeconds)"
                        $pendingCount = 0
                        $pendingClock.Reset()
                        Invoke-EmergencyRecovery -Reason "Persistent heartbeat: $($health.detail)"
                    }
                }
                elseif ($health.disposition -eq 'HEALTHY_VERIFIED') {
                    if ($pendingCount -gt 0) {
                        Write-WatchdogEvent 'reassert_pending_cleared' "count=$pendingCount; elapsedSeconds=$([math]::Round($pendingClock.Elapsed.TotalSeconds,1))"
                    }
                    $pendingCount = 0
                    $pendingClock.Reset()
                }
                else {
                    $pendingCount = 0
                    $pendingClock.Reset()
                    Invoke-EmergencyRecovery -Reason "Task state: $taskState; task definition valid: $taskDefinitionValid; heartbeat: $($health.detail)"
                }
            }
        }
        catch {
            $pendingCount = 0
            $pendingClock.Reset()
            Invoke-EmergencyRecovery -Reason "Unhandled watchdog loop error: $($_.Exception.Message)"
        }
        Start-Sleep -Seconds $watchdogPollSeconds
    }
}
finally {
    try { $mutex.ReleaseMutex() } catch { }
    $mutex.Dispose()
}
