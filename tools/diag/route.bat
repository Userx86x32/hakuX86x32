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
rem   route upload           pulls, then pushes .\routes to the diag-results branch
rem A batch runs on the phone by itself: a cable drop doesn't stop it.
rem After a batch (route auto / run / watch) the results are pulled and
rem uploaded to GitHub: the diag-results branch of hakuX86x32, routes\ in it
rem (needs Git for Windows; the first push asks you to sign in to GitHub).
rem Perfetto traces stay on the PC: set UPLOAD_TRACES=1 to upload them too.
rem set UPLOAD=0 to skip uploading.
setlocal
set "HERE=%~dp0"
set "REPO=https://github.com/Userx86x32/hakuX86x32.git"
set "RES=%HERE%results-repo"
if /i "%1"=="upload" set "UPLOAD_AFTER=1"
set "ADB=adb"
set "APK_URL=https://github.com/Userx86x32/hakuX86x32/releases/download/build-claude-vibrant-cerf-lmdbik-13/hakuX-debug-claude-vibrant-cerf-lmdbik-13-1df9d50-sd865up.apk"
where adb >nul 2>nul || if exist "%HERE%platform-tools\adb.exe" (set "ADB=%HERE%platform-tools\adb.exe") else if exist "%HERE%adb.exe" (set "ADB=%HERE%adb.exe") else if exist "C:\hakuX-tests\platform-tools\adb.exe" (set "ADB=C:\hakuX-tests\platform-tools\adb.exe") else if exist "C:\hakuX-tests\adb.exe" (set "ADB=C:\hakuX-tests\adb.exe") else (echo adb not found: put this file next to adb.exe or platform-tools & exit /b 1)
"%ADB%" get-state >nul 2>nul || (
  if /i "%1"=="upload" goto upload
  echo no phone: check the cable and USB debugging, and allow this PC on the phone
  exit /b 1
)
if /i "%1"=="upload" goto pull
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
set "UPLOAD_AFTER=1"
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
if "%UPLOAD_AFTER%"=="1" if not "%UPLOAD%"=="0" goto upload
goto :eof

rem ---- the results to GitHub: a checkout of the diag-results branch alone ----
:upload
where git >nul 2>nul || (
  echo results not uploaded: Git isn't installed. Install it with
  echo   winget install --id Git.Git -e
  echo then open a new Command Prompt and run: route upload
  goto :eof
)
if not exist "%HERE%routes" (echo nothing to upload yet & goto :eof)
if exist "%RES%\.git" goto upload_copy
git ls-remote --exit-code --heads "%REPO%" diag-results >nul 2>nul
if errorlevel 1 goto upload_new
git clone -q --branch diag-results --single-branch --depth 1 "%REPO%" "%RES%" || (echo results not uploaded: cloning failed & goto :eof)
goto upload_copy
:upload_new
rem the first upload starts the branch, with nothing of the code in it
git init -q -b diag-results "%RES%" || (echo results not uploaded: git init failed & goto :eof)
git -C "%RES%" remote add origin "%REPO%"
> "%RES%\README.md" echo # hakuX route results
>> "%RES%\README.md" echo.
>> "%RES%\README.md" echo Uploaded by tools/diag/route.bat after each batch: routes/^<route^>-^<time^>/ holds
>> "%RES%\README.md" echo report.txt, summary.csv, batch.txt and one folder per run (logcat.txt, sensors.csv, run.txt).
:upload_copy
git -C "%RES%" config user.name "hakuX route runner"
git -C "%RES%" config user.email "route-runner@users.noreply.github.com"
git -C "%RES%" config core.autocrlf false
git -C "%RES%" pull -q --ff-only origin diag-results >nul 2>nul
set "XF=*.pftrace route.pid"
if "%UPLOAD_TRACES%"=="1" set "XF=route.pid"
robocopy "%HERE%routes" "%RES%\routes" /E /NFL /NDL /NJH /NJS /NP /XF %XF% >nul
if errorlevel 8 (echo results not uploaded: copying them failed & goto :eof)
git -C "%RES%" add -A
git -C "%RES%" diff --cached --quiet && (echo results: nothing new to upload & goto :eof)
git -C "%RES%" commit -q -m "route results %DATE% %TIME%"
git -C "%RES%" push -q -u origin diag-results || (echo results not uploaded: the push failed, run: route upload & goto :eof)
echo results uploaded: https://github.com/Userx86x32/hakuX86x32/tree/diag-results/routes
endlocal
