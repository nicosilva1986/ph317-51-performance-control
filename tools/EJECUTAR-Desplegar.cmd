@echo off
title Desplegar calibracion de ventiladores - Predator PH317-51
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
echo    DESPLEGAR LA CALIBRACION NUEVA
echo.
echo    Solo despliega. No hace stress test ni desinstala nada.
echo    Tarda unos segundos, mas lo que tarde en soltar el MAX.
echo  ==================================================================
echo.

powershell -NoProfile -ExecutionPolicy Bypass -File "%~dp0Desplegar-Calibracion.ps1" %*

echo.
echo  ------------------------------------------------------------------
echo    Termino. Esta ventana NO se cierra sola.
echo  ------------------------------------------------------------------
pause
