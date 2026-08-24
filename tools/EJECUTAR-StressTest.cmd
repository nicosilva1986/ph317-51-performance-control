@echo off
title Stress test de la curva - Predator PH317-51
cd /d "%~dp0"

net session >nul 2>&1
if %errorlevel% neq 0 (
    echo.
    echo   Se necesitan permisos de administrador.
    echo   Acepta el cartel de Windows que va a aparecer.
    echo.
    powershell -NoProfile -Command "Start-Process -FilePath '%~f0' -Verb RunAs"
    if errorlevel 1 (
        echo.
        echo   NO se pudo elevar. Abri PowerShell como administrador y corre:
        echo       ^& '%~f0'
        echo.
        pause
    )
    exit /b
)

echo.
echo  ==================================================================
echo    STRESS TEST DE LA CURVA PROPORCIONAL
echo.
echo    Paso 0  Despliega la calibracion nueva si hace falta
echo    Fase A  Carga de CPU 10 min (NumPy, igual que el benchmark)
echo    Fase B  CPU + GPU 5 min
echo    Fase C  Enfriado 3 min
echo.
echo    Unos 20 minutos. Quedate mirando.
echo    Aborta solo a 92 C de CPU o 88 C de GPU.
echo.
echo    Sin la parte de GPU:  EJECUTAR-StressTest.cmd -SinGpu
echo  ==================================================================
echo.

powershell -NoProfile -ExecutionPolicy Bypass -File "%~dp0Stress-CurvaVentiladores.ps1" %*

echo.
echo  ------------------------------------------------------------------
echo    Termino. Esta ventana NO se cierra sola: lee lo de arriba.
echo    Queda un archivo stress-*.log en esta misma carpeta.
echo  ------------------------------------------------------------------
pause
