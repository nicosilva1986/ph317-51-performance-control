[CmdletBinding()]
param()

Set-StrictMode -Version Latest
$ErrorActionPreference = 'Stop'
$taskName = 'Acer Adaptive Fan Control'
$watchdogTaskName = 'Acer Adaptive Fan Watchdog'
$root = 'C:\ProgramData\AcerAdaptiveFanControl'
$statusPath = Join-Path $root 'adaptive-fan-status.json'
$watchdogLogPath = Join-Path $root 'watchdog.jsonl'
$resultPath = 'C:\Acer-Driver-Audit\FanControl\watchdog-recovery-live.json'

if (-not ([Security.Principal.WindowsPrincipal][Security.Principal.WindowsIdentity]::GetCurrent()).IsInRole(
    [Security.Principal.WindowsBuiltInRole]::Administrator
)) {
    $pwsh = Join-Path $PSHOME 'pwsh.exe'
    $process = Start-Process -FilePath $pwsh -Verb RunAs -WindowStyle Hidden -ArgumentList @(
        '-NoLogo', '-NoProfile', '-NonInteractive', '-ExecutionPolicy', 'Bypass', '-File', ('"' + $PSCommandPath + '"')
    ) -Wait -PassThru
    exit $process.ExitCode
}

function Set-EmergencyMax {
    $gaming = Get-CimInstance -Namespace 'root\wmi' -ClassName AcerGamingFunction | Select-Object -First 1
    if (-not $gaming) { throw 'AcerGamingFunction is unavailable.' }
    $null = Invoke-CimMethod -InputObject $gaming -MethodName SetGamingFanBehavior -Arguments @{ gmInput = [uint64]0x00820009 }
    $null = Invoke-CimMethod -InputObject $gaming -MethodName SetGamingFanSpeed -Arguments @{ gmInput = [uint64]0x00006401 }
    $null = Invoke-CimMethod -InputObject $gaming -MethodName SetGamingFanSpeed -Arguments @{ gmInput = [uint64]0x00006404 }
}

$started = [datetimeoffset]::Now
$result = [ordered]@{
    testedAt = $started.ToString('o')
    taskStopped = $false
    watchdogStayedRunning = $false
    primaryRestarted = $false
    healthyMaxRecovered = $false
    recoveryMilliseconds = $null
    finalStatus = $null
    error = $null
    status = 'FAILED'
}

try {
    $before = Get-Content -LiteralPath $statusPath -Raw | ConvertFrom-Json
    if ([string]$before.status -ne 'HEALTHY_VERIFIED' -or [string]$before.state -ne 'MAX') {
        throw "Unsafe test precondition: $($before.status)/$($before.state)."
    }
    $watchdog = Get-ScheduledTask -TaskName $watchdogTaskName
    if ($watchdog.State -ne 'Running') { throw "Watchdog is not running: $($watchdog.State)." }

    Stop-ScheduledTask -TaskName $taskName
    $result.taskStopped = $true

    $deadline = [datetimeoffset]::Now.AddSeconds(35)
    while ([datetimeoffset]::Now -lt $deadline) {
        Start-Sleep -Milliseconds 500
        $watchdog = Get-ScheduledTask -TaskName $watchdogTaskName
        $primary = Get-ScheduledTask -TaskName $taskName
        $result.watchdogStayedRunning = $watchdog.State -eq 'Running'
        if ($primary.State -ne 'Running') { continue }

        try {
            $status = Get-Content -LiteralPath $statusPath -Raw | ConvertFrom-Json
            $updated = [datetimeoffset]::Parse([string]$status.updatedAt, [Globalization.CultureInfo]::InvariantCulture)
            $mode = ([uint32]$status.fanBehaviorBitmap -shr 8) -band 3
            $fresh = $updated -gt $started
            $healthy = [string]$status.status -eq 'HEALTHY_VERIFIED' -and [string]$status.state -eq 'MAX' -and
                $mode -eq 2 -and [int]$status.cpuFanRpm -ge 5000 -and [int]$status.gpuFanRpm -ge 5000
            if ($fresh -and $healthy) {
                $result.primaryRestarted = $true
                $result.healthyMaxRecovered = $true
                $result.recoveryMilliseconds = [int]([datetimeoffset]::Now - $started).TotalMilliseconds
                $result.finalStatus = $status
                break
            }
        }
        catch { }
    }

    $logEvidence = $false
    if (Test-Path -LiteralPath $watchdogLogPath) {
        foreach ($line in @(Get-Content -LiteralPath $watchdogLogPath -Tail 50)) {
            try {
                $record = $line | ConvertFrom-Json
                $recordTime = if ($record.timestamp -is [datetime]) {
                    [datetimeoffset]$record.timestamp
                }
                else {
                    [datetimeoffset]::Parse([string]$record.timestamp, [Globalization.CultureInfo]::InvariantCulture, [Globalization.DateTimeStyles]::RoundtripKind)
                }
                if ([string]$record.event -eq 'primary_restarted' -and $recordTime -ge $started) {
                    $logEvidence = $true
                    break
                }
            }
            catch { }
        }
    }
    if (-not $result.primaryRestarted -or -not $result.healthyMaxRecovered -or -not $result.watchdogStayedRunning -or -not $logEvidence) {
        throw 'Watchdog recovery did not satisfy task, heartbeat, MAX RPM, and log evidence gates.'
    }
    $result.status = 'PASS'
}
catch {
    $result.error = $_.Exception.Message
    try { Set-EmergencyMax } catch { }
    try { Start-ScheduledTask -TaskName $taskName } catch { }
}
finally {
    [IO.File]::WriteAllText($resultPath, ($result | ConvertTo-Json -Depth 8), [Text.UTF8Encoding]::new($false))
}

if ($result.status -eq 'PASS') { exit 0 }
exit 1
