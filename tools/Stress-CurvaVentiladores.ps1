<#
    Stress-CurvaVentiladores.ps1   -   ADMINISTRADOR + PRESENCIA FISICA

    Valida en hardware la banda proporcional recien calibrada (65 C -> 55 %,
    85 C -> 100 %), contra la corrida en AUTO de fabrica del mismo dia.

      PASO 0  Se asegura de que el agente tenga la calibracion nueva. Si no,
              la despliega con el instalador transaccional.
      FASE A  Carga de CPU: NumPy float64 6144x6144, 8 hilos. Es el mismo
              workload del benchmark 2026-08-21, asi que las iteraciones son
              comparables.
      FASE B  CPU + GPU a la vez, que es el caso real de un juego.
      FASE C  Enfriado.

    No escribe nada al EC: lee el status.json que el agente ya publica. El
    unico escritor de hardware sigue siendo el controlador.

    SEGURIDAD
      - Aborta si el CPU llega a 92 C o la GPU a 88 C.
      - Aborta ante cualquier evento WHEA.
      - Mata la carga en el finally pase lo que pase.
      - No corre desatendido.

    Uso:  .\Stress-CurvaVentiladores.ps1
          .\Stress-CurvaVentiladores.ps1 -SinGpu
#>
[CmdletBinding()]
param(
    [int]    $SegundosCpu = 600,
    [int]    $SegundosGpu = 300,
    [int]    $SegundosEnfriado = 180,
    [int]    $AbortarCpuC = 92,
    [int]    $AbortarGpuC = 88,
    [switch] $SinGpu
)

$ErrorActionPreference = 'Stop'

$script:LogPath = Join-Path $PSScriptRoot ('stress-{0:yyyyMMdd-HHmmss}.log' -f (Get-Date))
try { Start-Transcript -LiteralPath $script:LogPath -Force | Out-Null } catch { }

function Titulo($t) { Write-Host "`n===== $t" -ForegroundColor Cyan }
function Info($t)   { Write-Host "      $t" -ForegroundColor Gray }
function OK($t)     { Write-Host "      OK - $t" -ForegroundColor Green }
function Alerta($t) { Write-Host "      $t" -ForegroundColor Yellow }

function Percentil {
    param([double[]] $Valores, [double] $P)
    if (-not $Valores -or $Valores.Count -eq 0) { return 0 }
    $s = @($Valores | Sort-Object)
    return $s[[int][math]::Floor(($s.Count - 1) * $P)]
}

$statusPath = 'C:\ProgramData\AcerAdaptiveFanControl\adaptive-fan-status.json'
$configPath = 'C:\ProgramData\AcerAdaptiveFanControl\fan-controller-config.json'
$repoRoot   = [IO.Path]::GetFullPath((Join-Path $PSScriptRoot '..'))
$stage      = Join-Path $repoRoot 'src\powershell\fan'
$destino    = Join-Path $repoRoot 'evidence\benchmarks\2026-08-24-curve-stress.json'

function Read-Estado {
    try { return Get-Content -LiteralPath $statusPath -Raw -ErrorAction Stop | ConvertFrom-Json }
    catch { return $null }
}

function Read-Gpu {
    try {
        $raw = & nvidia-smi --query-gpu=temperature.gpu,power.draw,clocks.sm,utilization.gpu --format=csv,noheader,nounits 2>$null
        if ($LASTEXITCODE -ne 0 -or -not $raw) { return $null }
        $p = ($raw | Select-Object -First 1) -split ',' | ForEach-Object { $_.Trim() }
        return [ordered]@{ tempC = [double]$p[0]; watts = [double]$p[1]; clockSm = [double]$p[2]; utilPct = [double]$p[3] }
    }
    catch { return $null }
}

function Get-WheaCount { param([datetime] $Desde)
    try { return @(Get-WinEvent -FilterHashtable @{ LogName='System'; ProviderName='Microsoft-Windows-WHEA-Logger'; StartTime=$Desde } -ErrorAction Stop).Count }
    catch { return 0 }
}

$inicio = Get-Date
$muestras = [System.Collections.Generic.List[object]]::new()
$abortado = $false
$motivo = ''
$jobs = @()
$furmark = $null
$furmarkInstalado = $false

function Muestrear {
    param([string] $Fase)
    $e = Read-Estado
    if (-not $e) { return $null }
    $g = Read-Gpu
    $m = [ordered]@{
        t = (Get-Date).ToString('o'); fase = $Fase
        state = [string]$e.state; curvePercent = [int]$e.curvePercent
        cpuTempC = [int]$e.cpuTempC; systemTempC = [int]$e.systemTempC
        cpuFanRpm = [int]$e.cpuFanRpm; gpuFanRpm = [int]$e.gpuFanRpm
        cpuLoadPct = [int]$e.cpuLoadPct
        gpuTempC = if ($g) { [int]$g.tempC } else { [int]$e.gpuTempC }
        gpuWatts = if ($g) { [double]$g.watts } else { 0 }
        gpuClockSm = if ($g) { [int]$g.clockSm } else { 0 }
        gpuUtilPct = if ($g) { [int]$g.utilPct } else { 0 }
    }
    $muestras.Add($m)
    return $m
}

function Test-Aborto {
    param($M)
    if (-not $M) { return $false }
    if ($M.cpuTempC -ge $AbortarCpuC) { $script:motivo = "CPU $($M.cpuTempC) C"; return $true }
    if ($M.gpuTempC -ge $AbortarGpuC) { $script:motivo = "GPU $($M.gpuTempC) C"; return $true }
    if ((Get-WheaCount -Desde $inicio) -gt 0) { $script:motivo = 'evento WHEA'; return $true }
    return $false
}

function Resumir {
    param([string] $Fase)
    $f = @($muestras | Where-Object { $_.fase -eq $Fase })
    if ($f.Count -eq 0) { return $null }
    $cpu = @($f | ForEach-Object { [double]$_.cpuTempC })
    $gpu = @($f | ForEach-Object { [double]$_.gpuTempC })
    $rpm = @($f | ForEach-Object { [double]$_.cpuFanRpm })
    $pct = @($f | ForEach-Object { [double]$_.curvePercent })
    $estados = $f | Group-Object state | ForEach-Object { "$($_.Name)=$([math]::Round(100*$_.Count/$f.Count))%" }
    return [ordered]@{
        muestras     = $f.Count
        cpuMaxC      = [int]($cpu | Measure-Object -Maximum).Maximum
        cpuMediaC    = [math]::Round(($cpu | Measure-Object -Average).Average, 1)
        cpuP95C      = [int](Percentil $cpu 0.95)
        gpuMaxC      = [int]($gpu | Measure-Object -Maximum).Maximum
        gpuMediaC    = [math]::Round(($gpu | Measure-Object -Average).Average, 1)
        rpmMedio     = [int](($rpm | Measure-Object -Average).Average)
        rpmMax       = [int](($rpm | Measure-Object -Maximum).Maximum)
        curvePctMedio = [int](($pct | Measure-Object -Average).Average)
        curvePctMax  = [int](($pct | Measure-Object -Maximum).Maximum)
        tiempoPorEstado = ($estados -join ' ')
    }
}

try {
    # ------------------------------------------------------------- PASO 0
    Titulo "Paso 0 - calibracion desplegada"
    $repoCfg = Join-Path $stage 'fan-controller-config.json'
    $hRepo = (Get-FileHash -LiteralPath $repoCfg -Algorithm SHA256).Hash
    $hVivo = if (Test-Path $configPath) { (Get-FileHash -LiteralPath $configPath -Algorithm SHA256).Hash } else { '' }
    if ($hRepo -eq $hVivo) {
        OK "el agente ya corre la calibracion del repo"
    }
    else {
        Alerta "el agente corre otra calibracion; desplegando la del repo"
        if (-not ([Security.Principal.WindowsPrincipal][Security.Principal.WindowsIdentity]::GetCurrent()).IsInRole(
                [Security.Principal.WindowsBuiltInRole]::Administrator)) {
            throw 'Para desplegar hace falta Administrador. Volve a abrirlo con el .cmd.'
        }
        $pwsh = Join-Path $PSHOME 'pwsh.exe'
        if (-not (Test-Path -LiteralPath $pwsh)) { $pwsh = 'pwsh.exe' }
        & $pwsh -NoProfile -File (Join-Path $stage 'Deploy-SecureAcerFanUpdate.ps1')
        if ($LASTEXITCODE -ne 0) { throw "El despliegue devolvio $LASTEXITCODE." }
        Start-Sleep -Seconds 10
        OK "desplegado"
    }
    $cfg = Get-Content -LiteralPath $configPath -Raw | ConvertFrom-Json
    Info ("banda: {0} C -> {1} %   hasta   {2} C -> {3} %   (curveEnabled={4})" -f `
        $cfg.curveMinTempC, $cfg.curveMinPct, $cfg.curveMaxTempC, $cfg.curveMaxPct, $cfg.curveEnabled)
    if (-not $cfg.curveEnabled) { throw 'La banda proporcional esta desactivada en la config desplegada.' }

    # ------------------------------------------------------------- reposo
    Titulo "Reposo (30 s de referencia)"
    Info "esperando a que baje de 60 C..."
    $limite = (Get-Date).AddMinutes(5)
    while ((Get-Date) -lt $limite) { $e = Read-Estado; if ($e -and [int]$e.cpuTempC -le 60) { break }; Start-Sleep -Seconds 3 }
    for ($i = 0; $i -lt 15; $i++) { $m = Muestrear 'reposo'; Start-Sleep -Seconds 2 }
    $m = $muestras[-1]
    Info ("reposo: CPU {0} C, {1} RPM, estado {2}" -f $m.cpuTempC, $m.cpuFanRpm, $m.state)

    # ------------------------------------------------------------- FASE A
    Titulo "Fase A - carga de CPU ($SegundosCpu s)"
    $py = Join-Path $env:TEMP 'stress_fma.py'
    @'
import json, os, sys, time
os.environ.setdefault("OMP_NUM_THREADS", "8")
import numpy as np
segundos = float(sys.argv[1]); salida = sys.argv[2]
n = 6144
a = np.random.rand(n, n); b = np.random.rand(n, n)
fin = time.time() + segundos; it = 0; tiempos = []
while time.time() < fin:
    t0 = time.time(); a @ b; tiempos.append(time.time() - t0); it += 1
json.dump({"iteraciones": it,
           "segundosPorIteracion": round(sum(tiempos)/len(tiempos), 4) if tiempos else 0},
          open(salida, "w"))
'@ | Set-Content -LiteralPath $py -Encoding utf8
    $cpuOut = Join-Path $env:TEMP 'stress_fma.json'
    Remove-Item -LiteralPath $cpuOut -ErrorAction SilentlyContinue
    $jobs += Start-Process -FilePath 'python' -ArgumentList $py, $SegundosCpu, $cpuOut -PassThru -WindowStyle Minimized

    $fin = (Get-Date).AddSeconds($SegundosCpu)
    while ((Get-Date) -lt $fin) {
        $m = Muestrear 'cpu'
        if ($m) { Write-Host ("`r      CPU {0,3} C  {1,5} RPM  {2,-5} {3,3} %  carga {4,3} %   " -f $m.cpuTempC, $m.cpuFanRpm, $m.state, $m.curvePercent, $m.cpuLoadPct) -NoNewline }
        if (Test-Aborto $m) { $abortado = $true; break }
        Start-Sleep -Seconds 2
    }
    Write-Host ""
    $jobs | ForEach-Object { if (-not $_.HasExited) { $_.Kill() } }
    $jobs = @()
    $cpuRes = if (Test-Path $cpuOut) { Get-Content -LiteralPath $cpuOut -Raw | ConvertFrom-Json } else { $null }
    if ($abortado) { Alerta "ABORTADO: $motivo" } else { OK "fase de CPU completada" }

    # ------------------------------------------------------------- FASE B
    $faseBCorrio = $false
    if ($SinGpu -or $abortado) {
        Titulo "Fase B omitida"
    }
    else {
        Titulo "Fase B - CPU + GPU ($SegundosGpu s)"
        $furmark = Get-ChildItem "$env:LOCALAPPDATA\Microsoft\WinGet\Packages" -Recurse -Filter 'FurMark*.exe' -ErrorAction SilentlyContinue |
            Select-Object -First 1 -ExpandProperty FullName
        if (-not $furmark) {
            Alerta "no hay generador de carga GPU instalado (desinstalamos FurMark)"
            $r = Read-Host "      Instalo FurMark temporalmente con winget y lo saco al final? (s/n)"
            if ($r -match '^[sSyY]') {
                & winget install --id Geeks3D.FurMark.2 --silent --accept-package-agreements --accept-source-agreements | Out-Null
                $furmarkInstalado = $true
                Start-Sleep -Seconds 5
                $furmark = Get-ChildItem "$env:LOCALAPPDATA\Microsoft\WinGet\Packages" -Recurse -Filter 'FurMark*.exe' -ErrorAction SilentlyContinue |
                    Select-Object -First 1 -ExpandProperty FullName
            }
        }
        if ($furmark) {
            Info "usando $([IO.Path]::GetFileName($furmark))"
            $jobs += Start-Process -FilePath $furmark -ArgumentList '--demo', 'furmark-gl', '--width', '1280', '--height', '720', '--max-time', ($SegundosGpu * 1000) -PassThru -ErrorAction SilentlyContinue
        }
        else {
            Alerta "sin FurMark: arranca vos un juego o algo 3D y despues volve aca"
            Read-Host "      Enter cuando la GPU este cargada"
        }
        $jobs += Start-Process -FilePath 'python' -ArgumentList $py, $SegundosGpu, (Join-Path $env:TEMP 'stress_fma_b.json') -PassThru -WindowStyle Minimized

        $fin = (Get-Date).AddSeconds($SegundosGpu)
        while ((Get-Date) -lt $fin) {
            $m = Muestrear 'cpu+gpu'
            if ($m) { Write-Host ("`r      CPU {0,3} C  GPU {1,3} C  {2,5} RPM  {3,-5} {4,3} %  gpu {5,3} %   " -f $m.cpuTempC, $m.gpuTempC, $m.cpuFanRpm, $m.state, $m.curvePercent, $m.gpuUtilPct) -NoNewline }
            if (Test-Aborto $m) { $abortado = $true; break }
            Start-Sleep -Seconds 2
        }
        Write-Host ""
        $faseBCorrio = $true
        $jobs | ForEach-Object { if ($_ -and -not $_.HasExited) { $_.Kill() } }
        $jobs = @()
        if ($abortado) { Alerta "ABORTADO: $motivo" } else { OK "fase CPU+GPU completada" }
    }

    # ------------------------------------------------------------- FASE C
    Titulo "Fase C - enfriado ($SegundosEnfriado s)"
    $fin = (Get-Date).AddSeconds($SegundosEnfriado)
    while ((Get-Date) -lt $fin) {
        $m = Muestrear 'enfriado'
        if ($m) { Write-Host ("`r      CPU {0,3} C  {1,5} RPM  {2,-5} {3,3} %   " -f $m.cpuTempC, $m.cpuFanRpm, $m.state, $m.curvePercent) -NoNewline }
        Start-Sleep -Seconds 2
    }
    Write-Host ""

    # ------------------------------------------------------------- reporte
    Titulo "Resultado"
    $resumen = [ordered]@{
        schemaVersion = 1
        createdAt     = $inicio.ToString('o')
        platform      = 'Acer Predator PH317-51 / Intel Core i7-7700HQ / GTX 1060'
        workloadCpu   = 'NumPy float64 6144x6144 matmul, 8 hilos (igual que 2026-08-21)'
        calibracion   = [ordered]@{
            curveEnabled = [bool]$cfg.curveEnabled
            minTempC = [int]$cfg.curveMinTempC; minPct = [int]$cfg.curveMinPct
            maxTempC = [int]$cfg.curveMaxTempC; maxPct = [int]$cfg.curveMaxPct
            maxCpuC = [int]$cfg.maxCpuC; releaseCpuC = [int]$cfg.releaseCpuC
        }
        abortado      = $abortado
        motivoAborto  = $motivo
        whea          = (Get-WheaCount -Desde $inicio)
        cpuIteraciones = if ($cpuRes) { [int]$cpuRes.iteraciones } else { 0 }
        cpuSegPorIteracion = if ($cpuRes) { [double]$cpuRes.segundosPorIteracion } else { 0 }
        fases = [ordered]@{
            reposo   = (Resumir 'reposo')
            cpu      = (Resumir 'cpu')
            cpuGpu   = if ($faseBCorrio) { (Resumir 'cpu+gpu') } else { $null }
            enfriado = (Resumir 'enfriado')
        }
        referenciaAutoDeFabrica = 'evidence/benchmarks/2026-08-24-acer-auto-curve.json (AUTO llego a 92 C con techo 4761 RPM)'
        referenciaMaxForzado    = 'evidence/benchmarks/2026-08-21-fan-auto-vs-max.json (MAX: 79 C max, 76.3 C medio, 166 iteraciones)'
    }
    foreach ($n in 'reposo', 'cpu', 'cpuGpu', 'enfriado') {
        $r = $resumen.fases[$n]
        if (-not $r) { continue }
        Write-Host ("      {0,-9} CPU max {1,3} C  medio {2,5} C  p95 {3,3} C | GPU max {4,3} C | RPM medio {5,5} max {6,5} | curva {7,3} % | {8}" -f `
            $n, $r.cpuMaxC, $r.cpuMediaC, $r.cpuP95C, $r.gpuMaxC, $r.rpmMedio, $r.rpmMax, $r.curvePctMedio, $r.tiempoPorEstado)
    }
    Write-Host ""
    Write-Host ("      Iteraciones CPU: {0}   ({1} s por iteracion)" -f $resumen.cpuIteraciones, $resumen.cpuSegPorIteracion) -ForegroundColor White
    Write-Host  "      Referencia MAX forzado (2026-08-21): 166 iteraciones, 79 C max, 76.3 C medio" -ForegroundColor DarkGray
    Write-Host  "      Referencia AUTO de fabrica (hoy):    llego a 92 C, techo 4761 RPM" -ForegroundColor DarkGray

    $resumen | ConvertTo-Json -Depth 8 | Set-Content -LiteralPath $destino -Encoding utf8
    OK "evidencia: $destino"
}
catch {
    Write-Host ""
    Write-Host "ERROR: $($_.Exception.Message)" -ForegroundColor Red
}
finally {
    Titulo "Limpieza"
    $jobs | ForEach-Object { if ($_ -and -not $_.HasExited) { try { $_.Kill() } catch { } } }
    Get-Process python, FurMark, furmark -ErrorAction SilentlyContinue | Stop-Process -Force -ErrorAction SilentlyContinue
    OK "carga detenida"
    if ($furmarkInstalado) {
        Info "sacando FurMark otra vez..."
        & winget uninstall --id Geeks3D.FurMark.2 --silent --disable-interactivity 2>&1 | Out-Null
        OK "FurMark desinstalado"
    }
    $e = Read-Estado
    if ($e) { Write-Host ("`n      Agente: {0}, CPU {1} C, {2} RPM, {3}" -f $e.state, $e.cpuTempC, $e.cpuFanRpm, $e.status) -ForegroundColor Green }
    try { Stop-Transcript | Out-Null } catch { }
    Write-Host "Log: $script:LogPath" -ForegroundColor DarkGray
    Read-Host "Enter para cerrar"
}
