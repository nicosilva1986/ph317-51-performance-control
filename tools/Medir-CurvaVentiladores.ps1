<#
    Medir-CurvaVentiladores.ps1   -   ADMINISTRADOR + PRESENCIA FISICA

    Cierra las dos incognitas que bloquean la curva proporcional:

      FASE 1  Cual es la curva de fabrica de Acer, incluido su techo real.
              Solo usa modo AUTO, que el agente ya escribe a diario.

      FASE 2  Si el modo CUSTOM (mode 3) sostiene un porcentaje comandado,
              y que RPM da cada %. Este payload NO esta validado en esta
              maquina: es la parte experimental.

    SEGURIDAD
      - Aborta si el CPU llega a 92 C.
      - Aborta si aparece cualquier evento WHEA durante la corrida.
      - Pase lo que pase (error, Ctrl-C, corte), el bloque finally fuerza MAX,
        vuelve a AUTO y rearranca el agente.
      - No corre desatendido: quedate mirando la pantalla.

    Uso:  .\Medir-CurvaVentiladores.ps1
          .\Medir-CurvaVentiladores.ps1 -SoloFase1     (sin escrituras CUSTOM)
#>
[CmdletBinding()]
param(
    [switch] $SoloFase1,
    [int]    $SegundosCarga = 480,
    [int]    $SegundosEnfriado = 240,
    [int]    $AbortarEnC = 92
)

$ErrorActionPreference = 'Stop'

# Todo lo que se imprime queda tambien en un .log al lado del script, para que
# un cierre inesperado de la ventana no se lleve la evidencia con el.
$script:LogPath = Join-Path $PSScriptRoot ('medicion-{0:yyyyMMdd-HHmmss}.log' -f (Get-Date))
try { Start-Transcript -LiteralPath $script:LogPath -Force | Out-Null } catch { }


function Titulo($t) { Write-Host "`n===== $t" -ForegroundColor Cyan }
function Info($t)   { Write-Host "      $t" -ForegroundColor Gray }
function OK($t)     { Write-Host "      OK - $t" -ForegroundColor Green }
function Alerta($t) { Write-Host "      $t" -ForegroundColor Yellow }

function Percentil {
    param([double[]] $Valores, [double] $P)
    if (-not $Valores -or $Valores.Count -eq 0) { return 0 }
    $s = @($Valores | Sort-Object)
    $i = [int][math]::Floor(($s.Count - 1) * $P)
    return $s[$i]
}

function Convert-GamingSensorValue { param([uint64] $RawValue) return [int]($RawValue -shr 8) }

function Read-Muestra {
    $cpu  = Invoke-CimMethod -InputObject $script:Gaming -MethodName 'GetGamingSysInfo' -Arguments @{ gmInput = [uint32]0x0101 }
    $gpu  = Invoke-CimMethod -InputObject $script:Gaming -MethodName 'GetGamingSysInfo' -Arguments @{ gmInput = [uint32]0x0A01 }
    $sys  = Invoke-CimMethod -InputObject $script:Gaming -MethodName 'GetGamingSysInfo' -Arguments @{ gmInput = [uint32]0x0301 }
    $cfan = Invoke-CimMethod -InputObject $script:Gaming -MethodName 'GetGamingSysInfo' -Arguments @{ gmInput = [uint32]0x0201 }
    $gfan = Invoke-CimMethod -InputObject $script:Gaming -MethodName 'GetGamingSysInfo' -Arguments @{ gmInput = [uint32]0x0601 }
    $beh  = Invoke-CimMethod -InputObject $script:Gaming -MethodName 'GetGamingFanBehavior' -Arguments @{ gmInput = [uint32]0x0009 }
    $procs = @(Get-CimInstance -ClassName Win32_PerfFormattedData_PerfOS_Processor)
    $total = $procs | Where-Object Name -eq '_Total' | Select-Object -First 1
    return [ordered]@{
        t           = (Get-Date).ToString('o')
        cpuTempC    = Convert-GamingSensorValue ([uint64]$cpu.gmOutput)
        gpuTempC    = Convert-GamingSensorValue ([uint64]$gpu.gmOutput)
        systemTempC = Convert-GamingSensorValue ([uint64]$sys.gmOutput)
        cpuFanRpm   = Convert-GamingSensorValue ([uint64]$cfan.gmOutput)
        gpuFanRpm   = Convert-GamingSensorValue ([uint64]$gfan.gmOutput)
        bitmap      = [uint32]$beh.gmOutput
        modoCpu     = (([uint32]$beh.gmOutput) -shr 8) -band 3
        cpuLoadPct  = [int]$total.PercentProcessorTime
        fase        = ''
    }
}

function Set-Ventiladores {
    param([ValidateSet('AUTO', 'MAX', 'CUSTOM')] [string] $Modo, [int] $Percent = 100)
    if ($Modo -eq 'AUTO') {
        $b = Invoke-CimMethod -InputObject $script:Gaming -MethodName 'SetGamingFanBehavior' -Arguments @{ gmInput = [uint64]0x00410009 }
        if ([uint32]$b.gmOutput -ne 0) { throw 'El firmware rechazo AUTO.' }
        return @{ behavior = 0; cpu = 0; gpu = 0 }
    }
    if ($Modo -eq 'MAX') {
        $b = Invoke-CimMethod -InputObject $script:Gaming -MethodName 'SetGamingFanBehavior' -Arguments @{ gmInput = [uint64]0x00820009 }
        $c = Invoke-CimMethod -InputObject $script:Gaming -MethodName 'SetGamingFanSpeed'    -Arguments @{ gmInput = [uint64]0x00006401 }
        $g = Invoke-CimMethod -InputObject $script:Gaming -MethodName 'SetGamingFanSpeed'    -Arguments @{ gmInput = [uint64]0x00006404 }
        if ([uint32]$b.gmOutput -ne 0 -or [uint32]$c.gmOutput -ne 0 -or [uint32]$g.gmOutput -ne 0) { throw 'El firmware rechazo MAX.' }
        return @{ behavior = 0; cpu = 0; gpu = 0 }
    }
    # CUSTOM: mode 3. Payload no validado en esta maquina.
    $b = Invoke-CimMethod -InputObject $script:Gaming -MethodName 'SetGamingFanBehavior' -Arguments @{ gmInput = [uint64]0x00C30009 }
    $c = Invoke-CimMethod -InputObject $script:Gaming -MethodName 'SetGamingFanSpeed'    -Arguments @{ gmInput = [uint64]((([uint64]$Percent) -shl 8) -bor 0x01) }
    $g = Invoke-CimMethod -InputObject $script:Gaming -MethodName 'SetGamingFanSpeed'    -Arguments @{ gmInput = [uint64]((([uint64]$Percent) -shl 8) -bor 0x04) }
    return @{ behavior = [uint32]$b.gmOutput; cpu = [uint32]$c.gmOutput; gpu = [uint32]$g.gmOutput }
}

function Get-WheaCount {
    param([datetime] $Desde)
    try {
        return @(Get-WinEvent -FilterHashtable @{ LogName = 'System'; ProviderName = 'Microsoft-Windows-WHEA-Logger'; StartTime = $Desde } -ErrorAction Stop).Count
    }
    catch { return 0 }
}

function Get-TareaAgente {
    param([string] $Nombre)
    return Get-ScheduledTask -ErrorAction SilentlyContinue | Where-Object { $_.TaskName -eq $Nombre } | Select-Object -First 1
}

# ------------------------------------------------------------------ preflight
if (-not ([Security.Principal.WindowsPrincipal][Security.Principal.WindowsIdentity]::GetCurrent()).IsInRole(
        [Security.Principal.WindowsBuiltInRole]::Administrator)) {
    Write-Host "Hay que correrlo como Administrador." -ForegroundColor Red
    Read-Host "Enter para salir"; exit 1
}

$cs = Get-CimInstance Win32_ComputerSystem
if ([string]$cs.Model -notmatch '(?i)\bPH317-51\b') {
    Write-Host "Hardware inesperado: $($cs.Manufacturer) $($cs.Model). Abortando." -ForegroundColor Red
    Read-Host "Enter para salir"; exit 1
}

$script:Gaming = Get-CimInstance -Namespace 'root\wmi' -ClassName 'AcerGamingFunction' -ErrorAction SilentlyContinue | Select-Object -First 1
if (-not $script:Gaming) {
    Write-Host "No encuentro AcerGamingFunction. Abortando." -ForegroundColor Red
    Read-Host "Enter para salir"; exit 1
}

$tareas = @('Acer Adaptive Fan Control', 'Acer Adaptive Fan Watchdog')
$inicio = Get-Date
$resultado = [ordered]@{
    schemaVersion = 1
    createdAt     = $inicio.ToString('o')
    platform      = 'Acer Predator PH317-51 / Intel Core i7-7700HQ'
    abortarEnC    = $AbortarEnC
    fase1         = $null
    fase2         = $null
    whea          = $null
    status        = 'INCOMPLETE'
}
# El script vive en tools/; la evidencia va al hermano evidence/benchmarks.
$destino = [IO.Path]::GetFullPath((Join-Path $PSScriptRoot '..\evidence\benchmarks\2026-08-24-acer-auto-curve.json'))
$jobs = @()

Titulo "Preparacion"
Info "Modelo: $($cs.Model)"

try {
    foreach ($t in $tareas) {
        $task = Get-TareaAgente -Nombre $t
        if (-not $task) { Alerta "no encuentro la tarea '$t'"; continue }
        try {
            $task | Disable-ScheduledTask -ErrorAction Stop | Out-Null
            $task | Stop-ScheduledTask -ErrorAction SilentlyContinue
            OK "agente pausado: $t"
        }
        catch { Alerta "no pude pausar '$t': $($_.Exception.Message)" }
    }
    Start-Sleep -Seconds 3

    # =================================================================== FASE 1
    Titulo "FASE 1 - curva de fabrica de Acer"
    Set-Ventiladores -Modo AUTO | Out-Null
    OK "ventiladores en AUTO"

    Info "esperando a bajar de 60 C..."
    $limite = (Get-Date).AddMinutes(5)
    while ((Get-Date) -lt $limite) {
        $m = Read-Muestra
        if ($m.cpuTempC -le 60) { break }
        Start-Sleep -Seconds 3
    }
    $m = Read-Muestra
    Info "partida: CPU $($m.cpuTempC) C, $($m.cpuFanRpm) RPM, modo $($m.modoCpu)"

    Info "cargando los 8 hilos por hasta $SegundosCarga s (Ctrl-C aborta y restaura)"
    $duracionJob = $SegundosCarga + 30
    $jobs = 1..8 | ForEach-Object {
        Start-Job -ScriptBlock {
            param($s)
            $fin = (Get-Date).AddSeconds($s)
            $x = 0.0
            while ((Get-Date) -lt $fin) { for ($i = 0; $i -lt 200000; $i++) { $x = [math]::Sqrt($x + $i) } }
        } -ArgumentList $duracionJob
    }

    $curva = [System.Collections.Generic.List[object]]::new()
    $abortar = $false
    $motivo = ''
    $finCarga = (Get-Date).AddSeconds($SegundosCarga)
    while ((Get-Date) -lt $finCarga) {
        $m = Read-Muestra
        $m.fase = 'carga'
        $curva.Add($m)
        Write-Host ("`r      CPU {0,3} C   {1,5} RPM   carga {2,3} %   modo {3}    " -f $m.cpuTempC, $m.cpuFanRpm, $m.cpuLoadPct, $m.modoCpu) -NoNewline
        if ($m.cpuTempC -ge $AbortarEnC) { $abortar = $true; $motivo = "CPU $($m.cpuTempC) C"; break }
        if ((Get-WheaCount -Desde $inicio) -gt 0) { $abortar = $true; $motivo = 'evento WHEA'; break }
        Start-Sleep -Seconds 2
    }
    Write-Host ""
    if ($jobs) {
        $jobs | Stop-Job -ErrorAction SilentlyContinue
        $jobs | Remove-Job -Force -ErrorAction SilentlyContinue
        $jobs = @()
    }
    if ($abortar) { Alerta "ABORTADO: $motivo" } else { OK "carga completada" }

    Info "midiendo el enfriado por $SegundosEnfriado s..."
    $finFrio = (Get-Date).AddSeconds($SegundosEnfriado)
    while ((Get-Date) -lt $finFrio) {
        $m = Read-Muestra
        $m.fase = 'enfriado'
        $curva.Add($m)
        Write-Host ("`r      CPU {0,3} C   {1,5} RPM    " -f $m.cpuTempC, $m.cpuFanRpm) -NoNewline
        Start-Sleep -Seconds 2
    }
    Write-Host ""

    $porTemp = $curva | Group-Object { [int]([int]$_.cpuTempC / 5) * 5 } | Sort-Object { [int]$_.Name }
    $tabla = @(foreach ($g in $porTemp) {
            $rpm = @($g.Group | ForEach-Object { [double]$_.cpuFanRpm })
            [ordered]@{
                tempBucketC = [int]$g.Name
                n           = $g.Count
                rpmP50      = [int](Percentil $rpm 0.5)
                rpmP90      = [int](Percentil $rpm 0.9)
                rpmMax      = [int](($rpm | Measure-Object -Maximum).Maximum)
            }
        })
    $resultado.fase1 = [ordered]@{
        muestras       = $curva.Count
        abortado       = $abortar
        motivoAborto   = $motivo
        tempMaxC       = [int](($curva | ForEach-Object { [int]$_.cpuTempC } | Measure-Object -Maximum).Maximum)
        rpmMaxAuto     = [int](($curva | ForEach-Object { [int]$_.cpuFanRpm } | Measure-Object -Maximum).Maximum)
        porTemperatura = $tabla
    }

    Write-Host ""
    Write-Host "      CURVA DE FABRICA MEDIDA" -ForegroundColor White
    Write-Host ("      {0,-10} {1,5} {2,9} {3,9} {4,9}" -f 'CPU C', 'n', 'RPM p50', 'RPM p90', 'RPM max')
    foreach ($r in $tabla) {
        Write-Host ("      {0,-10} {1,5} {2,9} {3,9} {4,9}" -f "$($r.tempBucketC)-$($r.tempBucketC + 4)", $r.n, $r.rpmP50, $r.rpmP90, $r.rpmMax)
    }
    Write-Host ("      Techo de Acer en AUTO: {0} RPM    (MAX conocido: 6122 RPM)" -f $resultado.fase1.rpmMaxAuto) -ForegroundColor White

    # =================================================================== FASE 2
    if ($SoloFase1) {
        Titulo "FASE 2 omitida (-SoloFase1)"
    }
    else {
        Titulo "FASE 2 - validacion del modo CUSTOM"
        Info "esperando a bajar de 60 C antes de tocar el EC..."
        $limite = (Get-Date).AddMinutes(6)
        while ((Get-Date) -lt $limite) {
            $m = Read-Muestra
            if ($m.cpuTempC -le 60) { break }
            Start-Sleep -Seconds 3
        }

        $puntos = @()
        foreach ($p in 40, 60, 80, 100) {
            Info "comandando CUSTOM $p %..."
            $rc = Set-Ventiladores -Modo CUSTOM -Percent $p
            if ($rc.behavior -ne 0 -or $rc.cpu -ne 0 -or $rc.gpu -ne 0) {
                Alerta "el firmware RECHAZO CUSTOM $p % (behavior=$($rc.behavior) cpu=$($rc.cpu) gpu=$($rc.gpu))"
                $puntos += [ordered]@{ percent = $p; aceptado = $false; behaviorRc = $rc.behavior; cpuRc = $rc.cpu; gpuRc = $rc.gpu }
                break
            }
            Start-Sleep -Seconds 15
            $s = @()
            $modos = @()
            $abortar = $false
            for ($i = 0; $i -lt 20; $i++) {
                $m = Read-Muestra
                $s += [double]$m.cpuFanRpm
                $modos += [int]$m.modoCpu
                if ($m.cpuTempC -ge $AbortarEnC) { $abortar = $true; break }
                Start-Sleep -Seconds 2
            }
            $enModo3 = @($modos | Where-Object { $_ -eq 3 }).Count
            $punto = [ordered]@{
                percent       = $p
                aceptado      = $true
                rpmP50        = [int](Percentil $s 0.5)
                rpmMin        = [int](($s | Measure-Object -Minimum).Minimum)
                rpmMax        = [int](($s | Measure-Object -Maximum).Maximum)
                muestras      = $modos.Count
                enModo3       = $enModo3
                derivoDeModo3 = $modos.Count - $enModo3
            }
            $puntos += $punto
            Write-Host ("      {0,3} %  ->  p50 {1,5} RPM   min {2,5}   max {3,5}   modo3 {4}/{5}" -f $p, $punto.rpmP50, $punto.rpmMin, $punto.rpmMax, $enModo3, $modos.Count) -ForegroundColor White
            if ($abortar) { Alerta "ABORTADO por temperatura"; break }
        }

        $aceptados = @($puntos | Where-Object { $_.aceptado })
        $monotona = $true
        for ($i = 1; $i -lt $aceptados.Count; $i++) {
            if ($aceptados[$i].rpmP50 -lt $aceptados[$i - 1].rpmP50) { $monotona = $false }
        }
        $derivo = @($aceptados | Where-Object { $_.derivoDeModo3 -gt 0 }).Count
        if ($aceptados.Count -eq 0)      { $veredicto = 'CUSTOM_RECHAZADO' }
        elseif ($aceptados.Count -lt 4)  { $veredicto = 'CUSTOM_PARCIAL' }
        elseif ($derivo -gt 0)           { $veredicto = 'CUSTOM_INESTABLE' }
        elseif (-not $monotona)          { $veredicto = 'CUSTOM_NO_MONOTONO' }
        else                             { $veredicto = 'CUSTOM_VALIDO' }

        $resultado.fase2 = [ordered]@{
            payload   = '0x00C30009'
            puntos    = $puntos
            aceptados = $aceptados.Count
            monotona  = $monotona
            veredicto = $veredicto
        }
        Write-Host ("      VEREDICTO: {0}" -f $veredicto) -ForegroundColor White
    }

    $resultado.status = 'COMPLETE'
}
catch {
    Write-Host ""
    Write-Host "ERROR: $($_.Exception.Message)" -ForegroundColor Red
    $resultado.status = "ERROR: $($_.Exception.Message)"
}
finally {
    Titulo "Restauracion (siempre corre)"
    if ($jobs) {
        $jobs | Stop-Job -ErrorAction SilentlyContinue
        $jobs | Remove-Job -Force -ErrorAction SilentlyContinue
    }
    try { Set-Ventiladores -Modo MAX | Out-Null; OK "MAX forzado"; Start-Sleep -Seconds 5 }
    catch { Alerta "no pude forzar MAX: $($_.Exception.Message)" }
    try { Set-Ventiladores -Modo AUTO | Out-Null; OK "vuelto a AUTO" }
    catch { Alerta "no pude volver a AUTO: $($_.Exception.Message)" }
    foreach ($t in $tareas) {
        $task = Get-TareaAgente -Nombre $t
        if (-not $task) { Alerta "REARRANCA A MANO: no encuentro '$t'"; continue }
        try {
            $task | Enable-ScheduledTask -ErrorAction Stop | Out-Null
            $task | Start-ScheduledTask -ErrorAction SilentlyContinue
            OK "agente rearrancado: $t"
        }
        catch { Alerta "REARRANCA A MANO '$t': $($_.Exception.Message)" }
    }
    $resultado.whea = [ordered]@{ durante = (Get-WheaCount -Desde $inicio) }
    try {
        $dir = Split-Path -Parent $destino
        if (Test-Path $dir) {
            $resultado | ConvertTo-Json -Depth 8 | Set-Content -LiteralPath $destino -Encoding utf8
            OK "evidencia: $destino"
        }
        else {
            $alt = Join-Path $env:TEMP '2026-08-24-acer-auto-curve.json'
            $resultado | ConvertTo-Json -Depth 8 | Set-Content -LiteralPath $alt -Encoding utf8
            Alerta "evidencia en $alt"
        }
    }
    catch { Alerta "no pude escribir la evidencia: $($_.Exception.Message)" }
    Write-Host ""
    Write-Host "Estado final: $($resultado.status)   WHEA durante la corrida: $($resultado.whea.durante)" -ForegroundColor Green
    try { Stop-Transcript | Out-Null } catch { }
    Write-Host "Log: $script:LogPath" -ForegroundColor DarkGray
    Read-Host "Enter para cerrar"
}
