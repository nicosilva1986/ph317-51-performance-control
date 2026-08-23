[CmdletBinding()]
param(
    [string] $Root = 'C:\ProgramData\AcerAdaptiveFanControl',
    [string] $PrimaryTaskName = 'Acer Adaptive Fan Control',
    [ValidateRange(5, 300)]
    [int] $HeartbeatMaximumAgeSeconds = 15,
    [ValidateRange(0, 60)]
    [int] $MaximumFutureSkewSeconds = 5,
    [ValidateRange(1, 20)]
    [int] $StatusReadAttempts = 5,
    [ValidateRange(1, 10)]
    [int] $TransientHeartbeatTolerance = 2,
    [ValidateRange(5, 300)]
    [int] $PrimaryStartTimeoutSeconds = 30,
    [ValidateRange(1, 20)]
    [int] $PrimaryStartRunningObservations = 3,
    [ValidateRange(1, 20)]
    [int] $RecoveryReregisterThreshold = 3,
    [switch] $ProbeOnly,
    [ValidateRange(0, 1000)]
    [int] $ProbePreviousPendingCount = 0,
    [ValidateRange(0, 3600)]
    [double] $ProbePendingElapsedSeconds = 0,
    [ValidateRange(0, 1000)]
    [int] $ProbePreviousTransientCount = 0
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
$script:ConsecutiveRecoveryFailures = 0

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

function Read-PrimaryStatusDocument {
    param([ValidateRange(1, 20)] [int] $Attempts = 5)

    # The primary republishes this file every poll. Sharing Delete and Write means this read never
    # blocks the writer's atomic swap, and a read that still loses the race is reported as a
    # transient failure rather than as evidence that the controller is dead.
    $lastDetail = 'Primary heartbeat is missing.'
    for ($attempt = 1; $attempt -le $Attempts; $attempt++) {
        try {
            $stream = [IO.File]::Open($statusPath, [IO.FileMode]::Open, [IO.FileAccess]::Read,
                ([IO.FileShare]::ReadWrite -bor [IO.FileShare]::Delete))
            try {
                $reader = [IO.StreamReader]::new($stream, [Text.UTF8Encoding]::new($false), $true)
                $raw = $reader.ReadToEnd()
            }
            finally {
                $stream.Dispose()
            }
            if ([string]::IsNullOrWhiteSpace($raw)) {
                $lastDetail = 'Primary heartbeat is empty.'
            }
            else {
                $document = $raw | ConvertFrom-Json
                if ($null -eq $document) {
                    $lastDetail = 'Primary heartbeat did not parse into an object.'
                }
                else {
                    return [pscustomobject]@{ ok = $true; status = $document; detail = 'OK' }
                }
            }
        }
        catch {
            $lastDetail = $_.Exception.Message
        }
        if ($attempt -lt $Attempts) { Start-Sleep -Milliseconds 120 }
    }
    return [pscustomobject]@{ ok = $false; status = $null; detail = $lastDetail }
}

function Test-PrimaryHeartbeatNewerThan {
    param([Parameter(Mandatory)] [datetimeoffset] $Mark)

    $document = Read-PrimaryStatusDocument -Attempts 1
    if (-not $document.ok) { return $false }
    $property = $document.status.PSObject.Properties['updatedAt']
    if ($null -eq $property) { return $false }
    $updated = [datetimeoffset]::MinValue
    if (-not [datetimeoffset]::TryParse([string]$property.Value, [Globalization.CultureInfo]::InvariantCulture,
            [Globalization.DateTimeStyles]::RoundtripKind, [ref]$updated)) {
        return $false
    }
    return $updated -gt $Mark
}

function Get-RequiredUnsignedInteger {
    param(
        [Parameter(Mandatory)] $InputObject,
        [Parameter(Mandatory)] [string] $Name,
        [Parameter(Mandatory)] [uint64] $Maximum
    )

    $property = $InputObject.PSObject.Properties[$Name]
    if ($null -eq $property -or $null -eq $property.Value -or $property.Value -is [bool]) {
        throw "Primary heartbeat has invalid unsigned integer: $Name"
    }

    $value = $property.Value
    $typeCode = [Type]::GetTypeCode($value.GetType())
    $signedTypes = @([TypeCode]::SByte, [TypeCode]::Int16, [TypeCode]::Int32, [TypeCode]::Int64)
    $unsignedTypes = @([TypeCode]::Byte, [TypeCode]::UInt16, [TypeCode]::UInt32, [TypeCode]::UInt64)
    if ($typeCode -in $signedTypes) {
        $signedValue = [int64]$value
        if ($signedValue -lt 0) { throw "Primary heartbeat has invalid unsigned integer: $Name" }
        $parsed = [uint64]$signedValue
    }
    elseif ($typeCode -in $unsignedTypes) {
        $parsed = [uint64]$value
    }
    else {
        throw "Primary heartbeat has invalid unsigned integer: $Name"
    }
    if ($parsed -gt $Maximum) { throw "Primary heartbeat has out-of-range unsigned integer: $Name" }
    return $parsed
}

function Get-PrimaryStatusHealth {
    param([Parameter(Mandatory)] $Configuration)

    $result = [ordered]@{ valid = $false; disposition = 'FATAL'; detail = ''; status = $null; ageSeconds = $null }
    try {
        $document = Read-PrimaryStatusDocument -Attempts $StatusReadAttempts
        if (-not $document.ok) {
            # A read that never landed is not evidence the controller stopped. Classify it as
            # transient so one lost race cannot tear down a healthy primary; a controller that is
            # genuinely dead still trips the staleness check below within HeartbeatMaximumAgeSeconds.
            $result.disposition = 'TRANSIENT'
            $result.detail = $document.detail
            return [pscustomobject]$result
        }
        $status = $document.status
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
        $behaviorBitmap = [uint32](Get-RequiredUnsignedInteger -InputObject $status -Name 'fanBehaviorBitmap' -Maximum ([uint32]::MaxValue))
        $mode = ($behaviorBitmap -shr 8) -band 3
        $healthCode = [string]$status.status
        $result.status = $status
        if ($healthCode -eq 'REASSERT_PENDING') {
            if ($state -ne 'MAX') {
                throw 'REASSERT_PENDING is transient only while the primary state is MAX.'
            }
            foreach ($name in @('cpuFanRpm', 'gpuFanRpm')) {
                [void](Get-RequiredUnsignedInteger -InputObject $status -Name $name -Maximum ([int32]::MaxValue))
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
            $cpuFanRpm = Get-RequiredUnsignedInteger -InputObject $status -Name 'cpuFanRpm' -Maximum ([int32]::MaxValue)
            $gpuFanRpm = Get-RequiredUnsignedInteger -InputObject $status -Name 'gpuFanRpm' -Maximum ([int32]::MaxValue)
            if ($mode -ne 2) { throw "MAX state does not match firmware mode $mode." }
            $minimumRpm = [int]$Configuration.minimumMaxRpm
            if ($cpuFanRpm -lt $minimumRpm -or $gpuFanRpm -lt $minimumRpm) {
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
        [ValidateSet('HEALTHY_VERIFIED', 'REASSERT_PENDING', 'TRANSIENT', 'FATAL')]
        [string] $Disposition,
        [ValidateRange(0, 1000)]
        [int] $PreviousPendingCount,
        [ValidateRange(0, 3600)]
        [double] $PendingElapsedSeconds,
        [ValidateRange(1, 300)]
        [int] $VerifyMaxAfterSeconds,
        [ValidateRange(0, 1000)]
        [int] $PreviousTransientCount = 0,
        [ValidateRange(1, 10)]
        [int] $TransientTolerance = 2
    )

    if ($Disposition -eq 'HEALTHY_VERIFIED') {
        return [pscustomobject]@{ action = 'NONE'; nextPendingCount = 0; nextTransientCount = 0; resetWindow = $true }
    }
    if ($Disposition -eq 'TRANSIENT') {
        # Losing a read race against the primary's own republish is common and self-correcting.
        # Recover only once the primary has failed to publish a readable heartbeat across
        # TransientTolerance consecutive polls.
        $nextTransient = $PreviousTransientCount + 1
        $transientAction = if ($nextTransient -ge $TransientTolerance) { 'QUIESCE_MAX_RESTART' } else { 'WAIT_PRIMARY' }
        return [pscustomobject]@{ action = $transientAction; nextPendingCount = 0; nextTransientCount = $nextTransient; resetWindow = $true }
    }
    if ($Disposition -eq 'FATAL') {
        return [pscustomobject]@{ action = 'QUIESCE_MAX_RESTART'; nextPendingCount = 0; nextTransientCount = 0; resetWindow = $true }
    }

    $nextCount = $PreviousPendingCount + 1
    $action = if ($nextCount -ge 2 -and $PendingElapsedSeconds -ge $VerifyMaxAfterSeconds) {
        'QUIESCE_MAX_RESTART'
    }
    else {
        'WAIT_PRIMARY'
    }
    return [pscustomobject]@{ action = $action; nextPendingCount = $nextCount; nextTransientCount = 0; resetWindow = $false }
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

function Stop-PrimaryAndAcquireControllerLease {
    $task = $null
    try { $task = Get-ScheduledTask -TaskName $PrimaryTaskName -ErrorAction SilentlyContinue } catch { }
    if ($task -and $task.State -eq 'Running') {
        Stop-ScheduledTask -TaskName $PrimaryTaskName
        # The task is registered MultipleInstances=IgnoreNew, so a Start issued while the previous
        # instance is still terminating is silently discarded. Wait for the engine to report the
        # stop before anyone tries to start it again.
        $stopClock = [Diagnostics.Stopwatch]::StartNew()
        while ($stopClock.Elapsed.TotalSeconds -lt 10) {
            Start-Sleep -Milliseconds 200
            $current = $null
            try { $current = Get-ScheduledTask -TaskName $PrimaryTaskName -ErrorAction SilentlyContinue } catch { }
            if (-not $current -or $current.State -ne 'Running') { break }
        }
    }

    $lease = [Threading.Mutex]::new($false, 'Global\AcerAdaptiveFanController')
    try {
        $acquired = $false
        try { $acquired = $lease.WaitOne(5000) }
        catch [Threading.AbandonedMutexException] { $acquired = $true }
        if (-not $acquired) {
            throw 'Timed out waiting for the primary controller write lease after stopping its task.'
        }
        return $lease
    }
    catch {
        $lease.Dispose()
        throw
    }
}

function Release-ControllerLease {
    param([Parameter(Mandatory)] [Threading.Mutex] $Lease)
    try { $Lease.ReleaseMutex() }
    finally { $Lease.Dispose() }
}

function Start-TrustedPrimaryTask {
    $task = $null
    try { $task = Get-ScheduledTask -TaskName $PrimaryTaskName -ErrorAction SilentlyContinue } catch { }
    if (-not $task -or -not (Test-PrimaryTaskDefinition -Task $task)) {
        Register-TrustedPrimaryTask
    }
    # Anything published after this mark was written by the instance being started, so a newer
    # heartbeat is unambiguous proof of life rather than a leftover from the previous instance.
    $restartMark = [datetimeoffset]::Now
    Start-ScheduledTask -TaskName $PrimaryTaskName

    $startClock = [Diagnostics.Stopwatch]::StartNew()
    $runningObservations = 0
    do {
        Start-Sleep -Milliseconds 250
        $task = Get-ScheduledTask -TaskName $PrimaryTaskName -ErrorAction SilentlyContinue
        if ($task -and $task.State -eq 'Running') {
            $runningObservations++
            if ($runningObservations -ge $PrimaryStartRunningObservations) { return }
        }
        else {
            $runningObservations = 0
        }

        # The task engine can report a transient non-Running state during hand-off. Declaring
        # failure while the controller is in fact alive is what left the fans pinned at MAX and
        # sent the watchdog back around to stop it again on the next poll.
        if (Test-PrimaryHeartbeatNewerThan -Mark $restartMark) { return }
    } while ($startClock.Elapsed.TotalSeconds -lt $PrimaryStartTimeoutSeconds)
    throw "Primary task did not reach Running state within $PrimaryStartTimeoutSeconds seconds after restart."
}

function Invoke-WatchdogRecoveryAction {
    param(
        [Parameter(Mandatory)]
        [ValidateSet('WAIT_PRIMARY', 'QUIESCE_MAX', 'QUIESCE_MAX_RESTART')]
        [string] $Action,
        [Parameter(Mandatory)] [string] $Reason,
        [Parameter(Mandatory)] [scriptblock] $StopPrimary,
        [Parameter(Mandatory)] [scriptblock] $RequestMax,
        [Parameter(Mandatory)] [scriptblock] $ReleasePrimary,
        [Parameter(Mandatory)] [scriptblock] $StartPrimary
    )

    if ($Action -eq 'WAIT_PRIMARY') {
        return [pscustomobject]@{ outcome = 'PRIMARY_REMAINS_AUTHORITATIVE'; resetPending = $false; detail = 'No watchdog write was dispatched.' }
    }

    $lease = $null
    try {
        $lease = & $StopPrimary
    }
    catch {
        return [pscustomobject]@{ outcome = 'RECOVERY_FAILED'; resetPending = $false; detail = "STOP failed: $($_.Exception.Message)" }
    }

    $maxError = ''
    try { & $RequestMax | Out-Null } catch { $maxError = $_.Exception.Message }

    $releaseError = ''
    try { & $ReleasePrimary $lease | Out-Null } catch { $releaseError = $_.Exception.Message }

    $startError = ''
    if ($Action -eq 'QUIESCE_MAX_RESTART' -and [string]::IsNullOrWhiteSpace($releaseError)) {
        try { & $StartPrimary | Out-Null } catch { $startError = $_.Exception.Message }
    }

    if ([string]::IsNullOrWhiteSpace($maxError) -and [string]::IsNullOrWhiteSpace($releaseError) -and
        [string]::IsNullOrWhiteSpace($startError)) {
        $outcome = if ($Action -eq 'QUIESCE_MAX_RESTART') { 'PRIMARY_RESTARTED' } else { 'MAX_HELD_WITH_PRIMARY_STOPPED' }
        return [pscustomobject]@{ outcome = $outcome; resetPending = $true; detail = 'OK' }
    }

    $detail = "$Reason; MAX error: $maxError; release error: $releaseError; start error: $startError"
    return [pscustomobject]@{ outcome = 'RECOVERY_FAILED'; resetPending = $false; detail = $detail }
}

function Invoke-EmergencyRecovery {
    param([string] $Reason)
    $result = Invoke-WatchdogRecoveryAction -Action 'QUIESCE_MAX_RESTART' -Reason $Reason `
        -StopPrimary { Stop-PrimaryAndAcquireControllerLease } -RequestMax { Set-EmergencyMax } `
        -ReleasePrimary { param($lease) Release-ControllerLease -Lease $lease } -StartPrimary { Start-TrustedPrimaryTask }
    if ($result.outcome -eq 'PRIMARY_RESTARTED') {
        $script:ConsecutiveRecoveryFailures = 0
        Write-WatchdogEvent 'primary_restarted' $Reason
    }
    else {
        $script:ConsecutiveRecoveryFailures++
        Write-WatchdogEvent 'primary_recovery_error' $result.detail
        if ($script:ConsecutiveRecoveryFailures -ge $RecoveryReregisterThreshold) {
            # Repeated failures mean the registered task itself can no longer start the controller.
            # Every one of these attempts leaves the fans at MAX with no primary, so rebuild the
            # task from the trusted definition instead of repeating the same failing restart.
            $reregisterDetail = 'OK'
            try { Register-TrustedPrimaryTask }
            catch { $reregisterDetail = $_.Exception.Message }
            Write-WatchdogEvent 'primary_task_reregistered' "consecutiveFailures=$($script:ConsecutiveRecoveryFailures); detail=$reregisterDetail"
            $script:ConsecutiveRecoveryFailures = 0
        }
    }
    return $result
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
            -PendingElapsedSeconds $ProbePendingElapsedSeconds -VerifyMaxAfterSeconds $verifySeconds `
            -PreviousTransientCount $ProbePreviousTransientCount -TransientTolerance $TransientHeartbeatTolerance
    }
    else {
        [pscustomobject]@{ action = 'QUIESCE_MAX'; nextPendingCount = 0; nextTransientCount = 0; resetWindow = $true }
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
    $transientCount = 0
    $pendingClock = [Diagnostics.Stopwatch]::new()
    while ($true) {
        try {
            $integrityState = Get-IntegrityState
            if (-not $integrityState.valid) {
                $pendingCount = 0
                $transientCount = 0
                $pendingClock.Reset()
                $integrityDispatch = Invoke-WatchdogRecoveryAction -Action 'QUIESCE_MAX' -Reason $integrityState.detail `
                    -StopPrimary { Stop-PrimaryAndAcquireControllerLease } -RequestMax { Set-EmergencyMax } `
                    -ReleasePrimary { param($lease) Release-ControllerLease -Lease $lease } -StartPrimary { Start-TrustedPrimaryTask }
                Write-WatchdogEvent 'integrity_failure_max_left_active' "$($integrityState.detail); outcome=$($integrityDispatch.outcome); $($integrityDispatch.detail)"
                Start-Sleep -Seconds 20
                continue
            }

            $task = Get-ScheduledTask -TaskName $PrimaryTaskName -ErrorAction SilentlyContinue
            $health = Get-PrimaryStatusHealth -Configuration $integrityState.config
            $taskDefinitionValid = $task -and (Test-PrimaryTaskDefinition -Task $task)
            if ($task -and -not $taskDefinitionValid) {
                $pendingCount = 0
                $transientCount = 0
                $pendingClock.Reset()
                [void](Invoke-EmergencyRecovery -Reason 'Primary task definition was altered.')
            }
            else {
                $taskHealthy = $taskDefinitionValid -and $task.State -eq 'Running'
                $taskState = if ($task) { [string]$task.State } else { 'MISSING' }
                if (-not $taskHealthy) {
                    $pendingCount = 0
                    $transientCount = 0
                    $pendingClock.Reset()
                    [void](Invoke-EmergencyRecovery -Reason "Task state: $taskState; task definition valid: $taskDefinitionValid; heartbeat: $($health.detail)")
                }
                elseif ($health.disposition -eq 'REASSERT_PENDING') {
                    if ($pendingCount -eq 0) { $pendingClock.Restart() }
                    $pendingElapsed = $pendingClock.Elapsed.TotalSeconds
                    $decision = Get-HeartbeatRecoveryDecision -Disposition $health.disposition -PreviousPendingCount $pendingCount `
                        -PendingElapsedSeconds $pendingElapsed -VerifyMaxAfterSeconds ([int]$integrityState.config.verifyMaxAfterSeconds)
                    $pendingCount = [int]$decision.nextPendingCount
                    if ($decision.action -eq 'WAIT_PRIMARY') {
                        $dispatch = Invoke-WatchdogRecoveryAction -Action $decision.action -Reason 'Primary MAX verification grace.' `
                            -StopPrimary { Stop-PrimaryAndAcquireControllerLease } -RequestMax { Set-EmergencyMax } `
                            -ReleasePrimary { param($lease) Release-ControllerLease -Lease $lease } -StartPrimary { Start-TrustedPrimaryTask }
                        Write-WatchdogEvent 'reassert_pending_primary_observing' "count=$pendingCount; elapsedSeconds=$([math]::Round($pendingElapsed,1)); verifySeconds=$([int]$integrityState.config.verifyMaxAfterSeconds); outcome=$($dispatch.outcome)"
                    }
                    else {
                        Write-WatchdogEvent 'reassert_pending_restart_threshold' "count=$pendingCount; elapsedSeconds=$([math]::Round($pendingElapsed,1)); verifySeconds=$([int]$integrityState.config.verifyMaxAfterSeconds)"
                        $dispatch = Invoke-EmergencyRecovery -Reason "Persistent heartbeat: $($health.detail)"
                        if ($dispatch.resetPending) {
                            $pendingCount = 0
                            $pendingClock.Reset()
                        }
                    }
                }
                elseif ($health.disposition -eq 'TRANSIENT') {
                    $pendingCount = 0
                    $pendingClock.Reset()
                    $decision = Get-HeartbeatRecoveryDecision -Disposition 'TRANSIENT' -PreviousPendingCount 0 `
                        -PendingElapsedSeconds 0 -VerifyMaxAfterSeconds ([int]$integrityState.config.verifyMaxAfterSeconds) `
                        -PreviousTransientCount $transientCount -TransientTolerance $TransientHeartbeatTolerance
                    $transientCount = [int]$decision.nextTransientCount
                    if ($decision.action -eq 'WAIT_PRIMARY') {
                        Write-WatchdogEvent 'heartbeat_unreadable_observing' "count=$transientCount; tolerance=$TransientHeartbeatTolerance; detail=$($health.detail)"
                    }
                    else {
                        Write-WatchdogEvent 'heartbeat_unreadable_threshold' "count=$transientCount; tolerance=$TransientHeartbeatTolerance; detail=$($health.detail)"
                        [void](Invoke-EmergencyRecovery -Reason "Unreadable heartbeat across $transientCount polls: $($health.detail)")
                        $transientCount = 0
                    }
                }
                elseif ($health.disposition -eq 'HEALTHY_VERIFIED') {
                    if ($pendingCount -gt 0) {
                        Write-WatchdogEvent 'reassert_pending_cleared' "count=$pendingCount; elapsedSeconds=$([math]::Round($pendingClock.Elapsed.TotalSeconds,1))"
                    }
                    if ($transientCount -gt 0) {
                        Write-WatchdogEvent 'heartbeat_unreadable_cleared' "count=$transientCount"
                    }
                    $pendingCount = 0
                    $transientCount = 0
                    $pendingClock.Reset()
                }
                else {
                    $pendingCount = 0
                    $transientCount = 0
                    $pendingClock.Reset()
                    [void](Invoke-EmergencyRecovery -Reason "Task state: $taskState; task definition valid: $taskDefinitionValid; heartbeat: $($health.detail)")
                }
            }
        }
        catch {
            $pendingCount = 0
            $transientCount = 0
            $pendingClock.Reset()
            [void](Invoke-EmergencyRecovery -Reason "Unhandled watchdog loop error: $($_.Exception.Message)")
        }
        Start-Sleep -Seconds $watchdogPollSeconds
    }
}
finally {
    try { $mutex.ReleaseMutex() } catch { }
    $mutex.Dispose()
}
