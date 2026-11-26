@echo off
rem hakuX's side of route.bat (the phone's side: hakux.sh): its package, its
rem test APK, what a backup holds and the checks after one, the first
rem queue.txt. route.bat calls it with a hook's name: init, installed,
rem after_backup, after_restore, reinstalled, queue_default (it sees
rem route.bat's variables: ADB, PKG, BK, Q, HERE).
goto %1

:init
set "PKG=com.rfandango.haku_x.debug"
rem The test APK: a build of claude/eager-franklin-417v0b (release
rem build-claude-eager-franklin-417v0b-<n>), with this runner's native side
rem (NC_PAD_STATE: the replay waits for the savestate's load; debug.hakux.opts).
rem Not optimized-test-v4's builds: they lack it. Build 22 and later: signed with the
rem repository's debug key (certificate SHA-256 2C3E189E...), each installs over the last.
set "APK_URL=https://github.com/Userx86x32/hakuX86x32/releases/download/build-claude-eager-franklin-417v0b-22/hakuX-debug-claude-eager-franklin-417v0b-22-7d7a275-sd865up.apk"
rem the backup: savestates, GPU driver, settings, save games, and each game's mods on or
rem off (files/mod_choices.json, the 60 fps mod) when the app has written it
set "BKNAME=hakux-backup"
set "BACKUP_WHAT=savestates, settings, mod choices, GPU driver and save games"
set "BACKUP_PATHS=files/native/states files/gpu_driver shared_prefs files/native/hdd/Partition1 files/native/hdd/Partition2 files/mod_choices.json"
set "PREFLIGHT_WHAT=the replay waits for the savestate; NC_IRQ_SCHED=1 in debug.hakux.env2"
exit /b 0

:installed
echo installed. Start Fable once by hand so hakuX remembers it, then: route auto
exit /b 0

:reinstalled
echo Open hakuX, pick your games folder again if it asks, start Fable once, then: route auto
exit /b 0

rem the backup holds the savestates, and the mod choices when the phone has them
:after_backup
tar -tf "%BK%" 2>nul | findstr /c:"files/native/states/" >nul || (echo backup failed: no savestates in %BK% & exit /b 1)
"%ADB%" exec-out run-as %PKG% ls files/mod_choices.json 2>nul | findstr /x /c:"files/mod_choices.json" >nul && (
  tar -tf "%BK%" 2>nul | findstr /x /c:"files/mod_choices.json" >nul || (echo backup failed: the mod choices ^(files/mod_choices.json^) aren't in %BK% & exit /b 1)
  echo backup: the mod choices are in it
)
exit /b 0

rem the savestates are back, and the mod choices as they were backed up (a reinstall once lost the 60 fps mod)
:after_restore
"%ADB%" shell "run-as %PKG% sh -c 'ls files/native/states/*/'" | findstr /i hxs >nul && (echo restored: savestates are back) || (echo restore: no savestates on the phone after it & exit /b 1)
tar -tf "%BK%" 2>nul | findstr /x /c:"files/mod_choices.json" >nul || (echo restore: no mod choices in the backup: check the game's Mods in hakuX ^(the 60 fps mod on^) & exit /b 0)
tar -xOf "%BK%" files/mod_choices.json > "%HERE%mod_choices.backup" 2>nul
"%ADB%" exec-out run-as %PKG% cat files/mod_choices.json > "%HERE%mod_choices.phone" 2>nul
fc /b "%HERE%mod_choices.backup" "%HERE%mod_choices.phone" >nul || (echo restore failed: the mod choices on the phone aren't the backup's & exit /b 1)
findstr /c:"60fps" "%HERE%mod_choices.phone" >nul && (echo restored: mod choices, the 60 fps mod on) || (echo restored: mod choices, but the 60 fps mod is off in them: turn it on in hakuX ^(Fable, Mods^))
del "%HERE%mod_choices.backup" "%HERE%mod_choices.phone"
exit /b 0

rem queue.txt the first time: the suite's batches in the order docs/diag-suite.md gives
:queue_default
> "%Q%" echo # route queue: one route command a line, run in order by "route queue".
>> "%Q%" echo # Lines starting with # are skipped. Finished lines go to queue.done.
>> "%Q%" echo # The charging test (V7) needs you to unplug the phone, so it isn't here.
rem Lookout Point (slot 3, a recorded route) and Great Wood: three scenes
rem don't fit in 30 minutes. vcpucore=0 set in every run.
>> "%Q%" echo suite scenes=lookout:3,wood:2 base:vcpucore=0 nogate:vcpucore=0,env=HAKUX_HLE_PB_VISGATE=0
>> "%Q%" echo suite scenes=lookout:3 base1:vcpucore=0 base2:vcpucore=0
>> "%Q%" echo # not run yet (v4): remove the # to run them
>> "%Q%" echo #suite spin200:pbspin=200 spin0:pbspin=0
>> "%Q%" echo #suite x4:vcpucore=1 all:vcpucore=0
>> "%Q%" echo #suite base1 base2
>> "%Q%" echo #suite spin200:pbspin=200 spin50:pbspin=50
exit /b 0
