$ErrorActionPreference = 'Stop'
Set-StrictMode -Version Latest

$scriptPath = Join-Path (Split-Path -Parent $PSScriptRoot) 'src\powershell\fan\Get-AcerFanAgentStatus.ps1'
$tempRoot = Join-Path ([IO.Path]::GetTempPath()) ('acer-agent-status-' + [Guid]::NewGuid().ToString('N'))
$assertions = 0

function Assert-True {
    param([bool] $Condition, [string] $Message)
    $script:assertions++
    if (-not $Condition) { throw "ASSERTION FAILED: $Message" }
}

function Write-Utf8NoBom {
    param([string] $Path, [string] $Content)
    [IO.File]::WriteAllText($Path, $Content, [Text.UTF8Encoding]::new($false))
}

try {
    New-Item -ItemType Directory -Path $tempRoot | Out-Null
    Write-Utf8NoBom (Join-Path $tempRoot 'AcerAdaptiveFanController.ps1') '# controller fixture'
    Write-Utf8NoBom (Join-Path $tempRoot 'fan-controller-config.json') '{"fixture":true}'
    Write-Utf8NoBom (Join-Path $tempRoot 'AcerFanWatchdog.ps1') '# watchdog fixture'

    $integrity = [ordered]@{
        schemaVersion = 2
        controller = (Get-FileHash -LiteralPath (Join-Path $tempRoot 'AcerAdaptiveFanController.ps1') -Algorithm SHA256).Hash
        config = (Get-FileHash -LiteralPath (Join-Path $tempRoot 'fan-controller-config.json') -Algorithm SHA256).Hash
        watchdog = (Get-FileHash -LiteralPath (Join-Path $tempRoot 'AcerFanWatchdog.ps1') -Algorithm SHA256).Hash
    }
    Write-Utf8NoBom (Join-Path $tempRoot 'integrity.json') ($integrity | ConvertTo-Json)

    $freshStatus = [ordered]@{
        updatedAt = [DateTimeOffset]::Now.ToString('o'); state = 'AUTO'; status = 'HEALTHY_VERIFIED'
        cpuTempC = 52; gpuTempC = 48; cpuLoadPct = 12; cpuFanRpm = 2100; gpuFanRpm = 2200
    }
    Write-Utf8NoBom (Join-Path $tempRoot 'adaptive-fan-status.json') ($freshStatus | ConvertTo-Json)
    Write-Utf8NoBom (Join-Path $tempRoot 'watchdog.jsonl') (([ordered]@{ timestamp = [DateTimeOffset]::Now.ToString('o'); event = 'watchdog_started'; detail = 'C:\Users\secret' } | ConvertTo-Json -Compress) + "`n{torn")

    $healthyJson = & $scriptPath -Root $tempRoot
    $healthy = $healthyJson | ConvertFrom-Json
    Assert-True ($healthy.conclusion -eq 'HEALTHY') 'fresh verified evidence must be healthy'
    Assert-True ($healthy.privilegedTaskQuery -eq 'NOT_ATTEMPTED_BY_DESIGN') 'protected tasks must not be queried'
    Assert-True ([bool]$healthy.controller.integrityVerified) 'all installed artifact hashes must verify'
    Assert-True ($healthy.watchdog.lastEvent -eq 'watchdog_started') 'torn final JSONL must fall back to the previous valid record'
    Assert-True ($healthyJson -notmatch 'secret') 'watchdog detail and user path must not be emitted'
    Assert-True ($healthyJson -notmatch [Regex]::Escape($tempRoot)) 'source root must not be emitted'

    $freshStatus.updatedAt = [DateTimeOffset]::Now.AddMinutes(-5).ToString('o')
    Write-Utf8NoBom (Join-Path $tempRoot 'adaptive-fan-status.json') ($freshStatus | ConvertTo-Json)
    $stale = (& $scriptPath -Root $tempRoot | ConvertFrom-Json)
    Assert-True ($stale.conclusion -eq 'ATTENTION_REQUIRED') 'stale heartbeat must require attention'
    Assert-True ($stale.reasonCode -eq 'HEARTBEAT_STALE') 'stale heartbeat must have a stable reason code'

    (Get-Content -LiteralPath (Join-Path $tempRoot 'integrity.json') -Raw | ConvertFrom-Json) | ForEach-Object {
        $_.controller = ('0' * 64)
        Write-Utf8NoBom (Join-Path $tempRoot 'integrity.json') ($_ | ConvertTo-Json)
    }
    $mismatch = (& $scriptPath -Root $tempRoot | ConvertFrom-Json)
    Assert-True (-not [bool]$mismatch.controller.integrityVerified) 'hash mismatch must be detected'

    $missingRoot = Join-Path $tempRoot 'missing'
    $unavailable = (& $scriptPath -Root $missingRoot | ConvertFrom-Json)
    Assert-True ($unavailable.conclusion -eq 'UNAVAILABLE') 'missing published root must be structured, not an elevation request'
    Assert-True ($unavailable.reasonCode -eq 'PUBLISHED_ROOT_MISSING') 'missing root must have a stable reason code'

    $source = Get-Content -LiteralPath $scriptPath -Raw
    foreach ($forbidden in @('Get-ScheduledTask', 'Start-ScheduledTask', 'Stop-ScheduledTask', 'Register-ScheduledTask', 'Start-Process', '-Verb RunAs')) {
        Assert-True ($source -notmatch [Regex]::Escape($forbidden)) "agent status script must not contain $forbidden"
    }

    "PASS: $assertions assertions"
}
finally {
    if (Test-Path -LiteralPath $tempRoot) { Remove-Item -LiteralPath $tempRoot -Recurse -Force }
}
