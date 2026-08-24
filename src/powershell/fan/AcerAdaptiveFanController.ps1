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

    # Move-Item -Force unlinks the destination before renaming it, so a concurrent reader can
    # observe the heartbeat as missing or half-written. File.Replace swaps the directory entry
    # atomically: the watchdog always sees either the previous document or the new one.
    for ($attempt = 1; $attempt -le 10; $attempt++) {
        try {
            if (Test-Path -LiteralPath $StatusPath -PathType Leaf) {
                # PowerShell binds a bare $null to String.Empty, which Replace rejects; NullString passes a real null.
                [System.IO.File]::Replace($temporaryPath, $StatusPath, [NullString]::Value, $true)
            }
            else {
                [System.IO.File]::Move($temporaryPath, $StatusPath)
            }
            return
        }
        catch [System.IO.IOException] {
            # A reader holds the destination open for this instant. Retry rather than fall back
            # immediately to the non-atomic rename.
            Start-Sleep -Milliseconds 50
        }
    }

    # Publishing the heartbeat matters more than publishing it atomically: a heartbeat the
    # watchdog never sees reads as a dead controller. The reader tolerates the residual gap.
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
    param(
        [ValidateSet('AUTO', 'MAX', 'CURVE')] [string] $Profile,
        [ValidateRange(0, 100)] [int] $Percent = 100
    )
    if ($null -eq $script:Gaming) { return }

    if ($Profile -eq 'CURVE') {
        # Firmware fan mode 3 is CUSTOM. In that mode SetGamingFanSpeed carries a real percentage
        # in bits 8-15 instead of the fixed 100 % that MAX writes, which is what makes a
        # proportional curve possible at all. Bitmap 0x0009 is CPU + GPU, as for the other modes.
        $behavior = Invoke-CimMethod -InputObject $script:Gaming -MethodName 'SetGamingFanBehavior' -Arguments @{ gmInput = [uint64]0x00C30009 }
        $cpu = Invoke-CimMethod -InputObject $script:Gaming -MethodName 'SetGamingFanSpeed' -Arguments @{ gmInput = [uint64]((([uint64]$Percent) -shl 8) -bor 0x01) }
        $gpu = Invoke-CimMethod -InputObject $script:Gaming -MethodName 'SetGamingFanSpeed' -Arguments @{ gmInput = [uint64]((([uint64]$Percent) -shl 8) -bor 0x04) }
        if ([uint32]$behavior.gmOutput -ne 0 -or [uint32]$cpu.gmOutput -ne 0 -or [uint32]$gpu.gmOutput -ne 0) {
            throw "Acer firmware rejected the CURVE fan command at $Percent %."
        }
        return
    }

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

function Set-VerifiedAutoProfile {
    Set-HardwareFanProfile -Profile 'AUTO'

    $simulationReadbackEnabled = $null -eq $script:Gaming -and
        [bool]$script:SimulationAutoReadbackMode
    if ($null -eq $script:Gaming -and -not $simulationReadbackEnabled) { return $null }

    $observed = $null
    $lastDetail = 'No readback was obtained.'
    foreach ($attempt in 1..5) {
        if ($null -ne $script:Gaming -and $attempt -gt 1) { Start-Sleep -Milliseconds 250 }
        try {
            if ($null -eq $script:Gaming) {
                if ($script:SimulationAutoReadbacks.Count -eq 0) { throw 'Simulated AUTO readback queue was exhausted.' }
                $observed = $script:SimulationAutoReadbacks.Dequeue()
            }
            else {
                $observed = Read-HardwareSample
            }
            if (-not (Test-SampleValidity $observed)) { throw 'One or more readback sensor values are outside the accepted range.' }
            $behaviorValue = Get-OptionalSampleValue $observed 'fanBehaviorBitmap'
            if ($null -eq $behaviorValue) { throw 'AUTO readback omitted fanBehaviorBitmap.' }
            $mode = ([uint32]$behaviorValue -shr 8) -band 3
            if ($mode -eq 1) { return $observed }
            $lastDetail = "Observed firmware mode $mode on attempt $attempt."
        }
        catch {
            $lastDetail = $_.Exception.Message
        }
    }

    $fallbackDetail = 'MAX fallback requested.'
    try { Set-HardwareFanProfile -Profile 'MAX' }
    catch { $fallbackDetail = "MAX fallback failed: $($_.Exception.Message)" }
    throw "AUTO firmware readback verification failed. $lastDetail $fallbackDetail"
}

function Get-CurveTargetPercent {
    param([double] $TemperatureC, [Parameter(Mandatory)] $Configuration)

    $minTemp = [double]$Configuration.curveMinTempC
    $maxTemp = [double]$Configuration.curveMaxTempC
    $minPct = [double]$Configuration.curveMinPct
    $maxPct = [double]$Configuration.curveMaxPct

    $raw = if ($TemperatureC -le $minTemp) { $minPct }
        elseif ($TemperatureC -ge $maxTemp) { $maxPct }
        else { $minPct + ($maxPct - $minPct) * (($TemperatureC - $minTemp) / ($maxTemp - $minTemp)) }

    # Quantise upward. Rounding to the nearest step would sometimes command less cooling than the
    # curve asks for; rounding up never does, and the steps keep the controller from rewriting the
    # percentage on every poll for a fraction of a degree.
    $step = [double]$Configuration.curveStepPct
    $stepped = [math]::Ceiling($raw / $step) * $step
    if ($stepped -gt $maxPct) { $stepped = $maxPct }
    if ($stepped -lt $minPct) { $stepped = $minPct }
    return [int]$stepped
}

function Get-CurveReleaseTemperature {
    param([int] $Percent, [Parameter(Mandatory)] $Configuration)

    # The lower edge of the temperature band that still maps to $Percent once the curve has been
    # quantised upward. Below this the curve already commands one step less, so this is the point
    # the falling hysteresis is measured from. Inverting $Percent directly would instead return the
    # top of the band and make the hysteresis window collapse.
    $minTemp = [double]$Configuration.curveMinTempC
    $maxTemp = [double]$Configuration.curveMaxTempC
    $minPct = [double]$Configuration.curveMinPct
    $maxPct = [double]$Configuration.curveMaxPct
    $edge = [double]$Percent - [double]$Configuration.curveStepPct
    if ($edge -le $minPct) { return $minTemp }
    if ($edge -ge $maxPct) { return $maxTemp }
    return $minTemp + ($maxTemp - $minTemp) * (($edge - $minPct) / ($maxPct - $minPct))
}

function Get-CurveCommand {
    param(
        [double] $AveragedTemperatureC,
        [int] $CurrentPercent,
        [double] $SecondsSinceLastChange,
        [Parameter(Mandatory)] $Configuration
    )

    $target = Get-CurveTargetPercent -TemperatureC $AveragedTemperatureC -Configuration $Configuration

    if ($CurrentPercent -le 0) {
        # MINSTART: the first command after the fans were firmware-owned has to be high enough to
        # spin them up reliably, even when the curve alone would ask for less.
        $start = [int]$Configuration.curveStartPct
        $percent = if ($target -lt $start) { $start } else { $target }
        return [pscustomobject]@{ percent = $percent; changed = $true; reason = 'curve_start' }
    }

    if ($target -gt $CurrentPercent) {
        # More cooling is never delayed. Only reductions are damped.
        return [pscustomobject]@{ percent = $target; changed = $true; reason = 'curve_increase' }
    }

    if ($target -lt $CurrentPercent) {
        if ($SecondsSinceLastChange -lt [double]$Configuration.curveDecreaseHoldSeconds) {
            return [pscustomobject]@{ percent = $CurrentPercent; changed = $false; reason = 'curve_decrease_hold' }
        }
        # Falling hysteresis: step down only once the average has dropped a further
        # curveDecreaseHysteresisC below the temperature that still justifies the current percent.
        # Without this an intermittent workload makes the fans audibly pump up and down.
        $releaseTemperature = Get-CurveReleaseTemperature -Percent $CurrentPercent -Configuration $Configuration
        if ($AveragedTemperatureC -gt ($releaseTemperature - [double]$Configuration.curveDecreaseHysteresisC)) {
            return [pscustomobject]@{ percent = $CurrentPercent; changed = $false; reason = 'curve_decrease_hysteresis' }
        }
        return [pscustomobject]@{ percent = $target; changed = $true; reason = 'curve_decrease' }
    }

    return [pscustomobject]@{ percent = $CurrentPercent; changed = $false; reason = 'curve_steady' }
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
        startupMinMaxSeconds = @(0, 7200)
        startupReleaseSamples = @(1, 3600)
        curveMinTempC = @(30, 95)
        curveMaxTempC = @(35, 100)
        curveMinPct = @(10, 100)
        curveMaxPct = @(50, 100)
        curveStartPct = @(10, 100)
        curveStepPct = @(1, 25)
        curveAverageSamples = @(1, 60)
        curveDecreaseHysteresisC = @(0, 20)
        curveDecreaseHoldSeconds = @(0, 600)
        curveMinimumVerifiedRpm = @(500, 10000)
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
    if ([double]$Configuration.startupMinMaxSeconds -gt [double]$Configuration.minMaxSeconds) { throw 'startupMinMaxSeconds must not exceed minMaxSeconds.' }
    # The startup default is the weakest claim the controller can hold, so the evidence needed to
    # drop it must never be stronger than the evidence needed to drop a MAX entered from real heat.
    if ([double]$Configuration.startupReleaseSamples -gt [double]$Configuration.releaseSamples) { throw 'startupReleaseSamples must not exceed releaseSamples.' }

    $startupReleaseLoadProperty = $Configuration.PSObject.Properties['startupReleaseIgnoresLoad']
    if ($null -eq $startupReleaseLoadProperty -or $startupReleaseLoadProperty.Value -isnot [bool]) {
        throw 'startupReleaseIgnoresLoad must be present and boolean.'
    }

    $curveEnabledProperty = $Configuration.PSObject.Properties['curveEnabled']
    if ($null -eq $curveEnabledProperty -or $curveEnabledProperty.Value -isnot [bool]) {
        throw 'curveEnabled must be present and boolean.'
    }
    if ([double]$Configuration.curveMinTempC -ge [double]$Configuration.curveMaxTempC) { throw 'curveMinTempC must be lower than curveMaxTempC.' }
    if ([double]$Configuration.curveMinPct -gt [double]$Configuration.curveMaxPct) { throw 'curveMinPct must not exceed curveMaxPct.' }
    if ([double]$Configuration.curveStartPct -lt [double]$Configuration.curveMinPct) { throw 'curveStartPct must not be lower than curveMinPct.' }
    if ([double]$Configuration.curveStartPct -gt [double]$Configuration.curveMaxPct) { throw 'curveStartPct must not exceed curveMaxPct.' }
    # The curve must already be at full speed before the critical threshold takes over, otherwise
    # there is a band where the machine is critically hot and the fans are still proportional.
    if ([double]$Configuration.curveMaxTempC -gt [double]$Configuration.criticalCpuC) { throw 'curveMaxTempC must not exceed criticalCpuC.' }
    if ([double]$Configuration.curveMinimumVerifiedRpm -gt [double]$Configuration.minimumMaxRpm) { throw 'curveMinimumVerifiedRpm must not exceed minimumMaxRpm.' }
}

if (-not (Test-Path -LiteralPath $ConfigPath)) { throw "Configuration not found: $ConfigPath" }
$script:Config = Get-Content -LiteralPath $ConfigPath -Raw | ConvertFrom-Json
Assert-ControllerConfiguration -Configuration $script:Config
# Off by default. With curveEnabled false every path below behaves exactly as the AUTO/MAX
# controller did, so the proportional band cannot activate without an explicit decision.
$script:CurveEnabled = [bool]$script:Config.curveEnabled

# Scoped strictly to the unproven startup MAX. Every other path keeps the load term.
$script:StartupReleaseIgnoresLoad = [bool]$script:Config.startupReleaseIgnoresLoad
if ($ValidateOnly) {
    [ordered]@{ status = 'VALID'; configPath = $ConfigPath } | ConvertTo-Json -Compress
    exit 0
}
$outputDirectory = Split-Path -Parent $LogPath
if (-not (Test-Path -LiteralPath $outputDirectory)) { New-Item -ItemType Directory -Path $outputDirectory -Force | Out-Null }

$simulation = $null
$simulationStartupMaxHold = $false
$script:Gaming = $null
$script:SimulationAutoReadbacks = $null
$script:SimulationAutoReadbackMode = $false
$mutex = $null
if ($SimulationPath) {
    $simulation = Get-Content -LiteralPath $SimulationPath -Raw | ConvertFrom-Json
    if ($simulation.initialState) { $InitialState = [string]$simulation.initialState }
    # A fixture that merely starts in MAX is not the same thing as the fail-safe MAX the controller
    # adopts before it has read a sample, so simulations opt into the startup hold explicitly.
    $startupHoldProperty = $simulation.PSObject.Properties['startupMaxHold']
    if ($null -ne $startupHoldProperty) { $simulationStartupMaxHold = [bool]$startupHoldProperty.Value }
    $script:SimulationAutoReadbacks = [System.Collections.Generic.Queue[object]]::new()
    $autoReadbacksProperty = $simulation.PSObject.Properties['autoWriteReadbacks']
    if ($null -ne $autoReadbacksProperty) {
        $script:SimulationAutoReadbackMode = $true
        foreach ($readback in @($autoReadbacksProperty.Value)) { $script:SimulationAutoReadbacks.Enqueue($readback) }
    }
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
# The MAX the controller adopts before it has read a single sample is a fail-safe default, not a
# response to measured heat. While that default is still in force the release gate uses
# startupMinMaxSeconds; every MAX entered from a real trigger keeps the full minMaxSeconds floor.
$startupMaxHold = $simulationStartupMaxHold -and $state -eq 'MAX'
$curvePercent = 0
$curveLastChangeSeconds = -1000.0
$curveTemperatures = [System.Collections.Generic.Queue[double]]::new()
$curveTemperature = 0.0
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
        $startupMaxHold = $true
    }
    Write-ControllerEvent -Event 'controller_started' -Data @{ state = $state; simulation = [bool]$simulation; startupMaxHold = [bool]$startupMaxHold }

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
            $releaseTrendStable = $cpuRise -le [double]$script:Config.releaseRiseToleranceC -and
                $gpuRise -le [double]$script:Config.releaseRiseToleranceC -and
                $systemRise -le [double]$script:Config.releaseRiseToleranceC

            $critical = $cpuTemp -ge [double]$script:Config.criticalCpuC -or
                $gpuTemp -ge [double]$script:Config.criticalGpuC -or
                $systemTemp -ge [double]$script:Config.criticalSystemC
            $hot = $cpuTemp -ge [double]$script:Config.maxCpuC -or
                $gpuTemp -ge [double]$script:Config.maxGpuC -or
                $systemTemp -ge [double]$script:Config.maxSystemC -or
                $loadSamples -ge [int]$script:Config.preemptLoadSamples -or
                $rapidRise
            $releaseThermalEnvelope = $cpuTemp -le [double]$script:Config.releaseCpuC -and
                ($gpuTemp -eq 0 -or $gpuTemp -le [double]$script:Config.releaseGpuC) -and
                $systemTemp -le [double]$script:Config.releaseSystemC
            $releaseIdleSample = $releaseThermalEnvelope -and
                $cpuLoad -le [double]$script:Config.releaseCpuLoadPct -and
                -not $loadTrigger
            $releaseReset = -not $releaseThermalEnvelope -or
                $rapidRise -or
                $loadSamples -ge [int]$script:Config.preemptLoadSamples

            # The curve is driven by the hotter of the two silicon sensors, averaged over the last
            # curveAverageSamples polls. Averaging is what stops a one-sample spike from stepping
            # the fans up; the system sensor is excluded because it is on a different scale from
            # the CPU-referenced curve thresholds.
            $curveSampleTemp = if ($gpuTemp -gt $cpuTemp) { $gpuTemp } else { $cpuTemp }
            $curveTemperatures.Enqueue([double]$curveSampleTemp)
            while ($curveTemperatures.Count -gt [int]$script:Config.curveAverageSamples) { [void]$curveTemperatures.Dequeue() }
            $curveTemperature = [double](($curveTemperatures | Measure-Object -Average).Average)

            if ($state -eq 'AUTO') {
                $coolSamples = 0
                if ($hot) { $hotSamples++ } else { $hotSamples = 0 }
                if ($critical -or $hotSamples -ge [int]$script:Config.enterSamples) {
                    # Critical heat always commands 100 %. Everything else is demand, and demand is
                    # exactly the band where the fans used to run at 6122 RPM with the machine in
                    # the forties.
                    if ($script:CurveEnabled -and -not $critical) {
                        $curveCommand = Get-CurveCommand -AveragedTemperatureC $curveTemperature -CurrentPercent 0 `
                            -SecondsSinceLastChange 0 -Configuration $script:Config
                        Set-HardwareFanProfile -Profile 'CURVE' -Percent $curveCommand.percent
                        $curvePercent = $curveCommand.percent
                        $curveLastChangeSeconds = $elapsedSeconds
                        $state = 'CURVE'
                    }
                    else {
                        Set-HardwareFanProfile -Profile 'MAX'
                        $curvePercent = 0
                        $state = 'MAX'
                    }
                    $maxSince = $now
                    $maxSinceSeconds = $elapsedSeconds
                    $lastMaxWrite = $now
                    $lastMaxWriteSeconds = $elapsedSeconds
                    $maxVerificationPending = $state -eq 'MAX'
                    $startupMaxHold = $false
                    $rpmMismatchSamples = 0
                    $reason = if ($critical) { 'critical_temperature' } elseif ($loadSamples -ge [int]$script:Config.preemptLoadSamples) { 'sustained_cpu_load' } elseif ($rapidRise) { 'rapid_temperature_rise' } else { 'sustained_temperature' }
                    $transition = [ordered]@{ at = $now.ToString('o'); from = 'AUTO'; to = $state; reason = $reason }
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
                        try {
                            $verifiedAutoSample = Set-VerifiedAutoProfile
                            if ($null -ne $verifiedAutoSample) { $sample = $verifiedAutoSample }
                        }
                        catch {
                            $state = 'MAX'
                            $maxSince = $now
                            $maxSinceSeconds = $elapsedSeconds
                            $lastMaxWrite = $now
                            $lastMaxWriteSeconds = $elapsedSeconds
                            $maxVerificationPending = $true
                            $startupMaxHold = $false
                            $coolSamples = 0
                            $rpmMismatchSamples = 0
                            $transition = [ordered]@{ at = $now.ToString('o'); from = 'AUTO'; to = 'MAX'; reason = 'auto_readback_fail_safe' }
                            $transitionHistory.Add($transition)
                            Write-ControllerEvent -Event 'profile_changed' -Data $transition
                            throw
                        }
                        Write-ControllerEvent -Event 'external_override_corrected' -Data @{ desiredState = 'AUTO'; fanBehaviorBitmap = $behaviorValue; mismatchSamples = $rpmMismatchSamples }
                        $lastMaxWrite = $now
                        $lastMaxWriteSeconds = $elapsedSeconds
                        $rpmMismatchSamples = 0
                    }
                }
            }
            else {
                $hotSamples = 0
                # The startup MAX is an unproven fail-safe default, not measured heat. Load predicts
                # heat still to come, which makes it the right gate for *entering* MAX and the wrong
                # one for leaving a default on a machine the sensors already show is cold. Windows
                # guarantees a CPU burst for the first seconds after a boot or a resume, so gating
                # this release on load pinned the fans at 6122 RPM with the package at 41 C.
                # Temperature still governs: every thermal reset below applies unchanged.
                $startupRelease = [bool]$startupMaxHold
                $releaseEvidenceSample = if ($startupRelease -and $script:StartupReleaseIgnoresLoad) {
                    $releaseThermalEnvelope
                }
                else {
                    $releaseIdleSample
                }
                if ($releaseReset) { $coolSamples = 0 }
                elseif ($releaseEvidenceSample) { $coolSamples++ }

                if ($state -eq 'CURVE') {
                    if ($critical) {
                        # The proportional band never covers a critical sample.
                        Set-HardwareFanProfile -Profile 'MAX'
                        $curvePercent = 0
                        $state = 'MAX'
                        $maxVerificationPending = $true
                        $lastMaxWrite = $now
                        $lastMaxWriteSeconds = $elapsedSeconds
                        $rpmMismatchSamples = 0
                        $transition = [ordered]@{ at = $now.ToString('o'); from = 'CURVE'; to = 'MAX'; reason = 'critical_temperature' }
                        $transitionHistory.Add($transition)
                        Write-ControllerEvent -Event 'profile_changed' -Data $transition
                    }
                    else {
                        $curveCommand = Get-CurveCommand -AveragedTemperatureC $curveTemperature -CurrentPercent $curvePercent `
                            -SecondsSinceLastChange ($elapsedSeconds - $curveLastChangeSeconds) -Configuration $script:Config
                        if ($curveCommand.changed -and $curveCommand.percent -ne $curvePercent) {
                            Set-HardwareFanProfile -Profile 'CURVE' -Percent $curveCommand.percent
                            Write-ControllerEvent -Event 'curve_speed_changed' -Data @{
                                from = $curvePercent; to = $curveCommand.percent; reason = $curveCommand.reason
                                temperatureC = [math]::Round($curveTemperature, 1)
                            }
                            $curvePercent = $curveCommand.percent
                            $curveLastChangeSeconds = $elapsedSeconds
                        }
                    }
                }

                $heldSeconds = $elapsedSeconds - $maxSinceSeconds
                # Only the unproven startup default may leave early, and it still has to earn it with
                # its own window of verified cool, trend-stable telemetry.
                $minimumHeldSeconds = if ($startupRelease) {
                    [double]$script:Config.startupMinMaxSeconds
                }
                else {
                    [double]$script:Config.minMaxSeconds
                }
                $requiredCoolSamples = if ($startupRelease) {
                    [int]$script:Config.startupReleaseSamples
                }
                else {
                    [int]$script:Config.releaseSamples
                }
                if ($heldSeconds -ge $minimumHeldSeconds -and
                    $coolSamples -ge $requiredCoolSamples -and
                    $releaseEvidenceSample -and
                    $releaseTrendStable) {
                    try {
                        $verifiedAutoSample = Set-VerifiedAutoProfile
                        if ($null -ne $verifiedAutoSample) { $sample = $verifiedAutoSample }
                    }
                    catch {
                        $lastMaxWrite = $now
                        $lastMaxWriteSeconds = $elapsedSeconds
                        $maxVerificationPending = $true
                        $coolSamples = 0
                        $rpmMismatchSamples = 0
                        throw
                    }
                    $releasedFrom = $state
                    $state = 'AUTO'
                    $curvePercent = 0
                    $releaseReason = if ($startupMaxHold) { 'startup_max_released_on_verified_cool' } else { 'sustained_cool_idle' }
                    $startupMaxHold = $false
                    $transition = [ordered]@{ at = $now.ToString('o'); from = $releasedFrom; to = 'AUTO'; reason = $releaseReason }
                    $transitionHistory.Add($transition)
                    Write-ControllerEvent -Event 'profile_changed' -Data $transition
                    $coolSamples = 0
                    $lastMaxWrite = $now
                    $lastMaxWriteSeconds = $elapsedSeconds
                    $rpmMismatchSamples = 0
                }
                elseif ($state -eq 'CURVE' -and -not $simulation) {
                    # CURVE is firmware mode 3. Anything else means something overwrote the mode,
                    # so re-issue the current percentage rather than falling back to 100 %.
                    $behaviorValue = Get-OptionalSampleValue $sample 'fanBehaviorBitmap'
                    $curveMode = if ($null -ne $behaviorValue) { ([uint32]$behaviorValue -shr 8) -band 3 } else { $null }
                    if ($null -ne $curveMode -and $curveMode -ne 3) { $rpmMismatchSamples++ } else { $rpmMismatchSamples = 0 }
                    if ($rpmMismatchSamples -ge [int]$script:Config.rpmMismatchSamples -and
                        ($elapsedSeconds - $lastMaxWriteSeconds) -ge [double]$script:Config.rpmReassertMinIntervalSeconds) {
                        Set-HardwareFanProfile -Profile 'CURVE' -Percent $curvePercent
                        Write-ControllerEvent -Event 'external_override_corrected' -Data @{ desiredState = 'CURVE'; curvePercent = $curvePercent; fanBehaviorBitmap = $behaviorValue; mismatchSamples = $rpmMismatchSamples }
                        $lastMaxWrite = $now
                        $lastMaxWriteSeconds = $elapsedSeconds
                        $rpmMismatchSamples = 0
                    }
                }
                elseif ($state -eq 'MAX' -and -not $simulation -and $maxVerificationPending -and $heldSeconds -ge [double]$script:Config.verifyMaxAfterSeconds) {
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
                elseif ($state -eq 'MAX' -and -not $simulation) {
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

            $statusCpuMaxLogicalLoad = Get-OptionalSampleValue $sample 'cpuMaxLogicalLoadPct'
            if ($null -eq $statusCpuMaxLogicalLoad) { $statusCpuMaxLogicalLoad = $sample.cpuLoadPct }
            $status = [ordered]@{
                updatedAt = $now.ToString('o')
                state = $state
                cpuTempC = [int]$sample.cpuTempC
                gpuTempC = [int]$sample.gpuTempC
                systemTempC = [int]$sample.systemTempC
                cpuLoadPct = [int]$sample.cpuLoadPct
                cpuMaxLogicalLoadPct = [int]$statusCpuMaxLogicalLoad
                cpuFanRpm = if ($null -ne (Get-OptionalSampleValue $sample 'cpuFanRpm')) { [int](Get-OptionalSampleValue $sample 'cpuFanRpm') } else { $null }
                gpuFanRpm = if ($null -ne (Get-OptionalSampleValue $sample 'gpuFanRpm')) { [int](Get-OptionalSampleValue $sample 'gpuFanRpm') } else { $null }
                fanBehaviorBitmap = if ($null -ne (Get-OptionalSampleValue $sample 'fanBehaviorBitmap')) { [uint32](Get-OptionalSampleValue $sample 'fanBehaviorBitmap') } else { $null }
                hotSamples = $hotSamples
                loadSamples = $loadSamples
                coolSamples = $coolSamples
                failureSamples = $failureSamples
                startupMaxHold = [bool]$startupMaxHold
                curvePercent = [int]$curvePercent
                status = if ($simulation) {
                    'SIMULATION'
                }
                elseif ($state -eq 'CURVE') {
                    $mode = if ($null -ne (Get-OptionalSampleValue $sample 'fanBehaviorBitmap')) { ([uint32](Get-OptionalSampleValue $sample 'fanBehaviorBitmap') -shr 8) -band 3 } else { $null }
                    # The percent-to-RPM relationship has not been measured on this hardware yet,
                    # so the health gate asserts the mode and a floor, not a predicted RPM.
                    if ($mode -eq 3 -and [int]$sample.cpuFanRpm -ge [int]$script:Config.curveMinimumVerifiedRpm -and [int]$sample.gpuFanRpm -ge [int]$script:Config.curveMinimumVerifiedRpm) { 'HEALTHY_VERIFIED' } else { 'REASSERT_PENDING' }
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
                    $curvePercent = 0
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
                    $startupMaxHold = $false
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
