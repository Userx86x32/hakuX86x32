#!/system/bin/sh
# Route runner, the core (docs/optimization-playbook.md, tools/diag/README.md):
# runs an app over and over with the switches to compare, alternating them
# (A B A B ...), and collects what any app on the phone shows: clocks, caps,
# load and temperatures, each thread's run-queue wait, what SurfaceFlinger
# presented, and on probe runs a Perfetto trace or a CPU profile. What is
# particular to an emulator (starting the game, savestates, input replay,
# its checks, log tags, threads and report sections) is in its adapter,
# adapters/<ADAPTER>.sh (route.cfg's ADAPTER=, hakux by default; "generic":
# any app, started and measured for APP_SECS). Runs on the phone; route.bat
# drives it from the PC (it pushes this, route_report.sh, route_trace.pbtx,
# adapters/ and route.cfg, starts it detached, follows it, pulls, uploads).
#
#   suite [scenes=<scene:slot,...>] [runs=N] <variant A> [variant B]
#       The 30-minute batch: for each scene (route.cfg SCENES), RUNS
#       measurement runs alternating A and B, then one probe run on A
#       (Perfetto in the first scene and simpleperf in the second, the other
#       way round next batch). A scene the adapter can't run (no savestate)
#       is skipped. scenes= and runs= override SCENES and RUNS for this batch.
#   auto
#       suite with the adapter's AUTO_VARIANTS.
#   run <scene> [runs] [variant ...]
#       One scene (slot SLOT): runs measurement runs cycling through the
#       variants, then the probes in PROBES (perfetto simpleperf, or the
#       adapter's).
#   clean
#       The properties the runner sets, put back (after a batch was cut off).
#   start <command ...> / watch / stop / status / report <batch dir>
#   preflight
#       Before a queue: one start of the first scene, checked as a run is.
#   apkrecord <apk file name>
#       Notes the APK route.bat just installed (its name, the installed
#       APK's sha256) for batch.txt's build identity.
#
# A variant is label:name=value,name=value. Every adapter takes debug.* (or
# any name with a dot): a system property, set before the run and put back
# after; the adapter's own names are in its file. Each run starts from the
# variant's settings alone: whatever another variant set is put back first.
#
# Output: /sdcard/hakux_diag/routes/<batch>-<time>/<NN>-<scene>-<label>/
# (logcat.txt, sensors.csv, run.txt, schedstat_start.txt, schedstat_end.txt,
# sflatency.txt, sftimestats.txt; probes: trace.pftrace, perf.data,
# simpleperf_*.txt), with batch.txt, report.txt and summary.csv beside the
# runs. run.txt's inputs= are the checksums of what the run started from
# (the adapter's: the savestate, the route); the report keeps runs with
# different inputs apart.
HERE=$(cd "$(dirname "$0")" && pwd)
TMPD=${HAKUX_TMP:-/data/local/tmp}      # (overrides for the host tests, tests/diag)
OUT=${HAKUX_OUT:-/sdcard/hakux_diag/routes}
PROCFS=${HAKUX_PROC:-/proc}

# ---- settings: route.cfg beside this script, then the adapter's defaults,
# then the core's (each only where route.cfg left it unset: an empty value,
# PROBES="", stays empty) ----
CFG=${HAKUX_CFG:-$HERE/route.cfg}
if [ -f "$CFG" ]; then
  tr -d '\r' < "$CFG" > "$TMPD/hakux_route_cfg" && . "$TMPD/hakux_route_cfg"
fi
ADAPTER=${HAKUX_ADAPTER:-${ADAPTER:-hakux}}
case "$ADAPTER" in
  ''|*[!A-Za-z0-9_-]*) echo "[route] error: ADAPTER is an adapter's name, adapters/<name>.sh (got '$ADAPTER')" >&2; exit 1;;
esac
[ -f "$HERE/adapters/$ADAPTER.sh" ] ||
  { echo "[route] error: no adapter $ADAPTER ($HERE/adapters/$ADAPTER.sh)" >&2; exit 1; }

# ---- the adapter's hooks (tools/diag/README.md): what an adapter doesn't
# define does nothing (these), but for ad_run_start, ad_run_started,
# ad_run_wait_done and ad_run_secs, which each adapter defines ----
ad_check_config() { :; }
ad_wait_app() { :; }
ad_scene_check() { :; }
ad_scene_missing() { :; }
ad_scene_ready() { :; }
ad_run_check() { :; }
ad_batch_begin() { :; }
ad_batch_info() { :; }
ad_settings() { :; }
ad_save() { :; }
ad_restore() { :; }
ad_saved_value() { echo "$2"; }
ad_clean() { :; }
ad_apk_fields() { :; }
ad_variant_prop() { return 1; }
ad_variant_knows() { return 1; }
ad_variant_begin() { :; }
ad_variant_set() { return 1; }
ad_variant_end() { :; }
ad_run_header() { :; }
ad_checksums() { :; }
ad_run_prepare() { :; }
ad_check_run() { return 0; }
ad_check_run_end() { return 0; }
ad_run_end() { :; }
ad_probe() { return 1; }
ad_command() { return 127; }
# One run's start and its checks.
ad_preflight() {   # run_dir scene slot
  { echo "scene=$2"; echo "slot=$3"; echo "build:"; apk_identity; } > "$1/run.txt"
  say_apk
  start_capture "$1"
  ad_run_prepare "$1" "$2" "$3"
  ad_run_start "$1" "$2" "$3"
  if ! ad_run_started "$1"; then say "FAILED: $ADAPTER_RUN didn't start (see $1/logcat.txt)"; return 1; fi
  if ad_check_run "$1"; then say "ok: $ADAPTER_RUN started, its checks passed"; return 0; fi
  say "FAILED: $(sed -n 's/^failed=//p' "$1/run.txt")"
  return 1
}
. "$HERE/adapters/$ADAPTER.sh"
for f in ad_run_start ad_run_started ad_run_wait_done ad_run_secs; do
  command -v $f > /dev/null 2>&1 ||
    { echo "[route] error: the $ADAPTER adapter defines no $f (tools/diag/README.md)" >&2; exit 1; }
done
: "${RUNS=6}"                   # measurement runs per scene (A B A B ...)
: "${SLOT=1}"                   # run's slot
: "${PROBES=perfetto}"          # run's probe runs (perfetto simpleperf, the adapter's; "" none)
: "${COOL_C=45}"                # cool down until the hottest gpuss zone is under this
: "${COOL_MAX=10}"              # ... for at most this many seconds (the app runs on meanwhile, so
                                # waiting barely cools it: 90 s never got 50-58 C under 45 C)
: "${PROBE_SECS=20}"            # a probe's length, mid-run
: "${NAME_MAX=40}"              # a scene's name, at most
: "${NAME_WHAT=scene}"
: "${SF_LAYER=SurfaceView[$PKG/}"       # SurfaceFlinger: the app's layer (its name holds this)
: "${SF_TIMESTATS_LAYER=SurfaceView[$PKG}"
: "${PROC_RUNAS=1}"             # /proc of the app through run-as (1), directly (0), or either (auto)
: "${STATE_PROP=}"              # (the adapter's: cleared after each run and at the end)
: "${SCENES=app}"               # (the adapter's words and defaults, when it has none)
: "${ADAPTER_APP=app}" "${ADAPTER_RUN=the run}" "${RUNNING_SAY=measuring...}" "${RUN_OVERHEAD=30}"
: "${AUTO_VARIANTS=base1 base2}" "${VARIANT_KEYS=none of its own}" "${THREADS=main=@main}"
: "${LOG_TAGS=ActivityManager:I AndroidRuntime:E DEBUG:F libc:F}"

[ -n "$HAKUX_PIDFILE" ] && echo $$ > "$HAKUX_PIDFILE"   # started detached (route.sh start)
say() { echo "[route] $*"; }
die() { echo "[route] error: $*" >&2; restore; exit 1; }

# ---- the switches: saved first, put back at the end ----
# The adapter's SAVED_PROPS and those the batch's variants name are put back
# as they were (ad_saved_value may leave part of one out); its RUNNER_PROPS
# are cleared at the end, not put back.
save_props() {
  # a batch killed before it could put things back (Auto Blocker ends it
  # with SIGKILL) left its saved values: those are from before it, and what
  # is set now is its variants'. Put back first, so they aren't saved as
  # the "before" values.
  if [ -f $TMPD/hakux_route_props ]; then
    say "a cut-off batch's settings put back first"
    restore
  fi
  : > $TMPD/hakux_route_props
  for p in $SAVED_PROPS $VARIANT_PROPS; do
    v=$(ad_saved_value "$p" "$(getprop $p)")
    grep -q "^$p=" $TMPD/hakux_route_props || echo "$p=$v" >> $TMPD/hakux_route_props
  done
  for p in $RUNNER_PROPS; do echo "$p=" >> $TMPD/hakux_route_props; done
  STAYON=$(settings get global stay_on_while_plugged_in 2>/dev/null)
  svc power stayon usb 2>&1 | cat > /dev/null   # the screen stays on while plugged in (put back after)
  ad_save
}
saved_value() { sed -n "s/^$1=//p" $TMPD/hakux_route_props; }
restore() {
  [ -f $TMPD/hakux_route_props ] || return 0
  pb=
  while IFS== read -r p v; do
    setprop "$p" "$v"
    case " $QUIET_PROPS " in *" $p "*) ;; *) pb="$pb ${p#$PROP_PREFIX}='$v'";; esac
  done < $TMPD/hakux_route_props
  say "put back:$pb"
  [ -n "$STATE_PROP" ] && setprop "$STATE_PROP" ''     # not put back: a new value would act
  rm -f $TMPD/hakux_route_props
  ad_restore
  [ -n "$STAYON" ] && settings put global stay_on_while_plugged_in "$STAYON" 2>&1 | cat > /dev/null
  stop_capture
}
trap 'say "stopped"; restore; exit 130' INT TERM HUP

check_name() {
  case "$1" in
    ''|*[!A-Za-z0-9_-]*) die "a $NAME_WHAT's name is letters, digits, - and _ (got '$1')";;
  esac
  [ ${#1} -le "$NAME_MAX" ] || die "$NAME_WHAT name too long ($NAME_MAX characters at most)"
}

app_pid() { pidof $PROC 2>/dev/null; }

# The hottest gpuss thermal zone (32-39 on the S24+), in whole degrees.
gpuss_c() {
  g=0
  for z in 32 33 34 35 36 37 38 39; do
    t=$(cat /sys/class/thermal/thermal_zone$z/temp 2>/dev/null)
    [ -n "$t" ] && [ "$t" -gt "$g" ] && g=$t
  done
  echo $((g / 1000))
}

# Waits for a pattern in a file; 1 on timeout (seconds) or when the app closes.
wait_log() {
  wl_file=$1 wl_pat=$2 wl_secs=$3 wl_i=0
  while [ $wl_i -lt "$wl_secs" ]; do
    grep -q "$wl_pat" "$wl_file" 2>/dev/null && return 0
    [ -n "$(app_pid)" ] || { sleep 2; grep -q "$wl_pat" "$wl_file" 2>/dev/null && return 0; return 1; }
    sleep 1; wl_i=$((wl_i + 1))
  done
  return 1
}

# ---- capture: every run ----
PIDS=""
start_capture() {
  cap_dir=$1
  # the adapter's log tags (logcat -s: a filter drops every tag it doesn't name)
  # shellcheck disable=SC2086
  logcat -v time -T "$(date '+%m-%d %H:%M:%S').000" -s $LOG_TAGS > "$cap_dir/logcat.txt" 2>&1 &
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
  # every 2 s: the last 127 frames SurfaceFlinger presented of the app's
  # layer (desired, actual present, ready; ns). --latency wants the layer's
  # exact name, its "#<id>" included, and --list wraps it
  # ("RequestedLayerState{47d71ac SurfaceView[...]@0(BLAST)#30759
  # parentId=...}" on Android 14 and later): the name alone, read again each
  # time (each run's new process makes a new layer); the newest (highest
  # id) BLAST one when the old one is still listed. SF_LAYER: what the
  # name holds (the adapter's; the app's SurfaceView by default);
  # SF_LAYER_ANY: a second choice when no layer holds that (the whole name
  # of a layer that holds it)
  sh -c '
    while true; do
      l=$(dumpsys SurfaceFlinger --list 2>/dev/null | awk -v pkg="$0" -v any="$1" "
        i = index(\$0, pkg) {
          n = substr(\$0, i); sub(/[ }].*\$/, \"\", n)
          id = n; if (!sub(/^.*#/, \"\", id) || id !~ /^[0-9]+\$/) id = 0
          b = (n ~ /BLAST/)
          if (best == \"\" || b > bb || (b == bb && id + 0 > bid)) { best = n; bb = b; bid = id + 0 }
          next
        }
        any != \"\" && index(\$0, any) {
          n = \$0; if (sub(/^.*RequestedLayerState\\{[0-9a-f]+ /, \"\", n)) sub(/ parentId=.*\$/, \"\", n)
          sub(/^ +/, \"\", n); sub(/ +\$/, \"\", n)
          id = n; if (!sub(/^.*#/, \"\", id) || id !~ /^[0-9]+\$/) id = 0
          if (alt == \"\" || id + 0 > aid) { alt = n; aid = id + 0 }
        }
        END { print (best != \"\" ? best : alt) }")
      echo "## $(date +%H:%M:%S) $l"
      [ -n "$l" ] && dumpsys SurfaceFlinger --latency "$l" 2>/dev/null | cat
      sleep 2
    done' "$SF_LAYER" "$SF_LAYER_ANY" > "$cap_dir/sflatency.txt" 2>&1 &
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

# A shell command on the app's /proc entries: through run-as (a debuggable
# app's own; PROC_RUNAS=1), directly (the shell may read any app's: 0), or
# directly, then through run-as when that printed nothing (auto).
proc_sh() {
  case "$PROC_RUNAS" in
    1) run-as $PKG sh -c "$1";;
    0) sh -c "$1";;
    *) ps_out=$(sh -c "$1" 2>/dev/null)
       if [ -n "$ps_out" ]; then echo "$ps_out"; else run-as $PKG sh -c "$1"; fi;;
  esac
}
# Each thread of the app's process: tid, time on a CPU and waiting for one
# (ns), timeslices, the CPU it last ran on, its name. Through a pipe (run-as
# can't write to shared storage).
snap_threads() {
  p=$(app_pid)
  [ -n "$p" ] || return 0
  proc_sh "cd $PROCFS/$p/task 2>/dev/null && for t in *; do
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

# ---- probes: mid-run, PROBE_SECS long ----
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
    # the config's app (its gfx/view trace sections): the adapter's package
    sed "s/^duration_ms: .*/duration_ms: $((PROBE_SECS * 1000))/; s/^\( *atrace_apps: \).*/\1\"$PKG\"/" "$HERE/route_trace.pbtx" |
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
  *)
    ad_probe "$1" "$2" || say "probe: $1 isn't a probe (perfetto, simpleperf, or the $ADAPTER adapter's)"
    ;;
  esac
}

# ---- variants ----
# The properties a list of variants names (for saving and putting back):
# the adapter's, and every name with a dot.
variant_props() {
  for v in "$@"; do
    case "$v" in *:*) ;; *) continue;; esac       # a label alone: nothing set
    echo "${v#*:}" | tr ',' '\n' | while IFS== read -r p val; do
      ad_variant_prop "$p" || case "$p" in *.*) echo "$p";; esac
    done
  done | sort -u | tr '\n' ' '
}

# A batch's variants checked before it starts: every name is one the
# adapter or the core takes.
check_variants() {
  for v in "$@"; do
    case "$v" in *:*) ;; *) continue;; esac
    for kv in $(echo "${v#*:}" | tr ',' ' '); do
      p=${kv%%=*}
      ad_variant_knows "$p" && continue
      case "$p" in *.*) continue;; esac
      die "variant $v: $p isn't something the $ADAPTER adapter can set (it takes: $VARIANT_KEYS; any property: debug.<name>=value)"
    done
  done
}

# Sets one variant up (label:name=value,...) for a run from slot $2: the
# batch's variant properties put back first (and the adapter's own
# settings), then this one's; prints what it set (for run.txt).
set_variant() {
  for p in $VARIANT_PROPS; do setprop "$p" "$(saved_value "$p")"; done
  ad_variant_begin "$1" "$2"
  for sv_kv in $(echo "${1#*:}" | tr ',' ' '); do
    [ "$sv_kv" = "$1" ] && break
    sv_p=${sv_kv%%=*}; sv_v=${sv_kv#*=}
    ad_variant_set "$sv_p" "$sv_v" "$1" "$2" && continue
    case "$sv_p" in
      *.*) setprop "$sv_p" "$sv_v"; echo "$sv_p=$sv_v";;
      *) die "variant $1: $sv_p isn't something the $ADAPTER adapter can set";;
    esac
  done
  ad_variant_end "$1" "$2"
}

# A failed run: its reason in run.txt, and said.
run_failed() {   # run_dir reason
  echo "failed=$2" >> "$1/run.txt"
  say "run $NRUN FAILED: $2"
}

# What the run starts from (the adapter's checksums: name_sha256=...) in
# run.txt, and inputs=, their short form; said when it isn't what the
# scene's earlier runs in this batch started from (the report keeps them apart).
record_inputs() {   # run_dir scene slot
  ad_checksums "$2" "$3" > "$TMPD/hakux_route_sums" 2>/dev/null
  [ -s "$TMPD/hakux_route_sums" ] || { rm -f "$TMPD/hakux_route_sums"; return 0; }
  cat "$TMPD/hakux_route_sums" >> "$1/run.txt"
  in=$(sed -n 's/^\([A-Za-z0-9]*\)_sha256=\(........\).*$/\1:\2/p' "$TMPD/hakux_route_sums" | tr '\n' ' ' | sed 's/ $//')
  rm -f "$TMPD/hakux_route_sums"
  echo "inputs=$in" >> "$1/run.txt"
  first=
  for f in "$BATCH"/*/run.txt; do
    [ "$f" = "$1/run.txt" ] && continue
    grep -qx "scene=$2" "$f" 2>/dev/null || continue
    first=$(sed -n 's/^inputs=//p' "$f"); [ -n "$first" ] && break
  done
  if [ -n "$first" ] && [ "$first" != "$in" ]; then
    say "scene $2: what this run starts from changed in the batch ($first, now $in): the report keeps its runs apart"
  fi
}

# The batch's folder and batch.txt: build, display, charging, caps.
new_batch() {   # name, then the variants
  BATCH=$OUT/$1-$(date +%Y%m%d-%H%M%S); mkdir -p "$BATCH"; shift
  {
    echo "variants=$*"; echo "scenes=$SCENES"; echo "runs=$RUNS"; ad_batch_info
    echo "build:"; dumpsys package $PKG 2>/dev/null | grep -E "versionName|lastUpdateTime|codePath" | sed 's/^ */  /'
    apk_identity
    getprop ro.product.model; getprop ro.build.fingerprint
    echo "display:"; dumpsys display 2>/dev/null | grep -E "mActiveModeId|mActiveSfDisplayMode|DisplayDeviceInfo\{" |
      sed 's/^ */  /' | cut -c1-300 | head -n 8
    echo "low_power=$(settings get global low_power 2>/dev/null)"
    echo "power at start:"; power_state
    echo "caps (scaling_max_freq):"; cat /sys/devices/system/cpu/cpufreq/policy*/scaling_max_freq
    # (route_report.sh: which adapter's report, of which app, which threads)
    echo "adapter=$ADAPTER"; echo "package=$PKG"; echo "threads=$THREADS"
  } > "$BATCH/batch.txt"
  NRUN=0
}

# Which APK is installed: its sha256, and the APK file "route install" put
# there (route.bat records it: apkrecord) when the sha256 is that one's,
# with what the adapter reads from its name (hakuX: the build number,
# commit and branch).
installed_apk() { pm path $PKG 2>/dev/null | sed -n 's/^package://p' | grep -m1 'base\.apk$'; }
apk_sha() { f=$(installed_apk); [ -n "$f" ] && sha256sum "$f" 2>/dev/null | cut -d' ' -f1; }
apk_identity() {
  sha=$(apk_sha); rec=$TMPD/hakux_apk.txt
  echo "  apk_sha256=${sha:-NA}"
  if [ -n "$sha" ] && [ -f "$rec" ] && [ "$(sed -n 's/^sha256=//p' "$rec")" = "$sha" ]; then
    name=$(sed -n 's/^file=//p' "$rec")
    echo "  apk_file=$name"
    echo "  apk_installed=$(sed -n 's/^time=//p' "$rec")"
    ad_apk_fields "$name"
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
  say "settings ($f): SCENES=\"$SCENES\" RUNS=$RUNS $(ad_settings) COOL_C=$COOL_C COOL_MAX=$COOL_MAX PROBE_SECS=$PROBE_SECS"
}

# Cools down until the hottest gpuss zone is under COOL_C (COOL_MAX s at most).
cool_down() {
  w=0
  while [ "$(gpuss_c)" -ge "$COOL_C" ] && [ $w -lt "$COOL_MAX" ]; do
    [ $w = 0 ] && say "cooling down: gpuss $(gpuss_c) C, waiting for under $COOL_C C (${COOL_MAX} s at most)"
    sleep 5; w=$((w + 5))
  done
}

# A variant's failed check: the same variant again would fail the same way,
# so the batch stops on its second failure (A and B alternate: "in a row"
# never happens).
fail_count() {   # variant name
  case " $RUNFAILS " in
    *" $1 "*) die "variant $1 failed its check twice ($(sed -n 's/^failed=//p' "$RUN_DIR/run.txt"))";;
  esac
  RUNFAILS="$RUNFAILS $1"
}

# One run: scene, slot, variant, kind (measure, or a probe's name).
one_run() {
  scene=$1 slot=$2 v=$3 kind=$4
  vname=${3%%:*}                    # (set_variant may reuse v: sh has no local variables)
  endfail=
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
  {
    echo "variant=${v%%:*}"; echo "kind=$kind"; echo "scene=$scene"; echo "slot=$slot"
    ad_run_header
    set_variant "$v" "$slot"
    echo "start=$(date)"; echo "start_gpuss_C=$(gpuss_c)"
    echo "battery_dC=$(cat /sys/class/power_supply/battery/temp 2>/dev/null)"
    echo "power at start:"; power_state
  } > "$RUN_DIR/run.txt"
  record_inputs "$RUN_DIR" "$scene" "$slot"
  say "run $NRUN: $scene, $label"
  ad_run_prepare "$RUN_DIR" "$scene" "$slot"
  start_capture "$RUN_DIR"
  ad_run_start "$RUN_DIR" "$scene" "$slot"
  if ad_run_started "$RUN_DIR"; then
    snap_threads "$RUN_DIR/schedstat_start.txt"
    if ! ad_check_run "$RUN_DIR"; then
      stop_capture
      { echo "end=$(date)"; echo "power at end:"; power_state; } >> "$RUN_DIR/run.txt"
      ad_run_end "$RUN_DIR"
      fail_count "$vname"
      return 0
    fi
    say "$RUNNING_SAY"
    if [ "$kind" != measure ]; then
      mid=$(( $(ad_run_secs "$scene") / 2 - PROBE_SECS / 2 ))
      [ $mid -gt 0 ] && sleep $mid
      say "probe: $kind for $PROBE_SECS s"
      run_probe "$kind" "$RUN_DIR"
    fi
    ad_run_wait_done "$RUN_DIR"
    snap_threads "$RUN_DIR/schedstat_end.txt"
    dump_timestats "$RUN_DIR"
    sleep 3
    ad_check_run_end "$RUN_DIR" || endfail=1
  else
    say "run $NRUN: $ADAPTER_RUN didn't start (see $RUN_DIR/logcat.txt)"
  fi
  stop_capture
  { echo "end=$(date)"; echo "power at end:"; power_state; } >> "$RUN_DIR/run.txt"
  [ -n "$(app_pid)" ] || say "run $NRUN: the $ADAPTER_APP closed (see $RUN_DIR/logcat.txt)"
  ad_run_end "$RUN_DIR"
  [ -z "$endfail" ] || fail_count "$vname"
}

# ---- commands ----
cmd_run() {
  name=$1; check_name "$name"; runs=${2:-3}
  if [ $# -ge 2 ]; then shift 2; else shift $#; fi
  case "$runs" in ''|*[!0-9]*) die "runs is a number (got '$runs')";; esac
  [ $# -gt 0 ] || set -- default
  ad_check_config
  check_variants "$@"
  ad_run_check "$name"
  mkdir -p "$OUT" || die "can't write $OUT"
  VARIANT_PROPS=$(variant_props "$@")
  ad_batch_begin "$@"
  save_props
  ad_scene_ready "$name" "$SLOT"
  new_batch "$name" "$@"
  say_settings
  ad_wait_app
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

# The batch's length, roughly: per scene the adapter can run, RUNS + 1 runs
# of it + its overhead (a savestate's load, the cool-down); over 30
# minutes, Auto Blocker may cut it (say so: SCENES or RUNS can be smaller).
batch_estimate() {
  est=0
  for sc in $SCENES; do
    [ -z "$(ad_scene_missing "${sc%%:*}" "${sc#*:}")" ] || continue
    rs=$(ad_run_secs "${sc%%:*}" estimate 2>/dev/null)
    est=$((est + (${rs:-0} + RUN_OVERHEAD) * (RUNS + 1)))
  done
  say "batch: about $((est / 60)) min (scenes $SCENES, $RUNS runs + a probe each)"
  [ $est -le 1800 ] || say "batch: over 30 minutes: Auto Blocker may cut it (resumed after); fewer scenes (scenes=...) or runs (runs=N) fit"
}

# Before a queue: one start of the first scene the adapter can run, checked
# as a run is (the adapter's checks), and the APK named. Its log and result
# in $OUT/preflight/; 1 when a check fails.
cmd_preflight() {
  if [ -f "$OUT/route.pid" ] && kill -0 "$(cat "$OUT/route.pid")" 2>/dev/null; then
    die "a batch is running: preflight only before one"
  fi
  ad_check_config
  mkdir -p "$OUT" || die "can't write $OUT"
  save_props
  ad_wait_app
  pf_scene= pf_slot=
  for sc in $SCENES; do
    [ -z "$(ad_scene_missing "${sc%%:*}" "${sc#*:}")" ] && { pf_scene=${sc%%:*}; pf_slot=${sc#*:}; break; }
  done
  [ -n "$pf_scene" ] || die "preflight: no scene can run (SCENES=\"$SCENES\")"
  ad_scene_ready "$pf_scene" "$pf_slot"
  RUN_DIR=$OUT/preflight; rm -rf "$RUN_DIR"; mkdir -p "$RUN_DIR"
  ok=1
  ad_preflight "$RUN_DIR" "$pf_scene" "$pf_slot" || ok=
  stop_capture
  restore
  ad_run_end "$RUN_DIR"
  if [ -n "$ok" ]; then echo "preflight=ok" >> "$RUN_DIR/run.txt"; say "preflight ok"; return 0; fi
  echo "preflight=failed" >> "$RUN_DIR/run.txt"
  say "preflight FAILED (log: $RUN_DIR/logcat.txt)"
  return 1
}
# (for ad_preflight: the build's lines, said)
say_apk() {
  apk_identity | sed -n 's/^  //p' | grep '^apk_' | while read -r l; do say "$l"; done
}

# The 30-minute batch (docs/diag-suite.md): per scene, RUNS measurement runs
# A B A B ..., then one probe run on A; the probes swap scenes each batch.
cmd_suite() {
  suite_args="$*"                   # (the resume key: scenes= and runs= included)
  # scenes=<scene:slot,...> and runs=<N> first: this batch's, over route.cfg's
  while :; do
    case "$1" in
      scenes=*) SCENES=$(echo "${1#scenes=}" | tr ',' ' '); shift;;
      runs=*) RUNS=${1#runs=}; shift
              case "$RUNS" in ''|*[!0-9]*) die "runs=N: a number (got '$RUNS')";; esac;;
      *) break;;
    esac
  done
  [ $# -ge 1 ] || die "suite needs a variant (A), and usually a second (B)"
  ad_check_config
  check_variants "$@"
  # every scene the adapter can run has what it needs before anything starts
  for sc in $SCENES; do
    check_name "${sc%%:*}"
    ad_scene_check "${sc%%:*}" "${sc#*:}"
  done
  batch_estimate
  mkdir -p "$OUT" || die "can't write $OUT"
  VARIANT_PROPS=$(variant_props "$@")
  ad_batch_begin "$@"
  save_props
  name=suite; [ -n "$SUITE_NAME" ] && name=$SUITE_NAME
  # the same suite again after it was cut off (Auto Blocker, the cable): its
  # batch goes on, keeping the runs that finished (.suite_state: the
  # command, the batch's folder, its probe order)
  key="$name $suite_args" st=$OUT/.suite_state resumed=
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
  ad_wait_app
  k=0
  for sc in $SCENES; do
    scene=${sc%%:*}; slot=${sc#*:}
    why=$(ad_scene_missing "$scene" "$slot")
    if [ -n "$why" ]; then
      say "scene $scene: $why, skipped${SKIP_HINT:+ ($SKIP_HINT)}"
      echo "skipped_scene=$scene ($why)" >> "$BATCH/batch.txt"
      continue
    fi
    ad_scene_ready "$scene" "$slot"
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
  # shellcheck disable=SC2086
  SUITE_NAME=auto cmd_suite $AUTO_VARIANTS
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

cmd_clean() {
  # a cut-off batch's saved values put back
  restore
  ad_clean
  for p in $STATE_PROP $RUNNER_PROPS; do setprop "$p" ''; done
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

# The comment at the top of a file, as text.
head_comment() { awk 'NR == 1 { next } /^#/ { sub(/^# ?/, ""); print; next } { exit }' "$1"; }
usage() {
  head_comment "$0"
  echo; echo "The $ADAPTER adapter (adapters/$ADAPTER.sh):"
  head_comment "$HERE/adapters/$ADAPTER.sh" | sed 's/^/  /'
}

case "$1" in
  suite) shift; cmd_suite "$@";;
  auto) shift; cmd_auto "$@";;
  start) shift; cmd_start "$@";;
  watch) cmd_watch;;
  stop) cmd_stop;;
  status) cmd_status;;
  clean) cmd_clean;;
  run) shift; cmd_run "$@";;
  report) shift; sh "$HERE/route_report.sh" "$@";;
  apkrecord) shift; cmd_apkrecord "$@";;
  preflight) cmd_preflight;;
  ''|help|-h|--help) usage; exit 2;;
  *) ad_command "$@"; r=$?
     [ $r = 127 ] && { usage; exit 2; }
     exit $r;;
esac
