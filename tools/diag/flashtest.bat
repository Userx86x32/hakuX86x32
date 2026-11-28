@echo off
rem Fable light-flash experiment (docs/fable-light-flash-investigation.md):
rem four short runs, each with one setting changed, counting the GPU
rem driver's bad visibility counts ("taken as 0") in each.
rem   flashtest               one phone on adb
rem   flashtest 192.168.1.28:34803    a phone on wireless debugging
rem Results: flashtest-results.txt beside this file (send that file).
setlocal enabledelayedexpansion
set "ADB=adb"
if not "%~1"=="" set "ADB=adb -s %~1"
set "PKG=com.rfandango.haku_x.debug"
set "OUT=%~dp0flashtest-results.txt"
%ADB% get-state >nul 2>nul || (echo No phone found. Check adb devices. & exit /b 1)
echo Fable light-flash experiment, %DATE% %TIME% > "%OUT%"
%ADB% shell setprop debug.hakux.tu_debug startup
call :run baseline      7 "HAKUX_NONE=1"
call :run priority-1    1 "HAKUX_NONE=1"
call :run prefer-gmem   7 "TU_AUTOTUNE_ALGO=prefer_gmem"
call :run prefer-sysmem 7 "TU_AUTOTUNE_ALGO=prefer_sysmem"
rem back to the defaults
%ADB% shell setprop debug.hakux.kgslprio 7
%ADB% shell setprop debug.hakux.env "HAKUX_NONE=1"
%ADB% shell setprop debug.hakux.tu_debug none
%ADB% shell am force-stop %PKG%
echo.
echo Done. Settings are back to normal. Send this file:
echo   %OUT%
type "%OUT%"
exit /b 0

:run
echo.
echo ===== Run "%~1" =====
%ADB% shell am force-stop %PKG%
%ADB% shell setprop debug.hakux.kgslprio %~2
%ADB% shell setprop debug.hakux.env "%~3"
%ADB% logcat -c
echo 1. Open hakuX Debug and start Fable.
echo 2. Load your save at Greatwood Gorge (the bridge).
echo 3. Start the phone's screen recorder (it makes the fault show up faster).
echo 4. Play for 90 seconds: cross the bridge back and forth, move the camera.
echo 5. Stop the recorder, then come back here.
set "SEEN="
set /p SEEN="How many flashes did you see (a number, then Enter)? "
%ADB% logcat -d > "%~dp0flashtest-%~1.log" 2>nul
set N=0
for /f %%C in ('findstr /c:"taken as 0" "%~dp0flashtest-%~1.log" ^| find /c /v ""') do set N=%%C
>> "%OUT%" echo.
>> "%OUT%" echo ===== %~1: kgslprio=%~2 env=%~3
>> "%OUT%" echo bad counts logged: !N!    flashes seen: !SEEN!
findstr /i /c:"TU_AUTOTUNE" /c:"TU_DEBUG" /c:"debug.hakux.env" /c:"kgsl" "%~dp0flashtest-%~1.log" >> "%OUT%"
findstr /c:"taken as 0" "%~dp0flashtest-%~1.log" >> "%OUT%"
echo   bad counts in this run: !N!
exit /b 0
