[CmdletBinding()]
param(
    [string] $ConfigPath = 'C:\Acer-Driver-Audit\FanControl\fan-controller-config.json',
    [string] $LogPath = 'C:\Acer-Driver-Audit\FanControl\adaptive-fan.jsonl',
    [string] $StatusPath = 'C:\Acer-Driver-Audit\FanControl\adaptive-fan-status.json',
    [string] $SimulationPath,
    [ValidateSet('AUTO', 'MAX')]
    [string] $InitialState = 'MAX',
    [switch] $ValidateOnly
)

Set-StrictMode -Version Latest
$ErrorActionPreference = 'Stop'

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

function Rotate-ControllerLog {
    param([string] $Path, [int64] $MaximumBytes, [int] $KeepFiles)
    if (-not (Test-Path -LiteralPath $Path)) { return }
    if ((Get-Item -LiteralPath $Path).Length -lt $MaximumBytes) { return }

    for ($index = $KeepFiles - 1; $index -ge 1; $index--) {
        $source = "$Path.$index"
        $destination = "$Path.$($index + 1)"
        if (Test-Path -LiteralPath $source) {
            Move-Item -LiteralPath $source -Destination $destination -Force
        }
    }
    Move-Item -LiteralPath $Path -Destination "$Path.1" -Force
}

function Write-ControllerEvent {
    param(
        [string] $Event,
        [System.Collections.IDictionary] $Data = @{}
    )
    try {
        Rotate-ControllerLog -Path $LogPath -MaximumBytes ([int64]$script:Config.logMaxBytes) -KeepFiles ([int]$script:Config.logKeepFiles)
        $record = [ordered]@{
            timestamp = (Get-Date).ToString('o')
            event = $Event
        }
        foreach ($key in $Data.Keys) { $record[$key] = $Data[$key] }
        [System.IO.File]::AppendAllText($LogPath, (($record | ConvertTo-Json -Compress -Depth 8) + [Environment]::NewLine), [System.Text.UTF8Encoding]::new($false))
    }
    catch {
        # Telemetry failure must never disable the thermal control path.
    }
}

function Write-ControllerStatus {
    param([System.Collections.IDictionary] $Status)
    $temporaryPath = "$StatusPath.tmp"
    [System.IO.File]::WriteAllText($temporaryPath, ($Status | ConvertTo-Json -Depth 8), [System.Text.UTF8Encoding]::new($false))
    Move-Item -LiteralPath $temporaryPath -Destination $StatusPath -Force
}

function Convert-GamingSensorValue {
    param([uint64] $RawValue)
    return [int]($RawValue -shr 8)
}

function Read-HardwareSample {
    $cpuRaw = Invoke-CimMethod -InputObject $script:Gaming -MethodName 'GetGamingSysInfo' -Arguments @{ gmInput = [uint32]0x0101 }
    $gpuRaw = Invoke-CimMethod -InputObject $script:Gaming -MethodName 'GetGamingSysInfo' -Arguments @{ gmInput = [uint32]0x0A01 }
    $systemRaw = Invoke-CimMethod -InputObject $script:Gaming -MethodName 'GetGamingSysInfo' -Arguments @{ gmInput = [uint32]0x0301 }
    $cpuFanRaw = Invoke-CimMethod -InputObject $script:Gaming -MethodName 'GetGamingSysInfo' -Arguments @{ gmInput = [uint32]0x0201 }
    $gpuFanRaw = Invoke-CimMethod -InputObject $script:Gaming -MethodName 'GetGamingSysInfo' -Arguments @{ gmInput = [uint32]0x0601 }
    $behaviorRaw = Invoke-CimMethod -InputObject $script:Gaming -MethodName 'GetGamingFanBehavior' -Arguments @{ gmInput = [uint32]0x0009 }
    $processors = @(Get-CimInstance -ClassName Win32_PerfFormattedData_PerfOS_Processor)
    $processor = $processors | Where-Object Name -eq '_Total' | Select-Object -First 1
    $logicalMaximum = ($processors | Where-Object Name -ne '_Total' | Measure-Object -Property PercentProcessorTime -Maximum).Maximum

    return [ordered]@{
        cpuTempC = Convert-GamingSensorValue ([uint64]$cpuRaw.gmOutput)
        gpuTempC = Convert-GamingSensorValue ([uint64]$gpuRaw.gmOutput)
        systemTempC = Convert-GamingSensorValue ([uint64]$systemRaw.gmOutput)
        cpuFanRpm = Convert-GamingSensorValue ([uint64]$cpuFanRaw.gmOutput)
        gpuFanRpm = Convert-GamingSensorValue ([uint64]$gpuFanRaw.gmOutput)
        fanBehaviorBitmap = [uint32]$behaviorRaw.gmOutput
        cpuLoadPct = [int]$processor.PercentProcessorTime
        cpuMaxLogicalLoadPct = [int]$logicalMaximum
    }
}

function Set-HardwareFanProfile {
    param([ValidateSet('AUTO', 'MAX')] [string] $Profile)
    if ($null -eq $script:Gaming) { return }

    if ($Profile -eq 'MAX') {
        $behavior = Invoke-CimMethod -InputObject $script:Gaming -MethodName 'SetGamingFanBehavior' -Arguments @{ gmInput = [uint64]0x00820009 }
        $cpu = Invoke-CimMethod -InputObject $script:Gaming -MethodName 'SetGamingFanSpeed' -Arguments @{ gmInput = [uint64]0x00006401 }
        $gpu = Invoke-CimMethod -InputObject $script:Gaming -MethodName 'SetGamingFanSpeed' -Arguments @{ gmInput = [uint64]0x00006404 }
        if ([uint32]$behavior.gmOutput -ne 0 -or [uint32]$cpu.gmOutput -ne 0 -or [uint32]$gpu.gmOutput -ne 0) {
            throw 'Acer firmware rejected one or more MAX fan commands.'
        }
    }
    else {
        $behavior = Invoke-CimMethod -InputObject $script:Gaming -MethodName 'SetGamingFanBehavior' -Arguments @{ gmInput = [uint64]0x00410009 }
        if ([uint32]$behavior.gmOutput -ne 0) {
            throw 'Acer firmware rejected the AUTO fan command.'
        }
    }
}

function Test-SampleValidity {
    param($Sample)
    $cpuValid = $null -ne $Sample.cpuTempC -and [double]$Sample.cpuTempC -ge 15 -and [double]$Sample.cpuTempC -le 110
    $gpuValid = $null -ne $Sample.gpuTempC -and ([double]$Sample.gpuTempC -eq 0 -or ([double]$Sample.gpuTempC -ge 15 -and [double]$Sample.gpuTempC -le 110))
    $systemValid = $null -ne $Sample.systemTempC -and [double]$Sample.systemTempC -ge 15 -and [double]$Sample.systemTempC -le 110
    $loadValid = $null -ne $Sample.cpuLoadPct -and [double]$Sample.cpuLoadPct -ge 0 -and [double]$Sample.cpuLoadPct -le 100
    return $cpuValid -and $gpuValid -and $systemValid -and $loadValid
}

function Get-OptionalSampleValue {
    param($Sample, [string] $Name)
    if ($Sample -is [System.Collections.IDictionary] -and $Sample.Contains($Name)) {
        return $Sample[$Name]
    }
    $property = $Sample.PSObject.Properties[$Name]
    if ($null -eq $property) { return $null }
    return $property.Value
}

function Assert-ControllerConfiguration {
    param([Parameter(Mandatory)] $Configuration)

    $ranges = [ordered]@{
        pollSeconds = @(1, 30)
        enterSamples = @(1, 30)
        releaseSamples = @(1, 3600)
        sensorFailureSamples = @(1, 30)
        rpmMismatchSamples = @(1, 30)
        minMaxSeconds = @(0, 7200)
        rpmReassertMinIntervalSeconds = @(1, 300)
        verifyMaxAfterSeconds = @(1, 300)
        telemetryEverySamples = @(1, 3600)
        maxCpuC = @(30, 100)
        maxGpuC = @(30, 100)
        maxSystemC = @(30, 100)
        preemptCpuLoadPct = @(1, 100)
        preemptCpuMaxLogicalLoadPct = @(1, 100)
        preemptLoadSamples = @(1, 300)
        preemptTemperatureC = @(30, 100)
        temperatureWindowSeconds = @(1, 300)
        riseTriggerC = @(1, 30)
        criticalCpuC = @(40, 105)
        criticalGpuC = @(40, 105)
        criticalSystemC = @(40, 105)
        releaseCpuC = @(20, 95)
        releaseGpuC = @(20, 95)
        releaseSystemC = @(20, 95)
        releaseRiseToleranceC = @(0, 20)
        releaseCpuLoadPct = @(0, 100)
        minimumMaxRpm = @(1000, 10000)
        logMaxBytes = @(65536, 1073741824)
        logKeepFiles = @(1, 100)
    }

    foreach ($name in $ranges.Keys) {
        $property = $Configuration.PSObject.Properties[$name]
        if ($null -eq $property -or $null -eq $property.Value) {
            throw "Required configuration value is missing: $name"
        }
        $number = 0.0
        if (-not [double]::TryParse([string]$property.Value, [Globalization.NumberStyles]::Float, [Globalization.CultureInfo]::InvariantCulture, [ref]$number)) {
            throw "Configuration value is not numeric: $name"
        }
        $minimum = [double]$ranges[$name][0]
        $maximum = [double]$ranges[$name][1]
        if ($number -lt $minimum -or $number -gt $maximum) {
            throw "Configuration value $name=$number is outside [$minimum,$maximum]."
        }
    }

    if ([double]$Configuration.releaseCpuC -ge [double]$Configuration.maxCpuC) { throw 'releaseCpuC must be lower than maxCpuC.' }
    if ([double]$Configuration.releaseGpuC -ge [double]$Configuration.maxGpuC) { throw 'releaseGpuC must be lower than maxGpuC.' }
    if ([double]$Configuration.releaseSystemC -ge [double]$Configuration.maxSystemC) { throw 'releaseSystemC must be lower than maxSystemC.' }
    if ([double]$Configuration.criticalCpuC -lt [double]$Configuration.maxCpuC) { throw 'criticalCpuC must not be lower than maxCpuC.' }
    if ([double]$Configuration.criticalGpuC -lt [double]$Configuration.maxGpuC) { throw 'criticalGpuC must not be lower than maxGpuC.' }
    if ([double]$Configuration.criticalSystemC -lt [double]$Configuration.maxSystemC) { throw 'criticalSystemC must not be lower than maxSystemC.' }
    if ([double]$Configuration.temperatureWindowSeconds -lt [double]$Configuration.pollSeconds) { throw 'temperatureWindowSeconds must be at least pollSeconds.' }
    if ([double]$Configuration.releaseCpuLoadPct -ge [double]$Configuration.preemptCpuLoadPct) { throw 'releaseCpuLoadPct must be lower than preemptCpuLoadPct.' }
}

if (-not (Test-Path -LiteralPath $ConfigPath)) { throw "Configuration not found: $ConfigPath" }
$script:Config = Get-Content -LiteralPath $ConfigPath -Raw | ConvertFrom-Json
Assert-ControllerConfiguration -Configuration $script:Config
if ($ValidateOnly) {
    [ordered]@{ status = 'VALID'; configPath = $ConfigPath } | ConvertTo-Json -Compress
    exit 0
}
$outputDirectory = Split-Path -Parent $LogPath
if (-not (Test-Path -LiteralPath $outputDirectory)) { New-Item -ItemType Directory -Path $outputDirectory -Force | Out-Null }

$simulation = $null
$script:Gaming = $null
$mutex = $null
if ($SimulationPath) {
    $simulation = Get-Content -LiteralPath $SimulationPath -Raw | ConvertFrom-Json
    if ($simulation.initialState) { $InitialState = [string]$simulation.initialState }
}
else {
    if (-not (Test-IsAdministrator)) { throw 'AcerAdaptiveFanController must run elevated.' }
    Assert-SupportedHardware
    $createdNew = $false
    $mutex = [Threading.Mutex]::new($true, 'Global\AcerAdaptiveFanController', [ref]$createdNew)
    if (-not $createdNew) { throw 'Another AcerAdaptiveFanController instance is already running.' }
    $script:Gaming = Get-CimInstance -Namespace 'root\wmi' -ClassName 'AcerGamingFunction' | Select-Object -First 1
    if (-not $script:Gaming) { throw 'AcerGamingFunction instance was not found.' }
}

$state = $InitialState
$hotSamples = 0
$coolSamples = 0
$failureSamples = 0
$loadSamples = 0
$sampleNumber = 0
$lastMaxWrite = [datetime]::MinValue
$lastMaxWriteSeconds = -1000.0
$maxSince = if ($state -eq 'MAX') { Get-Date } else { [datetime]::MinValue }
$maxSinceSeconds = 0.0
$maxVerificationPending = $state -eq 'MAX'
$rpmMismatchSamples = 0
$temperatureHistory = [System.Collections.Generic.Queue[object]]::new()
$transitionHistory = [System.Collections.Generic.List[object]]::new()
$monotonic = [Diagnostics.Stopwatch]::StartNew()

try {
    if (-not $simulation) {
        # Start from the thermally safe state. Hysteresis will return to AUTO after a genuinely cool interval.
        Set-HardwareFanProfile -Profile 'MAX'
        $state = 'MAX'
        $maxSince = Get-Date
        $maxSinceSeconds = $monotonic.Elapsed.TotalSeconds
        $lastMaxWrite = Get-Date
        $lastMaxWriteSeconds = $monotonic.Elapsed.TotalSeconds
        $maxVerificationPending = $true
    }
    Write-ControllerEvent -Event 'controller_started' -Data @{ state = $state; simulation = [bool]$simulation }

    $simulationIndex = 0
    while ($true) {
        $sampleNumber++
        $now = if ($simulation) {
            ([datetime]'2026-01-01T00:00:00Z').AddSeconds(($sampleNumber - 1) * [int]$script:Config.pollSeconds)
        } else { Get-Date }
        $elapsedSeconds = if ($simulation) { [double](($sampleNumber - 1) * [int]$script:Config.pollSeconds) } else { $monotonic.Elapsed.TotalSeconds }

        try {
            if ($simulation) {
                if ($simulationIndex -ge @($simulation.samples).Count) { break }
                $sample = $simulation.samples[$simulationIndex]
                $simulationIndex++
            }
            else {
                $sample = Read-HardwareSample
            }

            if (-not (Test-SampleValidity $sample)) { throw 'One or more sensor values are outside the accepted range.' }
            $failureSamples = 0

            $cpuTemp = [double]$sample.cpuTempC
            $gpuTemp = [double]$sample.gpuTempC
            $systemTemp = [double]$sample.systemTempC
            $cpuLoad = [double]$sample.cpuLoadPct
            $cpuMaxLogicalLoad = Get-OptionalSampleValue $sample 'cpuMaxLogicalLoadPct'
            if ($null -eq $cpuMaxLogicalLoad) { $cpuMaxLogicalLoad = $cpuLoad }
            $loadTrigger = $cpuLoad -ge [double]$script:Config.preemptCpuLoadPct -or
                [double]$cpuMaxLogicalLoad -ge [double]$script:Config.preemptCpuMaxLogicalLoadPct
            if ($loadTrigger) { $loadSamples++ } else { $loadSamples = 0 }

            $historyPoint = [pscustomobject]@{
                elapsedSeconds = $elapsedSeconds
                cpuTempC = $cpuTemp
                gpuTempC = $gpuTemp
                systemTempC = $systemTemp
            }
            $temperatureHistory.Enqueue($historyPoint)
            while ($temperatureHistory.Count -gt 1 -and ($elapsedSeconds - [double]$temperatureHistory.Peek().elapsedSeconds) -gt [double]$script:Config.temperatureWindowSeconds) {
                [void]$temperatureHistory.Dequeue()
            }
            $oldest = $temperatureHistory.Peek()
            $cpuRise = $cpuTemp - [double]$oldest.cpuTempC
            $gpuRise = if ($gpuTemp -eq 0 -or [double]$oldest.gpuTempC -eq 0) { 0 } else { $gpuTemp - [double]$oldest.gpuTempC }
            $systemRise = $systemTemp - [double]$oldest.systemTempC
            $rapidRise = ($cpuTemp -ge [double]$script:Config.preemptTemperatureC -and $cpuRise -ge [double]$script:Config.riseTriggerC) -or
                ($gpuTemp -ge [double]$script:Config.preemptTemperatureC -and $gpuRise -ge [double]$script:Config.riseTriggerC) -or
                ($systemTemp -ge [double]$script:Config.preemptTemperatureC -and $systemRise -ge [double]$script:Config.riseTriggerC)

            $critical = $cpuTemp -ge [double]$script:Config.criticalCpuC -or
                $gpuTemp -ge [double]$script:Config.criticalGpuC -or
                $systemTemp -ge [double]$script:Config.criticalSystemC
            $hot = $cpuTemp -ge [double]$script:Config.maxCpuC -or
                $gpuTemp -ge [double]$script:Config.maxGpuC -or
                $systemTemp -ge [double]$script:Config.maxSystemC -or
                $loadSamples -ge [int]$script:Config.preemptLoadSamples -or
                $rapidRise
            $cool = $cpuTemp -le [double]$script:Config.releaseCpuC -and
                ($gpuTemp -eq 0 -or $gpuTemp -le [double]$script:Config.releaseGpuC) -and
                $systemTemp -le [double]$script:Config.releaseSystemC -and
                $cpuRise -le [double]$script:Config.releaseRiseToleranceC -and
                $gpuRise -le [double]$script:Config.releaseRiseToleranceC -and
                $systemRise -le [double]$script:Config.releaseRiseToleranceC -and
                $cpuLoad -le [double]$script:Config.releaseCpuLoadPct

            if ($state -eq 'AUTO') {
                $coolSamples = 0
                if ($hot) { $hotSamples++ } else { $hotSamples = 0 }
                if ($critical -or $hotSamples -ge [int]$script:Config.enterSamples) {
                    Set-HardwareFanProfile -Profile 'MAX'
                    $state = 'MAX'
                    $maxSince = $now
                    $maxSinceSeconds = $elapsedSeconds
                    $lastMaxWrite = $now
                    $lastMaxWriteSeconds = $elapsedSeconds
                    $maxVerificationPending = $true
                    $rpmMismatchSamples = 0
                    $reason = if ($critical) { 'critical_temperature' } elseif ($loadSamples -ge [int]$script:Config.preemptLoadSamples) { 'sustained_cpu_load' } elseif ($rapidRise) { 'rapid_temperature_rise' } else { 'sustained_temperature' }
                    $transition = [ordered]@{ at = $now.ToString('o'); from = 'AUTO'; to = 'MAX'; reason = $reason }
                    $transitionHistory.Add($transition)
                    Write-ControllerEvent -Event 'profile_changed' -Data $transition
                    $hotSamples = 0
                }
                elseif (-not $simulation) {
                    $behaviorValue = Get-OptionalSampleValue $sample 'fanBehaviorBitmap'
                    $cpuFanMode = if ($null -ne $behaviorValue) { ([uint32]$behaviorValue -shr 8) -band 3 } else { $null }
                    if ($null -ne $cpuFanMode -and $cpuFanMode -ne 1) { $rpmMismatchSamples++ } else { $rpmMismatchSamples = 0 }
                    if ($rpmMismatchSamples -ge [int]$script:Config.rpmMismatchSamples -and
                        ($elapsedSeconds - $lastMaxWriteSeconds) -ge [double]$script:Config.rpmReassertMinIntervalSeconds) {
                        Set-HardwareFanProfile -Profile 'AUTO'
                        Write-ControllerEvent -Event 'external_override_corrected' -Data @{ desiredState = 'AUTO'; fanBehaviorBitmap = $behaviorValue; mismatchSamples = $rpmMismatchSamples }
                        $lastMaxWrite = $now
                        $lastMaxWriteSeconds = $elapsedSeconds
                        $rpmMismatchSamples = 0
                    }
                }
            }
            else {
                $hotSamples = 0
                if ($cool) { $coolSamples++ } else { $coolSamples = 0 }
                $heldSeconds = $elapsedSeconds - $maxSinceSeconds
                if ($heldSeconds -ge [double]$script:Config.minMaxSeconds -and $coolSamples -ge [int]$script:Config.releaseSamples) {
                    Set-HardwareFanProfile -Profile 'AUTO'
                    $state = 'AUTO'
                    $transition = [ordered]@{ at = $now.ToString('o'); from = 'MAX'; to = 'AUTO'; reason = 'sustained_cool_idle' }
                    $transitionHistory.Add($transition)
                    Write-ControllerEvent -Event 'profile_changed' -Data $transition
                    $coolSamples = 0
                    $lastMaxWrite = $now
                    $lastMaxWriteSeconds = $elapsedSeconds
                    $rpmMismatchSamples = 0
                }
                elseif (-not $simulation -and $maxVerificationPending -and $heldSeconds -ge [double]$script:Config.verifyMaxAfterSeconds) {
                    if ([int]$sample.cpuFanRpm -lt [int]$script:Config.minimumMaxRpm -or [int]$sample.gpuFanRpm -lt [int]$script:Config.minimumMaxRpm) {
                        Set-HardwareFanProfile -Profile 'MAX'
                        $lastMaxWrite = $now
                        $lastMaxWriteSeconds = $elapsedSeconds
                        Write-ControllerEvent -Event 'max_verification_retry' -Data @{ cpuFanRpm = [int]$sample.cpuFanRpm; gpuFanRpm = [int]$sample.gpuFanRpm }
                    }
                    else {
                        Write-ControllerEvent -Event 'max_verified' -Data @{ cpuFanRpm = [int]$sample.cpuFanRpm; gpuFanRpm = [int]$sample.gpuFanRpm }
                    }
                    $maxVerificationPending = $false
                }
                elseif (-not $simulation) {
                    $behaviorValue = Get-OptionalSampleValue $sample 'fanBehaviorBitmap'
                    $profileMismatch = ($null -ne $behaviorValue -and [uint32]$behaviorValue -ne [uint32]512) -or
                        [int]$sample.cpuFanRpm -lt [int]$script:Config.minimumMaxRpm -or
                        [int]$sample.gpuFanRpm -lt [int]$script:Config.minimumMaxRpm
                    if ($profileMismatch) { $rpmMismatchSamples++ } else { $rpmMismatchSamples = 0 }
                    if ($rpmMismatchSamples -ge [int]$script:Config.rpmMismatchSamples -and
                        ($elapsedSeconds - $lastMaxWriteSeconds) -ge [double]$script:Config.rpmReassertMinIntervalSeconds) {
                        Set-HardwareFanProfile -Profile 'MAX'
                        Write-ControllerEvent -Event 'external_override_corrected' -Data @{ fanBehaviorBitmap = $behaviorValue; cpuFanRpm = [int]$sample.cpuFanRpm; gpuFanRpm = [int]$sample.gpuFanRpm; mismatchSamples = $rpmMismatchSamples }
                        $lastMaxWrite = $now
                        $lastMaxWriteSeconds = $elapsedSeconds
                        $rpmMismatchSamples = 0
                    }
                }
            }

            $status = [ordered]@{
                updatedAt = $now.ToString('o')
                state = $state
                cpuTempC = [int]$cpuTemp
                gpuTempC = [int]$gpuTemp
                systemTempC = [int]$systemTemp
                cpuLoadPct = [int]$cpuLoad
                cpuMaxLogicalLoadPct = [int]$cpuMaxLogicalLoad
                cpuFanRpm = if ($null -ne (Get-OptionalSampleValue $sample 'cpuFanRpm')) { [int](Get-OptionalSampleValue $sample 'cpuFanRpm') } else { $null }
                gpuFanRpm = if ($null -ne (Get-OptionalSampleValue $sample 'gpuFanRpm')) { [int](Get-OptionalSampleValue $sample 'gpuFanRpm') } else { $null }
                fanBehaviorBitmap = if ($null -ne (Get-OptionalSampleValue $sample 'fanBehaviorBitmap')) { [uint32](Get-OptionalSampleValue $sample 'fanBehaviorBitmap') } else { $null }
                hotSamples = $hotSamples
                loadSamples = $loadSamples
                coolSamples = $coolSamples
                failureSamples = $failureSamples
                status = if ($simulation) {
                    'SIMULATION'
                }
                elseif ($state -eq 'MAX') {
                    $mode = if ($null -ne (Get-OptionalSampleValue $sample 'fanBehaviorBitmap')) { ([uint32](Get-OptionalSampleValue $sample 'fanBehaviorBitmap') -shr 8) -band 3 } else { $null }
                    if ($mode -eq 2 -and [int]$sample.cpuFanRpm -ge [int]$script:Config.minimumMaxRpm -and [int]$sample.gpuFanRpm -ge [int]$script:Config.minimumMaxRpm) { 'HEALTHY_VERIFIED' } else { 'REASSERT_PENDING' }
                }
                else {
                    $mode = if ($null -ne (Get-OptionalSampleValue $sample 'fanBehaviorBitmap')) { ([uint32](Get-OptionalSampleValue $sample 'fanBehaviorBitmap') -shr 8) -band 3 } else { $null }
                    if ($mode -eq 1) { 'HEALTHY_VERIFIED' } else { 'REASSERT_PENDING' }
                }
            }
            Write-ControllerStatus -Status $status
            if (($sampleNumber % [int]$script:Config.telemetryEverySamples) -eq 0) {
                Write-ControllerEvent -Event 'telemetry' -Data $status
            }
        }
        catch {
            $failureMessage = $_.Exception.Message
            $failureSamples++
            Write-ControllerEvent -Event 'sensor_or_control_error' -Data @{ message = $failureMessage; consecutiveFailures = $failureSamples; state = $state }
            if ($failureSamples -ge [int]$script:Config.sensorFailureSamples) {
                $reassertDue = $state -ne 'MAX' -or
                    ($elapsedSeconds - $lastMaxWriteSeconds) -ge [double]$script:Config.rpmReassertMinIntervalSeconds
                if ($reassertDue) {
                    $previousState = $state
                    Set-HardwareFanProfile -Profile 'MAX'
                    $state = 'MAX'
                    if ($previousState -ne 'MAX') {
                        $maxSince = $now
                        $maxSinceSeconds = $elapsedSeconds
                        $transition = [ordered]@{ at = $now.ToString('o'); from = $previousState; to = 'MAX'; reason = 'sensor_fail_safe' }
                        $transitionHistory.Add($transition)
                        Write-ControllerEvent -Event 'profile_changed' -Data $transition
                    }
                    else {
                        Write-ControllerEvent -Event 'fail_safe_max_reasserted' -Data @{ consecutiveFailures = $failureSamples; message = $failureMessage }
                    }
                    $lastMaxWrite = $now
                    $lastMaxWriteSeconds = $elapsedSeconds
                    $maxVerificationPending = $true
                    $rpmMismatchSamples = 0
                }
            }
            Write-ControllerStatus -Status ([ordered]@{
                updatedAt = $now.ToString('o')
                state = $state
                failureSamples = $failureSamples
                status = 'DEGRADED_FAIL_SAFE'
                lastError = $failureMessage
            })
        }

        if ($simulation) { continue }
        Start-Sleep -Seconds ([int]$script:Config.pollSeconds)
    }
}
finally {
    Write-ControllerEvent -Event 'controller_stopped' -Data @{ state = $state }
    if ($null -ne $mutex) {
        try { $mutex.ReleaseMutex() } catch { }
        $mutex.Dispose()
    }
}

[ordered]@{
    finalState = $state
    samples = $sampleNumber - 1
    transitions = @($transitionHistory)
} | ConvertTo-Json -Depth 8
