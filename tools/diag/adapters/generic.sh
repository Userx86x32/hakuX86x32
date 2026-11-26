# Any app, with no hooks (route.cfg: ADAPTER=generic, APP_PKG=<package>):
# each run starts the app (am start; force-stopped first, APP_RESTART=1),
# waits APP_WAIT seconds, then measures APP_SECS seconds. No savestate, no
# input replay: only the core's metrics (SurfaceFlinger's frames and gaps,
# clocks, caps, temperatures, per-thread run and wait, the probes), so any
# game or emulator can at least be measured. Hold the scene still (a menu,
# an attract mode, a spot the game starts in) for numbers that repeat.
# Sourced by route.sh and route_report.sh (definitions only);
# tools/diag/README.md has the hooks.
#
# route.cfg:
#   APP_PKG=com.example.game     the app (required)
#   APP_ACTIVITY=<pkg>/<activity> what am start starts (its launcher activity by default)
#   APP_PROCESS=<name>           the process measured (APP_PKG by default)
#   APP_WAIT=10 APP_SECS=60      seconds after the start before measuring; seconds measured
#   APP_RESTART=1                force-stop before each run (0: start it only when it isn't running)
#   APP_THREADS="main=@main render=RenderThread"   the threads table (column=thread name;
#                                @main: the process's main thread); the report also lists
#                                the busiest threads by name
#   APP_LOG_TAGS="Unity:I"       logcat tags captured besides ActivityManager's and crashes'
#   APP_LAYER=<text>             SurfaceFlinger's layer: the one whose name holds this
#                                (the app's SurfaceView, else any layer of the package)
#   SCENES="app"                 scene names (no slot): runs per name, for the report
# Variants: debug.<name>=value (any property with a dot), set before the
# run and put back after; a label alone (base1 base2: the noise).
#
# A template for a new adapter: the hooks it defines are the ones that do
# something here; every other hook is the core's default, which does
# nothing (scenes are names alone, no savestate, no checksums, no variant
# names of its own, no report sections: tools/diag/README.md).

: "${APP_PKG=}"
PKG=$APP_PKG
PROC=${APP_PROCESS:-$APP_PKG}
ADAPTER_APP=app
ADAPTER_RUN="the app"
RUNNING_SAY="measuring..."
NAME_WHAT=scene
NAME_MAX=40
SKIP_HINT=
STATE_PROP=
PROC_RUNAS=auto                 # /proc directly (the shell reads any app's), else run-as
SF_LAYER="SurfaceView[$PKG/"
SF_LAYER_ANY="$PKG/"
SF_TIMESTATS_LAYER="SurfaceView[$PKG/"
[ -n "$APP_LAYER" ] && { SF_LAYER=$APP_LAYER; SF_TIMESTATS_LAYER=$APP_LAYER; }
AUTO_VARIANTS="base1 base2"
VARIANT_KEYS="none of its own"
LOG_TAGS="ActivityManager:I AndroidRuntime:E DEBUG:F libc:F $APP_LOG_TAGS"
SAVED_PROPS=
RUNNER_PROPS=
PROP_PREFIX=
QUIET_PROPS=
THREADS=${APP_THREADS:-main=@main render=RenderThread}
THREAD_LABELS=${APP_THREAD_LABELS:-}

: "${SCENES=app}"
: "${APP_WAIT=10}"
: "${APP_SECS=60}"
: "${APP_RESTART=1}"
RUN_OVERHEAD=$((APP_WAIT + 15))   # a run's seconds besides those measured (the start, the cool-down)

ad_clean() { say "cleared: the variants' properties put back (if a batch was cut off)"; }
ad_check_config() {
  [ -n "$PKG" ] || die "the generic adapter measures one app: APP_PKG=<package> in route.cfg"
  for n in "$APP_WAIT" "$APP_SECS"; do
    case "$n" in ''|*[!0-9]*) die "APP_WAIT and APP_SECS are seconds (got '$APP_WAIT', '$APP_SECS')";; esac
  done
  [ "$APP_SECS" -gt 0 ] || die "APP_SECS: at least a second"
}
ad_settings() { echo "APP_PKG=$PKG APP_WAIT=$APP_WAIT APP_SECS=$APP_SECS APP_RESTART=$APP_RESTART"; }
ad_batch_info() { echo "app_wait=$APP_WAIT"; echo "app_secs=$APP_SECS"; echo "app_activity=$(app_component)"; }

# ---- the app ----
# What am start starts: APP_ACTIVITY, else the package's launcher activity.
app_component() {
  if [ -n "$APP_ACTIVITY" ]; then echo "$APP_ACTIVITY"; return 0; fi
  cmd package resolve-activity --brief -a android.intent.action.MAIN -c android.intent.category.LAUNCHER "$PKG" 2>/dev/null |
    tail -n 1 | grep '/'
}
start_app() {
  comp=$(app_component)
  [ -n "$comp" ] || { say "no launcher activity for $PKG (is it installed? APP_ACTIVITY=<pkg>/<activity>)"; return 1; }
  input keyevent KEYCODE_WAKEUP 2>&1 | cat > /dev/null
  wm dismiss-keyguard 2>&1 | cat > /dev/null    # no-op behind a PIN: unlock the phone first
  am start -n "$comp" -a android.intent.action.MAIN -c android.intent.category.LAUNCHER 2>&1 | cat > /dev/null
  w=0
  while [ -z "$(app_pid)" ] && [ $w -lt 30 ]; do sleep 1; w=$((w + 1)); done
  [ -n "$(app_pid)" ]
}
ad_wait_app() {
  [ -n "$(pm path "$PKG" 2>/dev/null)" ] || die "$PKG isn't installed"
  say "app: $PKG ($(app_component)); each run: start, $APP_WAIT s, then $APP_SECS s measured"
}
ad_run_secs() { echo "$APP_SECS"; }

# ---- a run: start, wait, measure ----
ad_run_prepare() {
  if [ "$APP_RESTART" = 1 ]; then
    am force-stop "$PKG" 2>&1 | cat > /dev/null
    sleep 1
  fi
}
ad_run_start() {
  if [ -z "$(app_pid)" ]; then start_app || say "the app didn't start"; fi
}
# Started: its pid; APP_WAIT s later, still the same process: the window
# starts (window_start=, pid= in run.txt).
ad_run_started() {
  gp=$(app_pid)
  [ -n "$gp" ] || return 1
  echo "pid=$gp" >> "$1/run.txt"
  say "app running (pid $gp): measuring in $APP_WAIT s"
  sleep "$APP_WAIT"
  [ "$(app_pid)" = "$gp" ] || { say "the app closed or restarted in its first $APP_WAIT s"; return 1; }
  GW_T0=$(date +%s)
  echo "window_start=$(date +%H:%M:%S)" >> "$1/run.txt"
}
ad_run_wait_done() {
  rem=$((GW_T0 + APP_SECS - $(date +%s)))
  [ $rem -gt 0 ] && sleep $rem
  echo "window_end=$(date +%H:%M:%S)" >> "$1/run.txt"
}
# The app's process lived through the window (a crash or restart spoils it).
ad_check_run_end() {
  [ "$(app_pid)" = "$(sed -n 's/^pid=//p' "$1/run.txt")" ] && return 0
  run_failed "$1" "the app's process (pid $(sed -n 's/^pid=//p' "$1/run.txt")) didn't last the window (now: $(app_pid | grep . || echo none); see logcat.txt)"
  return 1
}

# ---- the preflight: one start, checked ----
# The app starts and stays up; SurfaceFlinger lists a layer of it (else no
# frames are counted); its threads' schedstat can be read.
ad_preflight() {   # run_dir scene slot
  pf_dir=$1 ok=1
  { echo "scene=$2"; echo "package=$PKG"; echo "activity=$(app_component)"; echo "build:"; apk_identity; } > "$pf_dir/run.txt"
  say_apk
  start_capture "$pf_dir"
  ad_run_prepare
  ad_run_start
  if gp=$(app_pid) && [ -n "$gp" ]; then
    say "ok: $PKG started (pid $gp)"
    sleep "$APP_WAIT"
    if [ "$(app_pid)" = "$gp" ]; then say "ok: still running after $APP_WAIT s"; else say "FAILED: it closed or restarted in $APP_WAIT s"; ok=; fi
    sleep 3                                   # (sflatency.txt: a block every 2 s)
    l=$(sed -n 's/^## [0-9:]* //p' "$pf_dir/sflatency.txt" | grep . | tail -n 1)
    if [ -n "$l" ]; then say "ok: SurfaceFlinger's layer: $l"
    else say "FAILED: SurfaceFlinger lists no layer of $PKG (APP_LAYER=<part of its name> in route.cfg)"; ok=; fi
    snap_threads "$pf_dir/schedstat_start.txt"
    if [ -s "$pf_dir/schedstat_start.txt" ]; then say "ok: its threads' schedstat ($(wc -l < "$pf_dir/schedstat_start.txt" | tr -d ' ') threads)"
    else say "FAILED: its threads' schedstat can't be read (/proc/<pid>/task)"; ok=; fi
  else
    say "FAILED: $PKG didn't start (see $pf_dir/logcat.txt)"; ok=
  fi
  [ -n "$ok" ]
}

# The hakuX adapter's commands have no meaning here (127: not a command).
ad_command() {
  case "$1" in
    save|load|tour|record)
      die "$1: the generic adapter has no savestates or input replay (a run: start the app, wait APP_WAIT s, measure APP_SECS s)";;
    *) return 127;;
  esac
}

# ---- the report (route_report.sh): the core's columns and sections ----
REPORT_TITLE="route report ($PKG, generic adapter)"
REPORT_SECTIONS="main threads display busiest failed probes perrun"
SF_LABEL="the app's layer"
MAIN_NOTE="  (fps: frames SurfaceFlinger presented of the app's layer in the window; stutters: its gaps, over 1.5x the median frame interval)"
# (ad_report_run: none; the window is run.txt's window_start=, window_end=, pid=)
