[CmdletBinding()]
param(
    [ValidateSet('Harness', 'Owner', 'Contender')]
    [string] $Mode = 'Harness',
    [string] $ReadyPath,
    [ValidateRange(1, 15)]
    [int] $HoldSeconds = 4
)

Set-StrictMode -Version Latest
$ErrorActionPreference = 'Stop'

$commonPath = Join-Path $PSScriptRoot '..\src\powershell\maintenance\CRUWStateMachine.Common.ps1'
if (-not (Test-Path -LiteralPath $commonPath -PathType Leaf)) {
    throw "CRUW state-machine common source missing: $commonPath"
}
. $commonPath

if ($Mode -eq 'Owner') {
    $handle = $null
    try {
        $handle = Enter-CRUWOperationMutex
        [IO.File]::WriteAllText($ReadyPath, 'READY', [Text.UTF8Encoding]::new($false))
        Start-Sleep -Seconds $HoldSeconds
    }
    finally {
        if ($null -ne $handle) { Exit-CRUWOperationMutex $handle }
    }
    exit 0
}

if ($Mode -eq 'Contender') {
    $handle = $null
    try {
        $handle = Enter-CRUWOperationMutex
        Write-Error 'Contender unexpectedly acquired the machine-wide mutex'
        exit 3
    }
    catch {
        if ($_.Exception.Message -notmatch 'Another writer already owns') { throw }
        exit 0
    }
    finally {
        if ($null -ne $handle) { Exit-CRUWOperationMutex $handle }
    }
}

$isAdministrator = ([Security.Principal.WindowsPrincipal][Security.Principal.WindowsIdentity]::GetCurrent()).IsInRole(
    [Security.Principal.WindowsBuiltInRole]::Administrator
)
if (-not $isAdministrator) {
    throw 'Run this non-mutating native mutex smoke from an already elevated console'
}

$engines = [ordered]@{
    powershell51 = (Get-Command powershell.exe -ErrorAction Stop).Source
    pwsh = (Get-Command pwsh.exe -ErrorAction Stop).Source
}
$temporaryRoot = Join-Path ([IO.Path]::GetTempPath()) ('cruw-mutex-smoke-' + [guid]::NewGuid().ToString('N'))
New-Item -ItemType Directory -Path $temporaryRoot -ErrorAction Stop | Out-Null

try {
    foreach ($direction in @(
        [ordered]@{ owner = 'powershell51'; contender = 'pwsh' },
        [ordered]@{ owner = 'pwsh'; contender = 'powershell51' }
    )) {
        $ready = Join-Path $temporaryRoot ("ready-$($direction.owner)-$($direction.contender).txt")
        $ownerArguments = @(
            '-NoProfile', '-ExecutionPolicy', 'Bypass', '-File', ('"' + $PSCommandPath + '"'),
            '-Mode', 'Owner', '-ReadyPath', ('"' + $ready + '"'), '-HoldSeconds', [string]$HoldSeconds
        )
        $owner = Start-Process -FilePath $engines[$direction.owner] -ArgumentList $ownerArguments -WindowStyle Hidden -PassThru
        $deadline = [DateTimeOffset]::Now.AddSeconds(10)
        while (-not (Test-Path -LiteralPath $ready -PathType Leaf) -and -not $owner.HasExited -and [DateTimeOffset]::Now -lt $deadline) {
            Start-Sleep -Milliseconds 100
            $owner.Refresh()
        }
        if (-not (Test-Path -LiteralPath $ready -PathType Leaf)) {
            if (-not $owner.HasExited) { $owner.Kill() }
            throw "Mutex owner failed to signal readiness: $($direction.owner)"
        }

        & $engines[$direction.contender] -NoProfile -ExecutionPolicy Bypass -File $PSCommandPath -Mode Contender
        if ($LASTEXITCODE -ne 0) {
            throw "Mutex contender did not fail closed: $($direction.contender), exit $LASTEXITCODE"
        }
        $owner.WaitForExit(15000)
        if (-not $owner.HasExited -or $owner.ExitCode -ne 0) {
            if (-not $owner.HasExited) { $owner.Kill() }
            throw "Mutex owner failed: $($direction.owner)"
        }
    }

    $single = Enter-CRUWOperationMutex
    Exit-CRUWOperationMutex $single
    Write-Host 'PASS: native protected mutex excludes concurrent PS5.1/PS7 writers and releases cleanly.'
}
finally {
    if (Test-Path -LiteralPath $temporaryRoot) {
        Remove-Item -LiteralPath $temporaryRoot -Recurse -Force
    }
}
