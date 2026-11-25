#!/bin/sh
# Host test of tools/diag/route.sh: adb's side of the phone mocked (props,
# pidof, logcat, run-as), with a fake game whose savestate load starts a new
# process that records or replays as hakuX logs it.
#   sh tests/diag/route_test.sh
set -e
ROOT=$(cd "$(dirname "$0")/../.." && pwd)
M=$(mktemp -d)
trap 'kill $(cat "$M"/bg 2>/dev/null) 2>/dev/null; rm -rf "$M"' EXIT
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
exec tail -n 0 -F "$M/logcat" 2>/dev/null
X
cat > "$M/bin/run-as" <<'X'
#!/bin/sh
shift
for a; do set -- "$@" "$(echo "$a" | sed "s|/data/data|$M/data|g")"; shift; done
exec "$@"
X
for c in settings svc dumpsys perfetto; do printf '#!/bin/sh\nexit 0\n' > "$M/bin/$c"; done
chmod +x "$M"/bin/*
export PATH="$M/bin:$PATH" HAKUX_OUT="$M/out" HAKUX_TMP="$M" HAKUX_TRACE=0 HAKUX_COOL=0
echo 'NC_TRACE_X=1' > "$M/props/debug.hakux.env"

fail=0
check() { if eval "$1"; then echo "ok   $1"; else echo "FAIL $1"; fail=1; fi; }

echo "== record (the game started 2 s in)"
(sleep 2; echo 1000 > "$M/pid") & echo $! >> "$M/bg"
sh "$ROOT/tools/diag/route.sh" record bower > "$M/record.log" 2>&1 || { cat "$M/record.log"; exit 1; }
cat "$M/record.log"
check '[ "$(grep -vc "^#" "$M/out/bower.txt")" = 3 ]'
check 'grep -q "setprop debug.hakux.env=NC_PAD_RECORD=/data/data/com.rfandango.haku_x.debug/files/r/bower.txt" "$M/setprops"'
check '[ "$(cat "$M/props/debug.hakux.env")" = NC_TRACE_X=1 ]'      # put back
check '[ -z "$(cat "$M/props/debug.hakux.state")" ]'

echo "== run: 3 runs over 2 variants"
: > "$M/setprops"
sh "$ROOT/tools/diag/route.sh" run bower 3 x4:vcpucore=1 all:vcpucore=0,debug.hakux.adpf=0 > "$M/run.log" 2>&1 ||
  { cat "$M/run.log"; exit 1; }
cat "$M/run.log"
B=$(ls -d "$M"/out/bower-2*)
check '[ "$(ls "$B" | grep -c "^0[123]-")" = 3 ]'
check '[ -d "$B/01-x4" ] && [ -d "$B/02-all" ] && [ -d "$B/03-x4" ]'
check 'grep -q "debug.hakux.adpf=0" "$B/02-all/run.txt"'
check 'grep -q "setprop debug.hakux.env=NC_PAD_SCRIPT=@/data/data/com.rfandango.haku_x.debug/files/r/bower.txt" "$M/setprops"'
check '[ "$(grep -c "^0" "$B/summary.csv")" = 3 ]'
check 'grep -q "^01-x4,x4,3.0,90,30.0,1," "$B/summary.csv"'
check 'grep -q "vCPU starved # ms" "$B/report.txt"'
check '[ "$(cat "$M/props/debug.hakux.env")" = NC_TRACE_X=1 ]'
exit $fail
