#requires -Version 5.1

[CmdletBinding()]
param()

Set-StrictMode -Version Latest
$ErrorActionPreference = 'Stop'

$script:AssertionCount = 0

function Assert-True {
    param(
        [Parameter(Mandatory = $true)][bool]$Condition,
        [Parameter(Mandatory = $true)][string]$Message
    )

    $script:AssertionCount++
    if (-not $Condition) { throw "ASSERTION FAILED: $Message" }
}

function Test-ByteArrayEqual {
    param(
        [Parameter(Mandatory = $true)][byte[]]$Left,
        [Parameter(Mandatory = $true)][byte[]]$Right
    )

    if ($Left.Length -ne $Right.Length) { return $false }
    for ($index = 0; $index -lt $Left.Length; $index++) {
        if ($Left[$index] -ne $Right[$index]) { return $false }
    }
    return $true
}

function Write-TestJson {
    param(
        [Parameter(Mandatory = $true)][string]$Path,
        [Parameter(Mandatory = $true)][object]$Value
    )

    $encoding = New-Object System.Text.UTF8Encoding($false)
    [System.IO.File]::WriteAllText($Path, ($Value | ConvertTo-Json -Depth 20), $encoding)
}

function New-TestCandidate {
    param(
        [Parameter(Mandatory = $true)][string]$Id,
        [string]$RecordType = 'sample',
        [object]$Status = $null,
        [object]$Cpu = $null,
        [object]$Gpu = $null,
        [object]$Marker = $null,
        [object]$Whea = $null,
        [object]$Hypothesis = $null,
        [string[]]$Errors = @()
    )

    return [ordered]@{
        sessionId = $Id; sampleIndex = 0; timestampUtc = [datetime]::UtcNow
        recordType = $RecordType; status = $Status; cpu = $Cpu; gpu = $Gpu
        marker = $Marker; whea = $Whea; hypothesis = $Hypothesis; errors = $Errors
    }
}

function Wait-Until {
    param(
        [Parameter(Mandatory = $true)][scriptblock]$Condition,
        [int]$TimeoutSeconds = 10
    )

    $watch = [System.Diagnostics.Stopwatch]::StartNew()
    while ($watch.Elapsed.TotalSeconds -lt $TimeoutSeconds) {
        if (& $Condition) { return $true }
        Start-Sleep -Milliseconds 100
    }
    return $false
}

$repositoryRoot = Split-Path -Parent $PSScriptRoot
$telemetryScript = Join-Path $repositoryRoot 'src\powershell\telemetry\Invoke-LimitTelemetry.ps1'
Assert-True -Condition (Test-Path -LiteralPath $telemetryScript -PathType Leaf) -Message 'Telemetry script is present.'

$testRoot = Join-Path ([System.IO.Path]::GetTempPath()) ('predator-limit-telemetry-test-' + [guid]::NewGuid().ToString('N'))
$telemetryRoot = Join-Path $testRoot 'telemetry'
$rotationRoot = Join-Path $testRoot 'rotation'
[System.IO.Directory]::CreateDirectory($testRoot) | Out-Null
[System.IO.Directory]::CreateDirectory($telemetryRoot) | Out-Null
[System.IO.Directory]::CreateDirectory($rotationRoot) | Out-Null
$env:PREDATOR_TELEMETRY_TEST_HOOK = '1'
$startedSession = $null

try {
    . $telemetryScript -Action Run -InternalTestHook

    $delay = Get-NextSampleDelayMilliseconds -LastSampleStartedMilliseconds 2000 -NowMilliseconds 2500 -IntervalMilliseconds 2000
    Assert-True -Condition ($delay -eq 1500) -Message 'Monotonic scheduling subtracts provider work from the interval.'
    $overdueDelay = Get-NextSampleDelayMilliseconds -LastSampleStartedMilliseconds 2000 -NowMilliseconds 4500 -IntervalMilliseconds 2000
    Assert-True -Condition ($overdueDelay -eq 0) -Message 'An overdue sample does not add naive sleep drift.'
    $nextDelay = Get-NextSampleDelayMilliseconds -LastSampleStartedMilliseconds 4500 -NowMilliseconds 4600 -IntervalMilliseconds 2000
    Assert-True -Condition ($nextDelay -eq 1900) -Message 'After an overdue sample, the next start cannot occur faster than the interval.'

    $missingStatus = Get-StatusSnapshot -Path (Join-Path $testRoot 'missing-status.json')
    Assert-True -Condition ($missingStatus.statusError -eq 'status_missing' -and $null -eq $missingStatus.cpuTempC) -Message 'A missing status file degrades to null values and a category.'

    $corruptStatusPath = Join-Path $testRoot 'corrupt-status.json'
    [System.IO.File]::WriteAllText($corruptStatusPath, '{not-json', (New-Object System.Text.UTF8Encoding($false)))
    $corruptStatus = Get-StatusSnapshot -Path $corruptStatusPath
    Assert-True -Condition ($corruptStatus.statusError -eq 'status_invalid_json') -Message 'Corrupt status JSON degrades without aborting.'

    $lockedStatusPath = Join-Path $testRoot 'locked-status.json'
    [System.IO.File]::WriteAllText($lockedStatusPath, '{}', (New-Object System.Text.UTF8Encoding($false)))
    $lockedStream = [System.IO.File]::Open($lockedStatusPath, [System.IO.FileMode]::Open, [System.IO.FileAccess]::ReadWrite, [System.IO.FileShare]::None)
    try { $lockedStatus = Get-StatusSnapshot -Path $lockedStatusPath }
    finally { $lockedStream.Dispose() }
    Assert-True -Condition ($lockedStatus.statusError -eq 'status_locked') -Message 'A lock that denies sharing degrades to a locked category.'

    $validStatusPath = Join-Path $testRoot 'status-source.json'
    $statusFixture = [ordered]@{
        state = 'AUTO'; cpuFanRpm = 2100; gpuFanRpm = 2200; cpuTempC = 71; gpuTempC = 63
        updatedAt = [datetime]::UtcNow.AddSeconds(-2).ToString('o'); ignoredPath = 'C:\Users\Example\private.txt'; unknownText = 'private'
    }
    Write-TestJson -Path $validStatusPath -Value $statusFixture
    $validBytesBefore = [System.IO.File]::ReadAllBytes($validStatusPath)
    $validTimeBefore = (Get-Item -LiteralPath $validStatusPath).LastWriteTimeUtc
    $validStatus = Get-StatusSnapshot -Path $validStatusPath
    Assert-True -Condition ($validStatus.fanMode -eq 'AUTO' -and $validStatus.cpuFanRpm -eq 2100) -Message 'Only whitelisted status values are retained.'
    Assert-True -Condition ($validStatus.PSObject.Properties.Name -notcontains 'ignoredPath') -Message 'Unknown status fields are dropped.'

    $script:TestFixture = [pscustomobject][ordered]@{ gpuAbsent = $true }
    $absentGpu = Get-GpuSnapshot -SampleNumber 0
    Assert-True -Condition ($absentGpu.errorCategory -eq 'gpu_command_missing' -and $null -eq $absentGpu.powerDrawW) -Message 'Missing GPU tooling fails soft.'
    $gpuLine = '0, 95, 30, 1700, 4000, 105.5, 120.0, 82, Active, Not Active, Not Active, Active, Not Active, Not Active, Not Active, Not Active'
    $script:TestFixture = [pscustomobject][ordered]@{ gpuLines = @($gpuLine); gpuExitAtSample = 1 }
    $liveGpu = Get-GpuSnapshot -SampleNumber 0
    $deadGpu = Get-GpuSnapshot -SampleNumber 1
    Assert-True -Condition ($liveGpu.powerDrawW -eq 105.5 -and $liveGpu.throttle.softwarePowerCap) -Message 'Fake GPU stdout is parsed through the production CSV parser.'
    Assert-True -Condition ($deadGpu.errorCategory -eq 'gpu_process_exited') -Message 'A GPU process dying mid-session degrades the next sample.'
    $baseGpu = ConvertFrom-NvidiaCsvLine -Line '0, 50, 20, 1400, 3500, 80, 120, 70'
    Assert-True -Condition ($baseGpu.powerDrawW -eq 80 -and $null -eq $baseGpu.throttle) -Message 'The fallback query accepts builds without throttle-reason fields.'

    $script:TestFixture = [pscustomobject][ordered]@{ wheaStart = [ordered]@{ errorCategory = 'whea_query_failed' } }
    $failedWhea = Get-WheaSnapshot -StartUtc ([datetime]::UtcNow.AddSeconds(-1)) -EndUtc ([datetime]::UtcNow) -MaximumEvents 10 -Phase start
    Assert-True -Condition ($failedWhea.errorCategory -eq 'whea_query_failed' -and @($failedWhea.counts).Count -eq 0) -Message 'WHEA query failure degrades to an empty aggregate snapshot.'
    $cpuWithoutOptionalCounters = ConvertTo-CpuSnapshot -PerformanceRows @([pscustomobject][ordered]@{ Name = '_Total'; PercentProcessorPerformance = 100; PercentProcessorTime = 50; PercentIdleTime = 50; ProcessorFrequency = 2800 }) -ProcessorRow ([pscustomobject][ordered]@{ MaxClockSpeed = 2800; CurrentClockSpeed = 2800; NumberOfCores = 4; NumberOfLogicalProcessors = 8 }) -ErrorCategory $null
    Assert-True -Condition ($null -eq $cpuWithoutOptionalCounters.total.percentPerformanceLimit -and $null -eq $cpuWithoutOptionalCounters.total.performanceLimitFlags) -Message 'Absent performance-limit counter properties remain null.'
    $script:TestFixture = $null

    $thermal = Get-LimitReasonHypothesis -EffectiveRatio 31 -StockEnvelopeRatio 34 -CpuTemperatureC 96 -CpuLoadPct 95 -GpuUtilizationPct 0 -GpuTemperatureC 40 -GpuPowerDrawW 10 -GpuPowerLimitW 100 -PerformanceLimitPct 0
    $power = Get-LimitReasonHypothesis -EffectiveRatio 30 -StockEnvelopeRatio 34 -CpuTemperatureC 75 -CpuLoadPct 95 -GpuUtilizationPct 10 -GpuTemperatureC 50 -GpuPowerDrawW 20 -GpuPowerLimitW 120 -PerformanceLimitPct 10
    $gpu = Get-LimitReasonHypothesis -EffectiveRatio 34 -StockEnvelopeRatio 34 -CpuTemperatureC 70 -CpuLoadPct 30 -GpuUtilizationPct 95 -GpuTemperatureC 82 -GpuPowerDrawW 110 -GpuPowerLimitW 120 -PerformanceLimitPct 0
    $ratioCap = Get-LimitReasonHypothesis -EffectiveRatio 28 -StockEnvelopeRatio 34 -CpuTemperatureC 70 -CpuLoadPct 95 -GpuUtilizationPct 0 -GpuTemperatureC 40 -GpuPowerDrawW 10 -GpuPowerLimitW 120 -PerformanceLimitPct 0
    $unknown = Get-LimitReasonHypothesis -EffectiveRatio $null -StockEnvelopeRatio $null -CpuTemperatureC $null -CpuLoadPct $null -GpuUtilizationPct $null -GpuTemperatureC $null -GpuPowerDrawW $null -GpuPowerLimitW $null -PerformanceLimitPct $null
    Assert-True -Condition ($thermal.limitReasonHypothesis -eq 'thermal') -Message 'Thermal v0 heuristic is deterministic.'
    Assert-True -Condition ($power.limitReasonHypothesis -eq 'power') -Message 'Power v0 heuristic is deterministic.'
    Assert-True -Condition ($gpu.limitReasonHypothesis -eq 'gpu') -Message 'GPU v0 heuristic is deterministic.'
    Assert-True -Condition ($ratioCap.limitReasonHypothesis -eq 'ratio_cap') -Message 'Ratio-cap v0 heuristic is deterministic.'
    Assert-True -Condition ($unknown.limitReasonHypothesis -eq 'unknown' -and $unknown.confidence -eq 'low' -and $unknown.kind -eq 'hypothesis') -Message 'Null input defaults to a low-confidence unknown hypothesis.'
    Assert-True -Condition ($unknown.disclaimer -eq 'Heuristic hypothesis, not a measured limit cause.') -Message 'Every hypothesis carries the required disclaimer.'

    $privateValues = @(
        [string]$env:USERNAME,
        [string]$env:COMPUTERNAME,
        '01234567-89ab-4cde-8f01-23456789abcd',
        '00000000:01:00.0',
        'PCI\VEN_10DE&DEV_1C20\PRIVATE',
        'SERIAL-2026-12345678',
        'C:\Users\Example\private.txt',
        '\\server\share\private.txt',
        '/home/example/private.txt'
    )
    $sanitizerId = [guid]::NewGuid().ToString('N')
    $sanitized = ConvertTo-SanitizedTelemetryRecord -InputObject (New-TestCandidate -Id $sanitizerId -Status ([ordered]@{ fanMode = 'AUTO'; statusError = $privateValues[0] }) -Hypothesis $unknown -Errors $privateValues)
    $serializedSanitized = $sanitized | ConvertTo-Json -Depth 20 -Compress
    Assert-True -Condition ($sanitized.redactions.record -ge 9) -Message 'The sanitizer counts identifier, path, UUID, PCI, and serial redactions.'
    foreach ($privateValue in $privateValues) {
        Assert-True -Condition ($serializedSanitized.IndexOf($privateValue, [System.StringComparison]::OrdinalIgnoreCase) -lt 0) -Message 'A private value does not survive sanitizer output.'
    }
    $candidateWithUnknown = New-TestCandidate -Id $sanitizerId -Status ([ordered]@{ fanMode = 'AUTO'; unknownProperty = 'must-drop' }) -Hypothesis $unknown
    $unknownDropped = ConvertTo-SanitizedTelemetryRecord -InputObject $candidateWithUnknown
    Assert-True -Condition ($unknownDropped.status.PSObject.Properties.Name -notcontains 'unknownProperty') -Message 'The central sanitizer drops non-whitelisted properties.'

    $rotationId = [guid]::NewGuid().ToString('N')
    Write-SessionStateUnsafe -Directory $rotationRoot -State ([pscustomobject][ordered]@{ sessionId = $rotationId; status = 'running'; processId = 0; nextSampleIndex = 0; startedAtUtc = [datetime]::UtcNow.ToString('o'); stoppedAtUtc = $null; lastRecordType = $null })
    foreach ($number in 1..12) {
        $rotationCandidate = New-TestCandidate -Id $rotationId -RecordType marker -Marker ([ordered]@{ label = ('rotation-' + $number) }) -Hypothesis $unknown
        Write-TelemetryRecord -Directory $rotationRoot -Id $rotationId -Candidate $rotationCandidate -MaximumBytes 1024 -Retention 3 | Out-Null
    }
    $rotatedLogs = @(Get-ChildItem -LiteralPath $rotationRoot -File | Where-Object { $_.Name -like "session-$rotationId.jsonl*" })
    Assert-True -Condition ($rotatedLogs.Count -le 3 -and $rotatedLogs.Count -ge 2) -Message 'Size rotation retains a bounded number of files.'
    foreach ($rotatedLog in $rotatedLogs) {
        foreach ($line in [System.IO.File]::ReadAllLines($rotatedLog.FullName)) {
            if (-not [string]::IsNullOrWhiteSpace($line)) { $line | ConvertFrom-Json -ErrorAction Stop | Out-Null }
        }
    }
    Assert-True -Condition (@(Get-ChildItem -LiteralPath $testRoot -File | Where-Object { $_.Name -like "session-$rotationId*" }).Count -eq 0) -Message 'Rotation writes do not escape the telemetry directory.'

    $fixturePath = Join-Path $testRoot 'provider-fixture.json'
    $fixture = [ordered]@{
        statusSamples = @([ordered]@{ fanMode = 'AUTO'; cpuFanRpm = 2100; gpuFanRpm = 2200; cpuTempC = 70; gpuTempC = 62; timestampAgeSeconds = 1; statusError = $null })
        cpuSamples = @([ordered]@{
                performanceRows = @(
                    [ordered]@{ Name = '0,0'; PercentProcessorPerformance = 121; PercentProcessorTime = 80; PercentIdleTime = 20; ProcessorFrequency = 2800; PercentofMaximumFrequency = 121; PercentPerformanceLimit = 0; PerformanceLimitFlags = 0 },
                    [ordered]@{ Name = '0,1'; PercentProcessorPerformance = 121; PercentProcessorTime = 80; PercentIdleTime = 20; ProcessorFrequency = 2800; PercentofMaximumFrequency = 121; PercentPerformanceLimit = 0; PerformanceLimitFlags = 0 },
                    [ordered]@{ Name = '_Total'; PercentProcessorPerformance = 121; PercentProcessorTime = 80; PercentIdleTime = 20; ProcessorFrequency = 2800; PercentofMaximumFrequency = 121; PercentPerformanceLimit = 0; PerformanceLimitFlags = 0 }
                )
                processor = [ordered]@{ MaxClockSpeed = 2800; CurrentClockSpeed = 2800; NumberOfCores = 4; NumberOfLogicalProcessors = 8 }
            })
        gpuLines = @($gpuLine)
        wheaStart = [ordered]@{ events = @([ordered]@{ Id = 17; Level = 2; TimeCreated = '2026-08-22T12:00:00Z' }) }
        wheaEnd = [ordered]@{ events = @(
                [ordered]@{ Id = 17; Level = 2; TimeCreated = '2026-08-22T12:00:00Z' },
                [ordered]@{ Id = 17; Level = 2; TimeCreated = '2026-08-22T12:00:01Z' }
            ) }
    }
    Write-TestJson -Path $fixturePath -Value $fixture
    $scriptBytesBefore = [System.IO.File]::ReadAllBytes($telemetryScript)
    $scriptTimeBefore = (Get-Item -LiteralPath $telemetryScript).LastWriteTimeUtc
    $outsideFilesBefore = @(Get-ChildItem -LiteralPath $testRoot -File | ForEach-Object Name | Sort-Object)

    $startWatch = [System.Diagnostics.Stopwatch]::StartNew()
    $startedSession = & $telemetryScript -Action Start -DurationSeconds 30 -IntervalSeconds 1 -StatusPath $validStatusPath -LogPath $telemetryRoot -MaxLogBytes 1048576 -MaxLogFiles 3 -WheaMaxEvents 10 -TestFixturePath $fixturePath
    $startWatch.Stop()
    Assert-True -Condition (-not [string]::IsNullOrWhiteSpace([string]$startedSession.sessionId)) -Message 'Start returns an opaque session id.'
    Assert-True -Condition ($startWatch.Elapsed.TotalSeconds -lt 5) -Message 'Start returns without waiting for the detached sampling duration.'
    Assert-True -Condition ([string]$startedSession.logPath -eq (Join-Path $telemetryRoot ("session-$($startedSession.sessionId).jsonl"))) -Message 'Start returns the active log path and exits.'
    $runningObserved = Wait-Until -TimeoutSeconds 12 -Condition {
        $statePath = Join-Path $telemetryRoot 'active-session.json'
        if (-not (Test-Path -LiteralPath $statePath -PathType Leaf)) { return $false }
        try { $state = [System.IO.File]::ReadAllText($statePath) | ConvertFrom-Json; return $state.status -eq 'running' -and (Test-Path -LiteralPath $startedSession.logPath -PathType Leaf) } catch { return $false }
    }
    Assert-True -Condition $runningObserved -Message 'Detached Run enters running state and produces a mocked sample.'

    $markerRecord = & $telemetryScript -Action Mark -Label 'fma-start' -LogPath $telemetryRoot -MaxLogBytes 1048576 -MaxLogFiles 3
    Assert-True -Condition ($markerRecord.recordType -eq 'marker' -and $markerRecord.marker.label -eq 'fma-start') -Message 'Mark appends a validated label record.'
    $invalidMarkerRejected = $false
    try { & $telemetryScript -Action Mark -Label 'private free form' -LogPath $telemetryRoot | Out-Null }
    catch { $invalidMarkerRejected = $true }
    Assert-True -Condition $invalidMarkerRejected -Message 'Marker labels reject free-form text.'

    $stopResult = & $telemetryScript -Action Stop -LogPath $telemetryRoot -GracePeriodSeconds 12
    Assert-True -Condition $stopResult.finalized -Message 'Stop waits for bounded finalization.'
    $startedSession = $null
    $lines = [System.IO.File]::ReadAllLines($stopResult.logPath)
    Assert-True -Condition ($lines.Count -ge 3) -Message 'Lifecycle writes sample, marker, and final records.'
    $logBytes = [System.IO.File]::ReadAllBytes($stopResult.logPath)
    Assert-True -Condition (0x0D -notin $logBytes) -Message 'JSONL output uses LF line endings.'
    Assert-True -Condition (-not ($logBytes.Length -ge 3 -and $logBytes[0] -eq 0xEF -and $logBytes[1] -eq 0xBB -and $logBytes[2] -eq 0xBF)) -Message 'JSONL output is UTF-8 without BOM.'
    $parsedRecords = @($lines | ForEach-Object { $_ | ConvertFrom-Json -ErrorAction Stop })
    for ($recordIndex = 0; $recordIndex -lt $parsedRecords.Count; $recordIndex++) {
        Assert-True -Condition ([int64]$parsedRecords[$recordIndex].sampleIndex -eq $recordIndex) -Message 'Sample indexes remain monotonic across concurrent marker writes.'
    }
    Assert-True -Condition ($parsedRecords[-1].recordType -eq 'final' -and $null -ne $parsedRecords[-1].whea.end) -Message 'The final record contains the ending WHEA aggregate snapshot.'

    $summaryJson = & $telemetryScript -Action Summarize -InputPath $stopResult.logPath
    $summary = $summaryJson | ConvertFrom-Json -ErrorAction Stop
    Assert-True -Condition ($summary.sampleCounts.samples -ge 1 -and $summary.sampleCounts.markers -eq 1) -Message 'Summarize reports sample and marker counts.'
    Assert-True -Condition ($summary.effectiveRatio.count -ge 1 -and $summary.gpuPowerW.mean -eq 105.5) -Message 'Summarize emits compact numeric statistics.'
    Assert-True -Condition ($summary.wheaDelta[0].delta -eq 1) -Message 'Summarize calculates WHEA aggregate delta.'
    Assert-True -Condition ($null -ne $summary.hypothesisDistribution) -Message 'Summarize emits the hypothesis distribution.'

    $validBytesAfter = [System.IO.File]::ReadAllBytes($validStatusPath)
    $validTimeAfter = (Get-Item -LiteralPath $validStatusPath).LastWriteTimeUtc
    Assert-True -Condition (Test-ByteArrayEqual -Left $validBytesBefore -Right $validBytesAfter) -Message 'The status file remains byte-identical.'
    Assert-True -Condition ($validTimeBefore -eq $validTimeAfter) -Message 'The status file modification time remains unchanged.'
    $scriptBytesAfter = [System.IO.File]::ReadAllBytes($telemetryScript)
    $scriptTimeAfter = (Get-Item -LiteralPath $telemetryScript).LastWriteTimeUtc
    Assert-True -Condition (Test-ByteArrayEqual -Left $scriptBytesBefore -Right $scriptBytesAfter) -Message 'No repository file is written during lifecycle tests.'
    Assert-True -Condition ($scriptTimeBefore -eq $scriptTimeAfter) -Message 'The repository script modification time remains unchanged.'
    $outsideFilesAfter = @(Get-ChildItem -LiteralPath $testRoot -File | ForEach-Object Name | Sort-Object)
    Assert-True -Condition (($outsideFilesBefore -join '|') -eq ($outsideFilesAfter -join '|')) -Message 'No new file is written outside the telemetry directory.'

    Write-Output "PASS Test-InvokeLimitTelemetry ($script:AssertionCount assertions)"
}
finally {
    if ($null -ne $startedSession) {
        $statePath = Join-Path $telemetryRoot 'active-session.json'
        if (Test-Path -LiteralPath $statePath -PathType Leaf) {
            try {
                $state = [System.IO.File]::ReadAllText($statePath) | ConvertFrom-Json
                $stopPath = Join-Path $telemetryRoot ("session-$($state.sessionId).stop")
                [System.IO.File]::WriteAllText($stopPath, "stop`n", (New-Object System.Text.UTF8Encoding($false)))
                Start-Sleep -Seconds 2
            }
            catch { }
        }
    }
    Remove-Item Env:\PREDATOR_TELEMETRY_TEST_HOOK -ErrorAction SilentlyContinue
    if (Test-Path -LiteralPath $testRoot) { [System.IO.Directory]::Delete($testRoot, $true) }
}
