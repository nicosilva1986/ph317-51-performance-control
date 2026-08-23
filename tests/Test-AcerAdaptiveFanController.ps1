$ErrorActionPreference = 'Stop'
$root = Split-Path -Parent $PSCommandPath
$fanRoot = [IO.Path]::GetFullPath((Join-Path $root '..\src\powershell\fan'))
$controller = Join-Path $fanRoot 'AcerAdaptiveFanController.ps1'
$config = Join-Path $fanRoot 'fan-controller-config.json'
$engineName = if ($PSVersionTable.PSEdition -eq 'Core') { 'pwsh.exe' } else { 'powershell.exe' }
$engine = Join-Path $PSHOME $engineName
$testRoot = Join-Path ([IO.Path]::GetTempPath()) ('AcerAdaptiveFanTests-' + [guid]::NewGuid().ToString('N'))
New-Item -ItemType Directory -Path $testRoot | Out-Null

function New-Sample {
    param(
        [int] $Cpu,
        [int] $Gpu,
        [int] $System,
        [int] $Load,
        [int] $MaxLogical = -1,
        [int] $Behavior = -1,
        [int] $CpuFanRpm = -1,
        [int] $GpuFanRpm = -1
    )
    $sample = [ordered]@{ cpuTempC = $Cpu; gpuTempC = $Gpu; systemTempC = $System; cpuLoadPct = $Load }
    if ($MaxLogical -ge 0) { $sample.cpuMaxLogicalLoadPct = $MaxLogical }
    if ($Behavior -ge 0) { $sample.fanBehaviorBitmap = [uint32]$Behavior }
    if ($CpuFanRpm -ge 0) { $sample.cpuFanRpm = $CpuFanRpm }
    if ($GpuFanRpm -ge 0) { $sample.gpuFanRpm = $GpuFanRpm }
    return $sample
}

function Invoke-SimulationCase {
    param([string] $Name, [string] $InitialState, [object[]] $Samples, [object[]] $AutoWriteReadbacks = @(), [switch] $StartupMaxHold, [switch] $CurveEnabled)
    $caseRoot = Join-Path $testRoot $Name
    New-Item -ItemType Directory -Path $caseRoot | Out-Null
    $simulationPath = Join-Path $caseRoot 'simulation.json'
    $logPath = Join-Path $caseRoot 'events.jsonl'
    $statusPath = Join-Path $caseRoot 'status.json'
    $simulation = [ordered]@{ initialState = $InitialState; samples = $Samples }
    if ($StartupMaxHold) { $simulation.startupMaxHold = $true }
    if (@($AutoWriteReadbacks).Count -gt 0) { $simulation.autoWriteReadbacks = @($AutoWriteReadbacks) }
    $simulation | ConvertTo-Json -Depth 8 | Set-Content -LiteralPath $simulationPath -Encoding utf8
    $caseConfig = $config
    if ($CurveEnabled) {
        $caseConfig = Join-Path $caseRoot 'config.json'
        $configObject = Get-Content -LiteralPath $config -Raw | ConvertFrom-Json
        $configObject.curveEnabled = $true
        $configObject | ConvertTo-Json -Depth 8 | Set-Content -LiteralPath $caseConfig -Encoding utf8
    }
    $raw = & $engine -NoLogo -NoProfile -NonInteractive -File $controller -ConfigPath $caseConfig -SimulationPath $simulationPath -LogPath $logPath -StatusPath $statusPath
    if ($LASTEXITCODE -ne 0) { throw "Simulation $Name exited $LASTEXITCODE." }
    return [pscustomobject]@{
        result = ($raw | ConvertFrom-Json)
        status = (Get-Content -LiteralPath $statusPath -Raw | ConvertFrom-Json)
        events = @(Get-Content -LiteralPath $logPath | ForEach-Object { $_ | ConvertFrom-Json })
    }
}

$caseResults = [System.Collections.Generic.List[object]]::new()
try {
    $policy = Get-Content -LiteralPath $config -Raw | ConvertFrom-Json
    if ([int]$policy.pollSeconds -ne 2 -or [int]$policy.releaseSamples -ne 60 -or
        [int]$policy.minMaxSeconds -ne 300 -or [int]$policy.preemptCpuMaxLogicalLoadPct -ne 70 -or
        [int]$policy.preemptLoadSamples -ne 2 -or [int]$policy.startupMinMaxSeconds -ne 60) {
        throw 'Fan release policy contract drifted from the validated 2-minute idle / 5-minute MAX calibration.'
    }
    if ([int]$policy.startupMinMaxSeconds -gt [int]$policy.minMaxSeconds) {
        throw 'startupMinMaxSeconds must never exceed the triggered-MAX residence floor.'
    }
    $caseResults.Add([ordered]@{ name = 'release-policy-contract'; status = 'PASS' })

    $samples = [System.Collections.Generic.List[object]]::new()
    1..60 | ForEach-Object { $samples.Add((New-Sample 48 0 45 8)) }
    $case = Invoke-SimulationCase -Name 'minimum-max-residence' -InitialState MAX -Samples $samples
    if (@($case.result.transitions).Count -ne 0 -or $case.status.state -ne 'MAX' -or [int]$case.status.coolSamples -ne 60) {
        throw 'The 5-minute minimum MAX residence was weakened by the shorter idle-sample gate.'
    }
    $caseResults.Add([ordered]@{ name = 'minimum-max-residence'; status = 'PASS' })

    # The MAX adopted before the controller has read a single sample is an unproven fail-safe
    # default, so it is released under startupMinMaxSeconds. It still requires the full
    # releaseSamples of cool, idle, trend-stable evidence: 40 cool samples must not be enough.
    $samples = [System.Collections.Generic.List[object]]::new()
    1..40 | ForEach-Object { $samples.Add((New-Sample 48 0 45 8)) }
    $case = Invoke-SimulationCase -Name 'startup-max-holds-without-cool-evidence' -InitialState MAX -Samples $samples -StartupMaxHold
    if (@($case.result.transitions).Count -ne 0 -or $case.status.state -ne 'MAX' -or [int]$case.status.coolSamples -ne 40) {
        throw 'The startup fail-safe MAX released before releaseSamples of verified cool telemetry.'
    }
    $caseResults.Add([ordered]@{ name = 'startup-max-holds-without-cool-evidence'; status = 'PASS' })

    $samples = [System.Collections.Generic.List[object]]::new()
    1..60 | ForEach-Object { $samples.Add((New-Sample 48 0 45 8)) }
    $case = Invoke-SimulationCase -Name 'startup-max-releases-on-verified-cool' -InitialState MAX -Samples $samples -StartupMaxHold
    if (@($case.result.transitions).Count -ne 1 -or
        $case.result.transitions[0].reason -ne 'startup_max_released_on_verified_cool' -or
        $case.status.state -ne 'AUTO' -or [bool]$case.status.startupMaxHold) {
        throw 'The startup fail-safe MAX did not release once telemetry proved the machine cool.'
    }
    $caseResults.Add([ordered]@{ name = 'startup-max-releases-on-verified-cool'; status = 'PASS' })

    # A trigger fired while the startup hold is still in force must promote the hold to the full
    # residence: from that point on there is measured heat, not just an unproven default.
    $samples = [System.Collections.Generic.List[object]]::new()
    1..3 | ForEach-Object { $samples.Add((New-Sample 62 0 46 8)) }
    1..100 | ForEach-Object { $samples.Add((New-Sample 48 0 45 8)) }
    $case = Invoke-SimulationCase -Name 'startup-hold-promoted-by-real-trigger' -InitialState AUTO -Samples $samples -StartupMaxHold
    if (@($case.result.transitions).Count -ne 1 -or $case.result.transitions[0].to -ne 'MAX' -or
        $case.status.state -ne 'MAX' -or [int]$case.status.coolSamples -lt 60 -or [bool]$case.status.startupMaxHold) {
        throw 'A MAX entered from measured heat released under the startup floor.'
    }
    $caseResults.Add([ordered]@{ name = 'startup-hold-promoted-by-real-trigger'; status = 'PASS' })

    # A MAX entered from a real trigger keeps the full 5-minute residence, even with far more cool
    # evidence than the release gate asks for. This is the guarantee startupMinMaxSeconds must not
    # be able to reach.
    $samples = [System.Collections.Generic.List[object]]::new()
    1..3 | ForEach-Object { $samples.Add((New-Sample 52 0 46 80)) }
    1..100 | ForEach-Object { $samples.Add((New-Sample 48 0 45 8)) }
    $case = Invoke-SimulationCase -Name 'triggered-max-keeps-minimum-residence' -InitialState AUTO -Samples $samples
    if (@($case.result.transitions).Count -ne 1 -or $case.result.transitions[0].reason -ne 'sustained_cpu_load' -or
        $case.status.state -ne 'MAX' -or [int]$case.status.coolSamples -lt 60 -or [bool]$case.status.startupMaxHold) {
        throw 'A load-triggered MAX released before the 5-minute minimum residence elapsed.'
    }
    $caseResults.Add([ordered]@{ name = 'triggered-max-keeps-minimum-residence'; status = 'PASS' })

    $samples = [System.Collections.Generic.List[object]]::new()
    1..3 | ForEach-Object { $samples.Add((New-Sample 52 0 46 80)) }
    1..160 | ForEach-Object { $samples.Add((New-Sample 48 0 45 8)) }
    $case = Invoke-SimulationCase -Name 'triggered-max-releases-after-full-residence' -InitialState AUTO -Samples $samples
    if (@($case.result.transitions).Count -ne 2 -or $case.result.transitions[1].reason -ne 'sustained_cool_idle' -or
        $case.status.state -ne 'AUTO') {
        throw 'A load-triggered MAX did not release after its full residence and cool interval.'
    }
    $caseResults.Add([ordered]@{ name = 'triggered-max-releases-after-full-residence'; status = 'PASS' })

    # --- proportional curve -----------------------------------------------------------
    # The policy is off by default, so the whole suite above proves the AUTO/MAX behaviour is
    # unchanged. These cases drive it explicitly.
    $tokens = $null
    $parseErrors = $null
    $controllerAst = [Management.Automation.Language.Parser]::ParseFile($controller, [ref]$tokens, [ref]$parseErrors)
    if (@($parseErrors).Count -ne 0) { throw "Controller parser errors: $($parseErrors -join '; ')" }
    foreach ($name in @('Get-CurveTargetPercent', 'Get-CurveReleaseTemperature', 'Get-CurveCommand')) {
        $fn = $controllerAst.Find({
            param($node)
            $node -is [Management.Automation.Language.FunctionDefinitionAst] -and $node.Name -eq $name
        }.GetNewClosure(), $true)
        if ($null -eq $fn) { throw "The production curve function is missing: $name" }
        Invoke-Expression $fn.Extent.Text
    }

    $curveConfig = Get-Content -LiteralPath $config -Raw | ConvertFrom-Json

    # Linear interpolation, clamped at both ends, quantised upward so a step never commands less
    # cooling than the curve asks for.
    $expectations = @(
        @{ temp = 30.0; percent = 30 },
        @{ temp = 45.0; percent = 30 },
        @{ temp = 50.0; percent = 45 },
        @{ temp = 60.0; percent = 65 },
        @{ temp = 75.0; percent = 100 },
        @{ temp = 95.0; percent = 100 }
    )
    foreach ($expectation in $expectations) {
        $actual = Get-CurveTargetPercent -TemperatureC ([double]$expectation.temp) -Configuration $curveConfig
        if ($actual -ne [int]$expectation.percent) {
            throw "Curve at $($expectation.temp) C returned $actual %, expected $($expectation.percent) %."
        }
    }
    $caseResults.Add([ordered]@{ name = 'curve-interpolates-and-clamps'; status = 'PASS' })

    $previous = 0
    for ($t = 30.0; $t -le 95.0; $t += 0.5) {
        $current = Get-CurveTargetPercent -TemperatureC $t -Configuration $curveConfig
        if ($current -lt $previous) { throw "Curve is not monotonic: $t C dropped to $current %." }
        if ($current -lt [int]$curveConfig.curveMinPct -or $current -gt [int]$curveConfig.curveMaxPct) {
            throw "Curve at $t C returned $current %, outside the configured bounds."
        }
        $previous = $current
    }
    $caseResults.Add([ordered]@{ name = 'curve-is-monotonic-and-bounded'; status = 'PASS' })

    # MINSTART: the first command has to spin the fans up even where the curve asks for less.
    $command = Get-CurveCommand -AveragedTemperatureC 46.0 -CurrentPercent 0 -SecondsSinceLastChange 0 -Configuration $curveConfig
    if ($command.percent -ne [int]$curveConfig.curveStartPct -or -not $command.changed -or $command.reason -ne 'curve_start') {
        throw "Curve start ignored curveStartPct: got $($command.percent) % ($($command.reason))."
    }
    $caseResults.Add([ordered]@{ name = 'curve-start-honours-minstart'; status = 'PASS' })

    # More cooling is never delayed.
    $command = Get-CurveCommand -AveragedTemperatureC 70.0 -CurrentPercent 40 -SecondsSinceLastChange 0 -Configuration $curveConfig
    if ($command.percent -ne 90 -or -not $command.changed -or $command.reason -ne 'curve_increase') {
        throw "Curve increase was delayed or wrong: got $($command.percent) % ($($command.reason))."
    }
    $caseResults.Add([ordered]@{ name = 'curve-increase-is-immediate'; status = 'PASS' })

    # Reductions wait for the dwell, then for the falling hysteresis. Both gates exist so an
    # intermittent workload cannot make the fans audibly pump.
    $command = Get-CurveCommand -AveragedTemperatureC 46.0 -CurrentPercent 90 -SecondsSinceLastChange 10 -Configuration $curveConfig
    if ($command.changed -or $command.percent -ne 90 -or $command.reason -ne 'curve_decrease_hold') {
        throw "Curve decreased before curveDecreaseHoldSeconds: $($command.reason)."
    }
    $caseResults.Add([ordered]@{ name = 'curve-decrease-waits-for-dwell'; status = 'PASS' })

    $releaseTemperature = Get-CurveReleaseTemperature -Percent 90 -Configuration $curveConfig
    $justInside = $releaseTemperature - 1.0
    $command = Get-CurveCommand -AveragedTemperatureC $justInside -CurrentPercent 90 -SecondsSinceLastChange 600 -Configuration $curveConfig
    if ($command.changed -or $command.reason -ne 'curve_decrease_hysteresis') {
        throw "Curve decreased inside the hysteresis band: $($command.reason)."
    }
    $caseResults.Add([ordered]@{ name = 'curve-decrease-respects-hysteresis'; status = 'PASS' })

    $command = Get-CurveCommand -AveragedTemperatureC 60.0 -CurrentPercent 90 -SecondsSinceLastChange 600 -Configuration $curveConfig
    if (-not $command.changed -or $command.percent -ne 65 -or $command.reason -ne 'curve_decrease') {
        throw "Curve never stepped down: got $($command.percent) % ($($command.reason))."
    }
    $caseResults.Add([ordered]@{ name = 'curve-decrease-eventually-steps-down'; status = 'PASS' })

    $command = Get-CurveCommand -AveragedTemperatureC 60.0 -CurrentPercent 65 -SecondsSinceLastChange 600 -Configuration $curveConfig
    if ($command.changed -or $command.reason -ne 'curve_steady') {
        throw "Curve rewrote an unchanged percentage: $($command.reason)."
    }
    $caseResults.Add([ordered]@{ name = 'curve-steady-writes-nothing'; status = 'PASS' })

    # End to end: demand at 50 C must reach the proportional band, not 6122 RPM.
    $samples = [System.Collections.Generic.List[object]]::new()
    1..3 | ForEach-Object { $samples.Add((New-Sample 50 0 45 80)) }
    $case = Invoke-SimulationCase -Name 'curve-demand-is-proportional' -InitialState AUTO -Samples $samples -CurveEnabled
    if (@($case.result.transitions).Count -ne 1 -or $case.result.transitions[0].to -ne 'CURVE' -or
        $case.result.transitions[0].reason -ne 'sustained_cpu_load' -or $case.status.state -ne 'CURVE' -or
        [int]$case.status.curvePercent -ne 45) {
        throw "Demand at 50 C did not enter the proportional band at 45 %: state=$($case.status.state) percent=$($case.status.curvePercent)."
    }
    $caseResults.Add([ordered]@{ name = 'curve-demand-is-proportional'; status = 'PASS' })

    # The same demand with the curve off must still go to MAX, unchanged.
    $case = Invoke-SimulationCase -Name 'curve-disabled-still-uses-max' -InitialState AUTO -Samples $samples
    if (@($case.result.transitions).Count -ne 1 -or $case.result.transitions[0].to -ne 'MAX' -or
        $case.status.state -ne 'MAX' -or [int]$case.status.curvePercent -ne 0) {
        throw 'With curveEnabled false the controller no longer behaves as the MAX-only policy.'
    }
    $caseResults.Add([ordered]@{ name = 'curve-disabled-still-uses-max'; status = 'PASS' })

    # Critical heat is never proportional.
    $samples = [System.Collections.Generic.List[object]]::new()
    1..3 | ForEach-Object { $samples.Add((New-Sample 50 0 45 80)) }
    1..2 | ForEach-Object { $samples.Add((New-Sample 80 0 50 80)) }
    $case = Invoke-SimulationCase -Name 'curve-escalates-on-critical' -InitialState AUTO -Samples $samples -CurveEnabled
    $transitions = @($case.result.transitions)
    if ($transitions.Count -ne 2 -or $transitions[0].to -ne 'CURVE' -or
        $transitions[1].from -ne 'CURVE' -or $transitions[1].to -ne 'MAX' -or
        $transitions[1].reason -ne 'critical_temperature' -or
        $case.status.state -ne 'MAX' -or [int]$case.status.curvePercent -ne 0) {
        throw 'A critical sample did not escalate the proportional band to MAX.'
    }
    $caseResults.Add([ordered]@{ name = 'curve-escalates-on-critical'; status = 'PASS' })

    # Rising demand raises the percentage without waiting.
    $samples = [System.Collections.Generic.List[object]]::new()
    1..3 | ForEach-Object { $samples.Add((New-Sample 50 0 45 80)) }
    1..12 | ForEach-Object { $samples.Add((New-Sample 65 0 50 80)) }
    $case = Invoke-SimulationCase -Name 'curve-follows-rising-demand' -InitialState AUTO -Samples $samples -CurveEnabled
    if ($case.status.state -ne 'CURVE' -or [int]$case.status.curvePercent -ne 80) {
        throw "Rising demand did not raise the curve to 80 %: percent=$($case.status.curvePercent)."
    }
    if (-not (@($case.events | Where-Object { $_.event -eq 'curve_speed_changed' -and $_.reason -eq 'curve_increase' }).Count -ge 1)) {
        throw 'No curve_increase was recorded while demand was rising.'
    }
    $caseResults.Add([ordered]@{ name = 'curve-follows-rising-demand'; status = 'PASS' })

    # Falling demand holds the previous percentage for the dwell instead of pumping.
    $samples = [System.Collections.Generic.List[object]]::new()
    1..3 | ForEach-Object { $samples.Add((New-Sample 65 0 50 80)) }
    1..10 | ForEach-Object { $samples.Add((New-Sample 46 0 44 80)) }
    $case = Invoke-SimulationCase -Name 'curve-holds-through-brief-drop' -InitialState AUTO -Samples $samples -CurveEnabled
    $entryPercent = 80
    if ($case.status.state -ne 'CURVE' -or [int]$case.status.curvePercent -ne $entryPercent) {
        throw "A brief drop reduced the curve inside the dwell: percent=$($case.status.curvePercent)."
    }
    $caseResults.Add([ordered]@{ name = 'curve-holds-through-brief-drop'; status = 'PASS' })

    # Sustained cool demand eventually steps the curve down.
    $samples = [System.Collections.Generic.List[object]]::new()
    1..3 | ForEach-Object { $samples.Add((New-Sample 65 0 50 80)) }
    1..40 | ForEach-Object { $samples.Add((New-Sample 46 0 44 80)) }
    $case = Invoke-SimulationCase -Name 'curve-steps-down-when-sustained' -InitialState AUTO -Samples $samples -CurveEnabled
    if ($case.status.state -ne 'CURVE' -or [int]$case.status.curvePercent -ge $entryPercent) {
        throw "Sustained cool demand never reduced the curve: percent=$($case.status.curvePercent)."
    }
    if (-not (@($case.events | Where-Object { $_.event -eq 'curve_speed_changed' -and $_.reason -eq 'curve_decrease' }).Count -ge 1)) {
        throw 'No curve_decrease was recorded while demand was sustained and cool.'
    }
    $caseResults.Add([ordered]@{ name = 'curve-steps-down-when-sustained'; status = 'PASS' })

    $samples = [System.Collections.Generic.List[object]]::new()
    1..3 | ForEach-Object { $samples.Add((New-Sample 50 0 45 5)) }
    1..3 | ForEach-Object { $samples.Add((New-Sample 52 0 46 80)) }
    $case = Invoke-SimulationCase -Name 'isolated-total-load' -InitialState AUTO -Samples $samples
    if (@($case.result.transitions).Count -ne 1 -or $case.result.transitions[0].reason -ne 'sustained_cpu_load') { throw 'Isolated total-load preemption failed.' }
    $caseResults.Add([ordered]@{ name = 'isolated-total-load'; status = 'PASS' })

    $samples = [System.Collections.Generic.List[object]]::new()
    1..3 | ForEach-Object { $samples.Add((New-Sample 50 0 45 5 10)) }
    1..3 | ForEach-Object { $samples.Add((New-Sample 52 0 46 10 80)) }
    $case = Invoke-SimulationCase -Name 'isolated-logical-load' -InitialState AUTO -Samples $samples
    if (@($case.result.transitions).Count -ne 1 -or $case.result.transitions[0].reason -ne 'sustained_cpu_load') { throw 'Per-logical-CPU preemption failed.' }
    $caseResults.Add([ordered]@{ name = 'isolated-logical-load'; status = 'PASS' })

    $samples = @(
        (New-Sample 50 0 45 5),
        (New-Sample 56 0 46 5),
        (New-Sample 57 0 47 5)
    )
    $case = Invoke-SimulationCase -Name 'rapid-temperature-rise' -InitialState AUTO -Samples $samples
    if (@($case.result.transitions).Count -ne 1 -or $case.result.transitions[0].reason -ne 'rapid_temperature_rise') { throw 'Rapid-rise preemption failed.' }
    $caseResults.Add([ordered]@{ name = 'rapid-temperature-rise'; status = 'PASS' })

    $case = Invoke-SimulationCase -Name 'critical-immediate' -InitialState AUTO -Samples @((New-Sample 76 0 50 5))
    if (@($case.result.transitions).Count -ne 1 -or $case.result.transitions[0].reason -ne 'critical_temperature') { throw 'Critical-temperature fail-safe was not immediate.' }
    $caseResults.Add([ordered]@{ name = 'critical-immediate'; status = 'PASS' })

    $samples = [System.Collections.Generic.List[object]]::new()
    1..5 | ForEach-Object { $samples.Add((New-Sample 52 0 47 8)) }
    1..2 | ForEach-Object { $samples.Add((New-Sample 66 0 55 88)) }
    1..170 | ForEach-Object { $samples.Add((New-Sample 54 0 48 10)) }
    1..3 | ForEach-Object { $samples.Add((New-Sample 0 0 0 10)) }
    $case = Invoke-SimulationCase -Name 'hysteresis-and-sensor-failure' -InitialState AUTO -Samples $samples
    $transitions = @($case.result.transitions)
    if ($transitions.Count -ne 3) { throw "Expected 3 transitions, got $($transitions.Count)." }
    if ($transitions[0].to -ne 'MAX' -or $transitions[1].to -ne 'AUTO' -or $transitions[2].reason -ne 'sensor_fail_safe') { throw 'Hysteresis/fail-safe transition sequence failed.' }
    if ($case.status.state -ne 'MAX' -or $case.status.status -ne 'DEGRADED_FAIL_SAFE') { throw 'Sensor fail-safe status is incorrect.' }
    $caseResults.Add([ordered]@{ name = 'hysteresis-and-sensor-failure'; status = 'PASS' })

    $samples = [System.Collections.Generic.List[object]]::new()
    1..40 | ForEach-Object {
        $samples.Add((New-Sample 48 0 45 8))
        $samples.Add((New-Sample 48 0 45 8))
        $samples.Add((New-Sample 48 0 45 8))
        $samples.Add((New-Sample 52 0 45 8))
    }
    $case = Invoke-SimulationCase -Name 'safe-jitter-eventually-releases' -InitialState MAX -Samples $samples
    $transitions = @($case.result.transitions)
    $expectedRelease = [datetimeoffset]'2026-01-01T00:05:00Z'
    $actualRelease = if ($transitions.Count -eq 1) { ([datetimeoffset]$transitions[0].at).ToUniversalTime() } else { $null }
    if ($transitions.Count -ne 1 -or $transitions[0].from -ne 'MAX' -or $transitions[0].to -ne 'AUTO' -or
        $actualRelease -ne $expectedRelease) {
        throw 'Normal sensor quantization while safely cool prevented release to Auto.'
    }
    $caseResults.Add([ordered]@{ name = 'safe-jitter-eventually-releases'; status = 'PASS' })

    $samples = [System.Collections.Generic.List[object]]::new()
    1..151 | ForEach-Object { $samples.Add((New-Sample 48 0 45 8 10 512 6122 6122)) }
    $staleReadback = New-Sample 48 0 45 8 10 512 6122 6122
    $autoReadback = New-Sample 48 0 45 8 10 256 2500 2500
    $case = Invoke-SimulationCase -Name 'auto-transition-publishes-post-write-readback' -InitialState MAX -Samples $samples -AutoWriteReadbacks @($staleReadback, $autoReadback)
    if (@($case.result.transitions).Count -ne 1 -or $case.status.state -ne 'AUTO' -or
        [uint32]$case.status.fanBehaviorBitmap -ne 256) {
        throw 'AUTO transition published the stale pre-write MAX firmware sample.'
    }
    $caseResults.Add([ordered]@{ name = 'auto-transition-publishes-post-write-readback'; status = 'PASS' })

    $samples = [System.Collections.Generic.List[object]]::new()
    1..151 | ForEach-Object { $samples.Add((New-Sample 48 0 45 8 10 512 6122 6122)) }
    $staleReadbacks = 1..5 | ForEach-Object { New-Sample 48 0 45 8 10 512 6122 6122 }
    $case = Invoke-SimulationCase -Name 'auto-readback-failure-remains-max' -InitialState MAX -Samples $samples -AutoWriteReadbacks $staleReadbacks
    if (@($case.result.transitions).Count -ne 0 -or $case.result.finalState -ne 'MAX' -or
        $case.status.state -ne 'MAX' -or $case.status.status -ne 'DEGRADED_FAIL_SAFE' -or
        [string]$case.status.lastError -notlike 'AUTO firmware readback verification failed.*MAX fallback requested.*') {
        throw 'Unverified AUTO did not fail closed in MAX with an actionable degraded status.'
    }
    $caseResults.Add([ordered]@{ name = 'auto-readback-failure-remains-max'; status = 'PASS' })

    1..59 | ForEach-Object { $samples.Add((New-Sample 48 0 45 8 10 512 6122 6122)) }
    $case = Invoke-SimulationCase -Name 'auto-readback-failure-rearms-hysteresis' -InitialState MAX -Samples $samples -AutoWriteReadbacks $staleReadbacks
    $verificationErrors = @($case.events | Where-Object {
        $_.event -eq 'sensor_or_control_error' -and [string]$_.message -like 'AUTO firmware readback verification failed.*'
    })
    if ($verificationErrors.Count -ne 1 -or $case.result.finalState -ne 'MAX' -or
        $case.status.state -ne 'MAX' -or [int]$case.status.coolSamples -ne 59 -or
        @($case.result.transitions).Count -ne 0) {
        throw 'Failed AUTO verification was retried without a new residence and cool-idle qualification interval.'
    }
    $caseResults.Add([ordered]@{ name = 'auto-readback-failure-rearms-hysteresis'; status = 'PASS' })

    $samples.Add((New-Sample 48 0 45 8 10 512 6122 6122))
    $case = Invoke-SimulationCase -Name 'exhausted-auto-readbacks-stay-fail-closed' -InitialState MAX -Samples $samples -AutoWriteReadbacks $staleReadbacks
    $verificationErrors = @($case.events | Where-Object {
        $_.event -eq 'sensor_or_control_error' -and [string]$_.message -like 'AUTO firmware readback verification failed.*'
    })
    if ($verificationErrors.Count -ne 2 -or $case.result.finalState -ne 'MAX' -or
        $case.status.state -ne 'MAX' -or $case.status.status -ne 'DEGRADED_FAIL_SAFE' -or
        @($case.result.transitions).Count -ne 0) {
        throw 'Exhausted simulated AUTO readbacks silently bypassed verification or left fail-safe MAX.'
    }
    $caseResults.Add([ordered]@{ name = 'exhausted-auto-readbacks-stay-fail-closed'; status = 'PASS' })

    $samples = [System.Collections.Generic.List[object]]::new()
    1..150 | ForEach-Object { $samples.Add((New-Sample 48 0 45 8)) }
    $samples.Add((New-Sample 52 0 45 8))
    $samples.Add((New-Sample 48 0 45 8))
    $case = Invoke-SimulationCase -Name 'trend-gates-release-instant' -InitialState MAX -Samples $samples
    $transitions = @($case.result.transitions)
    $expectedRelease = [datetimeoffset]'2026-01-01T00:05:02Z'
    $actualRelease = if ($transitions.Count -eq 1) { ([datetimeoffset]$transitions[0].at).ToUniversalTime() } else { $null }
    if ($transitions.Count -ne 1 -or $actualRelease -ne $expectedRelease) {
        throw 'Release trend did not defer Auto until the first stable sample.'
    }
    $caseResults.Add([ordered]@{ name = 'trend-gates-release-instant'; status = 'PASS' })

    $samples = [System.Collections.Generic.List[object]]::new()
    1..100 | ForEach-Object { $samples.Add((New-Sample 48 0 45 8)) }
    1..2 | ForEach-Object { $samples.Add((New-Sample 48 0 45 40)) }
    1..60 | ForEach-Object { $samples.Add((New-Sample 48 0 45 8)) }
    $case = Invoke-SimulationCase -Name 'two-minute-idle-release-after-demand' -InitialState MAX -Samples $samples
    $transitions = @($case.result.transitions)
    $expectedRelease = [datetimeoffset]'2026-01-01T00:05:22Z'
    $actualRelease = if ($transitions.Count -eq 1) { ([datetimeoffset]$transitions[0].at).ToUniversalTime() } else { $null }
    if ($transitions.Count -ne 1 -or $actualRelease -ne $expectedRelease) {
        throw 'Auto did not release after the minimum MAX residence and two minutes of qualifying idle samples.'
    }
    $caseResults.Add([ordered]@{ name = 'two-minute-idle-release-after-demand'; status = 'PASS' })

    $samples = [System.Collections.Generic.List[object]]::new()
    1..149 | ForEach-Object { $samples.Add((New-Sample 48 0 45 8)) }
    $samples.Add((New-Sample 48 0 45 21))
    $samples.Add((New-Sample 48 0 45 8))
    $case = Invoke-SimulationCase -Name 'transient-non-idle-sample-pauses-release' -InitialState MAX -Samples $samples
    $transitions = @($case.result.transitions)
    $expectedRelease = [datetimeoffset]'2026-01-01T00:05:00Z'
    $actualRelease = if ($transitions.Count -eq 1) { ([datetimeoffset]$transitions[0].at).ToUniversalTime() } else { $null }
    if ($transitions.Count -ne 1 -or $actualRelease -ne $expectedRelease) {
        throw 'A transient non-idle sample erased the otherwise complete cool interval.'
    }
    $caseResults.Add([ordered]@{ name = 'transient-non-idle-sample-pauses-release'; status = 'PASS' })

    $samples = [System.Collections.Generic.List[object]]::new()
    1..150 | ForEach-Object { $samples.Add((New-Sample 48 0 45 8 10)) }
    $samples.Add((New-Sample 48 0 45 10 80))
    $samples.Add((New-Sample 48 0 45 8 10))
    $case = Invoke-SimulationCase -Name 'transient-logical-core-spike-pauses-release' -InitialState MAX -Samples $samples
    $transitions = @($case.result.transitions)
    $expectedRelease = [datetimeoffset]'2026-01-01T00:05:02Z'
    $actualRelease = if ($transitions.Count -eq 1) { ([datetimeoffset]$transitions[0].at).ToUniversalTime() } else { $null }
    if ($transitions.Count -ne 1 -or $actualRelease -ne $expectedRelease) {
        throw 'A transient logical-core spike did not pause release until the next idle sample.'
    }
    $caseResults.Add([ordered]@{ name = 'transient-logical-core-spike-pauses-release'; status = 'PASS' })

    $samples = [System.Collections.Generic.List[object]]::new()
    1..149 | ForEach-Object { $samples.Add((New-Sample 48 0 45 8)) }
    $samples.Add((New-Sample 48 0 45 40))
    $samples.Add((New-Sample 48 0 45 40))
    1..59 | ForEach-Object { $samples.Add((New-Sample 48 0 45 8)) }
    $case = Invoke-SimulationCase -Name 'sustained-demand-resets-release' -InitialState MAX -Samples $samples
    if (@($case.result.transitions).Count -ne 0 -or $case.status.state -ne 'MAX' -or [int]$case.status.coolSamples -ne 59) {
        throw 'Sustained CPU demand did not reset the cool interval.'
    }
    $samples.Add((New-Sample 48 0 45 8))
    $case = Invoke-SimulationCase -Name 'release-after-full-post-demand-interval' -InitialState MAX -Samples $samples
    $transitions = @($case.result.transitions)
    $expectedRelease = [datetimeoffset]'2026-01-01T00:07:00Z'
    $actualRelease = if ($transitions.Count -eq 1) { ([datetimeoffset]$transitions[0].at).ToUniversalTime() } else { $null }
    if ($transitions.Count -ne 1 -or $actualRelease -ne $expectedRelease) {
        throw 'Auto released before a complete cool interval after sustained demand.'
    }
    $caseResults.Add([ordered]@{ name = 'sustained-demand-resets-release'; status = 'PASS' })

    $samples = [System.Collections.Generic.List[object]]::new()
    1..149 | ForEach-Object { $samples.Add((New-Sample 48 0 45 8 10)) }
    $samples.Add((New-Sample 48 0 45 10 80))
    $samples.Add((New-Sample 48 0 45 10 80))
    1..59 | ForEach-Object { $samples.Add((New-Sample 48 0 45 8 10)) }
    $case = Invoke-SimulationCase -Name 'sustained-logical-core-demand-resets-release' -InitialState MAX -Samples $samples
    if (@($case.result.transitions).Count -ne 0 -or $case.status.state -ne 'MAX' -or [int]$case.status.coolSamples -ne 59) {
        throw 'Sustained logical-core demand did not reset the cool interval.'
    }
    $samples.Add((New-Sample 48 0 45 8 10))
    $case = Invoke-SimulationCase -Name 'release-after-full-post-logical-demand-interval' -InitialState MAX -Samples $samples
    $transitions = @($case.result.transitions)
    $expectedRelease = [datetimeoffset]'2026-01-01T00:07:00Z'
    $actualRelease = if ($transitions.Count -eq 1) { ([datetimeoffset]$transitions[0].at).ToUniversalTime() } else { $null }
    if ($transitions.Count -ne 1 -or $actualRelease -ne $expectedRelease) {
        throw 'Auto released before a complete idle interval after sustained logical-core demand.'
    }
    $caseResults.Add([ordered]@{ name = 'sustained-logical-core-demand-resets-release'; status = 'PASS' })

    $samples = [System.Collections.Generic.List[object]]::new()
    1..149 | ForEach-Object { $samples.Add((New-Sample 48 0 45 8)) }
    $samples.Add((New-Sample 56 0 45 8))
    1..59 | ForEach-Object { $samples.Add((New-Sample 48 0 45 8)) }
    $case = Invoke-SimulationCase -Name 'thermal-envelope-violation-resets-release' -InitialState MAX -Samples $samples
    if (@($case.result.transitions).Count -ne 0 -or $case.status.state -ne 'MAX' -or [int]$case.status.coolSamples -ne 59) {
        throw 'A thermal release-envelope violation did not reset the cool interval.'
    }
    $samples.Add((New-Sample 48 0 45 8))
    $case = Invoke-SimulationCase -Name 'release-after-full-post-thermal-violation-interval' -InitialState MAX -Samples $samples
    $transitions = @($case.result.transitions)
    $expectedRelease = [datetimeoffset]'2026-01-01T00:06:58Z'
    $actualRelease = if ($transitions.Count -eq 1) { ([datetimeoffset]$transitions[0].at).ToUniversalTime() } else { $null }
    if ($transitions.Count -ne 1 -or $actualRelease -ne $expectedRelease) {
        throw 'Auto released before a complete idle interval after a thermal envelope violation.'
    }
    $caseResults.Add([ordered]@{ name = 'thermal-envelope-violation-resets-release'; status = 'PASS' })

    $samples = [System.Collections.Generic.List[object]]::new()
    1..149 | ForEach-Object { $samples.Add((New-Sample 48 0 45 8)) }
    $samples.Add((New-Sample 55 0 45 8))
    1..59 | ForEach-Object { $samples.Add((New-Sample 48 0 45 8)) }
    $case = Invoke-SimulationCase -Name 'rapid-rise-resets-release' -InitialState MAX -Samples $samples
    if (@($case.result.transitions).Count -ne 0 -or $case.status.state -ne 'MAX' -or [int]$case.status.coolSamples -ne 59) {
        throw 'A rapid rise inside the release envelope did not reset the cool interval.'
    }
    $samples.Add((New-Sample 48 0 45 8))
    $case = Invoke-SimulationCase -Name 'release-after-full-post-rise-interval' -InitialState MAX -Samples $samples
    $transitions = @($case.result.transitions)
    $expectedRelease = [datetimeoffset]'2026-01-01T00:06:58Z'
    $actualRelease = if ($transitions.Count -eq 1) { ([datetimeoffset]$transitions[0].at).ToUniversalTime() } else { $null }
    if ($transitions.Count -ne 1 -or $actualRelease -ne $expectedRelease) {
        throw 'Auto released before a complete idle interval after a rapid thermal rise.'
    }
    $caseResults.Add([ordered]@{ name = 'rapid-rise-resets-release'; status = 'PASS' })

    $samples = [System.Collections.Generic.List[object]]::new()
    1..8 | ForEach-Object { $samples.Add((New-Sample 0 0 0 10)) }
    $case = Invoke-SimulationCase -Name 'max-sensor-error-reassert' -InitialState MAX -Samples $samples
    if (@($case.events | Where-Object event -eq 'fail_safe_max_reasserted').Count -lt 1) { throw 'MAX was not reasserted during persistent sensor failure.' }
    if ($case.status.state -ne 'MAX' -or $case.status.status -ne 'DEGRADED_FAIL_SAFE') { throw 'Persistent MAX failure did not remain fail-safe.' }
    $caseResults.Add([ordered]@{ name = 'max-sensor-error-reassert'; status = 'PASS' })

    $result = [ordered]@{ testedAt = (Get-Date).ToString('o'); cases = @($caseResults); status = 'PASS' }
    $result | ConvertTo-Json -Depth 8 | Set-Content -LiteralPath (Join-Path $root 'controller-test-result.json') -Encoding utf8
    $result | ConvertTo-Json -Depth 8
}
finally {
    $safeTempRoot = [IO.Path]::GetFullPath([IO.Path]::GetTempPath()).TrimEnd('\') + '\'
    $resolvedTestRoot = [IO.Path]::GetFullPath($testRoot)
    if ($resolvedTestRoot.StartsWith($safeTempRoot, [StringComparison]::OrdinalIgnoreCase) -and
        (Split-Path -Leaf $resolvedTestRoot) -like 'AcerAdaptiveFanTests-*') {
        Remove-Item -LiteralPath $resolvedTestRoot -Recurse -Force -ErrorAction SilentlyContinue
    }
}


exit 0
