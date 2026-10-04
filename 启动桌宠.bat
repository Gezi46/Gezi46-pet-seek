@echo off
rem ============================================================
rem  Launch the pet, plus its local AI service when it needs one.
rem
rem  The pet has two interchangeable AI backends (right-click the
rem  pet: "Chat & AI" -> "AI service settings..."):
rem    * official API   https://api.deepseek.com      (paid key, no local service)
rem    * local web app  http://127.0.0.1:8520/v1      (deepseek-web-api)
rem  This script reads the pet's own config and only starts the local
rem  service when that config actually points at it.
rem
rem  THREE RULES for this file (each one bit us already):
rem    1. keep it ASCII-only and CRLF - cmd parses multi-byte text and
rem       LF endings wrongly and starts running the fragments;
rem    2. never put a pipe character inside a bat line - cmd reads it as a pipe
rem       and executes the rest as commands (use foreach, not pipelines);
rem    3. use "%~dp0." for --path, never "%~dp0" - a trailing backslash-quote
rem       gets treated as an escaped quote and breaks the whole command.
rem
rem  OPTIONAL: set GODOT to the full path of your Godot 4 executable,
rem  and AI_DIR to the folder of the local AI service. Both are
rem  auto-detected / skipped when you leave them alone.
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

if not defined AI_DIR set "AI_DIR=%~dp0..\deepseek-web-api"
set "AI_HEALTH=http://127.0.0.1:8520/healthz"

rem ---- does the pet's config ask for the local 8520 service? ----
rem pet_chat.cfg lives under %APPDATA%\Godot\app_userdata\<project>\ but the
rem project folder name may be non-ASCII and this file must stay ASCII, so
rem find it by scanning instead of hardcoding the path. No pipelines (rule 2).
powershell -NoProfile -Command "$p=Join-Path $env:APPDATA 'Godot\app_userdata'; $f=''; foreach($d in (Get-ChildItem $p -Directory -EA SilentlyContinue)){ $c=Join-Path $d.FullName 'pet_chat.cfg'; if(Test-Path $c){ $f=$c; break } }; if($f -eq ''){exit 2}; if((Get-Content -Raw $f) -match '127\.0\.0\.1:8520'){exit 0}else{exit 1}"
if errorlevel 2 goto :local_ai
if errorlevel 1 goto :official_ai
goto :local_ai

:official_ai
echo [AI] config points at the official API - no local service needed.
goto :launch

:local_ai
powershell -NoProfile -Command "try{Invoke-WebRequest -Uri '%AI_HEALTH%' -TimeoutSec 2 -UseBasicParsing > $null; exit 0}catch{exit 1}"
if errorlevel 1 goto :start_ai
echo [AI] the local AI service is already running.
goto :launch

:start_ai
if not exist "%AI_DIR%\start.mjs" (
	echo [AI] cannot find %AI_DIR%\start.mjs - skipping, the pet falls back to local lines.
	goto :launch
)
echo [AI] starting the local AI service ...
start "local-ai" /min /d "%AI_DIR%" cmd /c node start.mjs
rem wait up to ~24s for it to answer
powershell -NoProfile -Command "for($i=0;$i -lt 30;$i++){try{Invoke-WebRequest -Uri '%AI_HEALTH%' -TimeoutSec 2 -UseBasicParsing > $null; exit 0}catch{Start-Sleep -Milliseconds 800}}; exit 1"
if errorlevel 1 (
	echo [AI] not up within 24s - the pet still starts, but AI chat falls back to local lines.
	echo [AI] troubleshoot: double-click %AI_DIR%\start.cmd and read the log
) else (
	echo [AI] ready.
)

:launch
rem ---- first run: build the import cache (.godot/) ----
rem A fresh clone has no .godot folder, and Godot does NOT import assets
rem when it is launched with --path - that only happens in the editor or
rem with an explicit --import. Skip this and the 3D model fails to load
rem (a screenful of "referenced non-existent resource" errors). Runs
rem once, takes ~10-30s; every later start finds the folder and skips it.
if not exist "%~dp0.godot\imported" (
	echo [GODOT] first run - importing assets, this takes a moment ...
	"%GODOT_EXE%" --headless --path "%~dp0." --import
)
start "" "%GODOT_EXE%" --path "%~dp0."
