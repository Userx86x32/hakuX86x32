#!/system/bin/sh
# hakuX route automation (docs/diag-suite.md): replay a route from a
# savestate over and over with the switches to compare, collecting hakuX's
# stutter and vblank logs, clocks/caps/temperatures, each thread's run-queue
# wait, what the display presented, and on probe runs a Perfetto trace, a
# CPU profile or hakuX's GPU-time profiler. Runs on the phone; route.bat
# drives it from the PC (it pushes this, route_report.sh, route_trace.pbtx
# and route.cfg, starts it detached, follows it, pulls and uploads).
#
#   suite <variant A> [variant B]
#       The 30-minute batch: for each scene (route.cfg SCENES, a route name
#       and its savestate slot: bower:1 wood:2), RUNS measurement runs
#       alternating A and B, then one probe run on A (Perfetto in the first
#       scene and simpleperf in the second, the other way round next batch).
#       A scene whose slot has no savestate is skipped.
#   auto
#       suite x4:vcpucore=1 all:vcpucore=0.
#   run <route> [runs] [variant ...]
#       One scene (slot SLOT): runs measurement runs cycling through the
#       variants, then the probes in PROBES (perfetto simpleperf prof).
#   tour <route> [seconds]
#       A route with no one playing (sticks only), ROUTE_SECS long by default.
#   record <route>
#       A route you play: loads the slot and records your controller until
#       you open hakuX's menu (or press Home).
#   save <slot> / load <slot>
#       A savestate of the running game to that slot, or loaded from it.
#   clean
#       The properties the runner sets, cleared (after a batch was cut off).
#   start <command ...> / watch / stop / status / report <batch dir>
#   apkrecord <apk file name>
#       Notes the APK route.bat just installed (its name, the installed
#       APK's sha256) for batch.txt's build identity.
#
# A variant is label:name=value,name=value. Names:
#   adpf, vcpucore, ... (or debug.anything): a property, set before the run
#   scale=2|3, asyncpipe=0|1, prebuild=0|1: hakuX core options (the app's
#       settings overridden for the run through debug.hakux.opts)
#   driver=system: the phone's own Vulkan driver, not the custom one
#   mod=40fps|60fps|none: only that mod on, the others off, in the app's
#       own mod choices for the game (files/mod_choices.json, read by each
#       new game process; 40fps's mod.txt asks for 120 Hz vblanks itself);
#       the choices are put back at the end, and a variant without mod= in
#       the same batch runs with them as they were. Each run checks the mods
#       the core applied (its hakuX-native-mods lines) and fails otherwise;
#       a variant failing twice stops the batch.
#   cold=1: the shader and pipeline caches cleared before the run
# Each run starts from the variant's settings alone: whatever another
# variant set is put back first.
#
# Output: /sdcard/hakux_diag/routes/<batch>-<time>/<NN>-<scene>-<label>/
# (logcat.txt, sensors.csv, run.txt, schedstat_start.txt, schedstat_end.txt,
# sflatency.txt, sftimestats.txt; probes: trace.pftrace, perf.data,
# simpleperf_*.txt), with
# batch.txt, report.txt and summary.csv beside the runs.
PKG=com.rfandango.haku_x.debug
HERE=$(cd "$(dirname "$0")" && pwd)

# ---- settings (route.cfg beside this script overrides them) ----
SCENES="bower:1 wood:2"     # route:slot, in order
RUNS=6                      # measurement runs per scene (A B A B ...)
ROUTE_SECS=75               # a tour's length
SLOT=1                      # run's slot
PROBES=perfetto             # run's probe runs (perfetto simpleperf prof; "" none)
COOL_C=45                   # cool down until the hottest gpuss zone is under this
COOL_MAX=10                 # ... for at most this many seconds (the game runs on meanwhile, so
                            # waiting barely cools it: 90 s never got 50-58 C under 45 C)
WATCH=0x862494              # debug.hakux.watch: Fable's presentation interval (D3D)
PROBE_SECS=20               # a probe's length, mid-route
CFG=${HAKUX_CFG:-$HERE/route.cfg}
if [ -f "$CFG" ]; then
  tr -d '\r' < "$CFG" > "${HAKUX_TMP:-/data/local/tmp}/hakux_route_cfg" &&
    . "${HAKUX_TMP:-/data/local/tmp}/hakux_route_cfg"
fi
APPDIR=/data/data/$PKG/files/r          # the app's own files (run-as: a debug build)
OUT=${HAKUX_OUT:-/sdcard/hakux_diag/routes}
TMPD=${HAKUX_TMP:-/data/local/tmp}      # (overrides for the host test, tests/diag)
TAGS="hakuX-hle-hitch:V hakuX-native:V hakuX-native-mods:V hakuX-app:V hakuX-native-usb:V
  hakuX-hle-pipe:V hakuX-hle:V hakuX-hle-prof:V hakuX-apu:V hakuX-native-watch:V hakuX-native-perf:V
  hakuX-native-vbl:V"

[ -n "$HAKUX_PIDFILE" ] && echo $$ > "$HAKUX_PIDFILE"   # started detached (route.sh start)
say() { echo "[route] $*"; }
die() { echo "[route] error: $*" >&2; restore; exit 1; }

# ---- the switches: saved first, put back at the end ----
# Properties the runner sets, and those the batch's variants name.
# debug.hakux.env and env2 are put back without any NC_PAD_ entries (the
# replay's and the recording's: a batch cut off before it put them back left
# them set, and the next batch must not keep them as the "normal" value, or
# every savestate load replays the route); the runner's own properties
# (opts, perf, perfsec) are cleared at the end, not put back.
SAVED_PROPS="debug.hakux.env debug.hakux.env2 debug.hakux.vcpucore debug.hakux.adpf"
RUNNER_PROPS="debug.hakux.opts debug.hakux.perf debug.hakux.perfsec"
without_pad() { echo "$1" | tr ';' '\n' | grep -v '^NC_PAD_' | tr '\n' ';' | sed 's/;*$//'; }
save_props() {
  : > $TMPD/hakux_route_props
  for p in $SAVED_PROPS $VARIANT_PROPS; do
    v=$(getprop $p)
    case "$p" in debug.hakux.env|debug.hakux.env2) v=$(without_pad "$v");; esac
    grep -q "^$p=" $TMPD/hakux_route_props || echo "$p=$v" >> $TMPD/hakux_route_props
  done
  for p in $RUNNER_PROPS; do echo "$p=" >> $TMPD/hakux_route_props; done
  STAYON=$(settings get global stay_on_while_plugged_in 2>/dev/null)
  svc power stayon usb 2>&1 | cat > /dev/null   # the screen stays on while plugged in (put back after)
  # the app's mod choices, when a variant changes them (put back after;
  # "-" for a file that wasn't there: the app then reads its old preferences)
  if [ -n "$MOD_BATCH" ] && [ ! -f $TMPD/hakux_route_modchoices ]; then
    run-as $PKG cat files/mod_choices.json > $TMPD/hakux_route_modchoices 2>/dev/null ||
      echo - > $TMPD/hakux_route_modchoices
  fi
}
saved_value() { sed -n "s/^$1=//p" $TMPD/hakux_route_props; }
restore() {
  [ -f $TMPD/hakux_route_props ] || return 0
  while IFS== read -r p v; do setprop "$p" "$v"; done < $TMPD/hakux_route_props
  setprop debug.hakux.state ''          # not put back: a new value would load a state
  rm -f $TMPD/hakux_route_props
  put_back_mod_choices && rm -f $TMPD/hakux_route_modchoices
  [ -n "$STAYON" ] && settings put global stay_on_while_plugged_in "$STAYON" 2>&1 | cat > /dev/null
  stop_capture
}
trap 'say "stopped"; restore; exit 130' INT TERM HUP

check_name() {
  case "$1" in
    ''|*[!A-Za-z0-9_-]*) die "a route's name is letters, digits, - and _ (got '$1')";;
  esac
  # debug.hakux.env holds 91 characters: NC_PAD_SCRIPT=@ + the path
  [ ${#1} -le 20 ] || die "route name too long (20 characters at most)"
}

native_pid() { pidof $PKG:native 2>/dev/null; }

# The hottest gpuss thermal zone (32-39 on the S24+), in whole degrees.
gpuss_c() {
  g=0
  for z in 32 33 34 35 36 37 38 39; do
    t=$(cat /sys/class/thermal/thermal_zone$z/temp 2>/dev/null)
    [ -n "$t" ] && [ "$t" -gt "$g" ] && g=$t
  done
  echo $((g / 1000))
}

# ---- the game: started from hakuX's last game, then savestate loads by property ----

# The disc hakuX ran last (its prefs' dvdUri; run-as: a debug build).
last_game() {
  run-as $PKG cat shared_prefs/x1box_prefs.xml 2>/dev/null |
    sed -n 's|.*<string name="dvdUri">\(.*\)</string>.*|\1|p' |
    sed "s/&quot;/\"/g; s/&apos;/'/g; s/&lt;/</g; s/&gt;/>/g; s/&amp;/\\&/g"
}

start_game() {
  uri=$(last_game)
  [ -n "$uri" ] || return 1
  input keyevent KEYCODE_WAKEUP 2>&1 | cat > /dev/null
  wm dismiss-keyguard 2>&1 | cat > /dev/null    # no-op behind a PIN: unlock the phone first
  say "starting $uri"
  am start -a android.intent.action.VIEW -d "$uri" -n $PKG/com.rfandango.haku_x.LauncherActivity 2>&1 | cat > /dev/null
  w=0
  while [ -z "$(native_pid)" ] && [ $w -lt 30 ]; do sleep 1; w=$((w + 1)); done
  [ -n "$(native_pid)" ]
}

wait_game() {
  if [ -z "$(native_pid)" ] && ! start_game; then
    say ">>> Couldn't start the game by itself (no last game in hakuX, or the phone"
    say "    is locked). Start Fable in hakuX now (don't load a state). Waiting..."
    while [ -z "$(native_pid)" ]; do sleep 2; done
  fi
  say "game running (pid $(native_pid))"
}

# Whether savestate slot $1 holds a state (of the game hakuX runs: any game's folder).
slot_exists() {
  run-as $PKG sh -c "ls files/native/states/*/slot$1.hxs" > /dev/null 2>&1
}

# Loads slot $1: the core starts again in a new process (that's how a load
# works), so a new pid is the sign. The request is a new property value each
# time; the app ignores it until the game can take savestates, so retry.
load_slot() {
  for try in 1 2 3 4 5 6 7 8 9 10 11 12; do
    old=$(native_pid)
    if [ -z "$old" ]; then
      # the game closed (or never started): start it again, then load
      say "the game isn't running: starting it"
      start_game || die "the game couldn't be started (is the phone unlocked?)"
      sleep 20
      old=$(native_pid)
    fi
    setprop debug.hakux.state ''
    sleep 1
    setprop debug.hakux.state "load:$1"
    w=0
    while [ $w -lt 15 ]; do
      sleep 1; w=$((w + 1))
      now=$(native_pid)
      if [ -n "$now" ] && [ "$now" != "$old" ]; then
        say "slot $1 loading (pid $now)"
        return 0
      fi
    done
    say "slot $1 not loaded yet (try $try; the game may still be booting)"
  done
  die "savestate slot $1 didn't load (is there a state in slot $1?)"
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

# The route's length in seconds (its last step's end, at 30 frames a second).
route_secs() {
  awk -F'[:f]' '/^[0-9]+f:/ { e = $1 + $(NF - 1); if (e > m) m = e } END { print int(m / 30) }' "$OUT/$1.txt"
}

# ---- capture: every run ----
PIDS=""
start_capture() {
  cap_dir=$1
  # shellcheck disable=SC2086
  logcat -v time -T "$(date '+%m-%d %H:%M:%S').000" -s $TAGS > "$cap_dir/logcat.txt" 2>&1 &
  PIDS="$PIDS $!"
  # every second: clocks, caps, load, temperatures; the thermal status
  # (dumpsys: heavy) every fifth
  sh -c '
    rd() { v=$(cat "$1" 2>/dev/null); echo "${v:-NA}"; }
    K=/sys/class/kgsl/kgsl-3d0; C=/sys/devices/system/cpu/cpufreq; T=/sys/class/thermal
    echo "time,gpu_mhz,gpu_busy_pct,gpu_temp,cpu0_khz,cpu2_khz,cpu5_khz,cpu7_khz,gpuss_max_mC,battery_dC,thermal_status,gpu_max_mhz,cpu2_max_khz,cpu5_max_khz,cpu7_max_khz,cpu0_max_khz"
    n=0; s=NA
    while true; do
      g=0; for z in 32 33 34 35 36 37 38 39; do t=$(cat $T/thermal_zone$z/temp 2>/dev/null); [ -n "$t" ] && [ "$t" -gt "$g" ] && g=$t; done
      if [ $((n % 5)) = 0 ]; then
        s=$(dumpsys thermalservice 2>/dev/null | grep -m1 "Thermal Status" | tr -dc 0-9); s=${s:-NA}
      fi
      n=$((n + 1))
      echo "$(date +%H:%M:%S),$(rd $K/clock_mhz),$(rd $K/gpu_busy_percentage),$(rd $K/temp),$(rd $C/policy0/scaling_cur_freq),$(rd $C/policy2/scaling_cur_freq),$(rd $C/policy5/scaling_cur_freq),$(rd $C/policy7/scaling_cur_freq),$g,$(rd /sys/class/power_supply/battery/temp),$s,$(rd $K/max_clock_mhz),$(rd $C/policy2/scaling_max_freq),$(rd $C/policy5/scaling_max_freq),$(rd $C/policy7/scaling_max_freq),$(rd $C/policy0/scaling_max_freq)"
      sleep 1
    done' > "$cap_dir/sensors.csv" 2>&1 &
  PIDS="$PIDS $!"
  # every 2 s: the last 127 frames SurfaceFlinger presented of hakuX's
  # SurfaceView (desired, actual present, ready; ns). --latency wants the
  # layer's exact name, its "#<id>" included, and --list wraps it
  # ("RequestedLayerState{47d71ac SurfaceView[...]@0(BLAST)#30759
  # parentId=...}" on Android 14 and later): the name alone, read again each
  # time (each run's new process makes a new layer); the newest (highest
  # id) BLAST one when the old one is still listed
  sh -c '
    while true; do
      l=$(dumpsys SurfaceFlinger --list 2>/dev/null | awk -v pkg="SurfaceView[$0/" "
        i = index(\$0, pkg) {
          n = substr(\$0, i); sub(/[ }].*\$/, \"\", n)
          id = n; if (!sub(/^.*#/, \"\", id) || id !~ /^[0-9]+\$/) id = 0
          b = (n ~ /BLAST/)
          if (best == \"\" || b > bb || (b == bb && id + 0 > bid)) { best = n; bb = b; bid = id + 0 }
        }
        END { print best }")
      echo "## $(date +%H:%M:%S) $l"
      [ -n "$l" ] && dumpsys SurfaceFlinger --latency "$l" 2>/dev/null | cat
      sleep 2
    done' $PKG > "$cap_dir/sflatency.txt" 2>&1 &
  PIDS="$PIDS $!"
  # SurfaceFlinger's own frame statistics from now on (the report's second
  # source for presented frames: present-to-present histogram per layer)
  dumpsys SurfaceFlinger --timestats -disable -clear -enable 2>&1 | cat > /dev/null
}
# The statistics since start_capture, then off again.
dump_timestats() {
  dumpsys SurfaceFlinger --timestats -dump 2>/dev/null | cat > "$1/sftimestats.txt"
  dumpsys SurfaceFlinger --timestats -disable -clear 2>&1 | cat > /dev/null
}
stop_capture() {
  for p in $PIDS; do kill "$p" 2>/dev/null; done
  PIDS=""
}

# Each thread of the game's process: tid, time on a CPU and waiting for one
# (ns), timeslices, the CPU it last ran on, its name. run-as: the app's own
# /proc entries; through a pipe (run-as can't write to shared storage).
snap_threads() {
  p=$(native_pid)
  [ -n "$p" ] || return 0
  run-as $PKG sh -c "cd /proc/$p/task 2>/dev/null && for t in *; do
      s=\$(cat \$t/schedstat 2>/dev/null) || continue
      c=\$(sed 's/^.*) //' \$t/stat 2>/dev/null | cut -d' ' -f37)
      echo \"\$t \$s \${c:-NA} \$(cat \$t/comm 2>/dev/null)\"
    done" 2>/dev/null | cat > "$1"
}

# Charging, as dumpsys battery and the phone's charging settings say.
power_state() {
  dumpsys battery 2>/dev/null | grep -i -E "powered|status:|level:|temperature:" | sed 's/^ */  /'
  settings list system 2>/dev/null | grep -i -E "pass_through|protect_battery|charging" | sed 's/^/  setting: /'
}

# ---- probes: mid-route, PROBE_SECS long ----
# A probe's tool's exit status and output size in run.txt; its console output
# kept as <tool>.txt only when it printed something (a quiet run printed
# nothing, and an empty file said less than run.txt does).
probe_result() {   # status run_dir tool output_file
  { echo "probe_exit=$1"; echo "probe_output_bytes=$(wc -c < "$4" 2>/dev/null | tr -d ' ')"; } >> "$2/run.txt"
  if [ -s "$TMPD/hakux_probe_out" ]; then cp "$TMPD/hakux_probe_out" "$2/$3.txt"; fi
  rm -f "$TMPD/hakux_probe_out"
}
run_probe() {   # kind run_dir
  case "$1" in
  perfetto)
    tf=${HAKUX_TRACE_FILE:-/data/misc/perfetto-traces/hakux-route.pftrace}
    rm -f "$tf"
    sed "s/^duration_ms: .*/duration_ms: $((PROBE_SECS * 1000))/" "$HERE/route_trace.pbtx" |
      perfetto --txt -c - -o "$tf" > "$TMPD/hakux_probe_out" 2>&1
    probe_result $? "$2" perfetto "$tf"
    cp "$tf" "$2/trace.pftrace" 2>/dev/null || say "probe: no Perfetto trace (see run.txt, perfetto.txt)"
    ;;
  simpleperf)
    pd=$TMPD/hakux-perf.data
    rm -f "$pd"
    # --app: a debuggable app's process, profiled through run-as
    simpleperf record --app $PKG -g -f 1000 --duration "$PROBE_SECS" -o "$pd" > "$TMPD/hakux_probe_out" 2>&1
    probe_result $? "$2" simpleperf "$pd"
    if [ -s "$pd" ]; then
      # its sample count (report's header: "Samples: N", "Event count: N")
      simpleperf report -i "$pd" --sort comm 2>/dev/null | grep -m2 -E "^(Samples|Event count):" |
        sed 's/^/probe_/; s/: */=/; s/ /_/' >> "$2/run.txt"
      simpleperf report -i "$pd" --sort dso,symbol --percent-limit 0.5 2>&1 | cat > "$2/simpleperf_symbols.txt"
      simpleperf report -i "$pd" --sort comm,dso --percent-limit 0.5 2>&1 | cat > "$2/simpleperf_threads.txt"
      cp "$pd" "$2/perf.data"
    else
      say "probe: no CPU profile (see run.txt, simpleperf.txt)"
    fi
    ;;
  prof)
    setprop debug.hakux.perfsec "$PROBE_SECS"
    setprop debug.hakux.perf "$(date +%s)"   # a new value starts it (hakuX-hle-prof lines)
    sleep "$PROBE_SECS"
    ;;
  esac
}

# ---- variants ----
# The properties a list of variants names (for saving and putting back).
variant_props() {
  for v in "$@"; do
    case "$v" in *:*) ;; *) continue;; esac       # a label alone: nothing set
    echo "${v#*:}" | tr ',' '\n' | while IFS== read -r p val; do
      case "$p" in
        ''|scale|asyncpipe|prebuild|driver|mod|cold) ;;
        debug.*) echo "$p";;
        *) echo "debug.hakux.$p";;
      esac
    done
  done | sort -u | tr '\n' ' '
}

# ---- mods: the app's own per-game choices ----
# The game key of the savestate in slot $1 (its folder: the app's game key,
# title ID and version, 4D5300D1.1).
slot_game() {
  run-as $PKG sh -c "ls files/native/states/*/slot$1.hxs" 2>/dev/null | head -n 1 |
    sed 's|^.*states/||; s|/slot[0-9]*\.hxs$||'
}

# The app's mod choices as JSON entries ("key":true, one a line, with the
# key unescaped first, then a tab, then the entry as written): the file
# (org.json escapes "/" as "\/"), or if it was never written, the shared
# preferences it replaced (per_game_mods).
mod_choice_entries() {
  { run-as $PKG cat files/mod_choices.json 2>/dev/null ||
      run-as $PKG cat shared_prefs/per_game_mods.xml 2>/dev/null |
        sed -n 's|.*<boolean name="\(.*\)" value="true" */>.*|"\1":true|p'; } |
    awk '{ s = s $0 } END {
      while (match(s, /"([^"\\]|\\.)*"[ \t]*:[ \t]*true/)) {
        e = substr(s, RSTART, RLENGTH); s = substr(s, RSTART + RLENGTH)
        k = e; sub(/"[ \t]*:[ \t]*true$/, "", k); sub(/^"/, "", k); gsub(/\\\//, "/", k)
        print k "\t" e
      }
    }'
}

# The mods on for game $1 in the app's choices (sorted, space-separated).
mods_on() {
  mod_choice_entries | awk -F'\t' -v p="$1/mod/" 'index($1, p) == 1 { print substr($1, length(p) + 1) }' |
    sort | tr '\n' ' ' | sed 's/ $//'
}

# The mods with XBE patches (the app's last manifest lists every mod's).
mods_with_patches() {
  run-as $PKG cat files/native/mods.txt 2>/dev/null | awk -F'\t' '$1 == "patch" || $1 == "patchoff" { print $3 }' | sort -u
}

# Game $1: only mod $2 on (none: every mod off); cheats and other games kept.
# Written whole and renamed into place, as the app writes it.
set_mod_choice() {
  mod_choice_entries | awk -F'\t' -v game="$1" -v id="$2" '
    index($1, game "/mod/") != 1 { out = out (out == "" ? "" : ",") $2 }
    END {
      if (id != "none") out = out (out == "" ? "" : ",") "\"" game "/mod/" id "\":true"
      print "{" out "}"
    }' | run-as $PKG sh -c 'cat > files/mod_choices.json.route && mv files/mod_choices.json.route files/mod_choices.json'
}

# The choices as they were before the batch.
put_back_mod_choices() {
  f=$TMPD/hakux_route_modchoices
  [ -f "$f" ] || return 0
  if [ "$(cat "$f")" = - ]; then
    run-as $PKG rm -f files/mod_choices.json
  else
    cat "$f" | run-as $PKG sh -c 'cat > files/mod_choices.json.route && mv files/mod_choices.json.route files/mod_choices.json'
  fi
}

# Sets one variant up (label:name=value,...) for a run from slot $2: the
# batch's variant properties and mod choices put back first, then this
# one's; prints what it set (for run.txt), and the mods the run must apply
# (mods_expected=, checked against the log once the run starts).
set_variant() {
  for p in $VARIANT_PROPS; do setprop "$p" "$(saved_value "$p")"; done
  [ -n "$MOD_BATCH" ] && put_back_mod_choices
  game=$(slot_game "$2")
  opts=
  for kv in $(echo "${1#*:}" | tr ',' ' '); do
    [ "$kv" = "$1" ] && break
    p=${kv%%=*}; v=${kv#*=}
    case "$p" in
      scale|asyncpipe|prebuild) opts="$opts $p=$v";;
      driver) [ "$v" = system ] && opts="$opts vkdriver=none";;
      mod) [ -n "$game" ] || die "mod $v: no savestate in slot $2 (its folder names the game)"
           [ "$v" = none ] || mods_with_patches | grep -qx "$v" ||
             die "mod $v: not in hakuX's mod list for this game (files/native/mods.txt; run the game once)"
           set_mod_choice "$game" "$v"
           [ "$(mods_on "$game")" = "${v#none}" ] ||
             die "mod $v: the app's mod choices didn't take it (files/mod_choices.json: $(mods_on "$game"))"
           echo "mod_choice=$game: ${v} only";;
      cold) if [ "$v" = 1 ]; then
              run-as $PKG sh -c 'rm -rf files/native/hle/*' && echo "cold: shader and pipeline caches cleared"
            fi;;
      debug.*) setprop "$p" "$v"; echo "$p=$v";;
      *) setprop "debug.hakux.$p" "$v"; echo "debug.hakux.$p=$v";;
    esac
  done
  opts=${opts# }
  [ ${#opts} -le 91 ] || die "variant $1: its options are too long for debug.hakux.opts (91 characters)"
  setprop debug.hakux.opts "$opts"
  echo "debug.hakux.opts=$opts"
  # the mods on in the choices that patch the XBE (each logs "<mod>: [xbe] ...: N bytes")
  # ("?": unknown, no game key or no manifest yet: not checked)
  exp=; pm=$(mods_with_patches)
  if [ -n "$game" ] && [ -n "$pm" ]; then
    for m in $(mods_on "$game"); do echo "$pm" | grep -qx "$m" && exp="$exp $m"; done
  else
    exp=" ?"
  fi
  echo "mods_expected=${exp# }"
}

# What the run's game process (pid $2, logcat $1) applied: its mods with
# XBE patches applied (sorted), and its debug.hakux.opts options.
mods_applied() {
  grep "hakuX-native-mods( *$2):" "$1" | sed -n 's/^.*): \([A-Za-z0-9._-]*\): \[.*\] [0-9a-f]*: [0-9]* bytes$/\1/p' |
    sort -u | tr '\n' ' ' | sed 's/ $//'
}
opts_applied() {
  grep "hakuX-app( *$2): debug.hakux.opts: " "$1" | sed 's/^.*debug.hakux.opts: //' | tr '\n' ' ' | sed 's/ $//'
}

# The run checked once its replay started: the mods the core applied are
# the variant's, and its debug.hakux.opts were read. 1, with failed= in
# run.txt, when not.
check_run() {
  rd=$1
  spid=$(grep -m1 "pad script: started" "$rd/logcat.txt" | sed -n 's/^[^(]*( *\([0-9]*\)).*/\1/p')
  want=$(sed -n 's/^mods_expected=//p' "$rd/run.txt")
  got=$(mods_applied "$rd/logcat.txt" "$spid")
  echo "mods_applied=$got" >> "$rd/run.txt"
  grep -h "hakuX-native-mods( *$spid): vblank at" "$rd/logcat.txt" | sed 's/^.*): /mods_vblank=/' | head -n 1 >> "$rd/run.txt"
  bad=
  [ "$got" = "$want" ] || [ "$want" = "?" ] || bad="mods: the variant's are '${want:-none}', the core applied '${got:-none}'"
  o=$(sed -n 's/^debug.hakux.opts=//p' "$rd/run.txt")
  if [ -n "$o" ] && [ "$(opts_applied "$rd/logcat.txt" "$spid")" != "$o" ]; then
    bad="${bad:+$bad; }debug.hakux.opts '$o' not read by the game (this APK is older than build 14, or the property didn't reach it)"
  fi
  [ -z "$bad" ] && return 0
  echo "failed=$bad" >> "$rd/run.txt"
  say "run $NRUN FAILED: $bad"
  return 1
}

# The route into the app's files (through a pipe: run-as can't read a file
# on shared storage, it came out empty: "pad script: no steps"), checked.
push_route() {
  run-as $PKG mkdir -p "$APPDIR" || die "run-as $PKG failed (a debug build is needed)"
  cat "$OUT/$1.txt" | run-as $PKG sh -c "cat > $APPDIR/$1.txt"
  want=$(wc -l < "$OUT/$1.txt"); got=$(run-as $PKG cat "$APPDIR/$1.txt" | wc -l)
  [ "$want" -gt 0 ] && [ "$got" = "$want" ] ||
    die "couldn't copy the route into the app ($got of $want lines)"
  say "route $1: $(grep -vc '^#' "$OUT/$1.txt") steps in the app"
}

# The batch's folder and batch.txt: build, display, charging, caps.
new_batch() {   # name, then the variants
  BATCH=$OUT/$1-$(date +%Y%m%d-%H%M%S); mkdir -p "$BATCH"; shift
  {
    echo "variants=$*"; echo "scenes=$SCENES"; echo "runs=$RUNS"; echo "route_secs=$ROUTE_SECS"
    echo "build:"; dumpsys package $PKG 2>/dev/null | grep -E "versionName|lastUpdateTime|codePath" | sed 's/^ */  /'
    apk_identity
    getprop ro.product.model; getprop ro.build.fingerprint
    echo "display:"; dumpsys display 2>/dev/null | grep -E "mActiveModeId|mActiveSfDisplayMode|DisplayDeviceInfo\{" |
      sed 's/^ */  /' | cut -c1-300 | head -n 8
    echo "low_power=$(settings get global low_power 2>/dev/null)"
    echo "power at start:"; power_state
    echo "caps (scaling_max_freq):"; cat /sys/devices/system/cpu/cpufreq/policy*/scaling_max_freq
  } > "$BATCH/batch.txt"
  NRUN=0
}

# Which APK is installed: its sha256, and the APK file "route install" put
# there (route.bat records it: apkrecord) when the sha256 is that one's,
# with the build number, commit and branch its name carries
# (hakuX-debug-<branch>-<build>-<commit>-<cpu>.apk).
installed_apk() { pm path $PKG 2>/dev/null | sed -n 's/^package://p' | grep -m1 'base\.apk$'; }
apk_sha() { f=$(installed_apk); [ -n "$f" ] && sha256sum "$f" 2>/dev/null | cut -d' ' -f1; }
apk_identity() {
  sha=$(apk_sha); rec=$TMPD/hakux_apk.txt
  echo "  apk_sha256=${sha:-NA}"
  if [ -n "$sha" ] && [ -f "$rec" ] && [ "$(sed -n 's/^sha256=//p' "$rec")" = "$sha" ]; then
    name=$(sed -n 's/^file=//p' "$rec")
    echo "  apk_file=$name"
    echo "  apk_installed=$(sed -n 's/^time=//p' "$rec")"
    echo "$name" | sed -n 's/^hakuX-debug-\(.*\)-\([0-9][0-9]*\)-\([0-9a-f]\{7,40\}\)-\([a-z0-9]*\)\.apk$/  apk_branch=\1\
  apk_build=\2\
  apk_commit=\3\
  apk_cpu=\4/p'
  else
    echo "  apk_file=unknown (not installed by \"route install\" since route.bat records it: install it with route install)"
  fi
}

# route.bat after an install: the APK file's name, and the installed APK's sha256.
cmd_apkrecord() {
  sha=$(apk_sha)
  [ -n "$sha" ] || die "apkrecord: $PKG isn't installed"
  { echo "file=$1"; echo "sha256=$sha"; echo "time=$(date '+%Y-%m-%d %H:%M:%S')"; } > $TMPD/hakux_apk.txt
  say "recorded: $1 (sha256 $sha)"
}

# The settings in use (route.cfg's, if it was found), at the start of a batch.
say_settings() {
  if [ -f "$CFG" ]; then f="from route.cfg"; else f="no route.cfg: the defaults"; fi
  say "settings ($f): SCENES=\"$SCENES\" RUNS=$RUNS ROUTE_SECS=$ROUTE_SECS COOL_C=$COOL_C COOL_MAX=$COOL_MAX PROBE_SECS=$PROBE_SECS"
}

# Cools down until the hottest gpuss zone is under COOL_C (COOL_MAX s at most).
cool_down() {
  w=0
  while [ "$(gpuss_c)" -ge "$COOL_C" ] && [ $w -lt "$COOL_MAX" ]; do
    [ $w = 0 ] && say "cooling down: gpuss $(gpuss_c) C, waiting for under $COOL_C C (${COOL_MAX} s at most)"
    sleep 5; w=$((w + 5))
  done
}

# One run: scene (route), slot, variant, kind (measure, or a probe's name).
one_run() {
  scene=$1 slot=$2 v=$3 kind=$4
  vname=${3%%:*}                    # (set_variant reuses v: sh has no local variables)
  NRUN=$((NRUN + 1))
  label=${v%%:*}
  [ "$kind" = measure ] || label=probe-$kind
  RUN_DIR=$BATCH/$(printf '%02d' $NRUN)-$scene-$label
  # a resumed batch: a run that finished is kept, one that was cut is done again
  if grep -q '^end=' "$RUN_DIR/run.txt" 2>/dev/null; then
    say "run $NRUN: $scene, $label: done before, kept"
    return 0
  fi
  rm -rf "$RUN_DIR"; mkdir -p "$RUN_DIR"
  cool_down
  # the guest word watch, set again each run (a restart clears properties;
  # each new game process reads it again); left set afterwards
  setprop debug.hakux.watch "$WATCH"
  {
    echo "variant=${v%%:*}"; echo "kind=$kind"; echo "scene=$scene"; echo "slot=$slot"
    echo "debug.hakux.watch=$WATCH"
    set_variant "$v" "$slot"
    echo "start=$(date)"; echo "start_gpuss_C=$(gpuss_c)"
    echo "battery_dC=$(cat /sys/class/power_supply/battery/temp 2>/dev/null)"
    echo "power at start:"; power_state
  } > "$RUN_DIR/run.txt"
  say "run $NRUN: $scene, $label"
  if [ -z "$(native_pid)" ]; then
    say "the game closed: starting it again"
    start_game || die "the game closed and couldn't start again (in $BATCH)"
    sleep 20                         # booting before the load request
  fi
  start_capture "$RUN_DIR"
  load_slot "$slot"
  if wait_log "$RUN_DIR/logcat.txt" "pad script: started" 120; then
    snap_threads "$RUN_DIR/schedstat_start.txt"
    if ! check_run "$RUN_DIR"; then
      # the same variant again would fail the same way: the batch stops on
      # its second failure (A and B alternate: "in a row" never happens)
      stop_capture
      { echo "end=$(date)"; echo "power at end:"; power_state; } >> "$RUN_DIR/run.txt"
      setprop debug.hakux.state ''
      case " $RUNFAILS " in
        *" $vname "*) die "variant $vname failed its check twice ($(sed -n 's/^failed=//p' "$RUN_DIR/run.txt"))";;
      esac
      RUNFAILS="$RUNFAILS $vname"
      return 0
    fi
    say "replaying..."
    if [ "$kind" != measure ]; then
      mid=$(( $(route_secs "$scene") / 2 - PROBE_SECS / 2 ))
      [ $mid -gt 0 ] && sleep $mid
      say "probe: $kind for $PROBE_SECS s"
      run_probe "$kind" "$RUN_DIR"
    fi
    wait_log "$RUN_DIR/logcat.txt" "pad script: done" 1800 || say "run $NRUN: the replay didn't finish"
    snap_threads "$RUN_DIR/schedstat_end.txt"
    dump_timestats "$RUN_DIR"
    sleep 3
  else
    say "run $NRUN: the replay didn't start (see $RUN_DIR/logcat.txt)"
  fi
  stop_capture
  { echo "end=$(date)"; echo "power at end:"; power_state; } >> "$RUN_DIR/run.txt"
  [ -n "$(native_pid)" ] || say "run $NRUN: the game closed (see $RUN_DIR/logcat.txt)"
  setprop debug.hakux.state ''
}

# Steps in a route file (0: none, or an empty file left by an old runner).
route_steps() { grep -c '^[0-9]' "$OUT/$1.txt" 2>/dev/null || true; }

# Readies a scene: its route (a tour if there's none, or it has no steps), in the app.
ready_scene() {
  check_name "$1"
  if [ "$(route_steps "$1")" -lt 1 ]; then
    [ -f "$OUT/$1.txt" ] && say "route $1: $OUT/$1.txt has no steps, making a new one"
    cmd_tour "$1" "$ROUTE_SECS"
  fi
  push_route "$1"
  setprop debug.hakux.env "NC_PAD_SCRIPT=@$APPDIR/$1.txt"
  setprop debug.hakux.env2 "NC_PAD_STATE=1"
}

# ---- commands ----
# A route with no one playing (sticks only), in frames since the load: a
# star around the savestate's spot. Each spoke runs out, then runs back the
# way it came (the stick pulled back: always a clear path, so a rock or a
# wall on the way out can't wedge him for good), then the camera turns for
# the next spoke; spokes of 5 to 12 seconds out.
cmd_tour() {
  name=$1; check_name "$name"; secs=${2:-$ROUTE_SECS}
  case "$secs" in ''|*[!0-9]*) die "seconds is a number (got '$secs')";; esac
  [ "$secs" -lt 10 ] && secs=$((secs * 60))     # a small number: minutes (route.sh tour x 3)
  mkdir -p "$OUT" || die "can't write $OUT"
  frames=$((secs * 30))                         # at 30 frames a second
  {
    echo "# hakuX route: tour (a star of out-and-back runs), $secs s (route.sh tour)"
    # (tour_ names: sh has no local variables, and the suite's k counts scenes)
    tour_f=90 tour_k=0
    while [ $tour_f -lt $frames ]; do
      case $((tour_k % 4)) in 0) len=150;; 1) len=300;; 2) len=210;; *) len=360;; esac
      echo "${tour_f}f:ly=32767:${len}f"; tour_f=$((tour_f + len))
      echo "${tour_f}f:ly=-32767:${len}f"; tour_f=$((tour_f + len))
      echo "${tour_f}f:rx=32767:45f"; tour_f=$((tour_f + 75))
      tour_k=$((tour_k + 1))
    done
  } > "$OUT/$name.txt"
  say "made $OUT/$name.txt ($(grep -vc '^#' "$OUT/$name.txt") steps, about $secs s)"
}

cmd_record() {
  name=$1; check_name "$name"
  mkdir -p "$OUT" || die "can't write $OUT"
  run-as $PKG mkdir -p "$APPDIR" || die "run-as $PKG failed (a debug build is needed)"
  save_props
  setprop debug.hakux.env "NC_PAD_RECORD=$APPDIR/$name.txt"
  setprop debug.hakux.env2 "NC_PAD_STATE=1"
  wait_game
  RUN_DIR=$OUT/$name-record; mkdir -p "$RUN_DIR"
  start_capture "$RUN_DIR"
  load_slot "$SLOT"
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
  # through a pipe: run-as may not touch a file on shared storage (SELinux)
  run-as $PKG cat "$APPDIR/$name.txt" | cat > "$OUT/$name.txt"
  [ -s "$OUT/$name.txt" ] || die "couldn't copy the route out of the app"
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
  [ "$(route_steps "$name")" -ge 1 ] || die "route $name has no steps ($OUT/$name.txt): record it, or: route tour $name"
  mkdir -p "$OUT" || die "can't write $OUT"
  VARIANT_PROPS=$(variant_props "$@")
  case " $* " in *[:,]mod=*) MOD_BATCH=1;; esac
  save_props
  ready_scene "$name"
  new_batch "$name" "$@"
  say_settings
  wait_game
  i=0
  while [ $i -lt "$runs" ]; do
    for v in "$@"; do
      [ $i -lt "$runs" ] || break
      one_run "$name" "$SLOT" "$v" measure
      i=$((i + 1))
    done
  done
  for p in $PROBES; do one_run "$name" "$SLOT" "$1" "$p"; done
  restore
  say "batch done: $BATCH"
  sh "$HERE/route_report.sh" "$BATCH"
}

RUNFAILS=                   # the variants whose run failed its check (one each is allowed)

# The 30-minute batch (docs/diag-suite.md): per scene, RUNS measurement runs
# A B A B ..., then one probe run on A; the probes swap scenes each batch.
cmd_suite() {
  [ $# -ge 1 ] || die "suite needs a variant (A), and usually a second (B)"
  mkdir -p "$OUT" || die "can't write $OUT"
  VARIANT_PROPS=$(variant_props "$@")
  case " $* " in *[:,]mod=*) MOD_BATCH=1;; esac
  save_props
  name=suite; [ -n "$SUITE_NAME" ] && name=$SUITE_NAME
  # the same suite again after it was cut off (Auto Blocker, the cable): its
  # batch goes on, keeping the runs that finished (.suite_state: the
  # command, the batch's folder, its probe order)
  key="$name $*" st=$OUT/.suite_state resumed=
  if [ -f "$st" ]; then
    IFS='|' read -r skey sdir sflip < "$st"
    if [ "$skey" = "$key" ] && [ -d "$sdir" ] && [ ! -f "$sdir/report.txt" ]; then
      BATCH=$sdir; flip=$sflip; NRUN=0; resumed=1
      say "resuming $BATCH: the runs that finished are kept"
    fi
  fi
  if [ -z "$resumed" ]; then
    new_batch "$name" "$@"
    flip=$(cat "$OUT/.probe_flip" 2>/dev/null); flip=${flip:-0}
    echo $((1 - flip)) > "$OUT/.probe_flip"
    echo "$key|$BATCH|$flip" > "$st"
  fi
  say_settings
  wait_game
  k=0
  for sc in $SCENES; do
    scene=${sc%%:*}; slot=${sc#*:}
    if ! slot_exists "$slot"; then
      say "scene $scene: no savestate in slot $slot, skipped (save one there to include it)"
      echo "skipped_scene=$scene (no savestate in slot $slot)" >> "$BATCH/batch.txt"
      continue
    fi
    ready_scene "$scene"
    i=0
    while [ $i -lt "$RUNS" ]; do
      for v in "$@"; do
        [ $i -lt "$RUNS" ] || break
        one_run "$scene" "$slot" "$v" measure
        i=$((i + 1))
      done
    done
    if [ $(( (k + flip) % 2 )) = 0 ]; then probe=perfetto; else probe=simpleperf; fi
    one_run "$scene" "$slot" "$1" "$probe"
    k=$((k + 1))
  done
  restore
  rm -f "$st"
  say "batch done: $BATCH"
  sh "$HERE/route_report.sh" "$BATCH"
}

cmd_auto() {
  SUITE_NAME=auto cmd_suite x4:vcpucore=1 all:vcpucore=0
}

# Detached from adb (a cable drop doesn't stop it): the output in
# $OUT/console.txt, followed by watch.
cmd_start() {
  mkdir -p "$OUT"
  if [ -f "$OUT/route.pid" ] && kill -0 "$(cat "$OUT/route.pid")" 2>/dev/null; then
    die "a batch is already running (pid $(cat "$OUT/route.pid")): route watch, or route stop"
  fi
  : > "$OUT/console.txt"; rm -f "$OUT/route.pid"
  echo "$*" > "$OUT/console.cmd"        # what's running (route.sh status, route queue)
  # its output through a pipe into console.txt: a service command (settings,
  # svc, wm, am) can't write to a file on shared storage itself ("Failure
  # calling service settings: Failed transaction")
  HAKUX_PIDFILE=$OUT/route.pid HAKUX_CONSOLE=$OUT/console.txt setsid sh -c \
    'nohup sh "$0" "$@" < /dev/null 2>&1 | cat > "$HAKUX_CONSOLE"' "$0" "$@" > /dev/null 2>&1 &
  w=0; while [ ! -s "$OUT/route.pid" ] && [ $w -lt 10 ]; do sleep 1; w=$((w + 1)); done
}

cmd_watch() {
  [ -f "$OUT/console.txt" ] || die "nothing started"
  tail -n +1 -f "$OUT/console.txt" &
  tp=$!
  while [ -f "$OUT/route.pid" ] && kill -0 "$(cat "$OUT/route.pid")" 2>/dev/null; do sleep 2; done
  sleep 1; kill $tp 2>/dev/null
  echo "[route] finished"
}

# A new value of debug.hakux.state each time (the app acts on a change).
cmd_save() {
  slot=$1
  case "$slot" in [1-9]) ;; *) die "save: a slot from 1 to 9 (got '$slot')";; esac
  [ -n "$(native_pid)" ] || die "the game isn't running: start Fable and get to the spot first"
  before=$(run-as $PKG sh -c "ls -l files/native/states/*/slot$slot.hxs" 2>/dev/null)
  setprop debug.hakux.state ''
  sleep 1
  setprop debug.hakux.state "save:$slot"
  w=0
  while [ $w -lt 30 ]; do
    sleep 1; w=$((w + 1))
    now=$(run-as $PKG sh -c "ls -l files/native/states/*/slot$slot.hxs" 2>/dev/null)
    if [ -n "$now" ] && [ "$now" != "$before" ]; then
      sleep 2
      say "saved to slot $slot"
      setprop debug.hakux.state ''
      return 0
    fi
  done
  setprop debug.hakux.state ''
  die "slot $slot: nothing saved in 30 s (is the game in play, not in a menu or loading?)"
}

cmd_load() {
  case "$1" in [1-9]) ;; *) die "load: a slot from 1 to 9 (got '$1')";; esac
  slot_exists "$1" || die "slot $1 holds no savestate"
  wait_game
  load_slot "$1"
  setprop debug.hakux.state ''
}

cmd_clean() {
  setprop debug.hakux.env "$(without_pad "$(getprop debug.hakux.env)")"
  setprop debug.hakux.env2 "$(without_pad "$(getprop debug.hakux.env2)")"
  for p in debug.hakux.state $RUNNER_PROPS; do setprop "$p" ''; done
  put_back_mod_choices && rm -f $TMPD/hakux_route_modchoices
  say "cleared: the replay and recording (NC_PAD_ in debug.hakux.env, env2), state, opts, perf; mod choices put back"
  say "(vcpucore, adpf and watch left as they are; restarting the phone clears them all)"
}

# The last detached command: "running|<command>|", "done|<command>|" (its
# batch finished), "failed|<command>|" (it stopped on an error of its own),
# "stopped|<command>|" (it ended without finishing or an error: killed, as
# by Auto Blocker, or stopped), or "none||".
cmd_status() {
  c=$(cat "$OUT/console.cmd" 2>/dev/null)
  if [ -f "$OUT/route.pid" ] && kill -0 "$(cat "$OUT/route.pid")" 2>/dev/null; then
    st=running
  elif grep -q "^\[route\] batch done" "$OUT/console.txt" 2>/dev/null; then
    st=done
  elif grep -q "^\[route\] error:" "$OUT/console.txt" 2>/dev/null; then
    st=failed        # it stopped on an error of its own (not killed): retrying won't help
  elif [ -n "$c" ]; then
    st=stopped
  else
    st=none
  fi
  echo "$st|$c|"      # (route.bat reads it: a delimiter after the command)
}

cmd_stop() {
  [ -f "$OUT/route.pid" ] && kill -TERM "$(cat "$OUT/route.pid")" 2>/dev/null && say "stopping" || say "nothing running"
}

case "$1" in
  suite) shift; cmd_suite "$@";;
  auto) shift; cmd_auto "$@";;
  start) shift; cmd_start "$@";;
  watch) cmd_watch;;
  stop) cmd_stop;;
  status) cmd_status;;
  save) shift; cmd_save "$@";;
  load) shift; cmd_load "$@";;
  clean) cmd_clean;;
  tour) shift; cmd_tour "$@";;
  record) shift; cmd_record "$@";;
  run) shift; cmd_run "$@";;
  report) shift; sh "$HERE/route_report.sh" "$@";;
  apkrecord) shift; cmd_apkrecord "$@";;
  *) sed -n '2,54p' "$0" | sed 's/^# \{0,1\}//'; exit 2;;
esac
