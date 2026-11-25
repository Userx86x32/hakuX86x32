#!/bin/sh
# Host test of tools/diag/route.sh: adb's side of the phone mocked (props,
# pidof, logcat, run-as), with a fake game whose savestate load starts a new
# process that records or replays as hakuX logs it.
#   sh tests/diag/route_test.sh
set -e
ROOT=$(cd "$(dirname "$0")/../.." && pwd)
M=$(mktemp -d)
trap 'kill $(cat "$M"/bg 2>/dev/null) 2>/dev/null || true; rm -rf "$M"; exit $fail' EXIT
mkdir -p "$M/bin" "$M/props" "$M/data" "$M/out"
: > "$M/logcat"
export M

cat > "$M/bin/getprop" <<'X'
#!/bin/sh
cat "$M/props/$1" 2>/dev/null || true
X
cat > "$M/bin/setprop" <<'X'
#!/bin/sh
printf '%s' "$2" > "$M/props/$1"
echo "setprop $1=$2" >> "$M/setprops"
log() { echo "11-25 $(date +%H:%M:%S).000 I/$1(  42): $2" >> "$M/logcat"; }
if [ "$1" = debug.hakux.state ] && [ "${2%%:*}" = save ] && [ -f "$M/pid" ]; then
  (sleep 1; echo state > "$M/data/com.rfandango.haku_x.debug/files/native/states/4D5300D1.1/slot${2#save:}.hxs") &
  echo $! >> "$M/bg"
fi
if [ "$1" = debug.hakux.state ] && [ "${2%%:*}" = load ] && [ -f "$M/pid" ]; then
  # the first request comes too early (the game still booting): ignored
  [ -f "$M/booted" ] || { touch "$M/booted"; exit 0; }
  (
    sleep 1; echo $(( $(cat "$M/pid") + 1 )) > "$M/pid"
    env=$(cat "$M/props/debug.hakux.env")
    sleep 1
    case "$env" in
    NC_PAD_SCRIPT=@*)
      log hakuX-native-usb "pad script: 3 steps, the last ending at frame 90 (waits for a savestate's load)"
      log hakuX-native-usb "pad script: started (frame 0)"
      log hakuX-hle-hitch "stutter #1 frame 40: 120.0 ms (expected 33.3): vCPU starved 80 ms | x"
      sleep 1
      log hakuX-native-usb "pad script: done (frame 90, 3000 ms)";;
    NC_PAD_RECORD=*)
      f=$M/data${env#NC_PAD_RECORD=/data/data}
      log hakuX-native-usb "pad record: to ${env#NC_PAD_RECORD=} from frame 3"
      printf '# hakuX pad recording\n10f:a:5f\n20f:ly=20480:60f\n80f:start:10f\n' > "$f"
      sleep 1
      log hakuX-native-usb "pad record: 3 steps to frame 90";;
    esac
  ) &
  echo $! >> "$M/bg"
fi
X
cat > "$M/bin/pidof" <<'X'
#!/bin/sh
cat "$M/pid" 2>/dev/null
X
cat > "$M/bin/logcat" <<'X'
#!/bin/sh
echo "$*" > "$M/logcat_args"
exec tail -n 0 -F "$M/logcat" 2>/dev/null
X
cat > "$M/bin/run-as" <<'X'
#!/bin/sh
cd "$M/data/$1" 2>/dev/null
shift
for a; do set -- "$@" "$(echo "$a" | sed "s|/data/data|$M/data|g")"; shift; done
exec "$@"
X
cat > "$M/bin/am" <<'X'
#!/bin/sh
echo "am $*" >> "$M/am"
(sleep 1; echo 2000 > "$M/pid") &
X
mkdir -p "$M/data/com.rfandango.haku_x.debug/shared_prefs"
printf '<map>\n  <string name="dvdUri">content://x/tree/ROMs%%2FFable%%20(USA).iso?a=1&amp;b=2</string>\n</map>\n' \
  > "$M/data/com.rfandango.haku_x.debug/shared_prefs/x1box_prefs.xml"
# perfetto and simpleperf: their output files, as asked (-o)
cat > "$M/bin/perfetto" <<'X'
#!/bin/sh
cat > /dev/null; while [ $# -gt 0 ]; do [ "$1" = -o ] && echo trace > "$2"; shift; done
X
cat > "$M/bin/simpleperf" <<'X'
#!/bin/sh
echo "simpleperf $*" >> "$M/simpleperf"
[ "$1" = report ] && { echo "report: $*"; exit 0; }
while [ $# -gt 0 ]; do [ "$1" = -o ] && echo data > "$2"; shift; done
X
A=$M/data/com.rfandango.haku_x.debug
mkdir -p "$A/files/native/states/4D5300D1.1" "$A/files/native/hle"
echo state > "$A/files/native/states/4D5300D1.1/slot1.hxs"      # slot 1 only: wood (slot 2) skipped
printf 'patch\tdefault.xbe\t60fps\t0x3F776: 83 -> 84\npatchoff\tdefault.xbe\t40fps\t0x3F881: CC -> 8B\ncheat\t0\t0\tx\n' \
  > "$A/files/native/mods.txt"
for c in settings svc dumpsys input wm; do printf '#!/bin/sh\nexit 0\n' > "$M/bin/$c"; done
chmod +x "$M"/bin/*
cat > "$M/route.cfg" <<'X'
RUNS=2
ROUTE_SECS=10
PROBE_SECS=2
COOL_MAX=0
X
export PATH="$M/bin:$PATH" HAKUX_OUT="$M/out" HAKUX_TMP="$M" HAKUX_CFG="$M/route.cfg" HAKUX_TRACE_FILE="$M/trace.pftrace"
# a batch cut off earlier left its replay in debug.hakux.env: kept out of
# what the runner puts back (else every savestate load replays the route)
printf 'NC_TRACE_X=1;NC_PAD_SCRIPT=@/old/route.txt' > "$M/props/debug.hakux.env"
printf 'NC_PAD_STATE=1' > "$M/props/debug.hakux.env2"

fail=0
check() { if eval "$1"; then echo "ok   $1"; else echo "FAIL $1"; fail=1; fi; }

echo "== record (the runner starts the game: am start)"
sh "$ROOT/tools/diag/route.sh" record bower > "$M/record.log" 2>&1 || { cat "$M/record.log"; exit 1; }
cat "$M/record.log"
check '[ "$(grep -vc "^#" "$M/out/bower.txt")" = 3 ]'
check 'grep -q "setprop debug.hakux.env=NC_PAD_RECORD=/data/data/com.rfandango.haku_x.debug/files/r/bower.txt" "$M/setprops"'
check '[ "$(cat "$M/props/debug.hakux.env")" = NC_TRACE_X=1 ]'      # put back, without the old replay
check '[ -z "$(cat "$M/props/debug.hakux.env2")" ]'
check '[ -z "$(cat "$M/props/debug.hakux.state")" ]'

echo "== tour, then run: 3 runs over 2 variants, the game started by the runner"
: > "$M/setprops"; rm -f "$M/pid" "$M/booted"
sh "$ROOT/tools/diag/route.sh" tour bower 2
check '[ "$(grep -c "f:ly=32767:" "$M/out/bower.txt")" = "$(grep -c "f:ly=-32767:" "$M/out/bower.txt")" ]'
check '[ "$(grep -c "f:ly=-32767:" "$M/out/bower.txt")" -ge 4 ]'
check '! grep -q "a\|b\|start" "$(sed 1d "$M/out/bower.txt" > "$M/t"; echo "$M/t")"'

sh "$ROOT/tools/diag/route.sh" run bower 3 x4:vcpucore=1 all:vcpucore=0,debug.hakux.adpf=0 > "$M/run.log" 2>&1 ||
  { cat "$M/run.log"; exit 1; }
cat "$M/run.log"
B=$(ls -d "$M"/out/bower-2*)
check 'grep -q "am start -a android.intent.action.VIEW -d content://x/tree/ROMs%2FFable%20(USA).iso?a=1&b=2 -n com.rfandango.haku_x.debug/com.rfandango.haku_x.LauncherActivity" "$M/am"'
check '[ -d "$B/01-bower-x4" ] && [ -d "$B/02-bower-all" ] && [ -d "$B/03-bower-x4" ] && [ -d "$B/04-bower-probe-perfetto" ]'
check '[ -s "$B/04-bower-probe-perfetto/trace.pftrace" ]'
check 'grep -q "debug.hakux.adpf=0" "$B/02-bower-all/run.txt"'
check '[ "$(grep -c "setprop debug.hakux.watch=0x862494" "$M/setprops")" = 4 ]'
check 'grep -q "^debug.hakux.watch=0x862494" "$B/03-bower-x4/run.txt"'
check 'grep -q "hakuX-native-vbl:V" "$M/logcat_args" && grep -q "hakuX-native-watch:V" "$M/logcat_args"'
check 'grep -q "setprop debug.hakux.env=NC_PAD_SCRIPT=@/data/data/com.rfandango.haku_x.debug/files/r/bower.txt" "$M/setprops"'
check '[ "$(grep -c "^0.*,measure," "$B/summary.csv")" = 3 ] && grep -q "^04-bower-probe-perfetto,.*,perfetto," "$B/summary.csv"'
check 'grep -q "^01-bower-x4,bower/x4,3.0,90,30.0,1," "$B/summary.csv"'
check 'grep -q "vCPU starved # ms" "$B/report.txt" && grep -q "^Probe runs" "$B/report.txt"'
check '[ "$(grep -c "^bower/x4 " "$B/report.txt")" -ge 1 ] && ! grep -q "^bower/x4/probe" "$B/report.txt"'
check '[ "$(cat "$M/props/debug.hakux.env")" = NC_TRACE_X=1 ]'
check '[ -z "$(cat "$M/props/debug.hakux.adpf")" ] && [ -z "$(cat "$M/props/debug.hakux.vcpucore")" ]'

echo "== suite: a mod and core options (A) against the app's settings (B); wood has no savestate"
: > "$M/setprops"; rm -f "$M/pid" "$M/booted"; : > "$M/logcat"
: > "$M/out/bower.txt"           # an empty route left by an old runner: made again
sh "$ROOT/tools/diag/route.sh" suite m40:mod=40fps,scale=3 base > "$M/suite.log" 2>&1 || { cat "$M/suite.log"; exit 1; }
cat "$M/suite.log"
check 'grep -q "route bower: .* has no steps, making a new one" "$M/suite.log" && [ "$(grep -c "^[0-9]" "$M/out/bower.txt")" -ge 3 ]'
B=$(ls -d "$M"/out/suite-2* | head -n 1)
check '[ -d "$B/01-bower-m40" ] && [ -d "$B/02-bower-base" ] && [ -d "$B/03-bower-probe-perfetto" ] && [ ! -d "$B/04-wood-m40" ]'
check 'grep -q "skipped_scene=wood" "$B/batch.txt" && grep -q "scene wood: no savestate in slot 2" "$M/suite.log"'
check 'grep -q "^setprop debug.hakux.opts=mods=/data/data/com.rfandango.haku_x.debug/files/r/mods-40fps.txt scale=3$" "$M/setprops"'
check 'grep -q "^debug.hakux.opts=$" "$B/02-bower-base/run.txt"'
check 'grep -q "^patch	default.xbe	40fps	" "$A/files/r/mods-40fps.txt" && grep -q "^patchoff	default.xbe	60fps	" "$A/files/r/mods-40fps.txt"'
check 'grep -q "^refresh	120$" "$A/files/r/mods-40fps.txt" && grep -q "^cheat	" "$A/files/r/mods-40fps.txt"'
check '[ -z "$(cat "$M/props/debug.hakux.opts")" ]'

echo "== suite: a cold start with hints off (A) against the default (B); the probe swaps to simpleperf"
: > "$M/setprops"; rm -f "$M/pid" "$M/booted"; : > "$M/logcat"
echo old > "$A/files/native/hle/cache.bin"
sh "$ROOT/tools/diag/route.sh" suite cold:cold=1,adpf=0 base > "$M/suite2.log" 2>&1 || { cat "$M/suite2.log"; exit 1; }
B=$(ls -d "$M"/out/suite-2* | tail -n 1)
check '[ ! -e "$A/files/native/hle/cache.bin" ] && grep -q "caches cleared" "$B/01-bower-cold/run.txt"'
check 'awk "/setprop debug.hakux.adpf=0/ { s = 1 } s && /setprop debug.hakux.adpf=\$/ { r = 1 } END { exit !r }" "$M/setprops"'
check '[ -s "$B/03-bower-probe-simpleperf/perf.data" ] && grep -q "^report: report" "$B/03-bower-probe-simpleperf/simpleperf_symbols.txt"'
check 'grep -q "record --app com.rfandango.haku_x.debug" "$M/simpleperf"'

echo "== save and clean (from the PC: route save 2, route clean)"
sh "$ROOT/tools/diag/route.sh" save 2 > "$M/save.log" 2>&1; cat "$M/save.log"
check '[ -f "$A/files/native/states/4D5300D1.1/slot2.hxs" ] && grep -q "saved to slot 2" "$M/save.log"'
check '[ -z "$(cat "$M/props/debug.hakux.state")" ]'
rm -f "$A/files/native/states/4D5300D1.1/slot2.hxs"
setprop debug.hakux.opts scale=3; setprop debug.hakux.env "NC_TRACE_Y=2;NC_PAD_SCRIPT=@x"; setprop debug.hakux.env2 NC_PAD_STATE=1
sh "$ROOT/tools/diag/route.sh" clean
check '[ -z "$(cat "$M/props/debug.hakux.opts")" ] && [ "$(cat "$M/props/debug.hakux.env")" = NC_TRACE_Y=2 ] && [ -z "$(cat "$M/props/debug.hakux.env2")" ]'

echo "== detached: start auto, then watch"
rm -f "$M/pid" "$M/booted"; : > "$M/logcat"
sh "$ROOT/tools/diag/route.sh" start auto
sh "$ROOT/tools/diag/route.sh" watch > "$M/watch.log" 2>&1
tail -n 4 "$M/watch.log"
check 'grep -q "batch done" "$M/watch.log"'
check '[ "$(ls -d "$M"/out/auto-2*/0* | wc -l)" = 3 ]'
check 'grep -q "^\[route\] finished" "$M/watch.log"'
check '[ "$(sh "$ROOT/tools/diag/route.sh" status)" = "done|auto|" ]'
echo "stop: not finished" > "$M/out/console.txt"
check '[ "$(sh "$ROOT/tools/diag/route.sh" status)" = "stopped|auto|" ]'
exit $fail' EXIT
mkdir -p "$M/bin" "$M/props" "$M/data" "$M/out"
: > "$M/logcat"
export M

cat > "$M/bin/getprop" <<'X'
#!/bin/sh
cat "$M/props/$1" 2>/dev/null || true
X
cat > "$M/bin/setprop" <<'X'
#!/bin/sh
printf '%s' "$2" > "$M/props/$1"
echo "setprop $1=$2" >> "$M/setprops"
log() { echo "11-25 $(date +%H:%M:%S).000 I/$1(  42): $2" >> "$M/logcat"; }
if [ "$1" = debug.hakux.state ] && [ "${2%%:*}" = load ] && [ -f "$M/pid" ]; then
  # the first request comes too early (the game still booting): ignored
  [ -f "$M/booted" ] || { touch "$M/booted"; exit 0; }
  (
    sleep 1; echo $(( $(cat "$M/pid") + 1 )) > "$M/pid"
    env=$(cat "$M/props/debug.hakux.env")
    sleep 1
    case "$env" in
    NC_PAD_SCRIPT=@*)
      log hakuX-native-usb "pad script: 3 steps, the last ending at frame 90 (waits for a savestate's load)"
      log hakuX-native-usb "pad script: started (frame 0)"
      log hakuX-hle-hitch "stutter #1 frame 40: 120.0 ms (expected 33.3): vCPU starved 80 ms | x"
      sleep 1
      log hakuX-native-usb "pad script: done (frame 90, 3000 ms)";;
    NC_PAD_RECORD=*)
      f=$M/data${env#NC_PAD_RECORD=/data/data}
      log hakuX-native-usb "pad record: to ${env#NC_PAD_RECORD=} from frame 3"
      printf '# hakuX pad recording\n10f:a:5f\n20f:ly=20480:60f\n80f:start:10f\n' > "$f"
      sleep 1
      log hakuX-native-usb "pad record: 3 steps to frame 90";;
    esac
  ) &
  echo $! >> "$M/bg"
fi
X
cat > "$M/bin/pidof" <<'X'
#!/bin/sh
cat "$M/pid" 2>/dev/null
X
cat > "$M/bin/logcat" <<'X'
#!/bin/sh
echo "$*" > "$M/logcat_args"
exec tail -n 0 -F "$M/logcat" 2>/dev/null
X
cat > "$M/bin/run-as" <<'X'
#!/bin/sh
cd "$M/data/$1" 2>/dev/null
shift
for a; do set -- "$@" "$(echo "$a" | sed "s|/data/data|$M/data|g")"; shift; done
exec "$@"
X
cat > "$M/bin/am" <<'X'
#!/bin/sh
echo "am $*" >> "$M/am"
(sleep 1; echo 2000 > "$M/pid") &
X
mkdir -p "$M/data/com.rfandango.haku_x.debug/shared_prefs"
printf '<map>\n  <string name="dvdUri">content://x/tree/ROMs%%2FFable%%20(USA).iso?a=1&amp;b=2</string>\n</map>\n' \
  > "$M/data/com.rfandango.haku_x.debug/shared_prefs/x1box_prefs.xml"
# perfetto and simpleperf: their output files, as asked (-o)
cat > "$M/bin/perfetto" <<'X'
#!/bin/sh
cat > /dev/null; while [ $# -gt 0 ]; do [ "$1" = -o ] && echo trace > "$2"; shift; done
X
cat > "$M/bin/simpleperf" <<'X'
#!/bin/sh
echo "simpleperf $*" >> "$M/simpleperf"
[ "$1" = report ] && { echo "report: $*"; exit 0; }
while [ $# -gt 0 ]; do [ "$1" = -o ] && echo data > "$2"; shift; done
X
A=$M/data/com.rfandango.haku_x.debug
mkdir -p "$A/files/native/states/4D5300D1.1" "$A/files/native/hle"
echo state > "$A/files/native/states/4D5300D1.1/slot1.hxs"      # slot 1 only: wood (slot 2) skipped
printf 'patch\tdefault.xbe\t60fps\t0x3F776: 83 -> 84\npatchoff\tdefault.xbe\t40fps\t0x3F881: CC -> 8B\ncheat\t0\t0\tx\n' \
  > "$A/files/native/mods.txt"
for c in settings svc dumpsys input wm; do printf '#!/bin/sh\nexit 0\n' > "$M/bin/$c"; done
chmod +x "$M"/bin/*
cat > "$M/route.cfg" <<'X'
RUNS=2
ROUTE_SECS=10
PROBE_SECS=2
COOL_MAX=0
X
export PATH="$M/bin:$PATH" HAKUX_OUT="$M/out" HAKUX_TMP="$M" HAKUX_CFG="$M/route.cfg" HAKUX_TRACE_FILE="$M/trace.pftrace"
# a batch cut off earlier left its replay in debug.hakux.env: kept out of
# what the runner puts back (else every savestate load replays the route)
printf 'NC_TRACE_X=1;NC_PAD_SCRIPT=@/old/route.txt' > "$M/props/debug.hakux.env"
printf 'NC_PAD_STATE=1' > "$M/props/debug.hakux.env2"

fail=0
check() { if eval "$1"; then echo "ok   $1"; else echo "FAIL $1"; fail=1; fi; }

echo "== record (the runner starts the game: am start)"
sh "$ROOT/tools/diag/route.sh" record bower > "$M/record.log" 2>&1 || { cat "$M/record.log"; exit 1; }
cat "$M/record.log"
check '[ "$(grep -vc "^#" "$M/out/bower.txt")" = 3 ]'
check 'grep -q "setprop debug.hakux.env=NC_PAD_RECORD=/data/data/com.rfandango.haku_x.debug/files/r/bower.txt" "$M/setprops"'
check '[ "$(cat "$M/props/debug.hakux.env")" = NC_TRACE_X=1 ]'      # put back, without the old replay
check '[ -z "$(cat "$M/props/debug.hakux.env2")" ]'
check '[ -z "$(cat "$M/props/debug.hakux.state")" ]'

echo "== tour, then run: 3 runs over 2 variants, the game started by the runner"
: > "$M/setprops"; rm -f "$M/pid" "$M/booted"
sh "$ROOT/tools/diag/route.sh" tour bower 2
check '[ "$(grep -c "f:ly=32767:" "$M/out/bower.txt")" = "$(grep -c "f:ly=-32767:" "$M/out/bower.txt")" ]'
check '[ "$(grep -c "f:ly=-32767:" "$M/out/bower.txt")" -ge 4 ]'
check '! grep -q "a\|b\|start" "$(sed 1d "$M/out/bower.txt" > "$M/t"; echo "$M/t")"'

sh "$ROOT/tools/diag/route.sh" run bower 3 x4:vcpucore=1 all:vcpucore=0,debug.hakux.adpf=0 > "$M/run.log" 2>&1 ||
  { cat "$M/run.log"; exit 1; }
cat "$M/run.log"
B=$(ls -d "$M"/out/bower-2*)
check 'grep -q "am start -a android.intent.action.VIEW -d content://x/tree/ROMs%2FFable%20(USA).iso?a=1&b=2 -n com.rfandango.haku_x.debug/com.rfandango.haku_x.LauncherActivity" "$M/am"'
check '[ "$(ls "$B" | grep -c "^0[123]-")" = 3 ]'
check '[ -d "$B/01-x4" ] && [ -d "$B/02-all" ] && [ -d "$B/03-x4" ]'
check 'grep -q "debug.hakux.adpf=0" "$B/02-all/run.txt"'
check '[ "$(grep -c "setprop debug.hakux.watch=0x862494" "$M/setprops")" = 3 ]'
check 'grep -q "^debug.hakux.watch=0x862494" "$B/03-x4/run.txt"'
check 'grep -q "present_interval_changes" "$B/summary.csv"'
check 'grep -q "hakuX-native-vbl:V" "$M/logcat_args" && grep -q "hakuX-native-watch:V" "$M/logcat_args"'
check 'grep -q "setprop debug.hakux.env=NC_PAD_SCRIPT=@/data/data/com.rfandango.haku_x.debug/files/r/bower.txt" "$M/setprops"'
check '[ "$(grep -c "^0" "$B/summary.csv")" = 3 ]'
check 'grep -q "^01-x4,x4,3.0,90,30.0,1," "$B/summary.csv"'
check 'grep -q "vCPU starved # ms" "$B/report.txt"'
check '[ "$(cat "$M/props/debug.hakux.env")" = NC_TRACE_X=1 ]'
echo "== detached: start auto 2, then watch"
rm -f "$M/pid" "$M/booted"; : > "$M/logcat"
sh "$ROOT/tools/diag/route.sh" start auto 2
sh "$ROOT/tools/diag/route.sh" watch > "$M/watch.log" 2>&1
tail -n 4 "$M/watch.log"
check 'grep -q "batch done" "$M/watch.log"'
check '[ "$(ls -d "$M"/out/auto-2*/0* | wc -l)" = 2 ]'
check 'grep -q "^\[route\] finished" "$M/watch.log"'
check '[ "$(sh "$ROOT/tools/diag/route.sh" status)" = "done|auto|" ]'
echo "stop: not finished" > "$M/out/console.txt"
check '[ "$(sh "$ROOT/tools/diag/route.sh" status)" = "stopped|auto|" ]'
exit $fail
