#!/system/bin/sh
# hakuX route automation: record a route from a savestate once, then replay
# it over and over with the switches you want to compare, collecting
# hakuX's stutter log, clocks/caps/temperatures and a perfetto trace of
# each run. Runs on the phone (adb shell); route.bat drives it from the PC.
#
#   sh route.sh record <name>
#       Start Fable when asked; the script loads savestate slot 1 and
#       records your controller until you open hakuX's menu (or press Home).
#   sh route.sh run <name> [runs] [variant ...]
#       Start Fable once when asked; then each run loads slot 1 and replays
#       the route. A variant is label:prop=value,prop=value (debug.hakux.
#       may be left out of prop), e.g. x4:vcpucore=1 all:vcpucore=0; runs
#       cycle through the variants (default: one, "default", as set now).
#   sh route.sh report <batch dir>
#
# Output: /sdcard/hakux_diag/routes/<name>.txt (the route) and
# /sdcard/hakux_diag/routes/<name>-<time>/<run>/ (logcat.txt, sensors.csv,
# trace.pftrace, run.txt), report.txt and summary.csv beside the runs.
# Settings: HAKUX_SLOT (1), HAKUX_COOL (seconds between runs, 45),
# HAKUX_TRACE (0: no perfetto trace).
PKG=com.rfandango.haku_x.debug
SLOT=${HAKUX_SLOT:-1}
COOL=${HAKUX_COOL:-45}
TRACE=${HAKUX_TRACE:-1}
APPDIR=/data/data/$PKG/files/r          # the app's own files (run-as: a debug build)
OUT=${HAKUX_OUT:-/sdcard/hakux_diag/routes}
TMPD=${HAKUX_TMP:-/data/local/tmp}      # (overrides for the host test, tests/diag)
HERE=$(cd "$(dirname "$0")" && pwd)
TAGS="hakuX-hle-hitch:V hakuX-native:V hakuX-native-mods:V hakuX-app:V hakuX-native-usb:V
  hakuX-hle-pipe:V hakuX-hle:V hakuX-hle-prof:V hakuX-apu:V hakuX-native-watch:V hakuX-native-perf:V"

say() { echo "[route] $*"; }
die() { echo "[route] error: $*" >&2; restore; exit 1; }

# ---- the switches: saved first, put back at the end ----
SAVED_PROPS="debug.hakux.env debug.hakux.env2 debug.hakux.vcpucore debug.hakux.adpf"
save_props() {
  : > $TMPD/hakux_route_props
  for p in $SAVED_PROPS; do echo "$p=$(getprop $p)" >> $TMPD/hakux_route_props; done
  STAYON=$(settings get global stay_on_while_plugged_in 2>/dev/null)
  svc power stayon usb 2>/dev/null     # the screen stays on while plugged in (put back after)
}
restore() {
  [ -f $TMPD/hakux_route_props ] || return 0
  while IFS== read -r p v; do setprop "$p" "$v"; done < $TMPD/hakux_route_props
  setprop debug.hakux.state ''          # not put back: a new value would load a state
  rm -f $TMPD/hakux_route_props
  [ -n "$STAYON" ] && settings put global stay_on_while_plugged_in "$STAYON" 2>/dev/null
  stop_capture
}
trap 'say "stopped"; restore; exit 130' INT TERM

check_name() {
  case "$1" in
    ''|*[!A-Za-z0-9_-]*) die "a route's name is letters, digits, - and _ (got '$1')";;
  esac
  # debug.hakux.env holds 91 characters: NC_PAD_SCRIPT=@ + the path
  [ ${#1} -le 20 ] || die "route name too long (20 characters at most)"
}

native_pid() { pidof $PKG:native 2>/dev/null; }

# ---- the game: started by the user, then savestate loads by property ----
wait_game() {
  if [ -z "$(native_pid)" ]; then
    say ">>> Start Fable in hakuX now (from the game list; don't load a state)."
    say "    Waiting for the game..."
    while [ -z "$(native_pid)" ]; do sleep 2; done
  fi
  say "game running (pid $(native_pid))"
}

# Loads the slot: the core starts again in a new process (that's how a load
# works), so a new pid is the sign. The request is a new property value each
# time; the app ignores it until the game can take savestates, so retry.
load_slot() {
  old=$(native_pid)
  [ -n "$old" ] || die "the game isn't running"
  for try in 1 2 3 4 5 6 7 8 9 10 11 12; do
    setprop debug.hakux.state ''
    sleep 1
    setprop debug.hakux.state "load:$SLOT"
    w=0
    while [ $w -lt 15 ]; do
      sleep 1; w=$((w + 1))
      now=$(native_pid)
      if [ -n "$now" ] && [ "$now" != "$old" ]; then
        say "slot $SLOT loading (pid $now)"
        return 0
      fi
    done
    [ -n "$(native_pid)" ] || die "the game closed"
    say "slot $SLOT not loaded yet (try $try; the game may still be booting)"
  done
  die "savestate slot $SLOT didn't load (is there a state in slot $SLOT?)"
}

# Waits for a pattern in a file; 1 on timeout (seconds) or when the game closes.
wait_log() {
  wl_file=$1 wl_pat=$2 wl_secs=$3 wl_i=0
  while [ $wl_i -lt "$wl_secs" ]; do
    grep -q "$wl_pat" "$wl_file" 2>/dev/null && return 0
    [ -n "$(native_pid)" ] || { sleep 2; grep -q "$wl_pat" "$wl_file" 2>/dev/null && return 0; return 1; }
    sleep 1; wl_i=$((wl_i + 1))
  done
  return 1
}

# ---- capture: logcat, sensors (as session.sh), perfetto ----
PIDS=""
start_capture() {
  cap_dir=$1
  # shellcheck disable=SC2086
  logcat -v time -T "$(date '+%m-%d %H:%M:%S').000" -s $TAGS > "$cap_dir/logcat.txt" 2>&1 &
  PIDS="$PIDS $!"
  sh -c '
    rd() { v=$(cat "$1" 2>/dev/null); echo "${v:-NA}"; }
    K=/sys/class/kgsl/kgsl-3d0; C=/sys/devices/system/cpu/cpufreq; T=/sys/class/thermal
    echo "time,gpu_mhz,gpu_busy_pct,gpu_temp,cpu0_khz,cpu2_khz,cpu5_khz,cpu7_khz,gpuss_max_mC,battery_dC,thermal_status,gpu_max_mhz,cpu2_max_khz,cpu5_max_khz,cpu7_max_khz,cpu0_max_khz"
    while true; do
      g=0; for z in 32 33 34 35 36 37 38 39; do t=$(cat $T/thermal_zone$z/temp 2>/dev/null); [ -n "$t" ] && [ "$t" -gt "$g" ] && g=$t; done
      s=$(dumpsys thermalservice 2>/dev/null | grep -m1 "Thermal Status" | tr -dc 0-9)
      echo "$(date +%H:%M:%S),$(rd $K/clock_mhz),$(rd $K/gpu_busy_percentage),$(rd $K/temp),$(rd $C/policy0/scaling_cur_freq),$(rd $C/policy2/scaling_cur_freq),$(rd $C/policy5/scaling_cur_freq),$(rd $C/policy7/scaling_cur_freq),$g,$(rd /sys/class/power_supply/battery/temp),${s:-NA},$(rd $K/max_clock_mhz),$(rd $C/policy2/scaling_max_freq),$(rd $C/policy5/scaling_max_freq),$(rd $C/policy7/scaling_max_freq),$(rd $C/policy0/scaling_max_freq)"
      sleep 2
    done' > "$cap_dir/sensors.csv" 2>&1 &
  PIDS="$PIDS $!"
  if [ "$TRACE" = 1 ]; then
    TRACE_FILE=${HAKUX_TRACE_FILE:-/data/misc/perfetto-traces/hakux-route.pftrace}
    rm -f "$TRACE_FILE"
    perfetto --txt -c - -o "$TRACE_FILE" < "$HERE/route_trace.pbtx" > "$cap_dir/perfetto.txt" 2>&1 &
    TRACE_PID=$!
  fi
}
stop_capture() {
  if [ -n "$TRACE_PID" ]; then
    kill -INT "$TRACE_PID" 2>/dev/null       # perfetto writes the trace out and ends
    k=0; while kill -0 "$TRACE_PID" 2>/dev/null && [ $k -lt 20 ]; do sleep 1; k=$((k + 1)); done
    [ -n "$RUN_DIR" ] && cp "$TRACE_FILE" "$RUN_DIR/trace.pftrace" 2>/dev/null
    TRACE_PID=""
  fi
  for p in $PIDS; do kill "$p" 2>/dev/null; done
  PIDS=""
}

# ---- variants ----
set_variant() {   # label:prop=value,prop=value
  props=${1#*:}
  [ "$props" = "$1" ] && return 0
  echo "$props" | tr ',' '\n' | while IFS== read -r p v; do
    [ -z "$p" ] && continue
    case "$p" in debug.*) ;; *) p=debug.hakux.$p;; esac
    setprop "$p" "$v"
    echo "$p=$v"
  done
}

# ---- commands ----
cmd_record() {
  name=$1; check_name "$name"
  mkdir -p "$OUT" || die "can't write $OUT"
  run-as $PKG mkdir -p "$APPDIR" || die "run-as $PKG failed (a debug build is needed)"
  save_props
  setprop debug.hakux.env "NC_PAD_RECORD=$APPDIR/$name.txt"
  setprop debug.hakux.env2 "NC_PAD_STATE=1"
  wait_game
  RUN_DIR=$OUT/$name-record; mkdir -p "$RUN_DIR"
  TRACE=0
  start_capture "$RUN_DIR"
  load_slot
  say ">>> Play the route now with the controller: recording starts at your first"
  say "    input. When you're done, open hakuX's menu (or press Home): that ends it."
  wait_log "$RUN_DIR/logcat.txt" "pad record: to" 3600 ||
    die "the recording didn't start (logcat: $RUN_DIR/logcat.txt)"
  say "recording..."
  while ! grep -q "pad record: .* steps to frame" "$RUN_DIR/logcat.txt"; do
    [ -n "$(native_pid)" ] || break
    sleep 1
  done
  sleep 1
  stop_capture
  run-as $PKG cat "$APPDIR/$name.txt" > "$OUT/$name.txt" || die "couldn't copy the route out"
  setprop debug.hakux.env ''        # stop recording on the next start
  steps=$(grep -vc '^#' "$OUT/$name.txt")
  last=$(tail -n 1 "$OUT/$name.txt")
  say "recorded $steps steps to $OUT/$name.txt (last: $last)"
  restore
}

cmd_run() {
  name=$1; check_name "$name"; runs=${2:-3}
  if [ $# -ge 2 ]; then shift 2; else shift $#; fi
  case "$runs" in ''|*[!0-9]*) die "runs is a number (got '$runs')";; esac
  [ $# -gt 0 ] || set -- default
  [ -f "$OUT/$name.txt" ] || die "no route $OUT/$name.txt (record it first)"
  mkdir -p "$OUT" || die "can't write $OUT"
  run-as $PKG mkdir -p "$APPDIR" || die "run-as $PKG failed (a debug build is needed)"
  run-as $PKG sh -c "cat > $APPDIR/$name.txt" < "$OUT/$name.txt" || die "couldn't copy the route in"
  save_props
  setprop debug.hakux.env "NC_PAD_SCRIPT=@$APPDIR/$name.txt"
  setprop debug.hakux.env2 "NC_PAD_STATE=1"
  BATCH=$OUT/$name-$(date +%Y%m%d-%H%M%S); mkdir -p "$BATCH"
  {
    echo "route=$name"; echo "runs=$runs"; echo "variants=$*"
    getprop ro.product.model; getprop ro.build.fingerprint
    echo "low_power=$(settings get global low_power 2>/dev/null)"
    dumpsys power 2>/dev/null | grep -i -E "mLowPowerModeEnabled|mBatterySaverEnabled|mIsPowered"
    echo "caps (scaling_max_freq):"; cat /sys/devices/system/cpu/cpufreq/policy*/scaling_max_freq
  } > "$BATCH/batch.txt"
  wait_game
  run=1
  while [ $run -le "$runs" ]; do
    for v in "$@"; do
      [ $run -le "$runs" ] || break
      label=${v%%:*}
      RUN_DIR=$BATCH/$(printf '%02d' $run)-$label; mkdir -p "$RUN_DIR"
      { echo "variant=$label"; set_variant "$v"; echo "start=$(date)"
        echo "battery_dC=$(cat /sys/class/power_supply/battery/temp 2>/dev/null)"; } > "$RUN_DIR/run.txt"
      say "run $run/$runs: $label"
      start_capture "$RUN_DIR"
      load_slot
      if wait_log "$RUN_DIR/logcat.txt" "pad script: started" 120; then
        say "replaying..."
        wait_log "$RUN_DIR/logcat.txt" "pad script: done" 1800 || say "run $run: the replay didn't finish"
        sleep 3
      else
        say "run $run: the replay didn't start (see $RUN_DIR/logcat.txt)"
      fi
      stop_capture
      [ -n "$(native_pid)" ] || die "the game closed; $run of $runs runs done (in $BATCH)"
      run=$((run + 1))
      if [ $run -le "$runs" ] && [ "$COOL" -gt 0 ]; then
        say "cooling down ${COOL} s"
        setprop debug.hakux.state ''
        sleep "$COOL"
      fi
    done
  done
  restore
  say "batch done: $BATCH"
  sh "$HERE/route_report.sh" "$BATCH"
}

case "$1" in
  record) shift; cmd_record "$@";;
  run) shift; cmd_run "$@";;
  report) shift; sh "$HERE/route_report.sh" "$@";;
  *) sed -n '2,22p' "$0" | sed 's/^# \{0,1\}//'; exit 2;;
esac
