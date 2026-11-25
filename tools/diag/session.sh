#!/system/bin/sh
# hakuX play-session diagnostics (read-only; no root, no settings changed).
#   sh session.sh start   before launching the game
#   sh session.sh mark "text"   note a moment (e.g. "bowerstone square")
#   sh session.sh stop    after playing
# Output: /sdcard/hakux_diag/<time>/ (logcat.txt, sensors.csv, marks.txt)
D=/sdcard/hakux_diag

case "$1" in
start)
  RUN=$D/$(date +%Y%m%d-%H%M%S)
  mkdir -p "$RUN" && echo "$RUN" > $D/current
  getprop ro.product.model > "$RUN/device.txt"
  getprop ro.build.fingerprint >> "$RUN/device.txt"
  # hakuX's own logs: stutters (hle-hitch) with their cause, mods applied,
  # shader compiles, vblank and display, audio
  nohup logcat -v time -s hakuX-hle-hitch:V hakuX-native:V hakuX-native-mods:V hakuX-app:V \
    hakuX-hle-pipe:V hakuX-hle:V hakuX-hle-prof:V hakuX-apu:V hakuX-native-watch:V hakuX-native-perf:V hakuX-native-vbl:V \
    > "$RUN/logcat.txt" 2>&1 &
  echo $! > "$RUN/pids"
  # clocks, load and temperatures every 5 s (NA where a file can't be read)
  nohup sh -c '
    rd() { v=$(cat "$1" 2>/dev/null); echo "${v:-NA}"; }
    K=/sys/class/kgsl/kgsl-3d0; C=/sys/devices/system/cpu/cpufreq; T=/sys/class/thermal
    echo "time,gpu_mhz,gpu_busy_pct,gpu_temp,cpu0_khz,cpu2_khz,cpu5_khz,cpu7_khz,gpuss_max_mC,battery_dC,thermal_status,gpu_max_mhz,cpu2_max_khz,cpu5_max_khz,cpu7_max_khz"
    while true; do
      g=0; for z in 32 33 34 35 36 37 38 39; do t=$(cat $T/thermal_zone$z/temp 2>/dev/null); [ -n "$t" ] && [ "$t" -gt "$g" ] && g=$t; done
      s=$(dumpsys thermalservice 2>/dev/null | grep -m1 "Thermal Status" | tr -dc 0-9)
      echo "$(date +%H:%M:%S),$(rd $K/clock_mhz),$(rd $K/gpu_busy_percentage),$(rd $K/temp),$(rd $C/policy0/scaling_cur_freq),$(rd $C/policy2/scaling_cur_freq),$(rd $C/policy5/scaling_cur_freq),$(rd $C/policy7/scaling_cur_freq),$g,$(rd /sys/class/power_supply/battery/temp),${s:-NA},$(rd $K/max_clock_mhz),$(rd $C/policy2/scaling_max_freq),$(rd $C/policy5/scaling_max_freq),$(rd $C/policy7/scaling_max_freq)"
      sleep 5
    done' > "$RUN/sensors.csv" 2>&1 &
  echo $! >> "$RUN/pids"
  echo "recording to $RUN"
  ;;
mark)
  RUN=$(cat $D/current) && echo "$(date +%H:%M:%S) $2" >> "$RUN/marks.txt" && echo "marked"
  ;;
stop)
  RUN=$(cat $D/current) || exit 1
  for p in $(cat "$RUN/pids"); do kill "$p" 2>/dev/null; done
  dumpsys battery > "$RUN/battery_end.txt" 2>/dev/null
  echo "stopped; files in $RUN:"; ls -l "$RUN"
  ;;
*)
  echo "usage: sh session.sh start | mark \"text\" | stop"
  ;;
esac
