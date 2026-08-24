<#
    Desplegar-Calibracion.ps1   -   ADMINISTRADOR

    Solo despliega la calibracion del repo al agente. Nada mas.
    El despliegue es transaccional: verifica hashes SHA-256, respalda la
    version actual y revierte solo si algo falla.

    Despues del despliegue el controlador arranca de nuevo y vuelve a tomar
    su MAX de arranque, que suelta cuando puede verificar la maquina fria.
    Con la calibracion nueva eso es CPU <= releaseCpuC durante 30 s.
#>
[CmdletBinding()]
param([int] $SegundosEspera = 150)

$ErrorActionPreference = 'Stop'
$script:LogPath = Join-Path $PSScriptRoot ('desplegar-{0:yyyyMMdd-HHmmss}.log' -f (Get-Date))
try { Start-Transcript -LiteralPath $script:LogPath -Force | Out-Null } catch { }

function Titulo($t) { Write-Host "`n===== $t" -ForegroundColor Cyan }
function OK($t)     { Write-Host "      OK - $t" -ForegroundColor Green }
function Alerta($t) { Write-Host "      $t" -ForegroundColor Yellow }
function Info($t)   { Write-Host "      $t" -ForegroundColor Gray }

$statusPath = 'C:\ProgramData\AcerAdaptiveFanControl\adaptive-fan-status.json'
$configPath = 'C:\ProgramData\AcerAdaptiveFanControl\fan-controller-config.json'
$stage      = [IO.Path]::GetFullPath((Join-Path $PSScriptRoot '..\src\powershell\fan'))

function Estado { try { Get-Content -LiteralPath $statusPath -Raw -ErrorAction Stop | ConvertFrom-Json } catch { $null } }

try {
    if (-not ([Security.Principal.WindowsPrincipal][Security.Principal.WindowsIdentity]::GetCurrent()).IsInRole(
            [Security.Principal.WindowsBuiltInRole]::Administrator)) {
        throw 'Hay que correrlo como Administrador.'
    }

    Titulo "Antes"
    $e = Estado
    if ($e) { Info ("estado {0}  CPU {1} C  {2} RPM  curva {3} %" -f $e.state, $e.cpuTempC, $e.cpuFanRpm, $e.curvePercent) }

    $repoCfg = Join-Path $stage 'fan-controller-config.json'
    $hRepo = (Get-FileHash -LiteralPath $repoCfg -Algorithm SHA256).Hash
    $hVivo = if (Test-Path $configPath) { (Get-FileHash -LiteralPath $configPath -Algorithm SHA256).Hash } else { '' }
    if ($hRepo -eq $hVivo) {
        OK "el agente ya corre la calibracion del repo, no hay nada que desplegar"
    }
    else {
        Titulo "Desplegando"
        $pwsh = Join-Path $PSHOME 'pwsh.exe'
        if (-not (Test-Path -LiteralPath $pwsh)) { $pwsh = 'pwsh.exe' }
        & $pwsh -NoProfile -File (Join-Path $stage 'Deploy-SecureAcerFanUpdate.ps1')
        if ($LASTEXITCODE -ne 0) { throw "El despliegue devolvio $LASTEXITCODE. Revisa C:\Acer-Driver-Audit\secure-fan-deploy.json" }
        OK "desplegado"
    }

    $cfg = Get-Content -LiteralPath $configPath -Raw | ConvertFrom-Json
    Titulo "Calibracion activa"
    Info ("banda proporcional: {0}" -f $(if ($cfg.curveEnabled) { 'SI' } else { 'NO' }))
    Info ("{0} C -> {1} %   hasta   {2} C -> {3} %" -f $cfg.curveMinTempC, $cfg.curveMinPct, $cfg.curveMaxTempC, $cfg.curveMaxPct)
    Info ("entra en banda a {0} C, suelta a {1} C" -f $cfg.maxCpuC, $cfg.releaseCpuC)

    Titulo "Esperando a que el controlador suelte su MAX de arranque"
    Info ("necesita CPU <= {0} C. Si estas usando la maquina fuerte, va a tardar." -f $cfg.releaseCpuC)
    Info "Ctrl-C para dejar de mirar; el agente sigue funcionando igual."
    $fin = (Get-Date).AddSeconds($SegundosEspera)
    $soltado = $false
    while ((Get-Date) -lt $fin) {
        $e = Estado
        if ($e) {
            Write-Host ("`r      {0,-6} CPU {1,3} C  {2,5} RPM  curva {3,3} %  cool {4,2}   " -f $e.state, $e.cpuTempC, $e.cpuFanRpm, $e.curvePercent, $e.coolSamples) -NoNewline
            if ($e.state -ne 'MAX') { $soltado = $true; break }
        }
        Start-Sleep -Seconds 2
    }
    Write-Host ""
    if ($soltado) {
        $e = Estado
        OK ("solto: estado {0}, {1} RPM a {2} C" -f $e.state, $e.cpuFanRpm, $e.cpuTempC)
    }
    else {
        Alerta "sigue en MAX. Deja la maquina quieta un minuto y va a soltar sola."
        Alerta "Es el MAX de arranque del controlador, no una falla: falla hacia maxima refrigeracion."
    }
}
catch {
    Write-Host ""
    Write-Host "ERROR: $($_.Exception.Message)" -ForegroundColor Red
}
finally {
    try { Stop-Transcript | Out-Null } catch { }
    Write-Host "Log: $script:LogPath" -ForegroundColor DarkGray
    Read-Host "Enter para cerrar"
}
