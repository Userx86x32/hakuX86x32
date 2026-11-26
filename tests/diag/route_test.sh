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
    # the new process: the app's options from debug.hakux.opts, and the mods
    # on in its choices (stale_mods: an app that ignores them, 60fps on)
    for o in $(cat "$M/props/debug.hakux.opts" 2>/dev/null); do log hakuX-app "debug.hakux.opts: $o"; done
    for e in $(cat "$M/props/debug.hakux.env" "$M/props/debug.hakux.env2" 2>/dev/null | tr ';' ' '); do
      log hakuX-app "debug.hakux.env: $e"
    done
    # the decoder: its spin logged when it isn't the 200 us default
    sp=$(cat "$M/props/debug.hakux.pbspin" 2>/dev/null)
    [ -n "$sp" ] && [ "$sp" != 200 ] && log hakuX-hle-pb "decoder spin before sleeping: $sp us (debug.hakux.pbspin)"
    if [ -f "$M/stale_mods" ]; then on=60fps; else
      on=$(tr -d '\\' < "$M/data/com.rfandango.haku_x.debug/files/mod_choices.json" 2>/dev/null |
        grep -o '"4D5300D1.1/mod/[^"]*":true' | sed 's|"4D5300D1.1/mod/||; s|".*||')
    fi
    for m in $on; do log hakuX-native-mods "$m: [default.xbe] 0003f776: 10 bytes"; done
    log hakuX-native-mods "0 files over the disc; 1 cheats (1 on), 0 code lines (0 bad)"
    sleep 1
    case "$env" in
    NC_PAD_SCRIPT=@*)
      # (old_apk: a build without NC_PAD_STATE, which doesn't wait)
      w=" (waits for a savestate's load)"; [ -f "$M/old_apk" ] && w=
      log hakuX-native-usb "pad script: 3 steps, the last ending at frame 90$w"
      log hakuX-native-usb "pad script: started (frame 0)"
      log hakuX-native-irq "line 3 delivered 12.5 ms after it rose: 2 refusals, first IRQL at or above it (IRQL 26, ISR line -1, thread t4); the guest CPU's thread ran 3.0 ms of it, waited for a host CPU 9.0 ms"
      log hakuX-hle-pb "kicks 1000 words 50000 headers 1 methods 2 faults 0 GET 0 PUT 0 binds 1 semaphores 2 flips 100 traps 0 (x)"
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
# the installed APK (pm path), and the app's mod choices as org.json writes them ("/" as "\/")
echo apk-bytes > "$M/base.apk"
printf '#!/bin/sh\necho "package:%s/base.apk"\n' "$M" > "$M/bin/pm"
CHOICES='{"4D5300D1.1\/mod\/60fps":true,"4D5300D1.1\/cheat\/x":true,"OTHER.1\/mod\/40fps":true}'
printf '%s' "$CHOICES" > "$A/files/mod_choices.json"
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
sh "$ROOT/tools/diag/route.sh" apkrecord hakuX-debug-claude-vibrant-cerf-lmdbik-15-abc1234-sd865up.apk
: > "$M/setprops"; rm -f "$M/pid" "$M/booted"; : > "$M/logcat"
: > "$M/out/bower.txt"           # an empty route left by an old runner: made again
sh "$ROOT/tools/diag/route.sh" suite m40:mod=40fps,scale=3 base > "$M/suite.log" 2>&1 || { cat "$M/suite.log"; exit 1; }
cat "$M/suite.log"
check 'grep -q "route bower: .* has no steps, making a new one" "$M/suite.log" && [ "$(grep -c "^[0-9]" "$M/out/bower.txt")" -ge 3 ]'
B=$(ls -d "$M"/out/suite-2* | head -n 1)
check '[ -d "$B/01-bower-m40" ] && [ -d "$B/02-bower-base" ] && [ -d "$B/03-bower-probe-perfetto" ] && [ ! -d "$B/04-wood-m40" ]'
check 'grep -q "skipped_scene=wood" "$B/batch.txt" && grep -q "scene wood: no savestate in slot 2" "$M/suite.log"'
check 'grep -q "^setprop debug.hakux.opts=scale=3$" "$M/setprops"'
check 'grep -q "^debug.hakux.opts=$" "$B/02-bower-base/run.txt"'
# the mod through the app's choices: 40fps only for A, the choices as they were for B
check 'grep -q "^mods_expected=40fps$" "$B/01-bower-m40/run.txt" && grep -q "^mods_applied=40fps$" "$B/01-bower-m40/run.txt"'
check 'grep -q "^mods_expected=60fps$" "$B/02-bower-base/run.txt" && grep -q "^mods_applied=60fps$" "$B/02-bower-base/run.txt"'
check '! grep -q "^failed=" "$B"/0*/run.txt && grep -A1 "^Failed runs" "$B/report.txt" | grep -q "^  none$"'
check '[ "$(grep "^01-bower-m40," "$B/summary.csv" | cut -d, -f47)" = 40fps ] && [ "$(grep "^02-bower-base," "$B/summary.csv" | cut -d, -f47)" = 60fps ]'
check '[ "$(cat "$A/files/mod_choices.json")" = "$CHOICES" ]'      # put back as it was
check '[ -z "$(cat "$M/props/debug.hakux.opts")" ]'
# the probe: its exit status in run.txt; no empty console file
check 'grep -q "^probe_exit=0$" "$B/03-bower-probe-perfetto/run.txt" && [ ! -e "$B/03-bower-probe-perfetto/perfetto.txt" ]'
# the build: the APK route install recorded
check 'grep -q "^  apk_build=15$" "$B/batch.txt" && grep -q "^  apk_commit=abc1234$" "$B/batch.txt" && grep -q "^  apk_branch=claude-vibrant-cerf-lmdbik$" "$B/batch.txt"'
check 'grep -q "^  apk_file=hakuX-debug-claude-vibrant-cerf-lmdbik-15-abc1234-sd865up.apk$" "$B/batch.txt" && grep -q "^  apk_sha256=[0-9a-f]\{64\}$" "$B/batch.txt"'

echo "== suite: an app that ignores its mod choices: 40fps fails, and failing twice stops the batch"
: > "$M/setprops"; rm -f "$M/pid" "$M/booted"; : > "$M/logcat"; touch "$M/stale_mods"
flip=$(cat "$M/out/.probe_flip")       # (the probe order of the batches after it kept)
sh "$ROOT/tools/diag/route.sh" suite m40:mod=40fps base > "$M/stale.log" 2>&1 && echo "(it didn't stop)"
rm -f "$M/stale_mods" "$M/out/.suite_state"; echo "$flip" > "$M/out/.probe_flip"
B=$(ls -d "$M"/out/suite-2* | tail -n 1)
check 'grep -q "^failed=mods: the variant.s are .40fps., the core applied .60fps." "$B/01-bower-m40/run.txt"'
check 'grep -q "run 1 FAILED" "$M/stale.log" && grep -q "error: variant m40 failed its check twice" "$M/stale.log"'
check '[ "$(cat "$A/files/mod_choices.json")" = "$CHOICES" ]'        # put back by the error's restore
sh "$ROOT/tools/diag/route.sh" report "$B" > /dev/null 2>&1
check '! grep -q "^01-bower-m40," "$B/summary.csv" && [ "$(grep "^02-bower-base," "$B/summary.csv" | cut -d, -f47)" = 60fps ]'
check 'grep -A3 "^Failed runs" "$B/report.txt" | grep -q "01-bower-m40 .*mods:"'

echo "== suite: the decoder's spin, 200 us against 0 (v4); NC_IRQ_SCHED in every run"
: > "$M/setprops"; rm -f "$M/pid" "$M/booted"; : > "$M/logcat"
flip=$(cat "$M/out/.probe_flip")
sh "$ROOT/tools/diag/route.sh" suite spin200:pbspin=200 spin0:pbspin=0 > "$M/spin.log" 2>&1 || { cat "$M/spin.log"; exit 1; }
echo "$flip" > "$M/out/.probe_flip"
B=$(ls -d "$M"/out/suite-2* | tail -n 1)
check 'grep -q "^pbspin_applied=200$" "$B/01-bower-spin200/run.txt" && grep -q "^pbspin_applied=0$" "$B/02-bower-spin0/run.txt"'
check '! grep -q "^failed=" "$B"/0*/run.txt'
check '[ "$(grep -c "^setprop debug.hakux.env2=NC_PAD_STATE=1;NC_IRQ_SCHED=1$" "$M/setprops")" -ge 3 ]'
check 'grep -q "hakuX-native-irq:V" "$M/logcat_args" && grep -q "hakuX-hle-pb:V" "$M/logcat_args"'
check 'grep -q "^02-bower-spin0,.*,0,1,0,0,1,0,12.5,12.5,3.0,3.0,9.0,1,1000,50000,0$" "$B/summary.csv"'
check 'grep -q "^bower/spin0 .* 0 " "$B/report.txt" && grep -q "^Late interrupts" "$B/report.txt"'
check '[ -z "$(cat "$M/props/debug.hakux.pbspin")" ] && [ -z "$(cat "$M/props/debug.hakux.env2")" ]'

echo "== preflight: before a queue, one replay start checked"
rm -f "$M/pid" "$M/booted"; : > "$M/logcat"
pre=0; sh "$ROOT/tools/diag/route.sh" preflight > "$M/pre.log" 2>&1 || pre=$?
cat "$M/pre.log"
check '[ $pre = 0 ] && grep -q "ok: pad script: .*(waits for a savestate.s load)" "$M/pre.log" && grep -q "preflight ok" "$M/pre.log"'
check 'grep -q "ok: debug.hakux.env2=NC_PAD_STATE=1;NC_IRQ_SCHED=1" "$M/pre.log" && grep -q "ok: the game read NC_IRQ_SCHED=1" "$M/pre.log"'
check 'grep -q "apk_branch=claude-vibrant-cerf-lmdbik" "$M/pre.log" && grep -q "^preflight=ok" "$M/out/preflight/run.txt"'
check '[ -z "$(cat "$M/props/debug.hakux.env2")" ] && [ "$(cat "$M/props/debug.hakux.env")" = NC_TRACE_X=1 ]'
echo "== preflight: an APK whose replay doesn't wait for the savestate fails it"
rm -f "$M/pid" "$M/booted"; : > "$M/logcat"; touch "$M/old_apk"
pre=0; sh "$ROOT/tools/diag/route.sh" preflight > "$M/pre2.log" 2>&1 || pre=$?
rm -f "$M/old_apk"
check '[ $pre = 1 ] && grep -q "FAILED: no \"(waits for a savestate.s load)\"" "$M/pre2.log" && grep -q "^preflight=failed" "$M/out/preflight/run.txt"'

echo "== suite: scenes= and an env= variant (the visibility gate off), vcpucore=0 in both; vcpucore put back"
: > "$M/setprops"; rm -f "$M/pid" "$M/booted"; : > "$M/logcat"
setprop debug.hakux.vcpucore 7                 # what it was before the batch
flip=$(cat "$M/out/.probe_flip")
sh "$ROOT/tools/diag/route.sh" suite scenes=bower:1 base:vcpucore=0 nogate:vcpucore=0,env=HAKUX_HLE_PB_VISGATE=0 > "$M/gate.log" 2>&1 ||
  { cat "$M/gate.log"; exit 1; }
echo "$flip" > "$M/out/.probe_flip"
B=$(ls -d "$M"/out/suite-2* | tail -n 1)
check 'grep -q "^scenes=bower:1$" "$B/batch.txt" && grep -q "batch: about .* min (scenes bower:1," "$M/gate.log"'
check 'grep -q "^debug.hakux.env2=NC_PAD_STATE=1;NC_IRQ_SCHED=1;HAKUX_HLE_PB_VISGATE=0$" "$B/02-bower-nogate/run.txt"'
check 'grep -q "^debug.hakux.env2=NC_PAD_STATE=1;NC_IRQ_SCHED=1$" "$B/01-bower-base/run.txt" && grep -q "^debug.hakux.vcpucore=0$" "$B/01-bower-base/run.txt"'
check '! grep -q "^failed=" "$B"/0*/run.txt'
check '[ "$(cat "$M/props/debug.hakux.vcpucore")" = 7 ] && grep -q "put back:.*vcpucore=.7." "$M/gate.log"'

echo "== a batch killed (Auto Blocker) left vcpucore=0: clean, and the next batch, put back what was before"
printf 'debug.hakux.env=NC_TRACE_X=1\ndebug.hakux.env2=\ndebug.hakux.vcpucore=\ndebug.hakux.adpf=\n' > "$M/hakux_route_props"
setprop debug.hakux.vcpucore 0
sh "$ROOT/tools/diag/route.sh" clean > /dev/null 2>&1
check '[ -z "$(cat "$M/props/debug.hakux.vcpucore")" ] && [ ! -f "$M/hakux_route_props" ]'
printf 'debug.hakux.env=NC_TRACE_X=1\ndebug.hakux.env2=\ndebug.hakux.vcpucore=\ndebug.hakux.adpf=\n' > "$M/hakux_route_props"
setprop debug.hakux.vcpucore 0
rm -f "$M/pid" "$M/booted"; : > "$M/logcat"
flip=$(cat "$M/out/.probe_flip")
sh "$ROOT/tools/diag/route.sh" suite scenes=bower:1 runs=1 x4:vcpucore=1 > "$M/killed.log" 2>&1 || { cat "$M/killed.log"; exit 1; }
echo "$flip" > "$M/out/.probe_flip"
check 'grep -q "a cut-off batch.s settings put back first" "$M/killed.log" && [ -z "$(cat "$M/props/debug.hakux.vcpucore")" ]'

echo "== a scene that must be recorded (not in TOUR_SCENES) and has no route: the batch doesn't start"
sh "$ROOT/tools/diag/route.sh" suite scenes=lookout:1 base > "$M/look.log" 2>&1 && echo "(it started)"
check 'grep -q "error: scene lookout: no route recorded .*route record lookout 1" "$M/look.log" && [ ! -f "$M/out/lookout.txt" ]'

echo "== suite: a cold start with hints off (A) against the default (B); the probe swaps to simpleperf"
: > "$M/setprops"; rm -f "$M/pid" "$M/booted"; : > "$M/logcat"
echo old > "$A/files/native/hle/cache.bin"
sh "$ROOT/tools/diag/route.sh" suite cold:cold=1,adpf=0 base > "$M/suite2.log" 2>&1 || { cat "$M/suite2.log"; exit 1; }
B=$(ls -d "$M"/out/suite-2* | tail -n 1)
check '[ ! -e "$A/files/native/hle/cache.bin" ] && grep -q "caches cleared" "$B/01-bower-cold/run.txt"'
check 'awk "/setprop debug.hakux.adpf=0/ { s = 1 } s && /setprop debug.hakux.adpf=\$/ { r = 1 } END { exit !r }" "$M/setprops"'
check '[ -s "$B/03-bower-probe-simpleperf/perf.data" ] && grep -q "^report: report" "$B/03-bower-probe-simpleperf/simpleperf_symbols.txt"'
check 'grep -q "record --app com.rfandango.haku_x.debug" "$M/simpleperf"'

echo "== resume: a suite cut off after its first run goes on in the same batch, the game restarted"
rm -f "$M/pid" "$M/booted"; : > "$M/logcat"
sh "$ROOT/tools/diag/route.sh" start suite r1:adpf=1 base
w=0; until grep -qs "^end=" "$M"/out/suite-2*/01-bower-r1/run.txt 2>/dev/null || [ $w -ge 120 ]; do sleep 1; w=$((w + 1)); done
sh "$ROOT/tools/diag/route.sh" stop; sleep 3
check '[ "$(sh "$ROOT/tools/diag/route.sh" status)" = "stopped|suite r1:adpf=1 base|" ]'
B1=$(ls -d "$M"/out/suite-2* | tail -n 1)
check '[ ! -f "$B1/report.txt" ] && [ -f "$M/out/.suite_state" ]'
rm -f "$M/pid"                                  # the game closed meanwhile
sh "$ROOT/tools/diag/route.sh" suite r1:adpf=1 base > "$M/resume.log" 2>&1 || { cat "$M/resume.log"; exit 1; }
cat "$M/resume.log"
check 'grep -q "resuming $B1" "$M/resume.log" && grep -q "run 1: bower, r1: done before, kept" "$M/resume.log"'
check '[ "$(ls -d "$M"/out/suite-2* | tail -n 1)" = "$B1" ] && [ -f "$B1/report.txt" ] && [ ! -f "$M/out/.suite_state" ]'
check '[ "$(ls -d "$B1"/0* | wc -l)" = 3 ] && grep -q "^end=" "$B1/02-bower-base/run.txt"'
check 'grep -q "settings (from route.cfg): .*COOL_MAX=0" "$M/resume.log"'

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
echo "[route] error: couldn't copy the route into the app (0 of 0 lines)" > "$M/out/console.txt"
check '[ "$(sh "$ROOT/tools/diag/route.sh" status)" = "failed|auto|" ]'
echo "stop: not finished" > "$M/out/console.txt"
check '[ "$(sh "$ROOT/tools/diag/route.sh" status)" = "stopped|auto|" ]'
