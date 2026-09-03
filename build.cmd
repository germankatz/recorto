@echo off
rem ============================================================================
rem  Recorto - compila recorto.ahk a los dos ejecutables.
rem
rem  Uso:
rem     build.cmd                          busca Ahk2Exe en las rutas tipicas
rem     build.cmd "C:\ruta\a\Compiler"     usa esa carpeta
rem
rem  Necesita AutoHotkey 1.1 (no v2). El zip portable de
rem  https://www.autohotkey.com/download/ahk.zip ya trae la carpeta Compiler.
rem ============================================================================
setlocal

set "AHKDIR=%~1"

if not "%AHKDIR%"=="" goto :check
for %%D in (
    "%ProgramFiles%\AutoHotkey\Compiler"
    "%ProgramFiles(x86)%\AutoHotkey\Compiler"
    "%LOCALAPPDATA%\Programs\AutoHotkey\Compiler"
    "%~dp0ahk\Compiler"
) do if exist "%%~D\Ahk2Exe.exe" set "AHKDIR=%%~D"

:check
if "%AHKDIR%"=="" goto :nocompiler
if not exist "%AHKDIR%\Ahk2Exe.exe" goto :nocompiler

echo Compilador: %AHKDIR%
echo.

echo [1/2] recorto.exe      (Unicode 32-bit - anda en Windows de 32 y 64 bits)
"%AHKDIR%\Ahk2Exe.exe" /in "%~dp0recorto.ahk" /out "%~dp0recorto.exe" /base "%AHKDIR%\Unicode 32-bit.bin" /silent
if not exist "%~dp0recorto.exe" goto :failed

echo [2/2] recorto_x64.exe  (Unicode 64-bit)
"%AHKDIR%\Ahk2Exe.exe" /in "%~dp0recorto.ahk" /out "%~dp0recorto_x64.exe" /base "%AHKDIR%\Unicode 64-bit.bin" /silent
if not exist "%~dp0recorto_x64.exe" goto :failed

echo.
echo Listo. El icono, el nombre y la version se embeben desde las directivas
echo ;@Ahk2Exe-... que estan al principio de recorto.ahk
exit /b 0

:nocompiler
echo.
echo ERROR: no encontre Ahk2Exe.exe
echo.
echo Bajate https://www.autohotkey.com/download/ahk.zip, descomprimilo, y
echo pasale a este script la ruta de la carpeta Compiler:
echo.
echo     build.cmd "C:\ruta\donde\descomprimiste\Compiler"
echo.
exit /b 1

:failed
echo.
echo ERROR: la compilacion no genero el ejecutable.
exit /b 1
