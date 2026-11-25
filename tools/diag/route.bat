@echo off
rem hakuX route automation from the PC: copies route.sh and friends to the
rem phone, runs them there, and pulls the results back next to this file.
rem   route install          the latest test APK (or: route install <file.apk or URL>)
rem   route suite A [B]      the 30-minute batch (docs/diag-suite.md): per scene
rem                          (bower: slot 1, wood: slot 2), 6 runs A B A B..., then a
rem                          probe run (Perfetto or simpleperf). A variant is
rem                          label:name=value,... e.g.
rem                            route suite base nohints:adpf=0
rem                            route suite fps60:mod=60fps fps40:mod=40fps
rem                            route suite base async0:asyncpipe=0
rem                            route suite base cold:cold=1
rem                            route suite base sysdrv:driver=system
rem                            route suite base x3:scale=3
rem   route auto             route suite x4:vcpucore=1 all:vcpucore=0
rem   route tour bower 75    a hands-off route alone (75 seconds)
rem   route run bower 6 x4:vcpucore=1 all:vcpucore=0   one scene (slot 1)
rem Settings (scenes, runs, cool-down...): route.cfg next to this file, if any.
rem   route record bower     a route you play yourself
rem   route save 2           a savestate of the running game to slot 2 (get there first)
rem   route load 2           loads slot 2
rem   route clean            clears the runner's settings on the phone (after a cut-off batch)
rem   route backup           savestates, settings, GPU driver and save games to hakux-backup.tar
rem   route restore          puts hakux-backup.tar back
rem   route reinstall        backup, uninstall, install the test APK, restore (when an
rem                          install fails: INSTALL_FAILED_UPDATE_INCOMPATIBLE)
rem   route queue            runs the batches in queue.txt one after another, by itself:
rem                          when the phone stops answering (Auto Blocker on, cable,
rem                          locked) it waits, says so, and carries on once it's back;
rem                          a batch Auto Blocker killed is cleaned up and run again
rem   route watch            follows a batch again (after the cable dropped)
rem   route stop             stops a batch
rem   route pull             copies /sdcard/hakux_diag/routes to .\routes
rem   route upload           pulls, then pushes .\routes to the diag-results branch
rem A batch runs on the phone by itself: a cable drop doesn't stop it.
rem After a batch (route auto / run / watch) the results are pulled and
rem uploaded to GitHub: the diag-results branch of hakuX86x32, routes\ in it
rem (needs Git for Windows; the first push asks you to sign in to GitHub).
rem Perfetto traces and CPU profiles (perf.data) stay on the PC: set
rem UPLOAD_TRACES=1 to upload them too (the simpleperf reports always go).
rem set UPLOAD=0 to skip uploading.
setlocal
set "HERE=%~dp0"
set "REPO=https://github.com/Userx86x32/hakuX86x32.git"
set "RES=%HERE%results-repo"
if /i "%1"=="upload" set "UPLOAD_AFTER=1"
set "ADB=adb"
set "APK_URL=https://github.com/Userx86x32/hakuX86x32/releases/download/build-claude-vibrant-cerf-lmdbik-14/hakuX-debug-claude-vibrant-cerf-lmdbik-14-e6ba66e-sd865up.apk"
where adb >nul 2>nul || if exist "%HERE%platform-tools\adb.exe" (set "ADB=%HERE%platform-tools\adb.exe") else if exist "%HERE%adb.exe" (set "ADB=%HERE%adb.exe") else if exist "C:\hakuX-tests\platform-tools\adb.exe" (set "ADB=C:\hakuX-tests\platform-tools\adb.exe") else if exist "C:\hakuX-tests\adb.exe" (set "ADB=C:\hakuX-tests\adb.exe") else (echo adb not found: put this file next to adb.exe or platform-tools & exit /b 1)
set "PKG=com.rfandango.haku_x.debug"
if /i "%1"=="queue" goto queue
"%ADB%" get-state >nul 2>nul || (
  if /i "%1"=="upload" goto upload
  echo no phone: check the cable and USB debugging, and allow this PC on the phone
  exit /b 1
)
if /i "%1"=="upload" goto pull
set "BK=%HERE%hakux-backup.tar"
if /i "%1"=="pull" goto pull
if /i "%1"=="install" goto install
if /i "%1"=="backup" goto backup
if /i "%1"=="restore" goto restore
if /i "%1"=="reinstall" goto reinstall
call :push_scripts || exit /b 1
if /i "%1"=="watch" goto watch
if /i "%1"=="stop" (
  "%ADB%" shell sh /data/local/tmp/hakux/route.sh stop
  goto :eof
)
if /i "%1"=="report" (
  "%ADB%" shell sh /data/local/tmp/hakux/route.sh %*
  goto pull
)
for %%C in (save load clean tour) do if /i "%1"=="%%C" (
  "%ADB%" shell sh /data/local/tmp/hakux/route.sh %*
  goto :eof
)
"%ADB%" shell sh /data/local/tmp/hakux/route.sh start %* || exit /b 1
:watch
set "UPLOAD_AFTER=1"
echo (following the phone; Ctrl+C or a cable drop leaves it running: route watch)
"%ADB%" shell sh /data/local/tmp/hakux/route.sh watch
goto pull

:install
call :install_apk %2
goto :eof
rem the APK: a file or URL (%1 of the call), else the test build
:install_apk
set "APK=%~1"
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
  echo or let route do it all, keeping savestates and saves:   route reinstall
  exit /b 1
)
if not "%REINST%"=="1" echo installed. Start Fable once by hand so hakuX remembers it, then: route auto
exit /b 0

rem ---- the scripts to the phone ----
:push_scripts
"%ADB%" shell mkdir -p /data/local/tmp/hakux
"%ADB%" push "%HERE%route.sh" "%HERE%route_report.sh" "%HERE%route_trace.pbtx" /data/local/tmp/hakux/ >nul || exit /b 1
if exist "%HERE%route.cfg" ("%ADB%" push "%HERE%route.cfg" /data/local/tmp/hakux/ >nul) else ("%ADB%" shell rm -f /data/local/tmp/hakux/route.cfg)
exit /b 0

rem ---- the queue: queue.txt's commands in order, finished ones in queue.done ----
:queue
set "Q=%HERE%queue.txt"
set "QD=%HERE%queue.done"
if not exist "%Q%" call :queue_default
if not exist "%QD%" type nul > "%QD%"
echo queue: %Q%  (finished: %QD%; delete it to run everything again)
echo Stop with Ctrl+C here, then: route stop
:queue_next
set "NEXT="
for /f "usebackq eol=# delims=" %%L in ("%Q%") do if not defined NEXT (
  findstr /x /c:"%%L" "%QD%" >nul || set "NEXT=%%L"
)
if not defined NEXT (
  echo [%TIME%] queue: everything in queue.txt is done
  goto :eof
)
set "TRIES=0"
:queue_try
call :wait_phone
call :push_scripts || goto queue_try
call :phone_status
rem the batch is still running (the phone was away a while): follow it again
if "%ST%"=="running" goto queue_watch
rem it finished while the phone was away
if "%ST%"=="done" if "%STC%"=="%NEXT%" goto queue_finished
rem (a try that was cut off resumes the batch, keeping its finished runs)
if %TRIES% geq 5 (
  echo [%TIME%] queue: "%NEXT%" didn't finish in 5 tries, skipped
  >> "%QD%" echo %NEXT%
  goto queue_next
)
set /a TRIES+=1
"%ADB%" shell sh /data/local/tmp/hakux/route.sh clean >nul
echo.
echo [%TIME%] queue: route %NEXT%   (try %TRIES%)
"%ADB%" shell sh /data/local/tmp/hakux/route.sh start %NEXT%
:queue_watch
"%ADB%" shell sh /data/local/tmp/hakux/route.sh watch
call :wait_phone
call :phone_status
if "%ST%"=="running" goto queue_watch
if "%ST%"=="done" if "%STC%"=="%NEXT%" goto queue_finished
if "%ST%"=="failed" goto queue_failed
echo [%TIME%] queue: "%NEXT%" was cut off (Auto Blocker or the cable): going on with it, its finished runs kept
goto queue_try
rem the runner stopped on an error of its own: the same again would fail the same way
:queue_failed
echo.
echo [%TIME%] queue: stopped. "%NEXT%" failed with:
"%ADB%" shell "grep 'route. error:' /sdcard/hakux_diag/routes/console.txt"
echo Fix that, then run "route queue" again: it starts with "%NEXT%".
goto :eof
:queue_finished
>> "%QD%" echo %NEXT%
echo [%TIME%] queue: "%NEXT%" done
set "UPLOAD_AFTER=1"
call :pull
goto queue_next

rem ST and STC: the phone's last batch (route.sh status): running/done/stopped/none, its command
:phone_status
set "ST=none"
set "STC="
rem (status prints state|command|: a stray carriage return falls after the last |)
for /f "tokens=1,2 delims=|" %%A in ('""%ADB%" shell sh /data/local/tmp/hakux/route.sh status"') do (
  set "ST=%%A"
  set "STC=%%B"
)
exit /b 0

rem waits until the phone answers adb (Auto Blocker on, unplugged, locked or not allowed: it doesn't)
:wait_phone
"%ADB%" get-state 2>nul | findstr /x device >nul && exit /b 0
echo.
echo [%TIME%] waiting for the phone. Check: plugged in, unlocked, Auto Blocker off
echo           (Settings, Security and privacy, Auto Blocker), and "Allow USB debugging" if asked.
set "BEEPS=0"
:wait_phone_loop
rem a beep about once a minute while waiting (set BEEP=0 for none)
set /a BEEPS+=1
set /a BEEPM=BEEPS %% 4
if not "%BEEP%"=="0" if "%BEEPM%"=="1" powershell -NoProfile -Command "[console]::Beep(880,300);[console]::Beep(660,300)" >nul 2>nul
ping -n 16 127.0.0.1 >nul
"%ADB%" get-state 2>nul | findstr /x device >nul || goto wait_phone_loop
echo [%TIME%] the phone is back
ping -n 6 127.0.0.1 >nul
exit /b 0

rem queue.txt the first time: the suite's batches in the order docs/diag-suite.md gives
:queue_default
> "%Q%" echo # route queue: one route command a line, run in order by "route queue".
>> "%Q%" echo # Lines starting with # are skipped. Finished lines go to queue.done.
>> "%Q%" echo # The charging test (V7) needs you to unplug the phone, so it isn't here.
>> "%Q%" echo suite base nohints:adpf=0
>> "%Q%" echo suite fps60:mod=60fps fps40:mod=40fps
>> "%Q%" echo suite base cold:cold=1
>> "%Q%" echo suite base async0:asyncpipe=0
>> "%Q%" echo suite base sysdrv:driver=system
>> "%Q%" echo suite base x3:scale=3
>> "%Q%" echo auto
exit /b 0

rem ---- backup / restore of the app's own files (run-as: a debug build) ----
:backup
call :do_backup
goto :eof
:do_backup
if exist "%BK%" move /y "%BK%" "%HERE%hakux-backup.old.tar" >nul
echo backing up savestates, settings, GPU driver and save games (let it finish)...
"%ADB%" exec-out run-as %PKG% tar -cf - files/native/states files/gpu_driver shared_prefs files/native/hdd/Partition1 files/native/hdd/Partition2 > "%BK%"
tar -tf "%BK%" 2>nul | findstr /c:"files/native/states/" >nul || (echo backup failed: no savestates in %BK% & exit /b 1)
for %%F in ("%BK%") do echo backup: %%~fF ^(%%~zF bytes^)
exit /b 0

:restore
call :do_restore
goto :eof
:do_restore
if not exist "%BK%" (echo no backup: %BK% isn't there & exit /b 1)
"%ADB%" push "%BK%" /data/local/tmp/hakux-backup.tar >nul || (echo restore failed: push & exit /b 1)
"%ADB%" shell "cat /data/local/tmp/hakux-backup.tar | run-as %PKG% tar -xf -"
"%ADB%" shell rm /data/local/tmp/hakux-backup.tar
"%ADB%" shell "run-as %PKG% sh -c 'ls files/native/states/*/'" | findstr /i hxs >nul && (echo restored: savestates are back) || (echo restore: no savestates on the phone after it & exit /b 1)
exit /b 0

:reinstall
set "REINST=1"
call :do_backup || (echo nothing uninstalled: the backup didn't work & goto :eof)
"%ADB%" uninstall %PKG%
call :install_apk %2 || (echo the install failed: your backup is in %BK%, put it back after installing with: route restore & goto :eof)
call :do_restore
echo Open hakuX, pick your games folder again if it asks, start Fable once, then: route auto
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
set "XF=*.pftrace perf.data route.pid"
if "%UPLOAD_TRACES%"=="1" set "XF=route.pid"
robocopy "%HERE%routes" "%RES%\routes" /E /NFL /NDL /NJH /NJS /NP /XF %XF% >nul
if errorlevel 8 (echo results not uploaded: copying them failed & goto :eof)
git -C "%RES%" add -A
git -C "%RES%" diff --cached --quiet && (echo results: nothing new to upload & goto :eof)
git -C "%RES%" commit -q -m "route results %DATE% %TIME%"
git -C "%RES%" push -q -u origin diag-results || (echo results not uploaded: the push failed, run: route upload & goto :eof)
echo results uploaded: https://github.com/Userx86x32/hakuX86x32/tree/diag-results/routes
goto :eof
