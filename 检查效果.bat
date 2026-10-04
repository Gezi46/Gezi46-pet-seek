@echo off
rem ============================================================
rem  One-command effect check.
rem
rem  Renders a few fixed views, writes the PNGs into the "check
rem  output" folder inside the project directory, and prints
rem  comparable numbers (solid / bright pixel counts), so a change
rem  can be judged without staring at a moving pet.
rem
rem  It renders the current config and a reference side by side, so
rem  you can see whether a fix is still doing its job.
rem
rem  Everything happens in ONE engine process on purpose: every
rem  variant needs a fresh pet instance, and booting the engine
rem  costs 5-10s each time.
rem
rem  NOTE: keep this file ASCII-only and CRLF (see the comment in
rem  the launch script for why).
rem ============================================================

rem ---- locate the Godot 4 executable ----
rem  1. %GODOT% if you set it yourself
rem  2. godot.exe / godot4.exe on PATH
rem  3. common install folders, including the usual Steam library paths
rem
rem  NOTE the filename list: the plain download ships as godot.exe or
rem  Godot_v4.x-stable_win64.exe, but the STEAM build is called
rem  godot.windows.opt.tools.64.exe.
set "GODOT_EXE="
if defined GODOT if exist "%GODOT%" set "GODOT_EXE=%GODOT%"
if not defined GODOT_EXE for %%i in (godot.exe godot4.exe) do if not "%%~$PATH:i"=="" set "GODOT_EXE=%%~$PATH:i"
if not defined GODOT_EXE for %%d in (
  "%ProgramFiles%\Godot"
  "%ProgramFiles(x86)%\Godot"
  "%LOCALAPPDATA%\Programs\Godot"
  "%USERPROFILE%\scoop\apps\godot\current"
  "C:\Godot"
  "D:\Godot"
  "%ProgramFiles(x86)%\Steam\steamapps\common\Godot Engine"
  "%ProgramFiles%\Steam\steamapps\common\Godot Engine"
  "C:\Steam\steamapps\common\Godot Engine"
  "D:\Steam\steamapps\common\Godot Engine"
  "E:\Steam\steamapps\common\Godot Engine"
) do if not defined GODOT_EXE for %%f in (
  "%%~d\godot.exe"
  "%%~d\godot4.exe"
  "%%~d\godot.windows.opt.tools.64.exe"
  "%%~d\Godot_v4*.exe"
) do if not defined GODOT_EXE if exist "%%~f" set "GODOT_EXE=%%~f"
if not defined GODOT_EXE (
  echo [ERR] no Godot 4 executable found.
  echo.
  echo   Tried: %%GODOT%%, PATH, the usual install folders and the usual
  echo   Steam library paths, under the names godot.exe / godot4.exe /
  echo   godot.windows.opt.tools.64.exe / Godot_v4*.exe
  echo.
  echo   Point this script at yours:
  echo        set "GODOT=C:\path\to\godot.exe"
  echo   or make it stick for new terminals:
  echo        setx GODOT "C:\path\to\godot.exe"
  echo.
  pause
  exit /b 1
)
echo [GODOT] %GODOT_EXE%

"%GODOT_EXE%" --path "%~dp0." --script res://tools/check_effect.gd
echo.
echo PNGs were written into the "check output" folder inside the project directory.
pause
