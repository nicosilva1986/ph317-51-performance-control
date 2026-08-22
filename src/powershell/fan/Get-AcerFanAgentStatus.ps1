[CmdletBinding()]
param(
    [string] $Root = 'C:\ProgramData\AcerAdaptiveFanControl',
    [ValidateRange(5, 300)]
    [int] $MaximumHeartbeatAgeSeconds = 30,
    [ValidateRange(1, 256)]
    [int] $WatchdogTailLines = 64,
    [switch] $FailOnUnhealthy
)

Set-StrictMode -Version Latest
$ErrorActionPreference = 'Stop'

function Read-BoundedJsonFile {
    param(
        [Parameter(Mandatory)] [string] $Path,
        [ValidateRange(1, 1048576)] [int] $MaximumBytes = 65536
    )

    $item = Get-Item -LiteralPath $Path -ErrorAction Stop
    if ([long]$item.Length -gt $MaximumBytes) {
        throw [InvalidDataException]::new('JSON input exceeds its fixed size limit.')
    }

    return Get-Content -LiteralPath $Path -Raw -Encoding UTF8 | ConvertFrom-Json
}

function Test-Sha256Text {
    param([AllowNull()] [object] $Value)
    return ([string]$Value -match '\A[0-9A-Fa-f]{64}\z')
}

function Get-LatestWatchdogRecord {
    param([Parameter(Mandatory)] [string] $Path)

    if (-not (Test-Path -LiteralPath $Path -PathType Leaf)) { return $null }
    $lines = @(Get-Content -LiteralPath $Path -Tail $WatchdogTailLines -Encoding UTF8)
    for ($index = $lines.Count - 1; $index -ge 0; $index--) {
        try {
            $record = $lines[$index] | ConvertFrom-Json -ErrorAction Stop
            if ($record.PSObject.Properties.Name -contains 'event' -and
                $record.PSObject.Properties.Name -contains 'timestamp') {
                return $record
            }
        }
        catch {
            # A torn final JSONL record is ignored; earlier bounded records remain usable.
        }
    }
    return $null
}

function New-UnavailableResult {
    param([Parameter(Mandatory)] [string] $ReasonCode)
    return [ordered]@{
        schemaVersion = 1
        observedAt = [DateTimeOffset]::Now.ToString('o')
        source = 'published_read_only_evidence'
        privilegedTaskQuery = 'NOT_ATTEMPTED_BY_DESIGN'
        conclusion = 'UNAVAILABLE'
        reasonCode = $ReasonCode
        controller = $null
        watchdog = $null
    }
}

$result = $null
$exitCode = 0

try {
    $resolvedRoot = [IO.Path]::GetFullPath($Root)
    if (-not (Test-Path -LiteralPath $resolvedRoot -PathType Container)) {
        $result = New-UnavailableResult -ReasonCode 'PUBLISHED_ROOT_MISSING'
    }
    else {
        $statusPath = Join-Path $resolvedRoot 'adaptive-fan-status.json'
        $integrityPath = Join-Path $resolvedRoot 'integrity.json'
        $watchdogLogPath = Join-Path $resolvedRoot 'watchdog.jsonl'

        if (-not (Test-Path -LiteralPath $statusPath -PathType Leaf)) {
            $result = New-UnavailableResult -ReasonCode 'STATUS_MISSING'
        }
        elseif (-not (Test-Path -LiteralPath $integrityPath -PathType Leaf)) {
            $result = New-UnavailableResult -ReasonCode 'INTEGRITY_MISSING'
        }
        else {
            $status = Read-BoundedJsonFile -Path $statusPath
            $integrity = Read-BoundedJsonFile -Path $integrityPath
            $updatedAt = [DateTimeOffset]::Parse([string]$status.updatedAt, [Globalization.CultureInfo]::InvariantCulture)
            $ageSeconds = [Math]::Max(0, [Math]::Round(([DateTimeOffset]::Now - $updatedAt).TotalSeconds, 1))

            $hashMap = [ordered]@{
                controller = 'AcerAdaptiveFanController.ps1'
                config = 'fan-controller-config.json'
                watchdog = 'AcerFanWatchdog.ps1'
            }
            $integrityVerified = $true
            foreach ($propertyName in $hashMap.Keys) {
                $expected = $integrity.$propertyName
                $artifactPath = Join-Path $resolvedRoot $hashMap[$propertyName]
                if (-not (Test-Sha256Text $expected) -or
                    -not (Test-Path -LiteralPath $artifactPath -PathType Leaf) -or
                    (Get-FileHash -LiteralPath $artifactPath -Algorithm SHA256).Hash -ine [string]$expected) {
                    $integrityVerified = $false
                }
            }

            $lastWatchdog = Get-LatestWatchdogRecord -Path $watchdogLogPath
            $watchdogResult = $null
            if ($null -ne $lastWatchdog) {
                $watchdogAt = [DateTimeOffset]::Parse([string]$lastWatchdog.timestamp, [Globalization.CultureInfo]::InvariantCulture)
                $watchdogResult = [ordered]@{
                    lastEvent = [string]$lastWatchdog.event
                    lastEventAt = $watchdogAt.ToString('o')
                    lastEventAgeSeconds = [Math]::Max(0, [Math]::Round(([DateTimeOffset]::Now - $watchdogAt).TotalSeconds, 1))
                }
            }

            $heartbeatFresh = $ageSeconds -le $MaximumHeartbeatAgeSeconds
            $healthCode = [string]$status.status
            $healthy = $heartbeatFresh -and $integrityVerified -and $healthCode -eq 'HEALTHY_VERIFIED'
            $result = [ordered]@{
                schemaVersion = 1
                observedAt = [DateTimeOffset]::Now.ToString('o')
                source = 'published_read_only_evidence'
                privilegedTaskQuery = 'NOT_ATTEMPTED_BY_DESIGN'
                conclusion = if ($healthy) { 'HEALTHY' } else { 'ATTENTION_REQUIRED' }
                reasonCode = if (-not $heartbeatFresh) { 'HEARTBEAT_STALE' } elseif (-not $integrityVerified) { 'INTEGRITY_MISMATCH' } elseif ($healthCode -ne 'HEALTHY_VERIFIED') { 'CONTROLLER_NOT_VERIFIED' } else { 'NONE' }
                controller = [ordered]@{
                    healthCode = $healthCode
                    state = [string]$status.state
                    heartbeatAt = $updatedAt.ToString('o')
                    heartbeatAgeSeconds = $ageSeconds
                    heartbeatFresh = $heartbeatFresh
                    integrityVerified = $integrityVerified
                    cpuTempC = [int]$status.cpuTempC
                    gpuTempC = [int]$status.gpuTempC
                    cpuLoadPct = [int]$status.cpuLoadPct
                    cpuFanRpm = [int]$status.cpuFanRpm
                    gpuFanRpm = [int]$status.gpuFanRpm
                }
                watchdog = $watchdogResult
            }
        }
    }
}
catch [UnauthorizedAccessException] {
    $result = New-UnavailableResult -ReasonCode 'PUBLISHED_EVIDENCE_NOT_READABLE'
}
catch [System.Security.SecurityException] {
    $result = New-UnavailableResult -ReasonCode 'PUBLISHED_EVIDENCE_NOT_READABLE'
}
catch {
    $result = New-UnavailableResult -ReasonCode 'PUBLISHED_EVIDENCE_INVALID'
}

if ([string]$result.conclusion -ne 'HEALTHY' -and $FailOnUnhealthy) { $exitCode = 2 }
$result | ConvertTo-Json -Depth 6
if ($FailOnUnhealthy) { exit $exitCode }
