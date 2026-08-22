[CmdletBinding()]
param()

$ErrorActionPreference = 'Stop'
$resultPath = 'C:\Acer-Driver-Audit\Recovery\winre-enable-result.json'

if (-not ([Security.Principal.WindowsPrincipal][Security.Principal.WindowsIdentity]::GetCurrent()).IsInRole(
    [Security.Principal.WindowsBuiltInRole]::Administrator
)) {
    $pwsh = (Get-Command pwsh.exe).Source
    $process = Start-Process -FilePath $pwsh -Verb RunAs -ArgumentList @(
        '-NoProfile', '-ExecutionPolicy', 'Bypass', '-File', ('"' + $PSCommandPath + '"')
    ) -Wait -PassThru
    exit $process.ExitCode
}

$before = (& reagentc.exe /info 2>&1 | Out-String).Trim()
$enableOutput = $null
$enableExitCode = 0
if ($before -match '(?im)Windows[^\r\n]*RE[^\r\n]*:\s*Disabled') {
    $enableOutput = (& reagentc.exe /enable 2>&1 | Out-String).Trim()
    $enableExitCode = $LASTEXITCODE
}
$after = (& reagentc.exe /info 2>&1 | Out-String).Trim()
$enabled = $after -match '(?im)Windows[^\r\n]*RE[^\r\n]*:\s*(Enabled|Habilitado)'
$locationPresent = $after -match '(?im)(location|Ubicaci[oó]n)[^\r\n]*:\s*\\\\\?\\GLOBALROOT'

$result = [ordered]@{
    checkedAt = (Get-Date).ToString('o')
    before = $before
    enableOutput = $enableOutput
    enableExitCode = $enableExitCode
    after = $after
    enabled = $enabled
    recoveryLocationPresent = $locationPresent
    status = if ($enabled -and $locationPresent -and $enableExitCode -eq 0) { 'PASS' } else { 'FAILED' }
}
$result | ConvertTo-Json -Depth 6 | Set-Content -LiteralPath $resultPath -Encoding utf8
$result | ConvertTo-Json -Depth 6
if ($result.status -ne 'PASS') { exit 1 }
