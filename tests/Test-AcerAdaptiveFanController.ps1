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
    param([int] $Cpu, [int] $Gpu, [int] $System, [int] $Load, [int] $MaxLogical = -1)
    $sample = [ordered]@{ cpuTempC = $Cpu; gpuTempC = $Gpu; systemTempC = $System; cpuLoadPct = $Load }
    if ($MaxLogical -ge 0) { $sample.cpuMaxLogicalLoadPct = $MaxLogical }
    return $sample
}

function Invoke-SimulationCase {
    param([string] $Name, [string] $InitialState, [object[]] $Samples)
    $caseRoot = Join-Path $testRoot $Name
    New-Item -ItemType Directory -Path $caseRoot | Out-Null
    $simulationPath = Join-Path $caseRoot 'simulation.json'
    $logPath = Join-Path $caseRoot 'events.jsonl'
    $statusPath = Join-Path $caseRoot 'status.json'
    [ordered]@{ initialState = $InitialState; samples = $Samples } | ConvertTo-Json -Depth 8 | Set-Content -LiteralPath $simulationPath -Encoding utf8
    $raw = & $engine -NoLogo -NoProfile -NonInteractive -File $controller -ConfigPath $config -SimulationPath $simulationPath -LogPath $logPath -StatusPath $statusPath
    if ($LASTEXITCODE -ne 0) { throw "Simulation $Name exited $LASTEXITCODE." }
    return [pscustomobject]@{
        result = ($raw | ConvertFrom-Json)
        status = (Get-Content -LiteralPath $statusPath -Raw | ConvertFrom-Json)
        events = @(Get-Content -LiteralPath $logPath | ForEach-Object { $_ | ConvertFrom-Json })
    }
}

$caseResults = [System.Collections.Generic.List[object]]::new()
try {
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
    1..149 | ForEach-Object { $samples.Add((New-Sample 48 0 45 8)) }
    $samples.Add((New-Sample 48 0 45 21))
    1..149 | ForEach-Object { $samples.Add((New-Sample 48 0 45 8)) }
    $case = Invoke-SimulationCase -Name 'release-envelope-violation-resets' -InitialState MAX -Samples $samples
    if (@($case.result.transitions).Count -ne 0 -or $case.status.state -ne 'MAX' -or [int]$case.status.coolSamples -ne 149) {
        throw 'A real release-envelope violation did not reset the cool interval.'
    }
    $samples.Add((New-Sample 48 0 45 8))
    $case = Invoke-SimulationCase -Name 'release-after-full-post-violation-interval' -InitialState MAX -Samples $samples
    $transitions = @($case.result.transitions)
    $expectedRelease = [datetimeoffset]'2026-01-01T00:09:58Z'
    $actualRelease = if ($transitions.Count -eq 1) { ([datetimeoffset]$transitions[0].at).ToUniversalTime() } else { $null }
    if ($transitions.Count -ne 1 -or $actualRelease -ne $expectedRelease) {
        throw 'Auto released before a complete cool interval after an envelope violation.'
    }
    $caseResults.Add([ordered]@{ name = 'release-envelope-violation-resets'; status = 'PASS' })

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
