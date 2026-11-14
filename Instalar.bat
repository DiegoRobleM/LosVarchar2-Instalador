@echo off
rem Abre el instalador grafico de mods (archivos\instalador-gui.ps1).
rem Esta ventana negra se puede ignorar: se cierra sola al terminar.
if not exist "%~dp0archivos\instalador-gui.ps1" (
  echo No encuentro archivos\instalador-gui.ps1.
  echo Extrae TODA la carpeta del .zip y vuelve a abrir Instalar.bat.
  pause
  exit /b 1
)
powershell -NoProfile -ExecutionPolicy Bypass -STA -File "%~dp0archivos\instalador-gui.ps1"
if errorlevel 1 (
  echo.
  echo Hubo un problema. Prueba con archivos\instalar-modo-texto.bat
  pause
)
