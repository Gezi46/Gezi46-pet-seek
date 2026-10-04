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
rem  2. godot.exe on PATH
rem  3. a few common install folders
set "GODOT_EXE="
if defined GODOT if exist "%GODOT%" set "GODOT_EXE=%GODOT%"
if not defined GODOT_EXE for %%i in (godot.exe) do if not "%%~$PATH:i"=="" set "GODOT_EXE=%%~$PATH:i"
if not defined GODOT_EXE for %%d in (
  "%ProgramFiles%\Godot"
  "%ProgramFiles(x86)%\Godot"
  "%LOCALAPPDATA%\Programs\Godot"
  "%USERPROFILE%\scoop\apps\godot\current"
  "C:\Godot"
  "D:\Godot"
) do if not defined GODOT_EXE if exist "%%~d\godot.exe" set "GODOT_EXE=%%~d\godot.exe"
if not defined GODOT_EXE (
  echo [ERR] godot.exe not found. Install Godot 4, or point GODOT at it:
  echo        set "GODOT=C:\path\to\godot.exe"
  echo.
  pause
  exit /b 1
)
echo [GODOT] %GODOT_EXE%

"%GODOT_EXE%" --path "%~dp0." --script res://tools/check_effect.gd
echo.
echo PNGs were written into the "check output" folder inside the project directory.
pause
