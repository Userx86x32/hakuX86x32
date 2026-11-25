@echo off
rem hakuX route automation from the PC: copies route.sh and friends to the
rem phone, runs them there, and pulls the results back next to this file.
rem   route install          the latest test APK (or: route install <file.apk or URL>)
rem   route auto [runs]      a hands-off route from savestate slot 1, then the batch:
rem                          X4 pinning on and off in turn (6 runs by default)
rem   route tour bower 3     the hands-off route alone (3 minutes)
rem   route run bower 6 x4:vcpucore=1 all:vcpucore=0
rem   route record bower     a route you play yourself
rem   route watch            follows a batch again (after the cable dropped)
rem   route stop             stops a batch
rem   route pull             copies /sdcard/hakux_diag/routes to .\routes
rem A batch runs on the phone by itself: a cable drop doesn't stop it.
setlocal
set "HERE=%~dp0"
set "ADB=adb"
set "APK_URL=https://github.com/Userx86x32/hakuX86x32/releases/download/build-claude-vibrant-cerf-lmdbik-11/hakuX-debug-claude-vibrant-cerf-lmdbik-11-c987c07-sd865up.apk"
where adb >nul 2>nul || if exist "%HERE%platform-tools\adb.exe" (set "ADB=%HERE%platform-tools\adb.exe") else if exist "%HERE%adb.exe" (set "ADB=%HERE%adb.exe") else if exist "C:\hakuX-tests\platform-tools\adb.exe" (set "ADB=C:\hakuX-tests\platform-tools\adb.exe") else if exist "C:\hakuX-tests\adb.exe" (set "ADB=C:\hakuX-tests\adb.exe") else (echo adb not found: put this file next to adb.exe or platform-tools & exit /b 1)
"%ADB%" get-state >nul 2>nul || (echo no phone: check the cable and USB debugging, and allow this PC on the phone & exit /b 1)
if /i "%1"=="pull" goto pull
if /i "%1"=="install" goto install
"%ADB%" shell mkdir -p /data/local/tmp/hakux
"%ADB%" push "%HERE%route.sh" "%HERE%route_report.sh" "%HERE%route_trace.pbtx" /data/local/tmp/hakux/ >nul || exit /b 1
if /i "%1"=="watch" goto watch
if /i "%1"=="stop" (
  "%ADB%" shell sh /data/local/tmp/hakux/route.sh stop
  goto :eof
)
if /i "%1"=="report" (
  "%ADB%" shell sh /data/local/tmp/hakux/route.sh %*
  goto pull
)
"%ADB%" shell sh /data/local/tmp/hakux/route.sh start %* || exit /b 1
:watch
echo (following the phone; Ctrl+C or a cable drop leaves it running: route watch)
"%ADB%" shell sh /data/local/tmp/hakux/route.sh watch
goto pull

:install
set "APK=%2"
if "%APK%"=="" set "APK=%APK_URL%"
if /i "%APK:~0,4%"=="http" (
  echo downloading %APK%
  curl.exe -L --fail -o "%HERE%hakux-test.apk" "%APK%" || (echo download failed & exit /b 1)
  set "APK=%HERE%hakux-test.apk"
)
"%ADB%" install -r "%APK%"
if errorlevel 1 (
  echo.
  echo If it says INSTALL_FAILED_UPDATE_INCOMPATIBLE, the APK is signed with another key:
  echo uninstall first with   "%ADB%" uninstall com.rfandango.haku_x.debug
  echo ^(that removes hakuX debug's settings and savestates: back them up first^)
  exit /b 1
)
echo installed. Start Fable once by hand so hakuX remembers it, then: route auto
goto :eof

:pull
if not exist "%HERE%routes" mkdir "%HERE%routes"
"%ADB%" pull /sdcard/hakux_diag/routes "%HERE%." >nul && echo results in %HERE%routes
endlocal
