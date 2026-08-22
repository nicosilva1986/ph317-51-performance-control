$ErrorActionPreference = 'Stop'
$root = Split-Path -Parent $PSCommandPath
$fanRoot = [IO.Path]::GetFullPath((Join-Path $root '..\src\powershell\fan'))
$watchdog = Join-Path $fanRoot 'AcerFanWatchdog.ps1'
$engineName = if ($PSVersionTable.PSEdition -eq 'Core') { 'pwsh.exe' } else { 'powershell.exe' }
$engine = Join-Path $PSHOME $engineName
$testRoot = Join-Path ([IO.Path]::GetTempPath()) ('AcerFanWatchdogTests-' + [guid]::NewGuid().ToString('N'))
New-Item -ItemType Directory -Path $testRoot | Out-Null

function Update-FixtureManifest {
    $manifest = [ordered]@{
        controller = (Get-FileHash -LiteralPath (Join-Path $testRoot 'AcerAdaptiveFanController.ps1') -Algorithm SHA256).Hash
        config = (Get-FileHash -LiteralPath (Join-Path $testRoot 'fan-controller-config.json') -Algorithm SHA256).Hash
        watchdog = (Get-FileHash -LiteralPath (Join-Path $testRoot 'AcerFanWatchdog.ps1') -Algorithm SHA256).Hash
    }
    $manifest | ConvertTo-Json | Set-Content -LiteralPath (Join-Path $testRoot 'integrity.json') -Encoding utf8
}

function Restore-Fixture {
    foreach ($name in @('AcerAdaptiveFanController.ps1', 'fan-controller-config.json', 'AcerFanWatchdog.ps1')) {
        Copy-Item -LiteralPath (Join-Path $fanRoot $name) -Destination (Join-Path $testRoot $name) -Force
    }
    Update-FixtureManifest
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

function Write-HeartbeatObject {
    param([Parameter(Mandatory)] $Heartbeat)
    $Heartbeat | ConvertTo-Json | Set-Content -LiteralPath (Join-Path $testRoot 'adaptive-fan-status.json') -Encoding utf8
}

function Invoke-Probe {
    param([int] $PreviousPendingCount = 0, [double] $PendingElapsedSeconds = 0)
    $raw = & $engine -NoLogo -NoProfile -NonInteractive -File $watchdog -Root $testRoot -ProbeOnly `
        -ProbePreviousPendingCount $PreviousPendingCount -ProbePendingElapsedSeconds $PendingElapsedSeconds
    $exitCode = $LASTEXITCODE
    return [pscustomobject]@{ exitCode = $exitCode; result = ($raw | ConvertFrom-Json) }
}

$cases = [System.Collections.Generic.List[object]]::new()
try {
    $tokens = $null
    $parseErrors = $null
    $watchdogAst = [Management.Automation.Language.Parser]::ParseFile($watchdog, [ref]$tokens, [ref]$parseErrors)
    if (@($parseErrors).Count -ne 0) { throw "Watchdog parser errors: $($parseErrors -join '; ')" }
    $dispatchAst = $watchdogAst.Find({
        param($node)
        $node -is [Management.Automation.Language.FunctionDefinitionAst] -and $node.Name -eq 'Invoke-WatchdogRecoveryAction'
    }, $true)
    if ($null -eq $dispatchAst) { throw 'The production watchdog dispatch function is missing.' }
    Invoke-Expression $dispatchAst.Extent.Text

    $dispatchTrace = [Collections.Generic.List[string]]::new()
    $dispatch = Invoke-WatchdogRecoveryAction -Action WAIT_PRIMARY -Reason 'test first pending' `
        -StopPrimary { [void]$dispatchTrace.Add('STOP'); 'lease' } -RequestMax { [void]$dispatchTrace.Add('MAX') } `
        -ReleasePrimary { param($lease) [void]$dispatchTrace.Add('RELEASE') } -StartPrimary { [void]$dispatchTrace.Add('START') }
    if ($dispatchTrace.Count -ne 0 -or $dispatch.outcome -ne 'PRIMARY_REMAINS_AUTHORITATIVE' -or $dispatch.resetPending) {
        throw 'First pending dispatch did not leave the primary as the only privileged writer.'
    }
    $cases.Add([ordered]@{ name = 'first-pending-leaves-primary-authoritative'; status = 'PASS' })

    $dispatchTrace.Clear()
    $dispatch = Invoke-WatchdogRecoveryAction -Action QUIESCE_MAX_RESTART -Reason 'test threshold' `
        -StopPrimary { [void]$dispatchTrace.Add('STOP'); 'lease' } -RequestMax { [void]$dispatchTrace.Add('MAX') } `
        -ReleasePrimary { param($lease) [void]$dispatchTrace.Add('RELEASE') } -StartPrimary { [void]$dispatchTrace.Add('START') }
    if (($dispatchTrace -join ',') -ne 'STOP,MAX,RELEASE,START' -or $dispatch.outcome -ne 'PRIMARY_RESTARTED' -or -not $dispatch.resetPending) {
        throw 'Restart threshold did not quiesce the primary before MAX and then restart it.'
    }
    $cases.Add([ordered]@{ name = 'restart-threshold-dispatches-stop-max-start'; status = 'PASS' })

    $dispatchTrace.Clear()
    $dispatch = Invoke-WatchdogRecoveryAction -Action QUIESCE_MAX_RESTART -Reason 'test STOP failure' `
        -StopPrimary { [void]$dispatchTrace.Add('STOP'); throw 'simulated STOP failure' } `
        -RequestMax { [void]$dispatchTrace.Add('MAX') } `
        -ReleasePrimary { param($lease) [void]$dispatchTrace.Add('RELEASE') } -StartPrimary { [void]$dispatchTrace.Add('START') }
    if (($dispatchTrace -join ',') -ne 'STOP' -or $dispatch.outcome -ne 'RECOVERY_FAILED' -or $dispatch.resetPending) {
        throw 'STOP failure permitted a concurrent watchdog write or reported success.'
    }
    $cases.Add([ordered]@{ name = 'stop-failure-prevents-watchdog-write'; status = 'PASS' })

    $dispatchTrace.Clear()
    $dispatch = Invoke-WatchdogRecoveryAction -Action QUIESCE_MAX_RESTART -Reason 'test MAX failure' `
        -StopPrimary { [void]$dispatchTrace.Add('STOP'); 'lease' } `
        -RequestMax { [void]$dispatchTrace.Add('MAX'); throw 'simulated MAX failure' } `
        -ReleasePrimary { param($lease) [void]$dispatchTrace.Add('RELEASE') } -StartPrimary { [void]$dispatchTrace.Add('START') }
    if (($dispatchTrace -join ',') -ne 'STOP,MAX,RELEASE,START' -or $dispatch.outcome -ne 'RECOVERY_FAILED' -or $dispatch.resetPending) {
        throw 'MAX failure did not restart the primary while preserving a failed recovery result.'
    }
    $cases.Add([ordered]@{ name = 'max-failure-restarts-but-does-not-report-success'; status = 'PASS' })

    $dispatchTrace.Clear()
    $dispatch = Invoke-WatchdogRecoveryAction -Action QUIESCE_MAX_RESTART -Reason 'test START failure' `
        -StopPrimary { [void]$dispatchTrace.Add('STOP'); 'lease' } -RequestMax { [void]$dispatchTrace.Add('MAX') } `
        -ReleasePrimary { param($lease) [void]$dispatchTrace.Add('RELEASE') } `
        -StartPrimary { [void]$dispatchTrace.Add('START'); throw 'simulated START failure' }
    if (($dispatchTrace -join ',') -ne 'STOP,MAX,RELEASE,START' -or $dispatch.outcome -ne 'RECOVERY_FAILED' -or $dispatch.resetPending) {
        throw 'START failure was incorrectly reported as a successful recovery.'
    }
    $cases.Add([ordered]@{ name = 'restart-failure-does-not-report-success'; status = 'PASS' })

    $continueAsts = @($watchdogAst.FindAll({ param($node) $node -is [Management.Automation.Language.ContinueStatementAst] }, $true))
    $integrityFailureIf = $watchdogAst.Find({
        param($node)
        $node -is [Management.Automation.Language.IfStatementAst] -and $node.Extent.Text -match 'integrity_failure_max_left_active'
    }, $true)
    if ($continueAsts.Count -ne 1 -or $null -eq $integrityFailureIf -or
        $continueAsts[0].Extent.StartLineNumber -lt $integrityFailureIf.Extent.StartLineNumber -or
        $continueAsts[0].Extent.EndLineNumber -gt $integrityFailureIf.Extent.EndLineNumber -or
        $watchdogAst.Extent.Text -notmatch 'Start-Sleep\s+-Seconds\s+\$watchdogPollSeconds') {
        throw 'A normal recovery path can bypass the watchdog poll sleep.'
    }
    $cases.Add([ordered]@{ name = 'normal-recovery-paths-retain-poll-sleep'; status = 'PASS' })

    Restore-Fixture
    Write-Heartbeat -State MAX -Health HEALTHY_VERIFIED -Behavior 512 -CpuRpm 6122 -GpuRpm 6122
    $probe = Invoke-Probe
    if ($probe.exitCode -ne 0 -or -not $probe.result.integrity.valid -or -not $probe.result.health.valid) { throw 'Healthy MAX probe failed.' }
    $cases.Add([ordered]@{ name = 'healthy-max'; status = 'PASS' })

    Write-Heartbeat -State AUTO -Health HEALTHY_VERIFIED -Behavior 256 -CpuRpm 2500 -GpuRpm 2500
    $probe = Invoke-Probe
    if ($probe.exitCode -ne 0 -or -not $probe.result.health.valid) { throw 'Healthy AUTO probe failed.' }
    $cases.Add([ordered]@{ name = 'healthy-auto'; status = 'PASS' })

    Write-Heartbeat -State MAX -Health REASSERT_PENDING -Behavior 256 -CpuRpm 1200 -GpuRpm 1100
    $probe = Invoke-Probe
    if ($probe.exitCode -eq 0 -or $probe.result.health.disposition -ne 'REASSERT_PENDING' -or
        $probe.result.decision.action -ne 'WAIT_PRIMARY' -or [double]$probe.result.verifyMaxAfterSeconds -ne 12 -or
        [int]$probe.result.decision.nextPendingCount -ne 1) {
        throw 'A fresh MAX spin-up heartbeat did not preserve the primary writer during its verification grace.'
    }
    $cases.Add([ordered]@{ name = 'max-reassert-pending-defers-restart'; status = 'PASS' })

    $probe = Invoke-Probe -PreviousPendingCount 1 -PendingElapsedSeconds 10
    if ($probe.result.decision.action -ne 'WAIT_PRIMARY' -or [int]$probe.result.decision.nextPendingCount -ne 2) {
        throw 'The second pending observation restarted before the protected verification interval elapsed.'
    }
    $cases.Add([ordered]@{ name = 'second-pending-before-grace-defers-restart'; status = 'PASS' })

    $probe = Invoke-Probe -PreviousPendingCount 2 -PendingElapsedSeconds 20
    if ($probe.exitCode -eq 0 -or $probe.result.health.disposition -ne 'REASSERT_PENDING' -or
        $probe.result.decision.action -ne 'QUIESCE_MAX_RESTART' -or [int]$probe.result.decision.nextPendingCount -ne 3) {
        throw 'Persistent MAX spin-up failure did not become restartable after the bounded grace interval.'
    }
    $cases.Add([ordered]@{ name = 'persistent-reassert-pending-restarts'; status = 'PASS' })

    $probe = Invoke-Probe -PendingElapsedSeconds 20
    if ($probe.result.decision.action -ne 'WAIT_PRIMARY' -or [int]$probe.result.decision.nextPendingCount -ne 1) {
        throw 'A single pending observation was allowed to restart solely because elapsed time was high.'
    }
    $cases.Add([ordered]@{ name = 'single-pending-never-restarts'; status = 'PASS' })

    Write-Heartbeat -State MAX -Health HEALTHY_VERIFIED -Behavior 512 -CpuRpm 6122 -GpuRpm 6122
    $probe = Invoke-Probe -PreviousPendingCount 3 -PendingElapsedSeconds 30
    if ($probe.exitCode -ne 0 -or $probe.result.decision.action -ne 'NONE' -or
        [int]$probe.result.decision.nextPendingCount -ne 0 -or -not $probe.result.decision.resetWindow) {
        throw 'A healthy heartbeat did not clear the pending restart window.'
    }
    $cases.Add([ordered]@{ name = 'healthy-heartbeat-clears-pending-window'; status = 'PASS' })

    Write-Heartbeat -State AUTO -Health REASSERT_PENDING -Behavior 512 -CpuRpm 6122 -GpuRpm 6122
    $probe = Invoke-Probe
    if ($probe.exitCode -eq 0 -or $probe.result.health.disposition -ne 'FATAL' -or
        $probe.result.decision.action -ne 'QUIESCE_MAX_RESTART') {
        throw 'AUTO REASSERT_PENDING did not force immediate single-writer recovery.'
    }
    $cases.Add([ordered]@{ name = 'auto-reassert-pending-restarts-immediately'; status = 'PASS' })

    foreach ($invalidBitmap in @($null, $true, '')) {
        Write-HeartbeatObject -Heartbeat ([ordered]@{
            updatedAt = ([datetimeoffset]::Now).ToString('o')
            state = 'MAX'
            status = 'REASSERT_PENDING'
            fanBehaviorBitmap = $invalidBitmap
            cpuFanRpm = 1200
            gpuFanRpm = 1100
        })
        $probe = Invoke-Probe
        if ($probe.exitCode -eq 0 -or $probe.result.health.disposition -ne 'FATAL' -or
            $probe.result.decision.action -ne 'QUIESCE_MAX_RESTART' -or [string]$probe.result.health.detail -notmatch 'unsigned integer') {
            throw "Invalid fanBehaviorBitmap '$invalidBitmap' did not fail closed."
        }
    }
    $cases.Add([ordered]@{ name = 'null-bool-empty-bitmap-fails-closed'; status = 'PASS' })

    Write-Heartbeat -State MAX -Health DEGRADED_FAIL_SAFE -Behavior 512 -CpuRpm 6122 -GpuRpm 6122
    $probe = Invoke-Probe
    if ($probe.exitCode -eq 0 -or $probe.result.health.valid -or [string]$probe.result.health.detail -notmatch 'DEGRADED_FAIL_SAFE' -or
        $probe.result.health.disposition -ne 'FATAL' -or
        $probe.result.decision.action -ne 'QUIESCE_MAX_RESTART') { throw 'Degraded heartbeat did not fail closed.' }
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

    foreach ($invalidVerifySeconds in @(0, 301)) {
        Restore-Fixture
        $fixtureConfigPath = Join-Path $testRoot 'fan-controller-config.json'
        $fixtureConfig = Get-Content -LiteralPath $fixtureConfigPath -Raw | ConvertFrom-Json
        $fixtureConfig.verifyMaxAfterSeconds = $invalidVerifySeconds
        $fixtureConfig | ConvertTo-Json -Depth 8 | Set-Content -LiteralPath $fixtureConfigPath -Encoding utf8
        Update-FixtureManifest
        Write-Heartbeat -State MAX -Health HEALTHY_VERIFIED -Behavior 512 -CpuRpm 6122 -GpuRpm 6122
        $probe = Invoke-Probe
        if ($probe.exitCode -eq 0 -or $probe.result.integrity.valid -or
            [string]$probe.result.integrity.detail -notmatch 'verifyMaxAfterSeconds') {
            throw "Unsafe verifyMaxAfterSeconds=$invalidVerifySeconds was accepted by watchdog integrity validation."
        }
        $cases.Add([ordered]@{ name = "verify-max-bound-$invalidVerifySeconds-fails-closed"; status = 'PASS' })
    }

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
