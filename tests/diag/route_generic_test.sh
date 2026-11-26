#!/bin/sh
# Host test of tools/diag/route.sh with the generic adapter (any app, no
# hooks): adb's side of the phone mocked (props, pidof, am, cmd, logcat,
# dumpsys SurfaceFlinger, a /proc of the app's threads), with a fake app
# that am start starts, whose layer SurfaceFlinger presents at 60 fps with a
# gap now and then, and whose threads run while it does. It isn't
# debuggable: run-as fails.
#   sh tests/diag/route_generic_test.sh
set -e
ROOT=$(cd "$(dirname "$0")/../.." && pwd)
M=${ROUTE_TEST_DIR:-$(mktemp -d)}     # (ROUTE_TEST_DIR: kept afterwards)
trap '[ -n "$ROUTE_TEST_DIR" ] || rm -rf "$M"; exit $fail' EXIT
mkdir -p "$M/bin" "$M/props" "$M/out" "$M/proc"
: > "$M/logcat"; echo 3000 > "$M/nextpid"
export M
PKG=com.example.game

cat > "$M/bin/getprop" <<'X'
#!/bin/sh
cat "$M/props/$1" 2>/dev/null || true
X
cat > "$M/bin/setprop" <<'X'
#!/bin/sh
printf '%s' "$2" > "$M/props/$1"
echo "setprop $1=$2" >> "$M/setprops"
X
cat > "$M/bin/pidof" <<'X'
#!/bin/sh
[ "$1" = com.example.game ] && cat "$M/pid" 2>/dev/null
exit 0
X
cat > "$M/bin/logcat" <<'X'
#!/bin/sh
echo "$*" > "$M/logcat_args"
exec tail -n 0 -F "$M/logcat" 2>/dev/null
X
# am start: a new process (its threads in $M/proc); force-stop: gone.
# ($M/crash: the process dies 3 s after its start)
cat > "$M/bin/am" <<'X'
#!/bin/sh
echo "am $*" >> "$M/am"
case "$1" in
  force-stop) [ -f "$M/pid" ] && rm -rf "$M/proc/$(cat "$M/pid")"; rm -f "$M/pid";;
  start)
    p=$(cat "$M/nextpid"); echo $((p + 10)) > "$M/nextpid"
    for t in "$p:example.game" "$((p + 1)):RenderThread" "$((p + 2)):UnityMain" "$((p + 3)):UnityGfxDeviceW" "$((p + 4)):Binder:${p}_1"; do
      d=$M/proc/$p/task/${t%%:*}; mkdir -p "$d"
      echo "${t#*:}" > "$d/comm"
      echo "1000000000 50000000 100" > "$d/schedstat"
      echo "${t%%:*} (${t#*:}) S $(seq 4 52 | tr '\n' ' ')" > "$d/stat"
    done
    echo "$p" > "$M/pid"
    echo "$(date '+%m-%d %H:%M:%S').000 I/ActivityManager(  999): Start proc $p:com.example.game/u0a1 for top-activity" >> "$M/logcat"
    if [ -f "$M/crash" ]; then (sleep 3; rm -f "$M/pid") > /dev/null 2>&1 & fi;;
esac
X
cat > "$M/bin/cmd" <<'X'
#!/bin/sh
[ "$1 $2" = "package resolve-activity" ] || exit 0
printf 'priority=0 preferredOrder=0 match=0x108000 specificIndex=-1 isDefault=true\ncom.example.game/com.example.game.MainActivity\n'
X
# SurfaceFlinger: the app's SurfaceView while it runs; --latency: its last
# 127 frames, 16.7 ms apart (a 50 ms gap every 60 frames) up to now, on a
# monotonic clock (ns since the test began). Each call also runs the app's
# threads a little (schedstat: run, wait).
cat > "$M/bin/dumpsys" <<'X'
#!/bin/sh
case "$1 $2" in
  "SurfaceFlinger --list")
    [ -f "$M/pid" ] && echo "RequestedLayerState{3f2a1b0 SurfaceView[com.example.game/com.example.game.MainActivity]@0(BLAST)#$(cat "$M/pid") parentId=12 z=0}"
    echo "RequestedLayerState{aa01 com.android.systemui.wallpapers.ImageWallpaper#5 parentId=1}";;
  "SurfaceFlinger --latency")
    [ -f "$M/pid" ] || exit 0
    for f in "$M"/proc/$(cat "$M/pid")/task/*/schedstat; do
      read -r r w s < "$f"; echo "$((r + 300000000)) $((w + 20000000)) $((s + 1))" > "$f"
    done
    now=$(( $(date +%s%N) - $(cat "$M/t0") ))
    echo 16666666
    awk -v now="$now" 'BEGIN { p = 16666667; last = int(now / p)
      for (f = last - 126; f <= last; f++) { t = f * p + int(f / 60) * 33333333; printf "%.0f\t%.0f\t%.0f\n", t - 4000000, t, t - 1000000 } }';;
  "package com.example.game") echo "    versionName=2.1.0";;
esac
exit 0
X
cat > "$M/bin/run-as" <<'X'
#!/bin/sh
echo "run-as: package not debuggable: $1" >&2
exit 1
X
cat > "$M/bin/perfetto" <<'X'
#!/bin/sh
cat > "$M/perfetto_cfg"; while [ $# -gt 0 ]; do [ "$1" = -o ] && echo trace > "$2"; shift; done
X
cat > "$M/bin/simpleperf" <<'X'
#!/bin/sh
echo "simpleperf: package com.example.game is not debuggable"; exit 1
X
echo apk-bytes > "$M/base.apk"
printf '#!/bin/sh\n[ "$2" = com.example.game ] && echo "package:%s/base.apk"\nexit 0\n' "$M" > "$M/bin/pm"
for c in settings svc input wm; do printf '#!/bin/sh\nexit 0\n' > "$M/bin/$c"; done
chmod +x "$M"/bin/*
date +%s%N > "$M/t0"
cat > "$M/route.cfg" <<'X'
ADAPTER=generic
APP_PKG=com.example.game
RUNS=2
APP_WAIT=1
APP_SECS=6
PROBE_SECS=2
COOL_MAX=0
X
export PATH="$M/bin:$PATH" HAKUX_OUT="$M/out" HAKUX_TMP="$M" HAKUX_CFG="$M/route.cfg" HAKUX_TRACE_FILE="$M/trace.pftrace" HAKUX_PROC="$M/proc"
R=$ROOT/tools/diag/route.sh

fail=0
check() { if eval "$1"; then echo "ok   $1"; else echo "FAIL $1"; fail=1; fi; }

echo "== suite: two labels (the noise) and a property; each run starts the app, waits, measures"
setprop debug.example.fast old
: > "$M/setprops"
sh "$R" suite base fast:debug.example.fast=1 > "$M/suite.log" 2>&1 || { cat "$M/suite.log"; exit 1; }
cat "$M/suite.log"
B=$(ls -d "$M"/out/suite-2* | head -n 1)
check '[ -d "$B/01-app-base" ] && [ -d "$B/02-app-fast" ] && [ -d "$B/03-app-probe-perfetto" ]'
check '[ "$(grep -c "^am force-stop com.example.game" "$M/am")" = 3 ] && [ "$(grep -c "^am start -n com.example.game/com.example.game.MainActivity" "$M/am")" = 3 ]'
check 'grep -q "^adapter=generic$" "$B/batch.txt" && grep -q "^package=com.example.game$" "$B/batch.txt" && grep -q "^app_secs=6$" "$B/batch.txt"'
check 'grep -q "versionName=2.1.0" "$B/batch.txt" && grep -q "^  apk_sha256=[0-9a-f]\{64\}$" "$B/batch.txt"'
check 'grep -q "ActivityManager:I" "$M/logcat_args" && ! grep -q hakuX "$M/logcat_args"'
check 'grep -q "Start proc .*com.example.game" "$B/01-app-base/logcat.txt"'
check 'grep -q "^pid=[0-9]" "$B/01-app-base/run.txt" && grep -q "^window_start=" "$B/01-app-base/run.txt" && grep -q "^window_end=" "$B/01-app-base/run.txt"'
check '! grep -q "^inputs=" "$B/01-app-base/run.txt" && ! grep -q "^failed=" "$B"/0*/run.txt'
# the property: set for B alone, put back after
check 'grep -q "^debug.example.fast=1$" "$B/02-app-fast/run.txt" && ! grep -q "^debug.example.fast" "$B/01-app-base/run.txt"'
check '[ "$(getprop debug.example.fast)" = old ] && grep -q "put back: debug.example.fast=.old." "$M/suite.log"'
# the probe: the trace config's app is this one; no hakuX probe
check '[ -s "$B/03-app-probe-perfetto/trace.pftrace" ] && grep -q "atrace_apps: \"com.example.game\"" "$M/perfetto_cfg"'
# the threads read straight from /proc (run-as fails: not debuggable)
check '[ -s "$B/01-app-base/schedstat_start.txt" ] && grep -q " UnityMain$" "$B/01-app-base/schedstat_end.txt"'
check 'grep -q "^## [0-9:]* SurfaceView\[com.example.game/com.example.game.MainActivity\]@0(BLAST)#[0-9]*$" "$B/01-app-base/sflatency.txt"'
# summary.csv: the core's columns, numbers from SurfaceFlinger and /proc
check 'head -n 1 "$B/summary.csv" | grep -q "^run,variant,kind,secs,frames,fps,stutters,per_min,worst_ms,start_gpuss_C,.*,main_run_ms,main_wait_ms,render_run_ms,render_wait_ms,sf_frames,sf_gaps,sf_worst_gap_ms,sf_median_ms,sf_source$"'
check '[ "$(grep -c ",measure," "$B/summary.csv")" = 2 ] && grep -q "^03-app-probe-perfetto,app/base/probe-perfetto,perfetto," "$B/summary.csv"'
row=$(grep "^01-app-base," "$B/summary.csv")
idx() { head -n 1 "$B/summary.csv" | tr ',' '\n' | grep -nx "$1" | cut -d: -f1; }
val() { echo "$row" | cut -d, -f"$(idx "$1")"; }
check '[ "$(val sf_source)" = latency ] && [ "$(val sf_median_ms)" = 16.7 ] && [ "$(val sf_worst_gap_ms)" = 50.0 ]'
check 'awk "BEGIN { exit !($(val secs) >= 5.5 && $(val secs) <= 8) }"'
check 'awk "BEGIN { exit !($(val fps) >= 50 && $(val fps) <= 62) }" && [ "$(val stutters)" -ge 1 ] && [ "$(val frames)" -ge 250 ]'
check '[ "$(val main_run_ms)" -ge 300 ] && [ "$(val render_run_ms)" -ge 300 ] && [ "$(val main_wait_ms)" -ge 20 ]'
# report.txt: the core's sections, the busiest threads by name
check 'grep -q "^route report (com.example.game, generic adapter): " "$B/report.txt" && grep -q "^app/base  *1 " "$B/report.txt"'
check 'grep -q "^Display " "$B/report.txt" && grep -q "^Busiest threads" "$B/report.txt" && grep -q " UnityGfxDeviceW " "$B/report.txt"'
check 'grep -q "^Threads " "$B/report.txt" && grep -A1 "^variant  *start C  *main  *wait  *render  *wait" "$B/report.txt" | grep -q "@main *RenderThr"'
check '! grep -q "Vblanks\|Late interrupts\|Decoder" "$B/report.txt" && grep -A1 "^Failed runs" "$B/report.txt" | grep -q "^  none$"'
check 'grep -q "03-app-probe-perfetto/trace.pftrace" "$B/report.txt"'

echo "== auto, detached: base1 base2 (the noise)"
sh "$R" start auto
sh "$R" watch > "$M/watch.log" 2>&1
check 'grep -q "batch done" "$M/watch.log" && [ "$(sh "$R" status)" = "done|auto|" ]'
B=$(ls -d "$M"/out/auto-2*)
check '[ -d "$B/01-app-base1" ] && [ -d "$B/02-app-base2" ] && [ -d "$B/03-app-probe-simpleperf" ]'      # (the probes alternate)
# simpleperf --app: this app isn't debuggable, the probe's failure kept
check 'grep -q "^probe_exit=1$" "$B/03-app-probe-simpleperf/run.txt" && grep -q "not debuggable" "$B/03-app-probe-simpleperf/simpleperf.txt"'

echo "== a variant the generic adapter can't set, its commands, no APP_PKG: nothing starts"
n=$(ls -d "$M"/out/suite-2* | wc -l)
sh "$R" suite base m60:mod=60fps > "$M/bad.log" 2>&1 && echo "(it started)"
check 'grep -q "error: variant m60:mod=60fps: mod isn.t something the generic adapter can set" "$M/bad.log" && [ "$(ls -d "$M"/out/suite-2* | wc -l)" = "$n" ]'
sh "$R" save 2 > "$M/save.log" 2>&1 && echo "(it saved)"
check 'grep -q "error: save: the generic adapter has no savestates" "$M/save.log"'
HAKUX_ADAPTER=generic APP_PKG= HAKUX_CFG=/nonexistent sh "$R" suite base > "$M/nopkg.log" 2>&1 && echo "(it started)"
check 'grep -q "error: the generic adapter measures one app: APP_PKG=" "$M/nopkg.log"'
sh "$R" > "$M/usage.log" 2>&1 || true
check 'grep -q "^The generic adapter (adapters/generic.sh):" "$M/usage.log" && grep -q "APP_SECS" "$M/usage.log"'

echo "== preflight: the app starts, its layer and threads are there"
pre=0; sh "$R" preflight > "$M/pre.log" 2>&1 || pre=$?
cat "$M/pre.log"
check '[ $pre = 0 ] && grep -q "ok: com.example.game started" "$M/pre.log" && grep -q "ok: SurfaceFlinger.s layer: SurfaceView\[com.example.game/" "$M/pre.log"'
check 'grep -q "ok: its threads. schedstat (5 threads)" "$M/pre.log" && grep -q "^preflight=ok" "$M/out/preflight/run.txt"'

echo "== an app that crashes in the window: its runs fail, the second stops the batch"
touch "$M/crash"
sh "$R" suite runs=4 base > "$M/crash.log" 2>&1 && echo "(it didn't stop)"
rm -f "$M/crash" "$M/out/.suite_state"
cat "$M/crash.log"
B=$(ls -d "$M"/out/suite-2* | tail -n 1)
check 'grep -q "^failed=the app.s process (pid [0-9]*) didn.t last the window" "$B/01-app-base/run.txt"'
check 'grep -q "error: variant base failed its check twice" "$M/crash.log" && [ ! -d "$B/03-app-base" ]'
