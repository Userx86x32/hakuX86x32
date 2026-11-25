@echo off
rem hakuX route automation from the PC: copies route.sh and friends to the
rem phone, runs them there, and pulls the results back next to this file.
rem   route record bowerstone
rem   route run bowerstone 6 x4:vcpucore=1 all:vcpucore=0
rem   route pull        (copies /sdcard/hakux_diag/routes to .\routes)
setlocal
set "HERE=%~dp0"
set "ADB=adb"
where adb >nul 2>nul || if exist "%HERE%platform-tools\adb.exe" (set "ADB=%HERE%platform-tools\adb.exe") else if exist "%HERE%adb.exe" (set "ADB=%HERE%adb.exe") else (echo adb not found: put this file in C:\hakuX-tests next to platform-tools & exit /b 1)
"%ADB%" get-state >nul 2>nul || (echo no phone: check the cable and USB debugging & exit /b 1)
if /i "%1"=="pull" goto pull
"%ADB%" shell mkdir -p /data/local/tmp/hakux
"%ADB%" push "%HERE%route.sh" "%HERE%route_report.sh" "%HERE%route_trace.pbtx" /data/local/tmp/hakux/ >nul || exit /b 1
"%ADB%" shell -t sh /data/local/tmp/hakux/route.sh %*
:pull
if not exist "%HERE%routes" mkdir "%HERE%routes"
"%ADB%" pull /sdcard/hakux_diag/routes "%HERE%." >nul && echo results in %HERE%routes
endlocal
