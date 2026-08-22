$ErrorActionPreference = 'Stop'
$root = Split-Path -Parent $PSCommandPath
$fanRoot = [IO.Path]::GetFullPath((Join-Path $root '..\src\powershell\fan'))
$watchdog = Join-Path $fanRoot 'AcerFanWatchdog.ps1'
$testRoot = Join-Path ([IO.Path]::GetTempPath()) ('AcerFanWatchdogTests-' + [guid]::NewGuid().ToString('N'))
New-Item -ItemType Directory -Path $testRoot | Out-Null

function Restore-Fixture {
    foreach ($name in @('AcerAdaptiveFanController.ps1', 'fan-controller-config.json', 'AcerFanWatchdog.ps1')) {
        Copy-Item -LiteralPath (Join-Path $fanRoot $name) -Destination (Join-Path $testRoot $name) -Force
    }
    $manifest = [ordered]@{
        controller = (Get-FileHash -LiteralPath (Join-Path $testRoot 'AcerAdaptiveFanController.ps1') -Algorithm SHA256).Hash
        config = (Get-FileHash -LiteralPath (Join-Path $testRoot 'fan-controller-config.json') -Algorithm SHA256).Hash
        watchdog = (Get-FileHash -LiteralPath (Join-Path $testRoot 'AcerFanWatchdog.ps1') -Algorithm SHA256).Hash
    }
    $manifest | ConvertTo-Json | Set-Content -LiteralPath (Join-Path $testRoot 'integrity.json') -Encoding utf8
}

function Write-Heartbeat {
    param([string] $State, [string] $Health, [uint32] $Behavior, [int] $CpuRpm, [int] $GpuRpm, [datetimeoffset] $UpdatedAt = [datetimeoffset]::Now)
    [ordered]@{
        updatedAt = $UpdatedAt.ToString('o')
        state = $State
        status = $Health
        fanBehaviorBitmap = $Behavior
        cpuFanRpm = $CpuRpm
        gpuFanRpm = $GpuRpm
    } | ConvertTo-Json | Set-Content -LiteralPath (Join-Path $testRoot 'adaptive-fan-status.json') -Encoding utf8
}

function Invoke-Probe {
    $raw = & (Join-Path $PSHOME 'pwsh.exe') -NoLogo -NoProfile -NonInteractive -File $watchdog -Root $testRoot -ProbeOnly
    $exitCode = $LASTEXITCODE
    return [pscustomobject]@{ exitCode = $exitCode; result = ($raw | ConvertFrom-Json) }
}

$cases = [System.Collections.Generic.List[object]]::new()
try {
    Restore-Fixture
    Write-Heartbeat -State MAX -Health HEALTHY_VERIFIED -Behavior 512 -CpuRpm 6122 -GpuRpm 6122
    $probe = Invoke-Probe
    if ($probe.exitCode -ne 0 -or -not $probe.result.integrity.valid -or -not $probe.result.health.valid) { throw 'Healthy MAX probe failed.' }
    $cases.Add([ordered]@{ name = 'healthy-max'; status = 'PASS' })

    Write-Heartbeat -State AUTO -Health HEALTHY_VERIFIED -Behavior 256 -CpuRpm 2500 -GpuRpm 2500
    $probe = Invoke-Probe
    if ($probe.exitCode -ne 0 -or -not $probe.result.health.valid) { throw 'Healthy AUTO probe failed.' }
    $cases.Add([ordered]@{ name = 'healthy-auto'; status = 'PASS' })

    Write-Heartbeat -State MAX -Health DEGRADED_FAIL_SAFE -Behavior 512 -CpuRpm 6122 -GpuRpm 6122
    $probe = Invoke-Probe
    if ($probe.exitCode -eq 0 -or $probe.result.health.valid -or [string]$probe.result.health.detail -notmatch 'DEGRADED_FAIL_SAFE') { throw 'Degraded heartbeat did not fail closed.' }
    $cases.Add([ordered]@{ name = 'degraded-fails-closed'; status = 'PASS' })

    '{not-json' | Set-Content -LiteralPath (Join-Path $testRoot 'adaptive-fan-status.json') -Encoding utf8
    $probe = Invoke-Probe
    if ($probe.exitCode -eq 0 -or $probe.result.health.valid) { throw 'Malformed heartbeat did not fail closed.' }
    $cases.Add([ordered]@{ name = 'malformed-status-fails-closed'; status = 'PASS' })

    Write-Heartbeat -State MAX -Health HEALTHY_VERIFIED -Behavior 512 -CpuRpm 6122 -GpuRpm 6122 -UpdatedAt ([datetimeoffset]::Now.AddMinutes(10))
    $probe = Invoke-Probe
    if ($probe.exitCode -eq 0 -or $probe.result.health.valid -or [string]$probe.result.health.detail -notmatch 'future') { throw 'Future heartbeat did not fail closed.' }
    $cases.Add([ordered]@{ name = 'future-status-fails-closed'; status = 'PASS' })

    Remove-Item -LiteralPath (Join-Path $testRoot 'adaptive-fan-status.json') -Force
    $probe = Invoke-Probe
    if ($probe.exitCode -eq 0 -or $probe.result.health.valid) { throw 'Missing heartbeat did not fail closed.' }
    $cases.Add([ordered]@{ name = 'missing-status-fails-closed'; status = 'PASS' })

    '{broken-manifest' | Set-Content -LiteralPath (Join-Path $testRoot 'integrity.json') -Encoding utf8
    $probe = Invoke-Probe
    if ($probe.exitCode -eq 0 -or $probe.result.integrity.valid) { throw 'Malformed integrity manifest did not fail closed.' }
    $cases.Add([ordered]@{ name = 'malformed-manifest-fails-closed'; status = 'PASS' })

    Restore-Fixture
    Add-Content -LiteralPath (Join-Path $testRoot 'fan-controller-config.json') -Value ' '
    $probe = Invoke-Probe
    if ($probe.exitCode -eq 0 -or $probe.result.integrity.valid -or [string]$probe.result.integrity.detail -notmatch 'mismatch') { throw 'Artifact tampering did not fail closed.' }
    $cases.Add([ordered]@{ name = 'hash-mismatch-fails-closed'; status = 'PASS' })

    $result = [ordered]@{ testedAt = (Get-Date).ToString('o'); cases = @($cases); status = 'PASS' }
    $result | ConvertTo-Json -Depth 8 | Set-Content -LiteralPath (Join-Path $root 'watchdog-test-result.json') -Encoding utf8
    $result | ConvertTo-Json -Depth 8
}
finally {
    $safeTempRoot = [IO.Path]::GetFullPath([IO.Path]::GetTempPath()).TrimEnd('\') + '\'
    $resolvedTestRoot = [IO.Path]::GetFullPath($testRoot)
    if ($resolvedTestRoot.StartsWith($safeTempRoot, [StringComparison]::OrdinalIgnoreCase) -and
        (Split-Path -Leaf $resolvedTestRoot) -like 'AcerFanWatchdogTests-*') {
        Remove-Item -LiteralPath $resolvedTestRoot -Recurse -Force -ErrorAction SilentlyContinue
    }
}

exit 0
