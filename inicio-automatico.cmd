@echo off
rem ============================================================================
rem  Recorto - hace que arranque solo al prender la PC.
rem
rem     inicio-automatico.cmd            lo agrega al Inicio
rem     inicio-automatico.cmd /quitar    lo saca
rem
rem  Crea un acceso directo en la carpeta de Inicio del usuario, con el
rem  argumento /tray para que arranque callado (sin abrir el recorte).
rem  No toca el registro ni necesita permisos de administrador.
rem ============================================================================
setlocal

set "STARTUP=%APPDATA%\Microsoft\Windows\Start Menu\Programs\Startup"
set "LNK=%STARTUP%\Recorto.lnk"
set "EXE=%~dp0recorto.exe"

if /i "%~1"=="/quitar"    goto :quitar
if /i "%~1"=="-quitar"    goto :quitar
if /i "%~1"=="/remove"    goto :quitar

if not exist "%EXE%" goto :sinexe

rem El acceso directo se crea con VBScript: cscript.exe esta en todos los
rem Windows desde XP, asi que no hace falta PowerShell ni nada instalado.
set "VBS=%TEMP%\recorto_inicio.vbs"
> "%VBS%"  echo Set sh = CreateObject("WScript.Shell")
>>"%VBS%"  echo Set lnk = sh.CreateShortcut("%LNK%")
>>"%VBS%"  echo lnk.TargetPath = "%EXE%"
>>"%VBS%"  echo lnk.Arguments = "/tray"
>>"%VBS%"  echo lnk.WorkingDirectory = "%~dp0"
>>"%VBS%"  echo lnk.IconLocation = "%EXE%,0"
>>"%VBS%"  echo lnk.Description = "Recorto - recorte de pantalla a PDF"
>>"%VBS%"  echo lnk.Save
cscript //nologo "%VBS%"
del "%VBS%" >nul 2>&1

if not exist "%LNK%" goto :fallo
echo.
echo   Listo. Recorto va a arrancar solo la proxima vez que prendas la PC.
echo.
echo   Acceso directo: %LNK%
echo   Apunta a:       %EXE% /tray
echo.
echo   OJO: si moves esta carpeta de lugar, volve a correr este script.
echo   Para deshacerlo:  inicio-automatico.cmd /quitar
echo.
exit /b 0

:quitar
if not exist "%LNK%" (
    echo.
    echo   Recorto no estaba en el Inicio. No hay nada que sacar.
    echo.
    exit /b 0
)
del "%LNK%"
if exist "%LNK%" goto :fallo
echo.
echo   Listo, Recorto ya no arranca solo.
echo.
exit /b 0

:sinexe
echo.
echo   ERROR: no encuentro recorto.exe en esta carpeta:
echo   %~dp0
echo.
echo   Poné este script al lado del ejecutable, o compilalo con build.cmd
echo.
exit /b 1

:fallo
echo.
echo   ERROR: no se pudo escribir en la carpeta de Inicio:
echo   %STARTUP%
echo.
exit /b 1
