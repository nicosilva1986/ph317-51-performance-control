@echo off
title Limpieza final - Predator PH317-51
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
echo    LIMPIEZA FINAL
echo.
echo    1) Desinstala MSI Afterburner y RivaTuner
echo    2) Saca ThrottleStop del arranque automatico
echo    3) Desinstala HWiNFO64
echo    4) Despliega el fix del arranque de ventiladores (60 s)
echo.
echo    Para saltear el paso 4:  EJECUTAR-Limpieza.cmd -SinDesplegar
echo  ==================================================================
echo.

powershell -NoProfile -ExecutionPolicy Bypass -File "%~dp0Limpieza-Final.ps1" %*

echo.
echo  ------------------------------------------------------------------
echo    Termino. Esta ventana NO se cierra sola: lee lo de arriba.
echo    Queda un archivo limpieza-*.log en esta misma carpeta.
echo  ------------------------------------------------------------------
pause
