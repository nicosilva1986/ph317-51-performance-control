#requires -Version 5.1

<#
.SYNOPSIS
Collects sanitized, read-only CPU, GPU, fan-status, and WHEA telemetry.

.DESCRIPTION
Runs a foreground or detached sampling session without changing fan, power,
driver, firmware, service, task, registry, or controller state. Records pass
through one explicit-whitelist sanitizer before they reach a JSONL log.

.PARAMETER Action
Start a detached session, Run in the foreground, Mark the active log, Stop the
active session, or Summarize an existing JSONL file.

.PARAMETER DurationSeconds
Maximum foreground or detached session duration.

.PARAMETER IntervalSeconds
Sampling interval. Scheduling uses a monotonic Stopwatch and accounts for work
time so collection overhead does not accumulate as sleep drift.

.PARAMETER StatusPath
Read-only adaptive fan controller status JSON path.

.PARAMETER LogPath
Telemetry directory. The default is outside the repository under ProgramData.

.PARAMETER InputPath
Existing JSONL file to read for Summarize.

.PARAMETER Label
Validated marker label for Mark.

.PARAMETER MaxLogBytes
Maximum active JSONL file size before bounded rotation.

.PARAMETER MaxLogFiles
Maximum number of active plus rotated JSONL files retained for a session.

.PARAMETER GracePeriodSeconds
Maximum time Stop waits for foreground finalization.

.PARAMETER WheaMaxEvents
Maximum number of WHEA events read by each aggregate snapshot.

.PARAMETER InternalTestHook
Loads functions without dispatching an action. Accepted only while the
PREDATOR_TELEMETRY_TEST_HOOK environment guard is set to 1.

.PARAMETER TestFixturePath
Internal deterministic provider fixture. Accepted only under the same test
guard; live CIM, GPU, status, and event-log providers are bypassed.
#>

[CmdletBinding()]
param(
    [Parameter(Mandatory = $true)]
    [ValidateSet('Start', 'Run', 'Mark', 'Stop', 'Summarize')]
    [string]$Action,

    [Parameter()]
    [ValidateRange(1, 604800)]
    [int]$DurationSeconds = 3600,

    [Parameter()]
    [ValidateRange(1, 60)]
    [int]$IntervalSeconds = 2,

    [Parameter()]
    [ValidateNotNullOrEmpty()]
    [string]$StatusPath = 'C:\ProgramData\AcerAdaptiveFanControl\adaptive-fan-status.json',

    [Parameter()]
    [ValidateNotNullOrEmpty()]
    [string]$LogPath = (Join-Path $env:ProgramData 'PredatorLimitTelemetry'),

    [Parameter()]
    [ValidateNotNullOrEmpty()]
    [string]$InputPath,

    [Parameter()]
    [ValidatePattern('^[a-z0-9][a-z0-9._-]{0,63}$')]
    [string]$Label,

    [Parameter()]
    [ValidateRange(1024, 1073741824)]
    [long]$MaxLogBytes = 8388608,

    [Parameter()]
    [ValidateRange(1, 100)]
    [int]$MaxLogFiles = 5,

    [Parameter()]
    [ValidateRange(1, 120)]
    [int]$GracePeriodSeconds = 15,

    [Parameter()]
    [ValidateRange(1, 10000)]
    [int]$WheaMaxEvents = 512,

    [Parameter()]
    [ValidatePattern('^[a-f0-9]{32}$')]
    [string]$SessionId,

    [Parameter()]
    [switch]$InternalTestHook,

    [Parameter()]
    [ValidateNotNullOrEmpty()]
    [string]$TestFixturePath
)

Set-StrictMode -Version Latest
$ErrorActionPreference = 'Stop'

$script:TelemetrySchemaVersion = 1
$script:HypothesisDisclaimer = 'Heuristic hypothesis, not a measured limit cause.'
$script:Utf8NoBom = New-Object System.Text.UTF8Encoding($false)
$script:TestFixture = $null
$script:GpuProvider = $null
$script:CimSession = $null
$script:InvocationParameters = @{}
foreach ($invocationKey in $PSBoundParameters.Keys) {
    $script:InvocationParameters[$invocationKey] = $PSBoundParameters[$invocationKey]
}

function Get-OptionalValue {
    param(
        [object]$InputObject,
        [Parameter(Mandatory = $true)][string]$Name
    )

    if ($null -eq $InputObject) { return $null }
    if ($InputObject -is [System.Collections.IDictionary]) {
        if ($InputObject.Contains($Name)) { return $InputObject[$Name] }
        return $null
    }
    $property = $InputObject.PSObject.Properties[$Name]
    if ($null -eq $property) { return $null }
    return $property.Value
}

function ConvertTo-NullableDouble {
    param([object]$Value)

    if ($null -eq $Value -or [string]::IsNullOrWhiteSpace([string]$Value)) { return $null }
    try {
        $number = [convert]::ToDouble($Value, [System.Globalization.CultureInfo]::InvariantCulture)
        if ([double]::IsNaN($number) -or [double]::IsInfinity($number)) { return $null }
        return $number
    }
    catch { return $null }
}

function ConvertTo-NullableInt64 {
    param([object]$Value)

    $number = ConvertTo-NullableDouble -Value $Value
    if ($null -eq $number) { return $null }
    if ($number -lt [long]::MinValue -or $number -gt [long]::MaxValue) { return $null }
    return [long][math]::Round($number, 0)
}

function Get-ExactFileSystemPath {
    param(
        [Parameter(Mandatory = $true)][string]$Path,
        [switch]$MustExist
    )

    if ([string]::IsNullOrWhiteSpace($Path)) { throw 'A non-empty filesystem path is required.' }
    if ($Path.IndexOfAny([char[]]'*?[]') -ge 0) { throw 'Wildcard paths are not allowed.' }
    if ($MustExist) {
        $resolved = Resolve-Path -LiteralPath $Path -ErrorAction Stop
        if ($resolved.Provider.Name -ne 'FileSystem') { throw 'Only filesystem paths are allowed.' }
        return $resolved.ProviderPath
    }
    $provider = $null
    $drive = $null
    $unresolved = $ExecutionContext.SessionState.Path.GetUnresolvedProviderPathFromPSPath(
        $Path,
        [ref]$provider,
        [ref]$drive
    )
    if ($null -eq $provider -or $provider.Name -ne 'FileSystem') { throw 'Only filesystem paths are allowed.' }
    return $unresolved
}

function Resolve-TelemetryDirectory {
    param([Parameter(Mandatory = $true)][string]$Path)

    $resolved = Get-ExactFileSystemPath -Path $Path
    if (Test-Path -LiteralPath $resolved) {
        if (-not (Test-Path -LiteralPath $resolved -PathType Container)) {
            throw 'LogPath must name a directory.'
        }
    }
    else {
        [System.IO.Directory]::CreateDirectory($resolved) | Out-Null
    }
    $full = [System.IO.Path]::GetFullPath($resolved).TrimEnd([System.IO.Path]::DirectorySeparatorChar)
    $root = [System.IO.Path]::GetPathRoot($full).TrimEnd([System.IO.Path]::DirectorySeparatorChar)
    if ($full.Equals($root, [System.StringComparison]::OrdinalIgnoreCase)) {
        throw 'LogPath must not be a filesystem root.'
    }
    return $full
}

function Assert-PathInsideTelemetryDirectory {
    param(
        [Parameter(Mandatory = $true)][string]$Directory,
        [Parameter(Mandatory = $true)][string]$Candidate
    )

    $root = [System.IO.Path]::GetFullPath($Directory).TrimEnd([System.IO.Path]::DirectorySeparatorChar)
    $full = [System.IO.Path]::GetFullPath($Candidate)
    $parent = [System.IO.Path]::GetDirectoryName($full)
    if (-not $parent.Equals($root, [System.StringComparison]::OrdinalIgnoreCase)) {
        throw 'A telemetry write target escaped the resolved telemetry directory.'
    }
    return $full
}

function Get-StatePath {
    param([Parameter(Mandatory = $true)][string]$Directory)
    return Assert-PathInsideTelemetryDirectory -Directory $Directory -Candidate (Join-Path $Directory 'active-session.json')
}

function Get-StopPath {
    param(
        [Parameter(Mandatory = $true)][string]$Directory,
        [Parameter(Mandatory = $true)][string]$Id
    )
    return Assert-PathInsideTelemetryDirectory -Directory $Directory -Candidate (Join-Path $Directory ("session-$Id.stop"))
}

function Get-SessionLogPath {
    param(
        [Parameter(Mandatory = $true)][string]$Directory,
        [Parameter(Mandatory = $true)][string]$Id
    )
    return Assert-PathInsideTelemetryDirectory -Directory $Directory -Candidate (Join-Path $Directory ("session-$Id.jsonl"))
}

function Invoke-WithSessionMutex {
    param(
        [Parameter(Mandatory = $true)][string]$Id,
        [Parameter(Mandatory = $true)][scriptblock]$ScriptBlock
    )

    $mutex = New-Object System.Threading.Mutex($false, "Local\PredatorLimitTelemetry_$Id")
    $acquired = $false
    try {
        try { $acquired = $mutex.WaitOne([timespan]::FromSeconds(10)) }
        catch [System.Threading.AbandonedMutexException] { $acquired = $true }
        if (-not $acquired) { throw 'Timed out acquiring telemetry session lock.' }
        return & $ScriptBlock
    }
    finally {
        if ($acquired) { $mutex.ReleaseMutex() }
        $mutex.Dispose()
    }
}

function Read-SessionState {
    param([Parameter(Mandatory = $true)][string]$Directory)

    $path = Get-StatePath -Directory $Directory
    if (-not (Test-Path -LiteralPath $path -PathType Leaf)) { return $null }
    foreach ($attempt in 1..20) {
        try { return ([System.IO.File]::ReadAllText($path) | ConvertFrom-Json -ErrorAction Stop) }
        catch {
            if ($attempt -eq 20) { throw 'The telemetry session state file is invalid or unavailable.' }
            Start-Sleep -Milliseconds 25
        }
    }
}

function Write-SessionStateUnsafe {
    param(
        [Parameter(Mandatory = $true)][string]$Directory,
        [Parameter(Mandatory = $true)][object]$State
    )

    $path = Get-StatePath -Directory $Directory
    $bytes = $script:Utf8NoBom.GetBytes(($State | ConvertTo-Json -Depth 12 -Compress) + "`n")
    $stream = $null
    try {
        $stream = [System.IO.File]::Open($path, [System.IO.FileMode]::Create, [System.IO.FileAccess]::Write, [System.IO.FileShare]::Read)
        $stream.Write($bytes, 0, $bytes.Length)
        $stream.Flush($true)
    }
    finally {
        if ($null -ne $stream) { $stream.Dispose() }
    }
}

function Test-PrivateTelemetryString {
    param([Parameter(Mandatory = $true)][AllowEmptyString()][string]$Value)

    if (-not [string]::IsNullOrWhiteSpace($env:USERNAME) -and $env:USERNAME.Length -ge 3 -and
        $Value.IndexOf($env:USERNAME, [System.StringComparison]::OrdinalIgnoreCase) -ge 0) { return $true }
    if (-not [string]::IsNullOrWhiteSpace($env:COMPUTERNAME) -and $env:COMPUTERNAME.Length -ge 3 -and
        $Value.IndexOf($env:COMPUTERNAME, [System.StringComparison]::OrdinalIgnoreCase) -ge 0) { return $true }
    $patterns = @(
        '(?i)(?<![A-Za-z0-9])[A-Z]:\\',
        '(?i)\\\\[^\\\s]+\\[^\\\s]+',
        '(?i)(?<![A-Za-z0-9])/home/[^/\s]+',
        '(?i)\b[0-9a-f]{8}-[0-9a-f]{4}-[1-5][0-9a-f]{3}-[89ab][0-9a-f]{3}-[0-9a-f]{12}\b',
        '(?i)\b[0-9a-f]{8}:[0-9a-f]{2}:[0-9a-f]{2}\.[0-9a-f]\b',
        '(?i)\b(?:PCI|USB|ACPI|HID|SCSI|STORAGE|ROOT|SWD|BTHENUM|DISPLAY)\\[^\s,;]+',
        '(?i)\b(?=[A-Z0-9-]{12,}\b)(?=[A-Z0-9-]*[A-Z])(?=(?:[A-Z0-9-]*[0-9]){4})[A-Z0-9-]+\b',
        '\b[0-9]{12,}\b'
    )
    foreach ($pattern in $patterns) {
        if ($Value -match $pattern) { return $true }
    }
    return $false
}

function ConvertTo-SafeTelemetryString {
    param(
        [object]$Value,
        [Parameter(Mandatory = $true)][ref]$RedactionCounter,
        [Parameter(Mandatory = $true)][string]$Pattern
    )

    if ($null -eq $Value) { return $null }
    $text = [string]$Value
    if ((Test-PrivateTelemetryString -Value $text) -or $text -notmatch $Pattern) {
        $RedactionCounter.Value++
        return '[redacted]'
    }
    return $text
}

function Copy-NumericFields {
    param(
        [object]$Source,
        [Parameter(Mandatory = $true)][string[]]$Names
    )

    $result = [ordered]@{}
    foreach ($name in $Names) {
        $result[$name] = ConvertTo-NullableDouble -Value (Get-OptionalValue -InputObject $Source -Name $name)
    }
    return $result
}

function ConvertTo-SanitizedTelemetryRecord {
    param([Parameter(Mandatory = $true)][object]$InputObject)

    $redactionCount = 0
    $id = [string](Get-OptionalValue -InputObject $InputObject -Name 'sessionId')
    if ($id -notmatch '^[a-f0-9]{32}$') { throw 'Telemetry records require a random opaque session id.' }
    $index = ConvertTo-NullableInt64 -Value (Get-OptionalValue -InputObject $InputObject -Name 'sampleIndex')
    if ($null -eq $index -or $index -lt 0) { throw 'Telemetry records require a non-negative monotonic sample index.' }
    $timestamp = $null
    try { $timestamp = ([datetime](Get-OptionalValue -InputObject $InputObject -Name 'timestampUtc')).ToUniversalTime().ToString('o') }
    catch { throw 'Telemetry records require a valid UTC timestamp.' }

    $recordType = ConvertTo-SafeTelemetryString -Value (Get-OptionalValue -InputObject $InputObject -Name 'recordType') -RedactionCounter ([ref]$redactionCount) -Pattern '^(sample|marker|final)$'

    $statusSource = Get-OptionalValue -InputObject $InputObject -Name 'status'
    $status = Copy-NumericFields -Source $statusSource -Names @('cpuFanRpm', 'gpuFanRpm', 'cpuTempC', 'gpuTempC', 'timestampAgeSeconds')
    $status['fanMode'] = ConvertTo-SafeTelemetryString -Value (Get-OptionalValue -InputObject $statusSource -Name 'fanMode') -RedactionCounter ([ref]$redactionCount) -Pattern '^(AUTO|MAX|CUSTOM|UNKNOWN)$'
    $status['statusError'] = ConvertTo-SafeTelemetryString -Value (Get-OptionalValue -InputObject $statusSource -Name 'statusError') -RedactionCounter ([ref]$redactionCount) -Pattern '^[a-z0-9][a-z0-9._-]{0,63}$'

    $cpuSource = Get-OptionalValue -InputObject $InputObject -Name 'cpu'
    $cpu = Copy-NumericFields -Source $cpuSource -Names @(
        'effectiveMHz', 'effectiveRatio', 'activeCoreEstimate', 'stockEnvelopeRatio',
        'maxClockMHz', 'currentClockMHz', 'numberOfCores', 'numberOfLogicalProcessors'
    )
    $cpu['errorCategory'] = ConvertTo-SafeTelemetryString -Value (Get-OptionalValue -InputObject $cpuSource -Name 'errorCategory') -RedactionCounter ([ref]$redactionCount) -Pattern '^[a-z0-9][a-z0-9._-]{0,63}$'
    $counterFields = @('percentProcessorPerformance', 'percentProcessorTime', 'percentIdleTime', 'processorFrequencyMHz', 'percentOfMaximumFrequency', 'percentPerformanceLimit', 'performanceLimitFlags')
    $cpu['total'] = Copy-NumericFields -Source (Get-OptionalValue -InputObject $cpuSource -Name 'total') -Names $counterFields
    $logicalRows = New-Object System.Collections.Generic.List[object]
    foreach ($row in @(Get-OptionalValue -InputObject $cpuSource -Name 'logicalProcessors')) {
        if ($null -eq $row) { continue }
        $safeRow = Copy-NumericFields -Source $row -Names $counterFields
        $safeRow['name'] = ConvertTo-SafeTelemetryString -Value (Get-OptionalValue -InputObject $row -Name 'name') -RedactionCounter ([ref]$redactionCount) -Pattern '^(?:_Total|[0-9]+(?:,[0-9]+)?)$'
        $logicalRows.Add([pscustomobject]$safeRow)
    }
    $cpu['logicalProcessors'] = $logicalRows.ToArray()

    $gpuSource = Get-OptionalValue -InputObject $InputObject -Name 'gpu'
    $gpu = Copy-NumericFields -Source $gpuSource -Names @('index', 'utilizationGpuPct', 'utilizationMemoryPct', 'clockSmMHz', 'clockMemoryMHz', 'powerDrawW', 'powerLimitW', 'temperatureC')
    $gpu['errorCategory'] = ConvertTo-SafeTelemetryString -Value (Get-OptionalValue -InputObject $gpuSource -Name 'errorCategory') -RedactionCounter ([ref]$redactionCount) -Pattern '^[a-z0-9][a-z0-9._-]{0,63}$'
    $throttleSource = Get-OptionalValue -InputObject $gpuSource -Name 'throttle'
    $throttle = [ordered]@{}
    foreach ($name in @('active', 'gpuIdle', 'applicationsClocksSetting', 'softwarePowerCap', 'hardwareSlowdown', 'hardwareThermalSlowdown', 'hardwarePowerBrakeSlowdown', 'syncBoost')) {
        $value = Get-OptionalValue -InputObject $throttleSource -Name $name
        $throttle[$name] = if ($null -eq $value) { $null } else { [bool]$value }
    }
    $gpu['throttle'] = $throttle

    $markerSource = Get-OptionalValue -InputObject $InputObject -Name 'marker'
    $marker = [ordered]@{
        label = ConvertTo-SafeTelemetryString -Value (Get-OptionalValue -InputObject $markerSource -Name 'label') -RedactionCounter ([ref]$redactionCount) -Pattern '^[a-z0-9][a-z0-9._-]{0,63}$'
    }

    $hypothesisSource = Get-OptionalValue -InputObject $InputObject -Name 'hypothesis'
    $basis = New-Object System.Collections.Generic.List[string]
    foreach ($rule in @(Get-OptionalValue -InputObject $hypothesisSource -Name 'basis')) {
        $safeRule = ConvertTo-SafeTelemetryString -Value $rule -RedactionCounter ([ref]$redactionCount) -Pattern '^[a-z0-9][a-z0-9._-]{0,63}$'
        if ($null -ne $safeRule) { $basis.Add($safeRule) }
    }
    $hypothesis = [ordered]@{
        kind                  = 'hypothesis'
        limitReasonHypothesis = ConvertTo-SafeTelemetryString -Value (Get-OptionalValue -InputObject $hypothesisSource -Name 'limitReasonHypothesis') -RedactionCounter ([ref]$redactionCount) -Pattern '^(thermal|power|gpu|ratio_cap|unknown)$'
        confidence            = ConvertTo-SafeTelemetryString -Value (Get-OptionalValue -InputObject $hypothesisSource -Name 'confidence') -RedactionCounter ([ref]$redactionCount) -Pattern '^(low|medium|high)$'
        basis                 = $basis.ToArray()
        disclaimer            = $script:HypothesisDisclaimer
    }

    $wheaSource = Get-OptionalValue -InputObject $InputObject -Name 'whea'
    $whea = [ordered]@{}
    foreach ($phase in @('start', 'end')) {
        $snapshotSource = Get-OptionalValue -InputObject $wheaSource -Name $phase
        if ($null -eq $snapshotSource) { $whea[$phase] = $null; continue }
        $counts = New-Object System.Collections.Generic.List[object]
        foreach ($count in @(Get-OptionalValue -InputObject $snapshotSource -Name 'counts')) {
            if ($null -eq $count) { continue }
            $counts.Add([pscustomobject][ordered]@{
                    id    = ConvertTo-NullableInt64 -Value (Get-OptionalValue -InputObject $count -Name 'id')
                    level = ConvertTo-NullableInt64 -Value (Get-OptionalValue -InputObject $count -Name 'level')
                    count = ConvertTo-NullableInt64 -Value (Get-OptionalValue -InputObject $count -Name 'count')
                })
        }
        $newest = Get-OptionalValue -InputObject $snapshotSource -Name 'newestTimestampUtc'
        if ($null -ne $newest) {
            try { $newest = ([datetime]$newest).ToUniversalTime().ToString('o') } catch { $newest = $null; $redactionCount++ }
        }
        $whea[$phase] = [ordered]@{
            counts             = $counts.ToArray()
            newestTimestampUtc = $newest
            errorCategory      = ConvertTo-SafeTelemetryString -Value (Get-OptionalValue -InputObject $snapshotSource -Name 'errorCategory') -RedactionCounter ([ref]$redactionCount) -Pattern '^[a-z0-9][a-z0-9._-]{0,63}$'
        }
    }

    $errors = New-Object System.Collections.Generic.List[string]
    foreach ($category in @(Get-OptionalValue -InputObject $InputObject -Name 'errors')) {
        $safeCategory = ConvertTo-SafeTelemetryString -Value $category -RedactionCounter ([ref]$redactionCount) -Pattern '^[a-z0-9][a-z0-9._-]{0,63}$'
        if ($null -ne $safeCategory) { $errors.Add($safeCategory) }
    }

    return [pscustomobject][ordered]@{
        schemaVersion = $script:TelemetrySchemaVersion
        sessionId     = $id
        sampleIndex   = $index
        timestampUtc  = $timestamp
        recordType    = $recordType
        status        = [pscustomobject]$status
        cpu           = [pscustomobject]$cpu
        gpu           = [pscustomobject]$gpu
        marker        = [pscustomobject]$marker
        whea          = [pscustomobject]$whea
        hypothesis    = [pscustomobject]$hypothesis
        redactions    = [pscustomobject][ordered]@{ record = $redactionCount }
        errors        = $errors.ToArray()
    }
}

function Rotate-TelemetryLogUnsafe {
    param(
        [Parameter(Mandatory = $true)][string]$Directory,
        [Parameter(Mandatory = $true)][string]$BasePath,
        [Parameter(Mandatory = $true)][int]$Retention
    )

    if (-not (Test-Path -LiteralPath $BasePath -PathType Leaf)) { return }
    if ($Retention -eq 1) {
        [System.IO.File]::Delete((Assert-PathInsideTelemetryDirectory -Directory $Directory -Candidate $BasePath))
        return
    }
    $oldest = Assert-PathInsideTelemetryDirectory -Directory $Directory -Candidate ($BasePath + '.' + ($Retention - 1))
    if (Test-Path -LiteralPath $oldest -PathType Leaf) { [System.IO.File]::Delete($oldest) }
    for ($slot = $Retention - 2; $slot -ge 1; $slot--) {
        $source = Assert-PathInsideTelemetryDirectory -Directory $Directory -Candidate ($BasePath + '.' + $slot)
        $destination = Assert-PathInsideTelemetryDirectory -Directory $Directory -Candidate ($BasePath + '.' + ($slot + 1))
        if (Test-Path -LiteralPath $source -PathType Leaf) { [System.IO.File]::Move($source, $destination) }
    }
    $first = Assert-PathInsideTelemetryDirectory -Directory $Directory -Candidate ($BasePath + '.1')
    [System.IO.File]::Move($BasePath, $first)
}

function Write-TelemetryRecord {
    param(
        [Parameter(Mandatory = $true)][string]$Directory,
        [Parameter(Mandatory = $true)][string]$Id,
        [Parameter(Mandatory = $true)][object]$Candidate,
        [Parameter(Mandatory = $true)][long]$MaximumBytes,
        [Parameter(Mandatory = $true)][int]$Retention
    )

    return Invoke-WithSessionMutex -Id $Id -ScriptBlock {
        $state = Read-SessionState -Directory $Directory
        if ($null -eq $state -or [string]$state.sessionId -ne $Id) { throw 'No matching telemetry session state exists.' }
        $nextIndex = [long]$state.nextSampleIndex
        if ($nextIndex -lt 0) { throw 'Telemetry state has an invalid sample index.' }
        if ($Candidate -is [System.Collections.IDictionary]) { $Candidate['sampleIndex'] = $nextIndex }
        else { $Candidate.sampleIndex = $nextIndex }
        $record = ConvertTo-SanitizedTelemetryRecord -InputObject $Candidate
        $lineBytes = $script:Utf8NoBom.GetBytes(($record | ConvertTo-Json -Depth 20 -Compress) + "`n")
        $basePath = Get-SessionLogPath -Directory $Directory -Id $Id
        if ((Test-Path -LiteralPath $basePath -PathType Leaf) -and
            ((Get-Item -LiteralPath $basePath).Length + $lineBytes.Length -gt $MaximumBytes)) {
            Rotate-TelemetryLogUnsafe -Directory $Directory -BasePath $basePath -Retention $Retention
        }
        $stream = $null
        try {
            $stream = [System.IO.File]::Open($basePath, [System.IO.FileMode]::Append, [System.IO.FileAccess]::Write, [System.IO.FileShare]::Read)
            $stream.Write($lineBytes, 0, $lineBytes.Length)
            $stream.Flush($true)
        }
        finally {
            if ($null -ne $stream) { $stream.Dispose() }
        }
        $state.nextSampleIndex = $nextIndex + 1
        $state.lastRecordType = $record.recordType
        Write-SessionStateUnsafe -Directory $Directory -State $state
        return $record
    }
}

function Read-SharedStatusJson {
    param([Parameter(Mandatory = $true)][string]$Path)

    if (-not (Test-Path -LiteralPath $Path -PathType Leaf)) {
        return [pscustomobject][ordered]@{ document = $null; errorCategory = 'status_missing' }
    }
    $stream = $null
    $reader = $null
    try {
        $resolved = Get-ExactFileSystemPath -Path $Path -MustExist
        $stream = [System.IO.File]::Open(
            $resolved,
            [System.IO.FileMode]::Open,
            [System.IO.FileAccess]::Read,
            ([System.IO.FileShare]::ReadWrite -bor [System.IO.FileShare]::Delete)
        )
        $reader = New-Object System.IO.StreamReader($stream, $script:Utf8NoBom, $true)
        $text = $reader.ReadToEnd()
        $document = $text | ConvertFrom-Json -ErrorAction Stop
        return [pscustomobject][ordered]@{ document = $document; errorCategory = $null }
    }
    catch [System.UnauthorizedAccessException] {
        return [pscustomobject][ordered]@{ document = $null; errorCategory = 'status_access_denied' }
    }
    catch [System.IO.IOException] {
        return [pscustomobject][ordered]@{ document = $null; errorCategory = 'status_locked' }
    }
    catch {
        return [pscustomobject][ordered]@{ document = $null; errorCategory = 'status_invalid_json' }
    }
    finally {
        if ($null -ne $reader) { $reader.Dispose(); $stream = $null }
        if ($null -ne $stream) { $stream.Dispose() }
    }
}

function Get-StatusSnapshot {
    param(
        [Parameter(Mandatory = $true)][string]$Path,
        [datetime]$NowUtc = [datetime]::UtcNow
    )

    $read = Read-SharedStatusJson -Path $Path
    $source = $read.document
    $mode = Get-OptionalValue -InputObject $source -Name 'fanMode'
    if ($null -eq $mode) { $mode = Get-OptionalValue -InputObject $source -Name 'state' }
    $modeText = if ($null -eq $mode) { $null } else { ([string]$mode).ToUpperInvariant() }
    if ($modeText -notin @('AUTO', 'MAX', 'CUSTOM', 'UNKNOWN')) { $modeText = $null }
    $timestamp = Get-OptionalValue -InputObject $source -Name 'updatedAt'
    if ($null -eq $timestamp) { $timestamp = Get-OptionalValue -InputObject $source -Name 'timestampUtc' }
    $age = $null
    if ($null -ne $timestamp) {
        try {
            $age = [math]::Max(0, [math]::Round(($NowUtc - ([datetime]$timestamp).ToUniversalTime()).TotalSeconds, 3))
        }
        catch { $age = $null }
    }
    return [pscustomobject][ordered]@{
        cpuFanRpm         = ConvertTo-NullableDouble -Value (Get-OptionalValue -InputObject $source -Name 'cpuFanRpm')
        gpuFanRpm         = ConvertTo-NullableDouble -Value (Get-OptionalValue -InputObject $source -Name 'gpuFanRpm')
        cpuTempC          = ConvertTo-NullableDouble -Value (Get-OptionalValue -InputObject $source -Name 'cpuTempC')
        gpuTempC          = ConvertTo-NullableDouble -Value (Get-OptionalValue -InputObject $source -Name 'gpuTempC')
        timestampAgeSeconds = $age
        fanMode           = $modeText
        statusError       = $read.errorCategory
    }
}

function Get-CounterRow {
    param([object]$Row)

    return [pscustomobject][ordered]@{
        name                        = [string](Get-OptionalValue -InputObject $Row -Name 'Name')
        percentProcessorPerformance = ConvertTo-NullableDouble -Value (Get-OptionalValue -InputObject $Row -Name 'PercentProcessorPerformance')
        percentProcessorTime        = ConvertTo-NullableDouble -Value (Get-OptionalValue -InputObject $Row -Name 'PercentProcessorTime')
        percentIdleTime             = ConvertTo-NullableDouble -Value (Get-OptionalValue -InputObject $Row -Name 'PercentIdleTime')
        processorFrequencyMHz       = ConvertTo-NullableDouble -Value (Get-OptionalValue -InputObject $Row -Name 'ProcessorFrequency')
        percentOfMaximumFrequency   = ConvertTo-NullableDouble -Value (Get-OptionalValue -InputObject $Row -Name 'PercentofMaximumFrequency')
        percentPerformanceLimit     = ConvertTo-NullableDouble -Value (Get-OptionalValue -InputObject $Row -Name 'PercentPerformanceLimit')
        performanceLimitFlags       = ConvertTo-NullableDouble -Value (Get-OptionalValue -InputObject $Row -Name 'PerformanceLimitFlags')
    }
}

function Get-StockRatioEnvelope {
    param([object]$ActiveCoreEstimate)

    if ($null -eq $ActiveCoreEstimate) { return $null }
    # Intel Core i7-7700HQ stock Turbo ratio envelope: 1C=38, 2C=36, 3C=35, 4C=34.
    $active = [int][math]::Max(1, [math]::Min(4, [double]$ActiveCoreEstimate))
    switch ($active) {
        1 { return 38.0 }
        2 { return 36.0 }
        3 { return 35.0 }
        default { return 34.0 }
    }
}

function ConvertTo-CpuSnapshot {
    param(
        [object[]]$PerformanceRows,
        [object]$ProcessorRow,
        [string]$ErrorCategory
    )

    $counterRows = @($PerformanceRows | ForEach-Object { Get-CounterRow -Row $_ })
    $total = @($counterRows | Where-Object { $_.name -eq '_Total' } | Select-Object -First 1)
    $logical = @($counterRows | Where-Object { $_.name -ne '_Total' })
    $numberOfCores = ConvertTo-NullableDouble -Value (Get-OptionalValue -InputObject $ProcessorRow -Name 'NumberOfCores')
    $numberOfLogical = ConvertTo-NullableDouble -Value (Get-OptionalValue -InputObject $ProcessorRow -Name 'NumberOfLogicalProcessors')
    $activeLogical = @($logical | Where-Object { $null -ne $_.percentIdleTime -and $_.percentIdleTime -lt 90 }).Count
    $activeCores = $null
    if ($null -ne $numberOfCores -and $null -ne $numberOfLogical -and $numberOfLogical -gt 0) {
        $threadsPerCore = [math]::Max(1.0, $numberOfLogical / $numberOfCores)
        $activeCores = [math]::Max(1, [math]::Min($numberOfCores, [math]::Ceiling($activeLogical / $threadsPerCore)))
    }
    $totalRow = if ($total.Count -gt 0) { $total[0] } else { $null }
    $maxClockMHz = ConvertTo-NullableDouble -Value (Get-OptionalValue -InputObject $ProcessorRow -Name 'MaxClockSpeed')
    $effectiveBaseMHz = $maxClockMHz
    if ($null -eq $effectiveBaseMHz -and $null -ne $totalRow) { $effectiveBaseMHz = $totalRow.processorFrequencyMHz }
    $effectiveMHz = $null
    if ($null -ne $totalRow -and $null -ne $effectiveBaseMHz -and $null -ne $totalRow.percentProcessorPerformance) {
        $effectiveMHz = [math]::Round($effectiveBaseMHz * $totalRow.percentProcessorPerformance / 100.0, 3)
    }
    $effectiveRatio = if ($null -eq $effectiveMHz) { $null } else { [math]::Round($effectiveMHz / 100.0, 3) }
    return [pscustomobject][ordered]@{
        effectiveMHz              = $effectiveMHz
        effectiveRatio            = $effectiveRatio
        activeCoreEstimate        = $activeCores
        stockEnvelopeRatio        = Get-StockRatioEnvelope -ActiveCoreEstimate $activeCores
        maxClockMHz               = $maxClockMHz
        currentClockMHz           = ConvertTo-NullableDouble -Value (Get-OptionalValue -InputObject $ProcessorRow -Name 'CurrentClockSpeed')
        numberOfCores             = $numberOfCores
        numberOfLogicalProcessors = $numberOfLogical
        total                     = $totalRow
        logicalProcessors         = $logical
        errorCategory             = if ([string]::IsNullOrWhiteSpace($ErrorCategory)) { $null } else { $ErrorCategory }
    }
}

function Get-CpuSnapshot {
    param([int]$SampleNumber)

    if ($null -ne $script:TestFixture) {
        $samples = @(Get-OptionalValue -InputObject $script:TestFixture -Name 'cpuSamples')
        if ($samples.Count -eq 0) { return ConvertTo-CpuSnapshot -PerformanceRows @() -ProcessorRow $null -ErrorCategory 'cim_unavailable' }
        $sample = $samples[[math]::Min($SampleNumber, $samples.Count - 1)]
        return ConvertTo-CpuSnapshot -PerformanceRows @(Get-OptionalValue -InputObject $sample -Name 'performanceRows') -ProcessorRow (Get-OptionalValue -InputObject $sample -Name 'processor') -ErrorCategory (Get-OptionalValue -InputObject $sample -Name 'errorCategory')
    }
    try {
        $parameters = @{ ClassName = 'Win32_PerfFormattedData_Counters_ProcessorInformation'; ErrorAction = 'Stop' }
        if ($null -ne $script:CimSession) { $parameters['CimSession'] = $script:CimSession }
        $performanceRows = @(Get-CimInstance @parameters)
        $processorParameters = @{ ClassName = 'Win32_Processor'; Property = @('MaxClockSpeed', 'CurrentClockSpeed', 'NumberOfCores', 'NumberOfLogicalProcessors'); ErrorAction = 'Stop' }
        if ($null -ne $script:CimSession) { $processorParameters['CimSession'] = $script:CimSession }
        $processor = @(Get-CimInstance @processorParameters | Select-Object -First 1)
        return ConvertTo-CpuSnapshot -PerformanceRows $performanceRows -ProcessorRow $(if ($processor.Count) { $processor[0] } else { $null }) -ErrorCategory $null
    }
    catch {
        return ConvertTo-CpuSnapshot -PerformanceRows @() -ProcessorRow $null -ErrorCategory 'cim_query_failed'
    }
}

function ConvertFrom-NvidiaCsvLine {
    param([Parameter(Mandatory = $true)][string]$Line)

    $parts = @($Line.Split(',') | ForEach-Object { $_.Trim() })
    if ($parts.Count -lt 8) { return $null }
    function Convert-NvidiaBoolean { param([string]$Text); if ($Text -eq 'Active') { return $true }; if ($Text -eq 'Not Active') { return $false }; return $null }
    return [pscustomobject][ordered]@{
        index                        = ConvertTo-NullableDouble -Value $parts[0]
        utilizationGpuPct            = ConvertTo-NullableDouble -Value $parts[1]
        utilizationMemoryPct         = ConvertTo-NullableDouble -Value $parts[2]
        clockSmMHz                   = ConvertTo-NullableDouble -Value $parts[3]
        clockMemoryMHz               = ConvertTo-NullableDouble -Value $parts[4]
        powerDrawW                   = ConvertTo-NullableDouble -Value $parts[5]
        powerLimitW                  = ConvertTo-NullableDouble -Value $parts[6]
        temperatureC                 = ConvertTo-NullableDouble -Value $parts[7]
        throttle                     = if ($parts.Count -ge 16) {
            [pscustomobject][ordered]@{
                active                    = Convert-NvidiaBoolean -Text $parts[8]
                gpuIdle                   = Convert-NvidiaBoolean -Text $parts[9]
                applicationsClocksSetting = Convert-NvidiaBoolean -Text $parts[10]
                softwarePowerCap          = Convert-NvidiaBoolean -Text $parts[11]
                hardwareSlowdown          = Convert-NvidiaBoolean -Text $parts[12]
                hardwareThermalSlowdown   = Convert-NvidiaBoolean -Text $parts[13]
                hardwarePowerBrakeSlowdown = Convert-NvidiaBoolean -Text $parts[14]
                syncBoost                 = Convert-NvidiaBoolean -Text $parts[15]
            }
        } else { $null }
        errorCategory                = $null
    }
}

function New-NullGpuSnapshot {
    param([Parameter(Mandatory = $true)][string]$ErrorCategory)
    return [pscustomobject][ordered]@{
        index = $null; utilizationGpuPct = $null; utilizationMemoryPct = $null
        clockSmMHz = $null; clockMemoryMHz = $null; powerDrawW = $null
        powerLimitW = $null; temperatureC = $null; throttle = $null
        errorCategory = $ErrorCategory
    }
}

function Start-GpuProvider {
    if ($null -ne $script:TestFixture) { return }
    $provider = [ordered]@{ process = $null; readTask = $null; latestLine = $null; restartCount = 0; queryProfile = 0; nextRestartUtc = [datetime]::MinValue; gaveUp = $false; errorCategory = $null }
    $script:GpuProvider = $provider
    Start-GpuProcess
}

function Start-GpuProcess {
    if ($null -eq $script:GpuProvider -or $script:GpuProvider.gaveUp) { return }
    $process = $null
    try {
        $baseQuery = 'index,utilization.gpu,utilization.memory,clocks.sm,clocks.mem,power.draw,power.limit,temperature.gpu'
        $throttleQuery = 'clocks_throttle_reasons.active,clocks_throttle_reasons.gpu_idle,clocks_throttle_reasons.applications_clocks_setting,clocks_throttle_reasons.sw_power_cap,clocks_throttle_reasons.hw_slowdown,clocks_throttle_reasons.hw_thermal_slowdown,clocks_throttle_reasons.hw_power_brake_slowdown,clocks_throttle_reasons.sync_boost'
        $query = if ($script:GpuProvider.queryProfile -eq 0) { "$baseQuery,$throttleQuery" } else { $baseQuery }
        $info = New-Object System.Diagnostics.ProcessStartInfo
        $info.FileName = 'nvidia-smi.exe'
        $info.Arguments = "--loop-ms=2000 --query-gpu=$query --format=csv,noheader,nounits"
        $info.UseShellExecute = $false
        $info.CreateNoWindow = $true
        $info.RedirectStandardOutput = $true
        $info.RedirectStandardError = $true
        $process = New-Object System.Diagnostics.Process
        $process.StartInfo = $info
        if (-not $process.Start()) { throw 'GPU process did not start.' }
        $script:GpuProvider.process = $process
        $script:GpuProvider.readTask = $process.StandardOutput.ReadLineAsync()
        $script:GpuProvider.errorCategory = $null
    }
    catch {
        if ($null -ne $process) { $process.Dispose() }
        $script:GpuProvider.process = $null
        $script:GpuProvider.readTask = $null
        $script:GpuProvider.errorCategory = 'gpu_command_missing'
        $script:GpuProvider.restartCount++
        if ($script:GpuProvider.restartCount -gt 2) { $script:GpuProvider.gaveUp = $true }
        else { $script:GpuProvider.nextRestartUtc = [datetime]::UtcNow.AddSeconds([math]::Pow(2, $script:GpuProvider.restartCount)) }
    }
}

function Register-GpuProcessExit {
    $process = $script:GpuProvider.process
    if ($null -ne $process) { $process.Dispose() }
    $script:GpuProvider.process = $null
    $script:GpuProvider.readTask = $null
    $script:GpuProvider.latestLine = $null
    $script:GpuProvider.errorCategory = 'gpu_process_exited'
    $script:GpuProvider.restartCount++
    $script:GpuProvider.queryProfile = 1
    if ($script:GpuProvider.restartCount -gt 2) { $script:GpuProvider.gaveUp = $true }
    else { $script:GpuProvider.nextRestartUtc = [datetime]::UtcNow.AddSeconds([math]::Pow(2, $script:GpuProvider.restartCount)) }
}

function Stop-GpuProvider {
    if ($null -eq $script:GpuProvider) { return }
    $process = $script:GpuProvider.process
    try {
        if ($null -ne $process -and -not $process.HasExited) {
            $process.Kill()
            $process.WaitForExit(5000) | Out-Null
        }
    }
    catch { }
    finally {
        if ($null -ne $process) { $process.Dispose() }
        $script:GpuProvider = $null
    }
}

function Get-GpuSnapshot {
    param([int]$SampleNumber)

    if ($null -ne $script:TestFixture) {
        $lines = @(Get-OptionalValue -InputObject $script:TestFixture -Name 'gpuLines')
        $absent = [bool](Get-OptionalValue -InputObject $script:TestFixture -Name 'gpuAbsent')
        if ($absent) { return New-NullGpuSnapshot -ErrorCategory 'gpu_command_missing' }
        $dieAt = ConvertTo-NullableInt64 -Value (Get-OptionalValue -InputObject $script:TestFixture -Name 'gpuExitAtSample')
        if ($null -ne $dieAt -and $SampleNumber -ge $dieAt) { return New-NullGpuSnapshot -ErrorCategory 'gpu_process_exited' }
        if ($lines.Count -eq 0) { return New-NullGpuSnapshot -ErrorCategory 'gpu_no_data' }
        $parsed = ConvertFrom-NvidiaCsvLine -Line ([string]$lines[[math]::Min($SampleNumber, $lines.Count - 1)])
        if ($null -eq $parsed) { return New-NullGpuSnapshot -ErrorCategory 'gpu_invalid_line' }
        return $parsed
    }
    if ($null -eq $script:GpuProvider) { return New-NullGpuSnapshot -ErrorCategory 'gpu_command_missing' }
    $process = $script:GpuProvider.process
    if ($null -ne $process -and $process.HasExited) {
        Register-GpuProcessExit
        return New-NullGpuSnapshot -ErrorCategory 'gpu_process_exited'
    }
    if ($script:GpuProvider.gaveUp) { return New-NullGpuSnapshot -ErrorCategory 'gpu_restart_exhausted' }
    if ($null -eq $script:GpuProvider.process -and [datetime]::UtcNow -ge $script:GpuProvider.nextRestartUtc) { Start-GpuProcess }
    if ($null -eq $script:GpuProvider.process -and -not [string]::IsNullOrWhiteSpace([string]$script:GpuProvider.errorCategory)) {
        return New-NullGpuSnapshot -ErrorCategory ([string]$script:GpuProvider.errorCategory)
    }
    $readTask = $script:GpuProvider.readTask
    while ($null -ne $readTask -and $readTask.IsCompleted) {
        try { $line = $readTask.GetAwaiter().GetResult() } catch { $line = $null }
        if (-not [string]::IsNullOrWhiteSpace($line)) { $script:GpuProvider.latestLine = $line }
        if ($null -eq $script:GpuProvider.process -or $script:GpuProvider.process.HasExited) { break }
        $script:GpuProvider.readTask = $script:GpuProvider.process.StandardOutput.ReadLineAsync()
        $readTask = $script:GpuProvider.readTask
    }
    if ($null -ne $script:GpuProvider.process -and $script:GpuProvider.process.HasExited) {
        Register-GpuProcessExit
        return New-NullGpuSnapshot -ErrorCategory 'gpu_process_exited'
    }
    if ([string]::IsNullOrWhiteSpace([string]$script:GpuProvider.latestLine)) { return New-NullGpuSnapshot -ErrorCategory 'gpu_no_data' }
    $parsed = ConvertFrom-NvidiaCsvLine -Line $script:GpuProvider.latestLine
    if ($null -eq $parsed) { return New-NullGpuSnapshot -ErrorCategory 'gpu_invalid_line' }
    return $parsed
}

function ConvertTo-WheaSnapshot {
    param(
        [object[]]$Events,
        [string]$ErrorCategory
    )

    if (-not [string]::IsNullOrWhiteSpace($ErrorCategory)) {
        return [pscustomobject][ordered]@{ counts = @(); newestTimestampUtc = $null; errorCategory = $ErrorCategory }
    }
    $groups = @($Events | Group-Object Id, Level | Sort-Object Name)
    $counts = @($groups | ForEach-Object {
            $first = $_.Group | Select-Object -First 1
            [pscustomobject][ordered]@{ id = [int64]$first.Id; level = [int64]$first.Level; count = [int64]$_.Count }
        })
    $newest = @($Events | Sort-Object TimeCreated -Descending | Select-Object -First 1)
    return [pscustomobject][ordered]@{
        counts             = $counts
        newestTimestampUtc = if ($newest.Count) { ([datetime]$newest[0].TimeCreated).ToUniversalTime().ToString('o') } else { $null }
        errorCategory      = $null
    }
}

function Get-WheaSnapshot {
    param(
        [Parameter(Mandatory = $true)][datetime]$StartUtc,
        [Parameter(Mandatory = $true)][datetime]$EndUtc,
        [Parameter(Mandatory = $true)][int]$MaximumEvents,
        [Parameter(Mandatory = $true)][ValidateSet('start', 'end')][string]$Phase
    )

    if ($null -ne $script:TestFixture) {
        $source = Get-OptionalValue -InputObject $script:TestFixture -Name ("whea$($Phase.Substring(0,1).ToUpperInvariant())$($Phase.Substring(1))")
        $error = Get-OptionalValue -InputObject $source -Name 'errorCategory'
        if ($null -ne $error) { return ConvertTo-WheaSnapshot -Events @() -ErrorCategory ([string]$error) }
        $events = @(Get-OptionalValue -InputObject $source -Name 'events')
        return ConvertTo-WheaSnapshot -Events $events -ErrorCategory $null
    }
    try {
        if ($EndUtc -le $StartUtc) { $EndUtc = $StartUtc.AddMilliseconds(1) }
        $events = @(Get-WinEvent -FilterHashtable @{
                ProviderName = 'Microsoft-Windows-WHEA-Logger'
                StartTime    = $StartUtc
                EndTime      = $EndUtc
            } -MaxEvents $MaximumEvents -ErrorAction Stop)
        return ConvertTo-WheaSnapshot -Events $events -ErrorCategory $null
    }
    catch {
        if ($_.FullyQualifiedErrorId -match 'NoMatchingEventsFound') { return ConvertTo-WheaSnapshot -Events @() -ErrorCategory $null }
        return ConvertTo-WheaSnapshot -Events @() -ErrorCategory 'whea_query_failed'
    }
}

function Get-LimitReasonHypothesis {
    param(
        [object]$EffectiveRatio,
        [object]$StockEnvelopeRatio,
        [object]$CpuTemperatureC,
        [object]$CpuLoadPct,
        [object]$GpuUtilizationPct,
        [object]$GpuTemperatureC,
        [object]$GpuPowerDrawW,
        [object]$GpuPowerLimitW,
        [object]$PerformanceLimitPct
    )

    $ratio = ConvertTo-NullableDouble -Value $EffectiveRatio
    $envelope = ConvertTo-NullableDouble -Value $StockEnvelopeRatio
    $cpuTemp = ConvertTo-NullableDouble -Value $CpuTemperatureC
    if ($null -eq $ratio -or $null -eq $envelope -or $null -eq $cpuTemp) {
        return [pscustomobject][ordered]@{ kind = 'hypothesis'; limitReasonHypothesis = 'unknown'; confidence = 'low'; basis = @('inputs-incomplete'); disclaimer = $script:HypothesisDisclaimer }
    }
    $cpuLoad = ConvertTo-NullableDouble -Value $CpuLoadPct
    $gpuUtil = ConvertTo-NullableDouble -Value $GpuUtilizationPct
    $gpuTemp = ConvertTo-NullableDouble -Value $GpuTemperatureC
    $gpuPower = ConvertTo-NullableDouble -Value $GpuPowerDrawW
    $gpuLimit = ConvertTo-NullableDouble -Value $GpuPowerLimitW
    $performanceLimit = ConvertTo-NullableDouble -Value $PerformanceLimitPct
    if ($cpuTemp -ge 90 -and $ratio -le ($envelope - 1.0)) {
        return [pscustomobject][ordered]@{ kind = 'hypothesis'; limitReasonHypothesis = 'thermal'; confidence = $(if ($cpuTemp -ge 95) { 'high' } else { 'medium' }); basis = @('cpu-hot', 'ratio-below-envelope'); disclaimer = $script:HypothesisDisclaimer }
    }
    if ($ratio -ge 27.5 -and $ratio -le 28.5 -and $envelope -ge 34 -and $cpuTemp -lt 90) {
        return [pscustomobject][ordered]@{ kind = 'hypothesis'; limitReasonHypothesis = 'ratio_cap'; confidence = 'medium'; basis = @('ratio-near-28x', 'stock-envelope-higher'); disclaimer = $script:HypothesisDisclaimer }
    }
    $gpuNearPower = $null -ne $gpuPower -and $null -ne $gpuLimit -and $gpuLimit -gt 0 -and ($gpuPower / $gpuLimit) -ge 0.9
    if ($null -ne $gpuUtil -and $gpuUtil -ge 80 -and (($null -ne $gpuTemp -and $gpuTemp -ge 80) -or $gpuNearPower) -and $cpuTemp -lt 85 -and $ratio -ge ($envelope - 1.0)) {
        return [pscustomobject][ordered]@{ kind = 'hypothesis'; limitReasonHypothesis = 'gpu'; confidence = 'medium'; basis = @('gpu-load-high', $(if ($gpuNearPower) { 'gpu-power-near-limit' } else { 'gpu-hot' }), 'cpu-not-hot'); disclaimer = $script:HypothesisDisclaimer }
    }
    if ($ratio -le ($envelope - 2.0) -and $cpuTemp -lt 85 -and (($null -ne $cpuLoad -and $cpuLoad -ge 70) -or ($null -ne $performanceLimit -and $performanceLimit -gt 0))) {
        return [pscustomobject][ordered]@{ kind = 'hypothesis'; limitReasonHypothesis = 'power'; confidence = $(if ($null -ne $performanceLimit -and $performanceLimit -gt 0) { 'medium' } else { 'low' }); basis = @('ratio-below-envelope', 'cpu-not-hot', $(if ($null -ne $performanceLimit -and $performanceLimit -gt 0) { 'performance-limit-counter' } else { 'cpu-load-high' })); disclaimer = $script:HypothesisDisclaimer }
    }
    return [pscustomobject][ordered]@{ kind = 'hypothesis'; limitReasonHypothesis = 'unknown'; confidence = 'low'; basis = @('no-v0-rule-matched'); disclaimer = $script:HypothesisDisclaimer }
}

function Get-NextSampleDelayMilliseconds {
    param(
        [Parameter(Mandatory = $true)][double]$LastSampleStartedMilliseconds,
        [Parameter(Mandatory = $true)][double]$NowMilliseconds,
        [Parameter(Mandatory = $true)][double]$IntervalMilliseconds
    )

    if ($IntervalMilliseconds -le 0) { throw 'IntervalMilliseconds must be positive.' }
    $target = $LastSampleStartedMilliseconds + $IntervalMilliseconds
    return [int][math]::Max(0, [math]::Ceiling($target - $NowMilliseconds))
}

function Wait-ForNextSample {
    param(
        [Parameter(Mandatory = $true)][System.Diagnostics.Stopwatch]$Stopwatch,
        [Parameter(Mandatory = $true)][double]$LastSampleStartedMilliseconds,
        [Parameter(Mandatory = $true)][double]$IntervalMilliseconds,
        [Parameter(Mandatory = $true)][string]$StopPath
    )

    while ($true) {
        if (Test-Path -LiteralPath $StopPath -PathType Leaf) { return $false }
        $delay = Get-NextSampleDelayMilliseconds -LastSampleStartedMilliseconds $LastSampleStartedMilliseconds -NowMilliseconds $Stopwatch.Elapsed.TotalMilliseconds -IntervalMilliseconds $IntervalMilliseconds
        if ($delay -le 0) { return $true }
        Start-Sleep -Milliseconds ([math]::Min(200, $delay))
    }
}

function Get-RecordErrors {
    param(
        [object]$Status,
        [object]$Cpu,
        [object]$Gpu,
        [object]$WheaSnapshot
    )

    $errors = New-Object System.Collections.Generic.List[string]
    foreach ($value in @(
            (Get-OptionalValue -InputObject $Status -Name 'statusError'),
            (Get-OptionalValue -InputObject $Cpu -Name 'errorCategory'),
            (Get-OptionalValue -InputObject $Gpu -Name 'errorCategory'),
            (Get-OptionalValue -InputObject $WheaSnapshot -Name 'errorCategory')
        )) {
        if (-not [string]::IsNullOrWhiteSpace([string]$value)) { $errors.Add([string]$value) }
    }
    return @($errors | Sort-Object -Unique)
}

function New-TelemetryCandidate {
    param(
        [Parameter(Mandatory = $true)][string]$Id,
        [Parameter(Mandatory = $true)][ValidateSet('sample', 'marker', 'final')][string]$RecordType,
        [object]$Status,
        [object]$Cpu,
        [object]$Gpu,
        [object]$Marker,
        [object]$Whea,
        [object]$Hypothesis,
        [string[]]$Errors = @()
    )

    return [ordered]@{
        sessionId   = $Id
        sampleIndex = 0
        timestampUtc = [datetime]::UtcNow
        recordType  = $RecordType
        status      = $Status
        cpu         = $Cpu
        gpu         = $Gpu
        marker      = $Marker
        whea        = $Whea
        hypothesis  = $Hypothesis
        errors      = $Errors
    }
}

function Initialize-TestFixture {
    if (-not $script:InvocationParameters.ContainsKey('TestFixturePath')) { return }
    if ($env:PREDATOR_TELEMETRY_TEST_HOOK -ne '1') { throw 'TestFixturePath is available only under the internal test guard.' }
    $fixturePath = Get-ExactFileSystemPath -Path $TestFixturePath -MustExist
    $script:TestFixture = [System.IO.File]::ReadAllText($fixturePath) | ConvertFrom-Json -ErrorAction Stop
}

function Invoke-RunAction {
    param([Parameter(Mandatory = $true)][string]$Directory)

    $id = $SessionId
    if ([string]::IsNullOrWhiteSpace($id)) { $id = [guid]::NewGuid().ToString('N') }
    $existingState = Read-SessionState -Directory $Directory
    if ($null -eq $existingState -or
        ([string]$existingState.status -notin @('starting', 'running') -and -not $script:InvocationParameters.ContainsKey('SessionId'))) {
        $initialState = [pscustomobject][ordered]@{ sessionId = $id; status = 'starting'; processId = $PID; nextSampleIndex = 0; startedAtUtc = [datetime]::UtcNow.ToString('o'); stoppedAtUtc = $null; lastRecordType = $null }
        Write-SessionStateUnsafe -Directory $Directory -State $initialState
    }
    Invoke-WithSessionMutex -Id $id -ScriptBlock {
        $state = Read-SessionState -Directory $Directory
        if ($null -eq $state -or [string]$state.sessionId -ne $id) { throw 'A different telemetry session is already active.' }
        $state.status = 'running'
        $state.processId = $PID
        Write-SessionStateUnsafe -Directory $Directory -State $state
    } | Out-Null
    $stopPath = Get-StopPath -Directory $Directory -Id $id
    $sessionStart = [datetime]::UtcNow
    $stopwatch = [System.Diagnostics.Stopwatch]::StartNew()
    $startWhea = $null
    $sampleNumber = 0
    try {
        if ($null -eq $script:TestFixture) {
            try { $script:CimSession = New-CimSession -ErrorAction Stop } catch { $script:CimSession = $null }
        }
        Start-GpuProvider
        $startWhea = Get-WheaSnapshot -StartUtc $sessionStart -EndUtc ([datetime]::UtcNow) -MaximumEvents $WheaMaxEvents -Phase start
        while ($stopwatch.Elapsed.TotalSeconds -lt $DurationSeconds -and -not (Test-Path -LiteralPath $stopPath -PathType Leaf)) {
            $sampleStarted = $stopwatch.Elapsed.TotalMilliseconds
            $status = if ($null -ne $script:TestFixture -and $null -ne (Get-OptionalValue -InputObject $script:TestFixture -Name 'statusSamples')) {
                $statusSamples = @(Get-OptionalValue -InputObject $script:TestFixture -Name 'statusSamples')
                $statusSamples[[math]::Min($sampleNumber, $statusSamples.Count - 1)]
            } else { Get-StatusSnapshot -Path $StatusPath }
            $cpu = Get-CpuSnapshot -SampleNumber $sampleNumber
            $gpu = Get-GpuSnapshot -SampleNumber $sampleNumber
            $hypothesis = Get-LimitReasonHypothesis -EffectiveRatio $cpu.effectiveRatio -StockEnvelopeRatio $cpu.stockEnvelopeRatio -CpuTemperatureC $status.cpuTempC -CpuLoadPct $cpu.total.percentProcessorTime -GpuUtilizationPct $gpu.utilizationGpuPct -GpuTemperatureC $gpu.temperatureC -GpuPowerDrawW $gpu.powerDrawW -GpuPowerLimitW $gpu.powerLimitW -PerformanceLimitPct $cpu.total.percentPerformanceLimit
            $whea = [ordered]@{ start = $(if ($sampleNumber -eq 0) { $startWhea } else { $null }); end = $null }
            $candidate = New-TelemetryCandidate -Id $id -RecordType sample -Status $status -Cpu $cpu -Gpu $gpu -Marker $null -Whea $whea -Hypothesis $hypothesis -Errors (Get-RecordErrors -Status $status -Cpu $cpu -Gpu $gpu -WheaSnapshot $(if ($sampleNumber -eq 0) { $startWhea } else { $null }))
            Write-TelemetryRecord -Directory $Directory -Id $id -Candidate $candidate -MaximumBytes $MaxLogBytes -Retention $MaxLogFiles | Out-Null
            $sampleNumber++
            if (-not (Wait-ForNextSample -Stopwatch $stopwatch -LastSampleStartedMilliseconds $sampleStarted -IntervalMilliseconds ($IntervalSeconds * 1000.0) -StopPath $stopPath)) { break }
        }
        $endWhea = Get-WheaSnapshot -StartUtc $sessionStart -EndUtc ([datetime]::UtcNow) -MaximumEvents $WheaMaxEvents -Phase end
        $unknown = Get-LimitReasonHypothesis -EffectiveRatio $null -StockEnvelopeRatio $null -CpuTemperatureC $null -CpuLoadPct $null -GpuUtilizationPct $null -GpuTemperatureC $null -GpuPowerDrawW $null -GpuPowerLimitW $null -PerformanceLimitPct $null
        $finalCandidate = New-TelemetryCandidate -Id $id -RecordType final -Status $null -Cpu $null -Gpu $null -Marker $null -Whea ([ordered]@{ start = $null; end = $endWhea }) -Hypothesis $unknown -Errors (Get-RecordErrors -Status $null -Cpu $null -Gpu $null -WheaSnapshot $endWhea)
        Write-TelemetryRecord -Directory $Directory -Id $id -Candidate $finalCandidate -MaximumBytes $MaxLogBytes -Retention $MaxLogFiles | Out-Null
        Invoke-WithSessionMutex -Id $id -ScriptBlock {
            $state = Read-SessionState -Directory $Directory
            $state.status = 'stopped'
            $state.stoppedAtUtc = [datetime]::UtcNow.ToString('o')
            Write-SessionStateUnsafe -Directory $Directory -State $state
        } | Out-Null
    }
    catch {
        $runError = $_
        try {
            Invoke-WithSessionMutex -Id $id -ScriptBlock {
                $state = Read-SessionState -Directory $Directory
                if ($null -ne $state -and [string]$state.sessionId -eq $id) {
                    $state.status = 'failed'
                    $state.stoppedAtUtc = [datetime]::UtcNow.ToString('o')
                    Write-SessionStateUnsafe -Directory $Directory -State $state
                }
            } | Out-Null
        }
        catch { }
        throw $runError
    }
    finally {
        Stop-GpuProvider
        if ($null -ne $script:CimSession) { $script:CimSession.Dispose(); $script:CimSession = $null }
        if (Test-Path -LiteralPath $stopPath -PathType Leaf) { [System.IO.File]::Delete($stopPath) }
    }
    return [pscustomobject][ordered]@{ sessionId = $id; logPath = Get-SessionLogPath -Directory $Directory -Id $id }
}

function Quote-ProcessArgument {
    param([Parameter(Mandatory = $true)][AllowEmptyString()][string]$Value)
    return '"' + $Value.Replace('"', '\"') + '"'
}

function Invoke-StartAction {
    param([Parameter(Mandatory = $true)][string]$Directory)

    $existing = Read-SessionState -Directory $Directory
    if ($null -ne $existing -and [string]$existing.status -in @('starting', 'running')) { throw 'A telemetry session is already active.' }
    $id = [guid]::NewGuid().ToString('N')
    $state = [pscustomobject][ordered]@{ sessionId = $id; status = 'starting'; processId = $null; nextSampleIndex = 0; startedAtUtc = [datetime]::UtcNow.ToString('o'); stoppedAtUtc = $null; lastRecordType = $null }
    Write-SessionStateUnsafe -Directory $Directory -State $state
    $engine = (Get-Process -Id $PID).Path
    $arguments = New-Object System.Collections.Generic.List[string]
    foreach ($pair in @(
            @('-NoProfile', $null), @('-ExecutionPolicy', 'Bypass'), @('-File', $PSCommandPath), @('-Action', 'Run'),
            @('-SessionId', $id), @('-DurationSeconds', [string]$DurationSeconds), @('-IntervalSeconds', [string]$IntervalSeconds),
            @('-StatusPath', $StatusPath), @('-LogPath', $Directory), @('-MaxLogBytes', [string]$MaxLogBytes),
            @('-MaxLogFiles', [string]$MaxLogFiles), @('-WheaMaxEvents', [string]$WheaMaxEvents)
        )) {
        $arguments.Add([string]$pair[0])
        if ($null -ne $pair[1]) { $arguments.Add((Quote-ProcessArgument -Value ([string]$pair[1]))) }
    }
    if ($script:InvocationParameters.ContainsKey('TestFixturePath')) {
        $arguments.Add('-TestFixturePath')
        $arguments.Add((Quote-ProcessArgument -Value (Get-ExactFileSystemPath -Path $TestFixturePath -MustExist)))
    }
    try {
        Start-Process -FilePath $engine -ArgumentList ($arguments -join ' ') -WindowStyle Hidden | Out-Null
    }
    catch {
        $state.status = 'failed'
        Write-SessionStateUnsafe -Directory $Directory -State $state
        throw
    }
    return [pscustomobject][ordered]@{ sessionId = $id; logPath = Get-SessionLogPath -Directory $Directory -Id $id }
}

function Invoke-MarkAction {
    param([Parameter(Mandatory = $true)][string]$Directory)

    if ([string]::IsNullOrWhiteSpace($Label)) { throw 'Mark requires -Label.' }
    $state = Read-SessionState -Directory $Directory
    if ($null -eq $state -or [string]$state.status -notin @('starting', 'running')) { throw 'No active telemetry session is available to mark.' }
    $unknown = Get-LimitReasonHypothesis -EffectiveRatio $null -StockEnvelopeRatio $null -CpuTemperatureC $null -CpuLoadPct $null -GpuUtilizationPct $null -GpuTemperatureC $null -GpuPowerDrawW $null -GpuPowerLimitW $null -PerformanceLimitPct $null
    $candidate = New-TelemetryCandidate -Id ([string]$state.sessionId) -RecordType marker -Status $null -Cpu $null -Gpu $null -Marker ([ordered]@{ label = $Label }) -Whea $null -Hypothesis $unknown
    return Write-TelemetryRecord -Directory $Directory -Id ([string]$state.sessionId) -Candidate $candidate -MaximumBytes $MaxLogBytes -Retention $MaxLogFiles
}

function Invoke-StopAction {
    param([Parameter(Mandatory = $true)][string]$Directory)

    $state = Read-SessionState -Directory $Directory
    if ($null -eq $state -or [string]$state.status -notin @('starting', 'running')) { throw 'No active telemetry session is available to stop.' }
    $id = [string]$state.sessionId
    $stopPath = Get-StopPath -Directory $Directory -Id $id
    [System.IO.File]::WriteAllBytes($stopPath, $script:Utf8NoBom.GetBytes("stop`n"))
    $deadline = [datetime]::UtcNow.AddSeconds($GracePeriodSeconds)
    do {
        Start-Sleep -Milliseconds 100
        $state = Read-SessionState -Directory $Directory
        if ($null -ne $state -and [string]$state.status -eq 'stopped') {
            return [pscustomobject][ordered]@{ sessionId = $id; logPath = Get-SessionLogPath -Directory $Directory -Id $id; finalized = $true }
        }
    } while ([datetime]::UtcNow -lt $deadline)
    throw 'Telemetry session did not finalize within the bounded grace period.'
}

function Get-NumberStatistics {
    param([object[]]$Values)

    $numbers = @($Values | ForEach-Object { ConvertTo-NullableDouble -Value $_ } | Where-Object { $null -ne $_ } | Sort-Object)
    if ($numbers.Count -eq 0) { return [pscustomobject][ordered]@{ count = 0; min = $null; max = $null; mean = $null; p50 = $null; p95 = $null; p99 = $null } }
    function Get-Percentile { param([double[]]$Sorted, [double]$Percent); $position = ($Sorted.Count - 1) * $Percent; $lower = [math]::Floor($position); $upper = [math]::Ceiling($position); if ($lower -eq $upper) { return $Sorted[$lower] }; return $Sorted[$lower] + (($Sorted[$upper] - $Sorted[$lower]) * ($position - $lower)) }
    return [pscustomobject][ordered]@{
        count = $numbers.Count
        min   = [math]::Round($numbers[0], 3)
        max   = [math]::Round($numbers[-1], 3)
        mean  = [math]::Round((($numbers | Measure-Object -Average).Average), 3)
        p50   = [math]::Round((Get-Percentile -Sorted $numbers -Percent 0.50), 3)
        p95   = [math]::Round((Get-Percentile -Sorted $numbers -Percent 0.95), 3)
        p99   = [math]::Round((Get-Percentile -Sorted $numbers -Percent 0.99), 3)
    }
}

function Get-WheaDelta {
    param([object[]]$Records)

    $start = $Records | ForEach-Object { $_.whea.start } | Where-Object { $null -ne $_ } | Select-Object -First 1
    $end = $Records | ForEach-Object { $_.whea.end } | Where-Object { $null -ne $_ } | Select-Object -Last 1
    $startCounts = @(Get-OptionalValue -InputObject $start -Name 'counts')
    $endCounts = @(Get-OptionalValue -InputObject $end -Name 'counts')
    $keys = New-Object System.Collections.Generic.List[string]
    foreach ($row in $startCounts + $endCounts) { $keys.Add("$($row.id)|$($row.level)") }
    $deltas = New-Object System.Collections.Generic.List[object]
    foreach ($key in @($keys | Sort-Object -Unique)) {
        $parts = $key.Split('|')
        $startCount = @($startCounts | Where-Object { [string]$_.id -eq $parts[0] -and [string]$_.level -eq $parts[1] } | Measure-Object -Property count -Sum).Sum
        $endCount = @($endCounts | Where-Object { [string]$_.id -eq $parts[0] -and [string]$_.level -eq $parts[1] } | Measure-Object -Property count -Sum).Sum
        $deltas.Add([pscustomobject][ordered]@{ id = [int]$parts[0]; level = [int]$parts[1]; delta = [int64]($endCount - $startCount) })
    }
    return $deltas.ToArray()
}

function Invoke-SummarizeAction {
    if ([string]::IsNullOrWhiteSpace($InputPath)) { throw 'Summarize requires -InputPath.' }
    $path = Get-ExactFileSystemPath -Path $InputPath -MustExist
    $records = New-Object System.Collections.Generic.List[object]
    foreach ($line in [System.IO.File]::ReadLines($path)) {
        if ([string]::IsNullOrWhiteSpace($line)) { continue }
        try { $records.Add(($line | ConvertFrom-Json -ErrorAction Stop)) }
        catch { throw 'InputPath contains an invalid JSONL record.' }
    }
    $samples = @($records | Where-Object { $_.recordType -eq 'sample' })
    $timestamps = @($records | ForEach-Object { try { [datetime]$_.timestampUtc } catch { $null } } | Where-Object { $null -ne $_ } | Sort-Object)
    $duration = if ($timestamps.Count -gt 1) { [math]::Round(($timestamps[-1] - $timestamps[0]).TotalSeconds, 3) } else { 0.0 }
    $distribution = [ordered]@{ thermal = 0; power = 0; gpu = 0; ratio_cap = 0; unknown = 0 }
    foreach ($record in $samples) { $value = [string]$record.hypothesis.limitReasonHypothesis; if ($distribution.Contains($value)) { $distribution[$value]++ } }
    $errors = @($records | ForEach-Object { @($_.errors) } | Where-Object { -not [string]::IsNullOrWhiteSpace([string]$_) } | Sort-Object -Unique)
    $redactions = [int64](($records | ForEach-Object { [int64]$_.redactions.record } | Measure-Object -Sum).Sum)
    $summary = [pscustomobject][ordered]@{
        schemaVersion          = 1
        sampleCounts           = [pscustomobject][ordered]@{ records = $records.Count; samples = $samples.Count; markers = @($records | Where-Object { $_.recordType -eq 'marker' }).Count }
        durationSeconds        = $duration
        effectiveRatio         = Get-NumberStatistics -Values @($samples | ForEach-Object { $_.cpu.effectiveRatio })
        cpuTemperatureC        = Get-NumberStatistics -Values @($samples | ForEach-Object { $_.status.cpuTempC })
        statusGpuTemperatureC  = Get-NumberStatistics -Values @($samples | ForEach-Object { $_.status.gpuTempC })
        gpuPowerW              = Get-NumberStatistics -Values @($samples | ForEach-Object { $_.gpu.powerDrawW })
        gpuTemperatureC        = Get-NumberStatistics -Values @($samples | ForEach-Object { $_.gpu.temperatureC })
        redactionCount         = $redactions
        wheaDelta              = Get-WheaDelta -Records $records.ToArray()
        errorCategoriesSeen    = $errors
        hypothesisDistribution = [pscustomobject]$distribution
    }
    return ($summary | ConvertTo-Json -Depth 12 -Compress)
}

if ($InternalTestHook) {
    if ($env:PREDATOR_TELEMETRY_TEST_HOOK -ne '1') { throw 'InternalTestHook requires the internal test guard.' }
    return
}

Initialize-TestFixture

if ($Action -eq 'Summarize') {
    Write-Output (Invoke-SummarizeAction)
    return
}

$telemetryDirectory = Resolve-TelemetryDirectory -Path $LogPath
switch ($Action) {
    'Start' { Write-Output (Invoke-StartAction -Directory $telemetryDirectory) }
    'Run' { Write-Output (Invoke-RunAction -Directory $telemetryDirectory) }
    'Mark' { Write-Output (Invoke-MarkAction -Directory $telemetryDirectory) }
    'Stop' { Write-Output (Invoke-StopAction -Directory $telemetryDirectory) }
}
