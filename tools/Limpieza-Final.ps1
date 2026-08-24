<#
    Limpieza-Final.ps1  -  requiere ADMINISTRADOR

    1) Desinstala MSI Afterburner (y RivaTuner, que vino con el)
    2) Saca ThrottleStop del arranque
    3) Desinstala HWiNFO64
    4) Despliega el fix del arranque de ventiladores (60 s en vez de 3 min 30 s)

    El paso 4 es transaccional: verifica hashes SHA-256, respalda la version
    actual y revierte sola si algo falla. Si preferis no tocar el agente,
    corre el script con  -SinDesplegar
#>
[CmdletBinding()]
param([switch] $SinDesplegar)

$ErrorActionPreference = 'Continue'

# Todo lo que se imprime queda tambien en un .log al lado del script, para que
# un cierre inesperado de la ventana no se lleve la evidencia con el.
$script:LogPath = Join-Path $PSScriptRoot ('limpieza-{0:yyyyMMdd-HHmmss}.log' -f (Get-Date))
try { Start-Transcript -LiteralPath $script:LogPath -Force | Out-Null } catch { }


if (-not ([Security.Principal.WindowsPrincipal][Security.Principal.WindowsIdentity]::GetCurrent()).IsInRole(
        [Security.Principal.WindowsBuiltInRole]::Administrator)) {
    Write-Host "Hay que correrlo como Administrador." -ForegroundColor Red
    Read-Host "Enter para salir"; exit 1
}

function Paso($t) { Write-Host "`n== $t" -ForegroundColor Cyan }
function OK($t)   { Write-Host "   OK - $t" -ForegroundColor Green }
function Warn($t) { Write-Host "   $t" -ForegroundColor Yellow }

# ---------------------------------------------------------------- 1) Afterburner
Paso "Desinstalando MSI Afterburner y RivaTuner"
foreach ($n in 'MSIAfterburner', 'RTSS', 'RTSSHooksLoader64', 'EncoderServer64') {
    Get-Process $n -ErrorAction SilentlyContinue | Stop-Process -Force -ErrorAction SilentlyContinue
}
Start-Sleep -Seconds 2
$desinstaladores = @(
    @{ N = 'MSI Afterburner';   P = 'C:\Program Files (x86)\MSI Afterburner\uninstall.exe' }
    @{ N = 'RivaTuner (RTSS)';  P = 'C:\Program Files (x86)\RivaTuner Statistics Server\uninstall.exe' }
)
foreach ($d in $desinstaladores) {
    if (Test-Path -LiteralPath $d.P) {
        # Instalador NSIS: /S es silencioso.
        Start-Process -FilePath $d.P -ArgumentList '/S' -Wait -ErrorAction SilentlyContinue
        Start-Sleep -Seconds 3
        if (Test-Path -LiteralPath $d.P) { Warn "$($d.N): el desinstalador quedo, revisar a mano" }
        else { OK "$($d.N) desinstalado" }
    }
    else { Warn "$($d.N): no estaba instalado" }
}
Get-ChildItem "$env:PUBLIC\Desktop", "$env:USERPROFILE\OneDrive\Desktop", "$env:USERPROFILE\Desktop" `
    -Filter '*Afterburner*' -ErrorAction SilentlyContinue | Remove-Item -Force -ErrorAction SilentlyContinue

# ------------------------------------------------------- 2) tareas de arranque
foreach ($n in 'ThrottleStop', 'MSIAfterburner') {
    Paso "Quitando del arranque: $n"
    Get-Process $n -ErrorAction SilentlyContinue | Stop-Process -Force -ErrorAction SilentlyContinue
    try {
        Unregister-ScheduledTask -TaskPath '\' -TaskName $n -Confirm:$false -ErrorAction Stop
        OK "tarea eliminada"
    } catch { Warn $_.Exception.Message }
}

# ------------------------------------------------------------------ 3) HWiNFO64
Paso "Desinstalando HWiNFO64"
Get-Process HWiNFO64, HWiNFO32 -ErrorAction SilentlyContinue | Stop-Process -Force -ErrorAction SilentlyContinue
$u = 'C:\Program Files\HWiNFO64\unins000.exe'
if (Test-Path $u) { Start-Process -FilePath $u -ArgumentList '/VERYSILENT', '/NORESTART' -Wait; OK "desinstalado" }
else { Warn "no estaba instalado" }

# ------------------------------------------------- 4) fix del arranque de fans
if ($SinDesplegar) {
    Paso "Despliegue del controlador omitido (-SinDesplegar)"
}
else {
    Paso "Desplegando el fix del arranque de ventiladores"
    # El script vive en tools/, el stage es el hermano src/powershell/fan.
    $stage = [IO.Path]::GetFullPath((Join-Path $PSScriptRoot '..\src\powershell\fan'))
    $deploy = Join-Path $stage 'Deploy-SecureAcerFanUpdate.ps1'
    if (-not (Test-Path -LiteralPath $deploy)) {
        Warn "no encuentro $deploy"
    }
    else {
        $pwsh = Join-Path $PSHOME 'pwsh.exe'
        if (-not (Test-Path -LiteralPath $pwsh)) { $pwsh = 'pwsh.exe' }
        Write-Host "   verificando hashes..." -NoNewline
        & $pwsh -NoProfile -File $deploy -ValidateOnly | Out-Null
        if ($LASTEXITCODE -ne 0) { Write-Host ""; Warn "la validacion fallo, no despliego"; }
        else {
            Write-Host " ok"
            & $pwsh -NoProfile -File $deploy
            if ($LASTEXITCODE -eq 0) { OK "controlador actualizado" } else { Warn "el despliegue devolvio $LASTEXITCODE - revisar C:\Acer-Driver-Audit\secure-fan-deploy.json" }
        }
    }
}

# ------------------------------------------------------------------ verificacion
Paso "Verificacion"
$t = Get-ScheduledTask -ErrorAction SilentlyContinue | Where-Object { $_.TaskName -in 'ThrottleStop', 'MSIAfterburner' }
if ($t) { $t | Select-Object TaskName, State | Format-Table -AutoSize | Out-String | Write-Host }
else    { OK "sin tareas de arranque de ThrottleStop/Afterburner" }

Write-Host "`n-- Estado del agente de ventiladores:" -ForegroundColor Cyan
$st = 'C:\ProgramData\AcerAdaptiveFanControl\adaptive-fan-status.json'
if (Test-Path $st) {
    Get-Content $st -Raw | ConvertFrom-Json |
        Select-Object state, cpuTempC, cpuFanRpm, gpuFanRpm, startupMaxHold, status |
        Format-List | Out-String | Write-Host
}
$cfg = 'C:\ProgramData\AcerAdaptiveFanControl\fan-controller-config.json'
if (Test-Path $cfg) {
    $c = Get-Content $cfg -Raw | ConvertFrom-Json
    if ($c.PSObject.Properties['startupReleaseIgnoresLoad']) {
        OK "fix desplegado (startupReleaseSamples=$($c.startupReleaseSamples), ignoresLoad=$($c.startupReleaseIgnoresLoad))"
    } else {
        Warn "el controlador desplegado todavia es el viejo"
    }
}

Write-Host "`nListo. La GPU vuelve a curva stock despues del proximo reinicio." -ForegroundColor Green
try { Stop-Transcript | Out-Null } catch { }
Write-Host "Log: $script:LogPath" -ForegroundColor DarkGray
Read-Host "Enter para cerrar"
