# hakuX (com.rfandango.haku_x.debug): replays a route (recorded controller
# input, NC_PAD_SCRIPT) from a savestate, with the game's own stutter,
# vblank, interrupt and decoder logs. Sourced by route.sh and
# route_report.sh (definitions only); tools/diag/README.md has the hooks.
#
# A scene is <route>:<slot>: a route file in /sdcard/hakux_diag/routes and
# the savestate slot it starts from (route.cfg SCENES; bower:1 wood:2).
#   tour <route> [seconds]
#       A route with no one playing (sticks only), ROUTE_SECS long by default.
#   record <route> [slot]
#       A route you play: loads the slot (SLOT by default) and records your
#       controller until you open hakuX's menu (or press Home).
#   save <slot> / load <slot>
#       A savestate of the running game to that slot, or loaded from it.
#   auto: suite x4:vcpucore=1 all:vcpucore=0
#
# Variant names (besides debug.anything):
#   adpf, vcpucore, ...: debug.hakux.<name>, set before the run
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
#   env=NAME=value: in debug.hakux.env2 after NC_PAD_STATE=1;NC_IRQ_SCHED=1
#       (read at game start; checked in the game's debug.hakux.env: lines)
#   pbspin=<us>: the decoder's spin before sleeping (debug.hakux.pbspin, v4;
#       read within a second; unset: 200), checked against its "decoder spin
#       before sleeping" line at the run's end (none: 200)
# Every run also gets NC_IRQ_SCHED=1 (IRQ_SCHED) in debug.hakux.env2, and
# must apply REQUIRED_MODS (the 60 fps mod) unless its variant sets mod=.
# Each run's inputs: the route's and the savestate's sha256.

PKG=com.rfandango.haku_x.debug
PROC=$PKG:native                # the game's process (the core runs in its own)
ADAPTER_APP=game
ADAPTER_RUN="the replay"
RUNNING_SAY="replaying..."
NAME_WHAT=route
NAME_MAX=20                     # debug.hakux.env holds 91 characters: NC_PAD_SCRIPT=@ + the path
RUN_OVERHEAD=30                 # a run's seconds besides its route (the savestate's load, the cool-down)
SKIP_HINT="save one there to include it"
STATE_PROP=debug.hakux.state
PROC_RUNAS=1
SF_LAYER="SurfaceView[$PKG/"
SF_LAYER_ANY=
SF_TIMESTATS_LAYER="SurfaceView[com.rfandango.haku_x"
AUTO_VARIANTS="x4:vcpucore=1 all:vcpucore=0"
VARIANT_KEYS="any debug.hakux.<name> (adpf, vcpucore, ...), scale, asyncpipe, prebuild, driver, mod, cold, env, pbspin"
LOG_TAGS="hakuX-hle-hitch:V hakuX-native:V hakuX-native-mods:V hakuX-app:V hakuX-native-usb:V
  hakuX-hle-pipe:V hakuX-hle:V hakuX-hle-prof:V hakuX-apu:V hakuX-native-watch:V hakuX-native-perf:V
  hakuX-native-vbl:V hakuX-native-irq:V hakuX-hle-pb:V"
# Properties put back after a batch: debug.hakux.env and env2 without any
# NC_PAD_ entries (the replay's and the recording's: a batch cut off before
# it put them back left them set, and the next batch must not keep them as
# the "normal" value, or every savestate load replays the route); the
# runner's own (opts, perf, perfsec) cleared, not put back.
SAVED_PROPS="debug.hakux.env debug.hakux.env2 debug.hakux.vcpucore debug.hakux.adpf"
RUNNER_PROPS="debug.hakux.opts debug.hakux.perf debug.hakux.perfsec"
PROP_PREFIX=debug.hakux.
QUIET_PROPS="debug.hakux.env debug.hakux.env2"
# The threads of the report's schedstat table: column=thread name (the
# vCPU's: the tid hakuX logs for it, else the busiest SDLThread), and their
# headings (top/bottom, _ a space)
THREADS="vcpu=SDLThread decode=hle-pb render=hle.render main=SDLActivity apu=apu.frame"
THREAD_LABELS="vCPU_run/SDLThread decode/hle-pb render/hle.rendr main/SDLActvty apu/apu.frame"

# ---- settings (route.cfg sets them first) ----
: "${SCENES=bower:1 wood:2}"    # route:slot, in order
: "${ROUTE_SECS=75}"            # a tour's length
: "${TOUR_SCENES=bower wood}"   # scenes whose route may be a hands-off tour, made when missing;
                                # any other (lookout) must be recorded: route record <name> <slot>
: "${WATCH=0x862494}"           # debug.hakux.watch: Fable's presentation interval (D3D)
: "${REQUIRED_MODS=60fps}"      # mods every run must apply (their "<mod>: [xbe] ...: N bytes" line)
                                # unless its variant sets mod=; "" for none
: "${IRQ_SCHED=1}"              # NC_IRQ_SCHED for every run (hakuX-native-irq: a late interrupt's
                                # thread wait), in debug.hakux.env2 beside the replay's NC_PAD_STATE
APPDIR=/data/data/$PKG/files/r  # the app's own files (run-as: a debug build)

without_pad() { echo "$1" | tr ';' '\n' | grep -v -e '^NC_PAD_' -e '^NC_IRQ_SCHED=' | tr '\n' ';' | sed 's/;*$//'; }
ad_saved_value() {   # property value: what is saved of it
  case "$1" in debug.hakux.env|debug.hakux.env2) without_pad "$2";; *) echo "$2";; esac
}
# the app's mod choices, when a variant changes them (put back after; "-"
# for a file that wasn't there: the app then reads its old preferences)
ad_save() {
  if [ -n "$MOD_BATCH" ] && [ ! -f $TMPD/hakux_route_modchoices ]; then
    run-as $PKG cat files/mod_choices.json > $TMPD/hakux_route_modchoices 2>/dev/null ||
      echo - > $TMPD/hakux_route_modchoices
  fi
}
ad_restore() { put_back_mod_choices && rm -f $TMPD/hakux_route_modchoices; }
ad_clean() {
  setprop debug.hakux.env "$(without_pad "$(getprop debug.hakux.env)")"
  setprop debug.hakux.env2 "$(without_pad "$(getprop debug.hakux.env2)")"
  put_back_mod_choices && rm -f $TMPD/hakux_route_modchoices
  say "cleared: the replay and recording (NC_PAD_ in debug.hakux.env, env2), state, opts, perf; mod choices put back"
  say "(vcpucore, adpf, pbspin: as before the cut-off batch, if one was; watch left set)"
}
ad_check_config() { :; }
ad_settings() { echo "ROUTE_SECS=$ROUTE_SECS"; }
ad_batch_info() { echo "route_secs=$ROUTE_SECS"; }
# the batch's kinds of variant (mods, the decoder's spin)
ad_batch_begin() {
  case " $* " in *[:,]mod=*) MOD_BATCH=1;; esac
  case " $* " in *[:,]pbspin=*) PBSPIN_BATCH=1;; esac
}

# The APK file's name: hakuX-debug-<branch>-<build>-<commit>-<cpu>.apk.
ad_apk_fields() {
  echo "$1" | sed -n 's/^hakuX-debug-\(.*\)-\([0-9][0-9]*\)-\([0-9a-f]\{7,40\}\)-\([a-z0-9]*\)\.apk$/  apk_branch=\1\
  apk_build=\2\
  apk_commit=\3\
  apk_cpu=\4/p'
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
  while [ -z "$(app_pid)" ] && [ $w -lt 30 ]; do sleep 1; w=$((w + 1)); done
  [ -n "$(app_pid)" ]
}

ad_wait_app() {
  if [ -z "$(app_pid)" ] && ! start_game; then
    say ">>> Couldn't start the game by itself (no last game in hakuX, or the phone"
    say "    is locked). Start Fable in hakuX now (don't load a state). Waiting..."
    while [ -z "$(app_pid)" ]; do sleep 2; done
  fi
  say "game running (pid $(app_pid))"
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
    old=$(app_pid)
    if [ -z "$old" ]; then
      # the game closed (or never started): start it again, then load
      say "the game isn't running: starting it"
      start_game || die "the game couldn't be started (is the phone unlocked?)"
      sleep 20
      old=$(app_pid)
    fi
    setprop debug.hakux.state ''
    sleep 1
    setprop debug.hakux.state "load:$1"
    w=0
    while [ $w -lt 15 ]; do
      sleep 1; w=$((w + 1))
      now=$(app_pid)
      if [ -n "$now" ] && [ "$now" != "$old" ]; then
        say "slot $1 loading (pid $now)"
        return 0
      fi
    done
    say "slot $1 not loaded yet (try $try; the game may still be booting)"
  done
  die "savestate slot $1 didn't load (is there a state in slot $1?)"
}

# The route's length in seconds (its last step's end, at 30 frames a second).
route_secs() {
  awk -F'[:f]' '/^[0-9]+f:/ { e = $1 + $(NF - 1); if (e > m) m = e } END { print int(m / 30) }' "$OUT/$1.txt"
}
# A run's length: its route's (estimate: ROUTE_SECS when it has none yet).
ad_run_secs() {
  if [ "$2" = estimate ]; then
    rs=$(route_secs "$1" 2>/dev/null); [ "${rs:-0}" -gt 0 ] || rs=$ROUTE_SECS; echo "$rs"
  else
    route_secs "$1"
  fi
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

# ---- variants ----
# The property a variant's name sets (printed; 1: none), and whether the
# adapter takes the name.
ad_variant_prop() {
  case "$1" in
    ''|scale|asyncpipe|prebuild|driver|mod|cold|env) return 0;;
    debug.*) echo "$1";;
    *) echo "debug.hakux.$1";;
  esac
}
ad_variant_knows() { return 0; }    # any other name: a debug.hakux. property

# One variant for a run from slot $2 (set_variant): the mod choices put back
# first, then each name=value (ad_variant_set, printing what it set for
# run.txt), then debug.hakux.env2 and opts, and the mods the run must apply
# (mods_expected=, checked against the log once the run starts).
ad_variant_begin() {
  [ -n "$MOD_BATCH" ] && put_back_mod_choices
  game=$(slot_game "$2")
  opts= envx= modset=
}
ad_variant_set() {   # name value variant slot
  case "$1" in
    scale|asyncpipe|prebuild) opts="$opts $1=$2";;
    env) case "$2" in [A-Za-z_]*=*) envx="$envx;$2";; *) die "variant $3: env=NAME=value (got '$2')";; esac;;
    driver) [ "$2" = system ] && opts="$opts vkdriver=none";;
    mod) [ -n "$game" ] || die "mod $2: no savestate in slot $4 (its folder names the game)"
         [ "$2" = none ] || mods_with_patches | grep -qx "$2" ||
           die "mod $2: not in hakuX's mod list for this game (files/native/mods.txt; run the game once)"
         modset=1
         set_mod_choice "$game" "$2"
         [ "$(mods_on "$game")" = "${2#none}" ] ||
           die "mod $2: the app's mod choices didn't take it (files/mod_choices.json: $(mods_on "$game"))"
         echo "mod_choice=$game: ${2} only";;
    cold) if [ "$2" = 1 ]; then
            run-as $PKG sh -c 'rm -rf files/native/hle/*' && echo "cold: shader and pipeline caches cleared"
          fi;;
    debug.*) setprop "$1" "$2"; echo "$1=$2";;
    *) setprop "debug.hakux.$1" "$2"; echo "debug.hakux.$1=$2";;
  esac
}
ad_variant_end() {
  # debug.hakux.env2: the replay's and NC_IRQ_SCHED, then the variant's env=
  e2="$(run_env2)$envx"
  [ ${#e2} -le 91 ] || die "variant $1: debug.hakux.env2 would be too long (91 characters): $e2"
  setprop debug.hakux.env2 "$e2"
  echo "debug.hakux.env2=$e2"
  echo "env_variant=${envx#;}"
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
  # the baseline's mods (the 60 fps mod): required of every run whose
  # variant doesn't choose its mods (a reinstall lost the choice once, and
  # whole batches ran without it, passing as the choices said)
  [ -n "$modset" ] && echo "mods_required=" || echo "mods_required=$REQUIRED_MODS"
}

# ---- checks ----
# The required mods (list $3) whose patch line process $2 didn't log
# ("60fps: [default.xbe] 0003f776: 10 bytes"), in logcat $1.
mods_missing() {
  ma=$(mods_applied "$1" "$2")
  for m in $3; do case " $ma " in *" $m "*) ;; *) printf '%s ' "$m";; esac; done | sed 's/ $//'
}
# Why, if the log says: a savestate made with other mods (its mods taken back).
mods_missing_hint() {
  l=$(grep "hakuX-native-mods( *$2): savestate " "$1" | head -n 1 | sed 's/^.*): //')
  echo "hakuX's mod choices for the game have it off (lost at a reinstall?): turn it on in hakuX (Fable, Mods), then run again${l:+; the log: $l}"
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
# The replaying process (its "pad script: started" line's pid).
replay_pid() { grep -m1 "pad script: started" "$1" | sed -n 's/^[^(]*( *\([0-9]*\)).*/\1/p'; }

# The run checked at its end: the decoder's spin (debug.hakux.pbspin) is the
# variant's. The decoder logs "decoder spin before sleeping: N us" only when
# the value changes from its 200 us default: no line is 200. 1, with failed=.
ad_check_run_end() {
  rd=$1
  grep -q '^debug.hakux.pbspin=' "$rd/run.txt" || [ -n "$PBSPIN_BATCH" ] || return 0
  spid=$(replay_pid "$rd/logcat.txt")
  want=$(sed -n 's/^debug.hakux.pbspin=//p' "$rd/run.txt")
  [ -n "$want" ] || want=$(saved_value debug.hakux.pbspin)
  case "$want" in ''|*[!0-9]*) want=200;; esac
  [ "$want" -gt 2000 ] && want=2000
  got=$(grep "hakuX-hle-pb( *$spid): decoder spin before sleeping: " "$rd/logcat.txt" | tail -n 1 |
    sed 's/^.*sleeping: \([0-9]*\) us.*/\1/')
  echo "pbspin_applied=${got:-200}" >> "$rd/run.txt"
  [ "${got:-200}" = "$want" ] && return 0
  echo "failed=pbspin: the variant's is $want us, the decoder spun ${got:-200} us" >> "$rd/run.txt"
  say "run $NRUN FAILED: pbspin $want us asked, the decoder logged ${got:-200} us"
  return 1
}

# The run checked once its replay started: the mods the core applied are
# the variant's, and its debug.hakux.opts were read. 1, with failed= in
# run.txt, when not.
ad_check_run() {
  rd=$1
  spid=$(replay_pid "$rd/logcat.txt")
  want=$(sed -n 's/^mods_expected=//p' "$rd/run.txt")
  got=$(mods_applied "$rd/logcat.txt" "$spid")
  echo "mods_applied=$got" >> "$rd/run.txt"
  grep -h "hakuX-native-mods( *$spid): vblank at" "$rd/logcat.txt" | sed 's/^.*): /mods_vblank=/' | head -n 1 >> "$rd/run.txt"
  bad=
  [ "$got" = "$want" ] || [ "$want" = "?" ] || bad="mods: the variant's are '${want:-none}', the core applied '${got:-none}'"
  miss=$(mods_missing "$rd/logcat.txt" "$spid" "$(sed -n 's/^mods_required=//p' "$rd/run.txt")")
  [ -z "$miss" ] || bad="${bad:+$bad; }mods: required $miss not applied (no \"$miss: [default.xbe] ...: N bytes\" line): $(mods_missing_hint "$rd/logcat.txt" "$spid")"
  o=$(sed -n 's/^debug.hakux.opts=//p' "$rd/run.txt")
  if [ -n "$o" ] && [ "$(opts_applied "$rd/logcat.txt" "$spid")" != "$o" ]; then
    bad="${bad:+$bad; }debug.hakux.opts '$o' not read by the game (this APK is older than build 14, or the property didn't reach it)"
  fi
  # the replay waited for the savestate's load (NC_PAD_STATE: a build with
  # this branch's native changes); without it, it ran from the game's boot
  if ! grep "hakuX-native-usb( *$spid): pad script: " "$rd/logcat.txt" | grep -q "(waits for a savestate's load)"; then
    bad="${bad:+$bad; }the replay didn't wait for the savestate's load (no \"(waits for a savestate's load)\": this APK lacks NC_PAD_STATE)"
  fi
  for e in $(sed -n 's/^env_variant=//p' "$rd/run.txt" | tr ';' ' '); do
    grep -qF "debug.hakux.env: $e" "$rd/logcat.txt" ||
      bad="${bad:+$bad; }$e (the variant's env=) not in the game's environment"
  done
  if [ "$IRQ_SCHED" = 1 ] && ! grep -q "hakuX-app( *$spid): debug.hakux.env: NC_IRQ_SCHED=1" "$rd/logcat.txt"; then
    bad="${bad:+$bad; }NC_IRQ_SCHED=1 not in the game's environment (debug.hakux.env2)"
  fi
  [ -z "$bad" ] && return 0
  run_failed "$rd" "$bad"
  return 1
}

# ---- a run ----
# The guest word watch, set again each run (a restart clears properties;
# each new game process reads it again); left set afterwards.
ad_run_header() {
  setprop debug.hakux.watch "$WATCH"
  echo "debug.hakux.watch=$WATCH"
}
# What the run starts from: the route in the app, the savestate.
ad_checksums() {   # scene slot
  s=$(run-as $PKG cat "$APPDIR/$1.txt" 2>/dev/null | sha256sum 2>/dev/null | cut -d' ' -f1)
  [ -n "$s" ] && echo "route_sha256=$s"
  s=$(run-as $PKG sh -c "cat files/native/states/*/slot$2.hxs" 2>/dev/null | sha256sum 2>/dev/null | cut -d' ' -f1)
  [ -n "$s" ] && echo "state_sha256=$s"
  return 0
}
ad_run_prepare() {
  if [ -z "$(app_pid)" ]; then
    say "the game closed: starting it again"
    start_game || die "the game closed and couldn't start again (in $BATCH)"
    sleep 20                         # booting before the load request
  fi
}
ad_run_start() { load_slot "$3"; }
ad_run_started() { wait_log "$1/logcat.txt" "pad script: started" 120; }
ad_run_wait_done() {
  wait_log "$1/logcat.txt" "pad script: done" 1800 || say "run $NRUN: the replay didn't finish"
}
ad_run_end() { setprop debug.hakux.state ''; }
# hakuX's GPU-time profiler (hakuX-hle-prof lines), PROBE_SECS long.
ad_probe() {
  [ "$1" = prof ] || return 1
  setprop debug.hakux.perfsec "$PROBE_SECS"
  setprop debug.hakux.perf "$(date +%s)"   # a new value starts it
  sleep "$PROBE_SECS"
}

# ---- scenes: a route and its savestate ----
# Steps in a route file (0: none, or an empty file left by an old runner).
route_steps() { n=$(grep -c '^[0-9]' "$OUT/$1.txt" 2>/dev/null); echo "${n:-0}"; }   # (no file: 0)

# Why a scene can't run (nothing: it can).
ad_scene_missing() { slot_exists "$2" || echo "no savestate in slot $2"; }
# Before a suite: a scene with a savestate has a route, or may get a tour.
ad_scene_check() {
  slot_exists "$2" || return 0
  if [ "$(route_steps "$1")" -lt 1 ]; then
    case " $TOUR_SCENES " in
      *" $1 "*) ;;
      *) die "scene $1: no route recorded ($OUT/$1.txt): route record $1 $2";;
    esac
  fi
}
ad_run_check() {
  [ "$(route_steps "$1")" -ge 1 ] || die "route $1 has no steps ($OUT/$1.txt): record it, or: route tour $1"
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
# Readies a scene: its route (a tour if there's none, or it has no steps), in the app.
ad_scene_ready() {
  check_name "$1"
  if [ "$(route_steps "$1")" -lt 1 ]; then
    [ -f "$OUT/$1.txt" ] && say "route $1: $OUT/$1.txt has no steps, making a new one"
    cmd_tour "$1" "$ROUTE_SECS"
  fi
  push_route "$1"
  setprop debug.hakux.env "NC_PAD_SCRIPT=@$APPDIR/$1.txt"
  setprop debug.hakux.env2 "$(run_env2)"
}
# debug.hakux.env2 for a replay: the savestate wait, and NC_IRQ_SCHED (read
# at game start: set again before every run)
run_env2() { if [ "$IRQ_SCHED" = 1 ]; then echo "NC_PAD_STATE=1;NC_IRQ_SCHED=1"; else echo "NC_PAD_STATE=1"; fi; }

# ---- the preflight: one replay start, checked ----
# The replay waits for the savestate's load; the required mods applied;
# NC_IRQ_SCHED=1 set in debug.hakux.env2 and in the game's environment.
ad_preflight() {   # run_dir scene slot
  pf_dir=$1 ok=1
  setprop debug.hakux.env2 "$(run_env2)"
  { echo "scene=$2"; echo "slot=$3"; echo "debug.hakux.env2=$(getprop debug.hakux.env2)"
    echo "mods_expected=?"; echo "build:"; apk_identity; } > "$pf_dir/run.txt"
  say_apk
  start_capture "$pf_dir"
  load_slot "$3"
  if wait_log "$pf_dir/logcat.txt" "pad script: started" 120; then
    spid=$(replay_pid "$pf_dir/logcat.txt")
    l=$(grep "hakuX-native-usb( *$spid): pad script: " "$pf_dir/logcat.txt" | grep -m1 "(waits for a savestate's load)")
    if [ -n "$l" ]; then say "ok: ${l#*): }"; else say "FAILED: no \"(waits for a savestate's load)\" (this APK lacks NC_PAD_STATE)"; ok=; fi
    if [ -n "$REQUIRED_MODS" ]; then
      miss=$(mods_missing "$pf_dir/logcat.txt" "$spid" "$REQUIRED_MODS")
      if [ -z "$miss" ]; then
        for m in $REQUIRED_MODS; do
          say "ok: $(grep "hakuX-native-mods( *$spid): $m: \[" "$pf_dir/logcat.txt" | head -n 1 | sed 's/^.*): //')"
        done
      else
        say "FAILED: the $miss mod wasn't applied: $(mods_missing_hint "$pf_dir/logcat.txt" "$spid")"; ok=
      fi
    fi
    if [ "$IRQ_SCHED" = 1 ]; then
      e2=$(sed -n 's/^debug.hakux.env2=//p' "$pf_dir/run.txt")
      case ";$e2;" in
        *";NC_IRQ_SCHED=1;"*) say "ok: debug.hakux.env2=$e2";;
        *) say "FAILED: debug.hakux.env2 is '$e2', without NC_IRQ_SCHED=1"; ok=;;
      esac
      if grep -q "hakuX-app( *$spid): debug.hakux.env: NC_IRQ_SCHED=1" "$pf_dir/logcat.txt"; then
        say "ok: the game read NC_IRQ_SCHED=1 (its debug.hakux.env: line)"
      else
        say "FAILED: the game didn't log debug.hakux.env: NC_IRQ_SCHED=1"; ok=
      fi
    fi
  else
    say "FAILED: the replay didn't start in 120 s (see $pf_dir/logcat.txt)"; ok=
  fi
  [ -n "$ok" ]
}

# ---- the adapter's commands ----
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
  [ -n "$2" ] && SLOT=$2
  case "$SLOT" in [1-9]) ;; *) die "record: a slot from 1 to 9 (got '$SLOT')";; esac
  slot_exists "$SLOT" || die "slot $SLOT holds no savestate: get to the spot, then route save $SLOT"
  mkdir -p "$OUT" || die "can't write $OUT"
  run-as $PKG mkdir -p "$APPDIR" || die "run-as $PKG failed (a debug build is needed)"
  save_props
  setprop debug.hakux.env "NC_PAD_RECORD=$APPDIR/$name.txt"
  setprop debug.hakux.env2 "NC_PAD_STATE=1"
  ad_wait_app
  RUN_DIR=$OUT/$name-record; mkdir -p "$RUN_DIR"
  start_capture "$RUN_DIR"
  load_slot "$SLOT"
  say ">>> Play the route now with the controller: recording starts at your first"
  say "    input. When you're done, open hakuX's menu (or press Home): that ends it."
  wait_log "$RUN_DIR/logcat.txt" "pad record: to" 3600 ||
    die "the recording didn't start (logcat: $RUN_DIR/logcat.txt)"
  say "recording..."
  while ! grep -q "pad record: .* steps to frame" "$RUN_DIR/logcat.txt"; do
    [ -n "$(app_pid)" ] || break
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

# A new value of debug.hakux.state each time (the app acts on a change).
cmd_save() {
  slot=$1
  case "$slot" in [1-9]) ;; *) die "save: a slot from 1 to 9 (got '$slot')";; esac
  [ -n "$(app_pid)" ] || die "the game isn't running: start Fable and get to the spot first"
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
  ad_wait_app
  load_slot "$1"
  setprop debug.hakux.state ''
}

# The adapter's commands (127: not one).
ad_command() {
  case "$1" in
    save) shift; cmd_save "$@";;
    load) shift; cmd_load "$@";;
    tour) shift; cmd_tour "$@";;
    record) shift; cmd_record "$@";;
    *) return 127;;
  esac
}

# ---- the report (route_report.sh) ----
REPORT_TITLE="hakuX route report"
SUMMARY_COLUMNS="run,variant,secs,frames,fps,stutters,per_min,over_ms,worst_ms,hangs,work_ms,max_gpuss_C,max_batt_C,min_cap_big_khz,min_cap_prime_khz,cpu7_avg_khz,gpu_avg_mhz,vbl_answer_avg_ms,vbl_answer_max_ms,vbl_over_2ms,vbl_over_8ms,vbl_unanswered,flip_delay_avg_ms,flip_delay_max_ms,present_interval_start,present_interval_changes,present_interval_values,kind,start_gpuss_C,vcpu_run_ms,vcpu_wait_ms,decode_run_ms,decode_wait_ms,render_run_ms,render_wait_ms,main_run_ms,main_wait_ms,apu_run_ms,apu_wait_ms,jit_drops,jit_drops_max_10s,sf_frames,sf_gaps,sf_worst_gap_ms,sf_median_ms,sf_source,mods,pbspin_us,irq_late,irq_isr,irq_if0,irq_irql,irq_none,irq_late_avg_ms,irq_late_max_ms,irq_ran_avg_ms,irq_ran_max_ms,irq_hostwait_avg_ms,pb_lines,pb_kicks,pb_words,pb_flips"
REPORT_SECTIONS="main vblanks threads jitdisplay irq decoder failed probes perrun watch causes"
SF_LABEL="hakuX's layer"
WINDOW_WORD=replay
# a second line per run in the report's "Per run" (awk, c(column))
PERRUN_AWK='if (c("vbl_answer_avg_ms") != "NA")
  printf "  %-24s vblank answer %s avg %s max ms, %s over 2 ms, %s over 8 ms, %s unanswered; flips %s avg %s max ms after; interval %s, %s changes (%s)\n",
    "", c("vbl_answer_avg_ms"), c("vbl_answer_max_ms"), c("vbl_over_2ms"), c("vbl_over_8ms"), c("vbl_unanswered"),
    c("flip_delay_avg_ms"), c("flip_delay_max_ms"), c("present_interval_start"), c("present_interval_changes"), c("present_interval_values")'

ad_report_begin() { : > "$B/reasons.txt"; : > "$B/watch.txt"; }

# A run's own numbers from hakuX's log (logcat -v time), as name=value
# lines: the replay's window (window=<start s> <end s> <pid>, from "pad
# script: started" to "done") and what it stuttered; 1 when the replay
# didn't run (the run is left out).
ad_report_run() {   # run_dir run variant kind
  rs=$B/reasons.txt; [ "$4" = measure ] || rs=/dev/null   # probes: not in the causes
  # the watched guest word that is the presentation interval (route.sh's
  # debug.hakux.watch; D3D's 0x862494 in Fable), as the watch log writes it
  waddr=$(sed -n 's/^debug.hakux.watch=//p' "$1/run.txt" 2>/dev/null | cut -d, -f1)
  waddr=$(printf '%08x' "$(( ${waddr:-0x862494} ))")
  awk -v run="$2" -v variant="$3" -v reasons="$rs" -v waddr="$waddr" -v watchf="$B/watch.txt" '
    function secs(t,  a) { split(t, a, ":"); return a[1] * 3600 + a[2] * 60 + a[3] }
    function pid(line) { return match(line, /\( *[0-9]+\)/) ? substr(line, RSTART + 1, RLENGTH - 2) + 0 : -1 }
    function msg(line) { sub(/^[^)]*\): /, "", line); return line }
    # a guest word as a number where small (the interval: 1, 2...), else hex
    function word(h,  d, i, c) {
      sub(/^0+/, "", h); if (h == "") return 0
      if (length(h) > 4) return "0x" h
      d = 0; for (i = 1; i <= length(h); i++) { c = index("0123456789abcdef", substr(h, i, 1)) - 1; d = d * 16 + c }
      return d
    }
    /pad script: started/ { t0 = secs($2); started = 1; spid = pid($0); next }
    # the watch: each process logs the word once at its start, then on each
    # change; the replaying process: its first value is the start, its changes
    # inside the window are counted (the log comes before the window filter)
    /hakuX-native-watch/ && / = [0-9a-f]+ \(was [0-9a-f]+\) at vblank/ {
      m = msg($0); split(m, wv, " ")
      if (wv[1] != waddr) next
      p = pid($0); val = word(wv[3])
      if (!(p in wfirst)) { wfirst[p] = val; next }
      if (started && !done && p == spid) {
        pich++; pivals = pivals (pivals == "" ? wfirst[p] : "") ">" val
        rt = secs($2) - t0; if (rt < 0) rt += 86400      # seconds into the replay
        print run "\t" variant "\t" $2 "\t" word(substr(wv[5], 1, 8)) "\t" val "\t" wv[8] "\t" sprintf("%.1f", rt) >> watchf
      }
      next
    }
    /pad script: done/ {
      t1 = secs($2)
      if (match($0, /frame [0-9]+, [0-9]+ ms/)) {
        split(substr($0, RSTART, RLENGTH), d, /[ ,]+/); frames = d[2]; ms = d[3]
      }
      done = 1; next
    }
    !started || done { next }
    # FEX code thrown away (the guest wrote over translated code: the Fable pager)
    /translations of .* dropped/ {
      jit++; bk = int((secs($2) - t0) / 10); jb[bk]++; if (jb[bk] > jmax) jmax = jb[bk]
      next
    }
    /hakuX-native-vbl.*vblank answered/ {
      split(msg($0), b, " ")               # vblank answered N times: avg A max M ms, X over 2 ms, ...
      vn += b[3]; vsum += b[3] * b[6]; if (b[8] > vmax) vmax = b[8]
      v2 += b[10]; v8 += b[14]; vmiss += b[18]
      sub(/:$/, "", b[22]); fn += b[22]; fsum += b[22] * b[23]; if (b[25] > fmax) fmax = b[25]
      nvbl++
      next
    }
    /hakuX-native-perf.*last 10 s:/ {
      if (match($0, /work [0-9.]+ ms/)) { split(substr($0, RSTART, RLENGTH), w, " "); work += w[2]; nwork++ }
      next
    }
    /hakuX-hle-hitch/ && /(stutter|HANG) #[0-9]+ frame/ {
      line = $0; sub(/^[^)]*\): /, "", line)    # the message, after "I/tag( pid): "
      hang = line ~ /^HANG/
      if (match(line, /front [0-9.]+ ms after the last \(expected [0-9.]+\)/)) {
        split(substr(line, RSTART, RLENGTH), v, /[ ()]+/); got = v[2]; expd = v[8]
        why = line; sub(/^[^|]*dropped: /, "", why)
      } else if (match(line, /: [0-9.]+ (ms|s) \(expected [0-9.]+/)) {
        split(substr(line, RSTART, RLENGTH), v, /[ ()]+/); got = v[2]; expd = v[5]
        if (v[3] == "s") got *= 1000
        why = substr(line, RSTART + RLENGTH); sub(/^[^)]*\): /, "", why)
      } else next
      sub(/ \|.*$/, "", why); gsub(/[0-9]+(\.[0-9]+)?/, "#", why)
      n++; hangs += hang; over += got - expd; if (got > worst) worst = got
      print variant "\t" got - expd "\t" why >> reasons
      next
    }
    END {
      if (!started) { printf "%s: no \"pad script: started\" (the replay did not run)\n", run > "/dev/stderr"; exit 1 }
      if (!done) { t1 = t0; printf "%s: no \"pad script: done\" (cut short)\n", run > "/dev/stderr" }
      dur = (ms ? ms / 1000 : t1 - t0); if (dur < 0) dur += 86400
      print "window=" t0 " " t1 " " spid
      printf "secs=%.1f\nframes=%d\nfps=%.1f\nstutters=%d\nper_min=%.1f\nover_ms=%.0f\nworst_ms=%.1f\nhangs=%d\nwork_ms=%.2f\n",
        dur, frames, (dur > 0 ? frames / dur : 0), n, (dur > 0 ? n * 60 / dur : 0),
        over, worst, hangs, (nwork ? work / nwork : 0)
      if (nvbl)                            # NA: no vblank log (a build before optimized-test-v3)
        printf "vbl_answer_avg_ms=%.2f\nvbl_answer_max_ms=%.2f\nvbl_over_2ms=%d\nvbl_over_8ms=%d\nvbl_unanswered=%d\nflip_delay_avg_ms=%.2f\nflip_delay_max_ms=%.2f\n",
          (vn ? vsum / vn : 0), vmax, v2, v8, vmiss, (fn ? fsum / fn : 0), fmax
      printf "present_interval_start=%s\npresent_interval_changes=%d\npresent_interval_values=%s\n",
        (spid in wfirst ? wfirst[spid] : "NA"), pich, (pivals == "" ? "-" : pivals)
      print "jit_drops=" jit + 0; print "jit_drops_max_10s=" jmax + 0
    }
  ' "$1/logcat.txt"
}

# The thread whose tid hakuX logs (the vCPU: "thread vCPU: tid N", or its
# performance hint session's "(vCPU N"): "<tid> SDLThread".
ad_report_pin() {   # run_dir pid
  awk -v spid="$2" '
    function pid(line) { return match(line, /\( *[0-9]+\)/) ? substr(line, RSTART + 1, RLENGTH - 2) + 0 : -1 }
    pid($0) == spid && /hakuX-native-perf.*thread vCPU: tid [0-9]+/ { t = $NF }
    pid($0) == spid && /hakuX-native-perf.*hint session: .*\(vCPU [0-9]+/ && !t {
      m = $0; sub(/^.*\(vCPU /, "", m); sub(/[^0-9].*$/, "", m); t = m }
    END { print t + 0 " SDLThread" }' "$1/logcat.txt"
}

# The rest of a run's numbers (name=value lines), in its window: the mods
# applied; the decoder's spin (the last "decoder spin before sleeping" of
# the replay's process; none: its 200 us default), the late interrupts
# (hakuX-native-irq: "line N delivered X ms after it rose: R refusals,
# first <why> (IRQL ...); the guest CPU's thread ran Y ms of it[, waited
# for a host CPU Z ms]", one over 8 ms each) by their first reason, and
# the decoder's statistics lines (hakuX-hle-pb "kicks K words W ... flips
# F": kicks and words since the last line, flips in all).
ad_report_extra() {   # run_dir pid t0 t1
  mods=$(sed -n 's/^mods_applied=//p' "$1/run.txt" 2>/dev/null | tr ' ' '+')
  grep -q '^mods_applied=' "$1/run.txt" 2>/dev/null && mods=${mods:-none}
  echo "mods=${mods:-NA}"
  pbspin=$(sed -n 's/^pbspin_applied=//p' "$1/run.txt" 2>/dev/null)
  awk -v spid="$2" -v t0="$3" -v t1="$4" -v pbspin="$pbspin" '
    function secs(t,  a) { split(t, a, ":"); return a[1] * 3600 + a[2] * 60 + a[3] }
    function pid(line) { return match(line, /\( *[0-9]+\)/) ? substr(line, RSTART + 1, RLENGTH - 2) + 0 : -1 }
    function after(line, key,  i) { i = index(line, key); return i ? substr(line, i + length(key)) + 0 : -1 }
    pid($0) != spid { next }
    /hakuX-hle-pb.*decoder spin before sleeping: / { sp = after($0, "sleeping: ") }
    { t = secs($2); if (t1 < t0 && t < t0) t += 86400 }
    t < t0 || t > (t1 < t0 ? t1 + 86400 : t1) { next }
    /hakuX-native-irq.* delivered [0-9.]+ ms after it rose/ {
      n++; lat = after($0, " delivered "); ls += lat; if (lat > lm) lm = lat
      ran = after($0, "thread ran "); if (ran >= 0) { rs += ran; if (ran > rm) rm = ran }
      hw = after($0, "waited for a host CPU "); if (hw >= 0) hs += hw
      if (index($0, "first an ISR running")) isr++
      else if (index($0, "first interrupts off (IF 0)")) if0++
      else if (index($0, "first IRQL at or above it")) irql++
      else if (index($0, "first none: no kernel entry meanwhile")) none++
      next
    }
    /hakuX-hle-pb.*: kicks [0-9]+ words [0-9]+ / {
      pl++; pk += after($0, ": kicks "); pw += after($0, " words ")
      f = after($0, " flips "); if (pl == 1) f0 = f; f1 = f
      next
    }
    END {
      if (pbspin == "") pbspin = (sp == "" ? 200 : sp)
      printf "pbspin_us=%s\nirq_late=%d\nirq_isr=%d\nirq_if0=%d\nirq_irql=%d\nirq_none=%d\n", pbspin, n, isr, if0, irql, none
      if (n) printf "irq_late_avg_ms=%.1f\nirq_late_max_ms=%.1f\nirq_ran_avg_ms=%.1f\nirq_ran_max_ms=%.1f\nirq_hostwait_avg_ms=%.1f\n", ls / n, lm, rs / n, rm, hs / n
      if (pl) printf "pb_lines=%d\npb_kicks=%d\npb_words=%d\npb_flips=%d\n", pl, pk, pw, f1 - f0; else print "pb_lines=0"
    }' "$1/logcat.txt"
}

# The report's own sections (route_report.sh: $SUM, awk with COLS: c(name)).
ad_section_vblanks() {
  echo "Vblanks (the title's handler answering each vblank, and its flips after them; averages per run):"
  awk -F, "$COLS"'
    c("kind") == "measure" && c("vbl_answer_avg_ms") != "NA" { v = c("variant"); if (!(v in runs)) order[++nv] = v
      runs[v]++; a[v] += c("vbl_answer_avg_ms"); if (c("vbl_answer_max_ms") > mx[v]) mx[v] = c("vbl_answer_max_ms")
      o2[v] += c("vbl_over_2ms"); o8[v] += c("vbl_over_8ms"); un[v] += c("vbl_unanswered")
      fa[v] += c("flip_delay_avg_ms"); if (c("flip_delay_max_ms") > fm[v]) fm[v] = c("flip_delay_max_ms")
      pc[v] += c("present_interval_changes") }
    END {
      if (!nv) { print "  (no vblank log: the build is older than optimized-test-v3)"; exit }
      printf "%-22s %4s %9s %9s %9s %9s %11s %10s %10s %10s\n", "variant", "runs", "answer ms", "worst ms", ">2 ms", ">8 ms", "unanswered", "flip ms", "flip worst", "PI changes"
      for (i = 1; i <= nv; i++) { v = order[i]; r = runs[v]
        printf "%-22s %4d %9.2f %9.2f %9.1f %9.1f %11.1f %10.2f %10.2f %10.1f\n", v, r, a[v] / r, mx[v], o2[v] / r, o8[v] / r, un[v] / r, fa[v] / r, fm[v], pc[v] / r }
    }' "$SUM"
}

ad_section_jitdisplay() {
  echo "JIT and display (averages per run; SF = what SurfaceFlinger presented of hakuX's layer, gaps = over 1.5x the median frame interval):"
  awk -F, "$COLS"'
    function add(k, x) { if (x != "NA") { s[k, v] += x; n[k, v]++ } }
    function avg(k, f) { return n[k, v] ? sprintf(f, s[k, v] / n[k, v]) : "NA" }
    c("kind") == "measure" { v = c("variant"); if (!(v in seen)) { seen[v] = 1; order[++nv] = v }
      add("jit_drops", c("jit_drops")); add("jit_drops_max_10s", c("jit_drops_max_10s")); add("sf_frames", c("sf_frames")); add("sf_gaps", c("sf_gaps"))
      if (c("sf_worst_gap_ms") != "NA" && c("sf_worst_gap_ms") > wst[v]) wst[v] = c("sf_worst_gap_ms"); add("sf_median_ms", c("sf_median_ms"))
      if (!((v, c("sf_source")) in src)) { src[v, c("sf_source")] = 1; srcs[v] = srcs[v] (srcs[v] == "" ? "" : "+") c("sf_source") }
      if (!((v, c("mods")) in md)) { md[v, c("mods")] = 1; mods[v] = mods[v] (mods[v] == "" ? "" : " ") c("mods") } }
    END {
      printf "%-22s %7s %9s %9s %8s %9s %9s %10s %-10s %s\n", "variant", "JIT", "JIT/10s", "SF frames", "SF gaps", "SF worst", "SF median", "", "SF source", "mods applied"
      for (i = 1; i <= nv; i++) { v = order[i]
        printf "%-22s %7s %9s %9s %8s %9s %9s %10s %-10s %s\n", v, avg("jit_drops", "%.0f"), avg("jit_drops_max_10s", "%.0f"), avg("sf_frames", "%.0f"), avg("sf_gaps", "%.0f"),
          (v in wst) ? sprintf("%.1f", wst[v]) : "NA", avg("sf_median_ms", "%.1f"), "", srcs[v], mods[v] }
    }' "$SUM"
}

ad_section_irq() {
  echo "Late interrupts (hakuX-native-irq: delivered over 8 ms after the line rose; per run; by the first reason the kernel couldn't deliver it):"
  awk -F, "$COLS"'
    function add(k, x) { if (x != "NA") { s[k, v] += x; n[k, v]++ } }
    function avg(k, f) { return n[k, v] ? sprintf(f, s[k, v] / n[k, v]) : "NA" }
    c("kind") == "measure" { v = c("variant"); if (!(v in seen)) { seen[v] = 1; order[++nv] = v }
      split("irq_late irq_isr irq_if0 irq_irql irq_none irq_late_avg_ms irq_ran_avg_ms irq_hostwait_avg_ms", ks, " ")
      for (i = 1; i <= 8; i++) add(ks[i], c(ks[i]))
      if (c("irq_late_max_ms") != "NA" && c("irq_late_max_ms") > lm[v]) lm[v] = c("irq_late_max_ms")
      if (c("irq_ran_max_ms") != "NA" && c("irq_ran_max_ms") > rm[v]) rm[v] = c("irq_ran_max_ms") }
    END {
      printf "%-22s %6s %6s %6s %6s %6s %9s %9s %9s %9s %11s\n", "variant", "late", "ISR", "IF 0", "IRQL", "none", "late avg", "late max", "ran avg", "ran max", "host wait"
      for (i = 1; i <= nv; i++) { v = order[i]
        printf "%-22s %6s %6s %6s %6s %6s %9s %9s %9s %9s %11s\n", v, avg("irq_late", "%.1f"), avg("irq_isr", "%.1f"), avg("irq_if0", "%.1f"), avg("irq_irql", "%.1f"), avg("irq_none", "%.1f"),
          avg("irq_late_avg_ms", "%.1f"), (v in lm) ? sprintf("%.1f", lm[v]) : "NA", avg("irq_ran_avg_ms", "%.1f"), (v in rm) ? sprintf("%.1f", rm[v]) : "NA", avg("irq_hostwait_avg_ms", "%.1f") }
      print "  (late: lines a run; ISR = an ISR running, IF 0 = interrupts off, IRQL = IRQL at or above it, none = no kernel entry"
      print "   meanwhile; ran = ms the guest CPU'"'"'s thread ran of the delay; host wait = ms it waited for a host CPU)"
    }' "$SUM"
}

ad_section_decoder() {
  echo "Decoder (hle-pb thread from schedstat, ms per run; hakuX-hle-pb statistics lines summed over the replay):"
  awk -F, "$COLS"'
    function add(k, x) { if (x != "NA") { s[k, v] += x; n[k, v]++ } }
    function avg(k) { return n[k, v] ? sprintf("%.0f", s[k, v] / n[k, v]) : "NA" }
    c("kind") == "measure" { v = c("variant"); if (!(v in seen)) { seen[v] = 1; order[++nv] = v }
      if (!((v, c("pbspin_us")) in sp)) { sp[v, c("pbspin_us")] = 1; sps[v] = sps[v] (sps[v] == "" ? "" : "/") c("pbspin_us") }
      split("decode_run_ms decode_wait_ms vcpu_run_ms vcpu_wait_ms pb_lines pb_kicks pb_words pb_flips", ks, " ")
      for (i = 1; i <= 8; i++) add(ks[i], c(ks[i])) }
    END {
      printf "%-22s %10s %9s %9s %9s %9s %8s %9s %12s %8s\n", "variant", "pbspin us", "pb run", "pb wait", "vCPU run", "vCPU wait", "pb lines", "kicks", "words", "flips"
      for (i = 1; i <= nv; i++) { v = order[i]
        printf "%-22s %10s %9s %9s %9s %9s %8s %9s %12s %8s\n", v, sps[v], avg("decode_run_ms"), avg("decode_wait_ms"), avg("vcpu_run_ms"), avg("vcpu_wait_ms"),
          avg("pb_lines"), avg("pb_kicks"), avg("pb_words"), avg("pb_flips") }
    }' "$SUM"
}

# Every change of the watched presentation interval (0x862494) during the
# replays, with its time into the replay, per scene, Lookout Point first;
# 2 or 0x80000002: Fable itself asked for 30 fps there.
ad_section_watch() {
  waddr_all=$(sed -n 's/^debug.hakux.watch=//p' "$B"/*/run.txt 2>/dev/null | sort -u | tr '\n' ' ' | sed 's/ $//')
  waddr_all=${waddr_all:-0x862494}
  echo "Presentation interval changes during the replays (the watch, $waddr_all; per scene, Lookout Point first):"
  if [ -s "$B/watch.txt" ]; then
    awk -F'\t' '
      { sc = $2; sub(/\/.*/, "", sc); if (!(sc in seen)) { seen[sc] = 1; order[++ns] = sc }
        line[sc, ++n[sc]] = $0
        if ($5 == "2" || $5 == "0x80000002") { thirty[sc]++; runs30[sc, $1] = 1 } }
      function show(sc,  i, f, note) {
        printf "  %s (%s): %d changes, %d to 30 fps\n", (sc == "lookout" ? "Lookout Point" : sc), sc, n[sc], thirty[sc]
        for (i = 1; i <= n[sc]; i++) {
          split(line[sc, i], f, "\t")
          note = (f[5] == "2" || f[5] == "0x80000002") ? "   <- Fable asked for 30 fps" : ""
          printf "    %-28s +%6s s  %s > %s  (%s, vblank %s)%s\n", f[1], f[7], f[4], f[5], f[3], f[6], note
        }
      }
      END { if ("lookout" in seen) show("lookout")
            for (j = 1; j <= ns; j++) if (order[j] != "lookout") show(order[j]) }' "$B/watch.txt"
  else
    echo "  none"
  fi
}

ad_section_causes() {
  echo "Commonest causes (count, ms over the expected frame time in all; per variant):"
  awk -F'\t' '{ k = $1 "\t" $3; if (!(k in n)) keys[++nk] = k; n[k]++; ms[k] += $2 }
    END { for (i = 1; i <= nk; i++) { k = keys[i]; split(k, p, "\t")
            printf "%s\t%d\t%.0f\t%s\n", p[1], n[k], ms[k], p[2] } }' "$B/reasons.txt" |
    sort -t "$(printf '\t')" -k1,1 -k3,3nr |
    awk -F'\t' '{ if ($1 != last) { print "  " $1 ":"; shown = 0; last = $1 }
                  if (shown++ < 8) printf "    %4d x %7s ms  %s\n", $2, $3, $4 }'
}
