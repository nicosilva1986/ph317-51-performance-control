@echo off
title Medicion de curva de ventiladores - Predator PH317-51
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
echo    MEDICION DE CURVA DE VENTILADORES
echo.
echo    Dura unos 25 minutos. Quedate mirando la pantalla.
echo    Ctrl-C aborta y restaura los ventiladores automaticamente.
echo.
echo    Para hacer solo la parte sin riesgo (sin tocar el EC), cerra
echo    esta ventana y usa:  EJECUTAR-Medicion.cmd -SoloFase1
echo  ==================================================================
echo.

powershell -NoProfile -ExecutionPolicy Bypass -File "%~dp0Medir-CurvaVentiladores.ps1" %*

echo.
echo  ------------------------------------------------------------------
echo    Termino. Esta ventana NO se cierra sola: lee lo de arriba.
echo    Queda un archivo medicion-*.log en esta misma carpeta.
echo  ------------------------------------------------------------------
pause
