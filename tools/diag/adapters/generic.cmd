@echo off
rem The generic adapter's side of route.bat (the phone's side: generic.sh):
rem any app, APP_PKG= in route.cfg. No test APK (route install <file or URL>)
rem and no backup (an app that isn't debuggable keeps its files to itself:
rem route backup, restore and reinstall refuse). route.bat calls it with a
rem hook's name: init, installed, after_backup, after_restore, reinstalled,
rem queue_default.
goto %1

:init
if not defined APP_PKG call :cfg_pkg
if not defined APP_PKG (echo the generic adapter measures one app: APP_PKG=^<package^> in route.cfg & exit /b 1)
set "PKG=%APP_PKG%"
set "APK_URL="
set "BKNAME=%APP_PKG%-backup"
set "BACKUP_WHAT="
set "BACKUP_PATHS="
set "PREFLIGHT_WHAT=the app starts and stays up, SurfaceFlinger shows its layer, its threads can be read"
exit /b 0
:cfg_pkg
if not exist "%HERE%route.cfg" exit /b 0
for /f "usebackq tokens=1,* delims==" %%A in (`findstr /b /c:"APP_PKG=" "%HERE%route.cfg"`) do set "APP_PKG=%%~B"
exit /b 0

:installed
echo installed. Then: route preflight, or route suite base1 base2
exit /b 0

:reinstalled
exit /b 0

:after_backup
exit /b 0

:after_restore
exit /b 0

:queue_default
> "%Q%" echo # route queue: one route command a line, run in order by "route queue".
>> "%Q%" echo # Lines starting with # are skipped. Finished lines go to queue.done.
>> "%Q%" echo # The generic adapter: each run starts %APP_PKG%, waits APP_WAIT s, measures APP_SECS s.
>> "%Q%" echo suite base1 base2
exit /b 0
