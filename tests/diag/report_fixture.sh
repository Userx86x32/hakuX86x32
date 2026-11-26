#!/bin/sh
# A hakuX batch made up line by line, for route_report.sh: every log line the
# hakuX adapter parses (stutters of each form, a hang, vblanks, the watch,
# late interrupts of each reason, the decoder, JIT drops, the vCPU's tid),
# sensors, per-thread schedstat, both SurfaceFlinger sources, a probe run, a
# failed run, a run cut short and one that never started.
#   sh tests/diag/report_fixture.sh <new batch dir>
# tests/diag/golden/hakux_{summary.csv,report.txt} are what route_report.sh
# made of it before the runner was split into a core and adapters
# (route_report_test.sh compares).
set -e
B=${1:?usage: report_fixture.sh <batch dir>}
mkdir -p "$B"
printf 'variants=a b\nscenes=lookout:3 bower:1\nruns=2\n' > "$B/batch.txt"

# logcat lines: L <time> <tag> <pid> <message>
L() { printf '11-25 %s I/%s(%5d): %s\n' "$1" "$2" "$3" "$4"; }

# one measurement run's log: pid $1, minute $2 (12:<m>:..), its numbers scaled by $3
runlog() {
  p=$1 m=$2 k=$3
  L "12:$m:05.100" hakuX-native-watch "$p" "00862494 = 00000001 (was 00000000) at vblank 10"
  L "12:$m:05.200" hakuX-native-watch "$p" "00123456 = 00000003 (was 00000001) at vblank 11"
  L "12:$m:05.300" hakuX-native-perf "$p" "thread vCPU: tid $((p + 1))"
  L "12:$m:05.400" hakuX-hle-pb "$p" "decoder spin before sleeping: $((50 * k)) us (debug.hakux.pbspin)"
  L "12:$m:06.000" hakuX-native-usb "$p" "pad script: 3 steps, the last ending at frame 1800 (waits for a savestate's load)"
  L "12:$m:06.250" hakuX-native-usb "$p" "pad script: started (frame 0)"
  L "12:$m:08.000" hakuX-native-watch "$p" "00862494 = 00000002 (was 00000001) at vblank 130"
  L "12:$m:09.000" hakuX-native-watch "$((p + 50))" "00862494 = 00000001 (was 00000000) at vblank 1"
  L "12:$m:10.000" hakuX-native-vbl "$p" "vblank answered 600 times: avg 0.$((40 + k)) max $((3 + k)).20 ms, $((4 * k)) over 2 ms, $k over 8 ms, 0 unanswered; flip delay 590: 1.$((20 + k)) max 6.50 ms"
  L "12:$m:12.000" hakuX-native-perf "$p" "last 10 s: frames 300 work $((10 + k)).5 ms busy 80%"
  L "12:$m:14.000" hakuX-hle-hitch "$p" "stutter #1 frame 240: $((40 + k)).0 ms (expected 33.3): vCPU waited on the GPU 30 ms | q 2"
  L "12:$m:15.000" hakuX-hle-hitch "$p" "stutter #2 frame 300: front 45.5 ms after the last (expected 16.7), 2 dropped: report gate 25 ms | x"
  L "12:$m:16.000" hakuX-hle-hitch "$p" "HANG #3 frame 400: 1.$k s (expected 33.3): vCPU in the guest 1200 ms | y"
  L "12:$m:17.000" hakuX-hle-hitch "$p" "stutter #4 frame 500: 50.0 ms (expected 33.3): vCPU waited on the GPU 12 ms | q 3"
  L "12:$m:18.000" hakuX-native "$p" "FEX: 12 translations of 0x00401000 dropped (code written)"
  L "12:$m:18.500" hakuX-native "$p" "FEX: 3 translations of 0x00402000 dropped (code written)"
  L "12:$m:31.000" hakuX-native "$p" "FEX: 1 translations of 0x00403000 dropped (code written)"
  L "12:$m:20.000" hakuX-native-irq "$p" "line 3 delivered 12.5 ms after it rose: 2 refusals, first IRQL at or above it (IRQL 26, ISR line -1, thread t4); the guest CPU's thread ran 3.0 ms of it, waited for a host CPU 9.0 ms"
  L "12:$m:21.000" hakuX-native-irq "$p" "line 1 delivered 9.$k ms after it rose: 1 refusals, first an ISR running (IRQL 2); the guest CPU's thread ran 8.0 ms of it"
  L "12:$m:22.000" hakuX-native-irq "$p" "line 1 delivered 20.0 ms after it rose: 3 refusals, first interrupts off (IF 0); the guest CPU's thread ran 1.5 ms of it, waited for a host CPU 0.5 ms"
  L "12:$m:23.000" hakuX-native-irq "$p" "line 4 delivered 8.5 ms after it rose: 1 refusals, first none: no kernel entry meanwhile; the guest CPU's thread ran 2.0 ms of it"
  L "12:$m:23.500" hakuX-native-irq "$((p + 50))" "line 4 delivered 99.0 ms after it rose: 1 refusals, first none: no kernel entry meanwhile"
  L "12:$m:24.000" hakuX-hle-pb "$p" "kicks $((1000 * k)) words 50000 headers 1 methods 2 faults 0 GET 0 PUT 0 binds 1 semaphores 2 flips 100 traps 0 (x)"
  L "12:$m:34.000" hakuX-hle-pb "$p" "kicks 500 words $((20000 * k)) headers 1 methods 2 faults 0 GET 0 PUT 0 binds 1 semaphores 2 flips 400 traps 0 (x)"
  L "12:$m:36.000" hakuX-native-watch "$p" "00862494 = 80000002 (was 00000002) at vblank 1700"
  L "12:$m:40.000" hakuX-native-vbl "$p" "vblank answered 300 times: avg 0.90 max 9.$k ms, 2 over 2 ms, 1 over 8 ms, 3 unanswered; flip delay 290: 2.00 max 4.0 ms"
}
done_line() { L "12:$2:42.250" hakuX-native-usb "$1" "pad script: done (frame 1800, $3 ms)"; }

# sensors.csv: one row a second from 12:<m>:00 to 12:<m>:50
sensors() {
  echo "time,gpu_mhz,gpu_busy_pct,gpu_temp,cpu0_khz,cpu2_khz,cpu5_khz,cpu7_khz,gpuss_max_mC,battery_dC,thermal_status,gpu_max_mhz,cpu2_max_khz,cpu5_max_khz,cpu7_max_khz,cpu0_max_khz"
  awk -v m="$1" -v k="$2" 'BEGIN { for (s = 0; s <= 50; s++)
    printf "12:%s:%02d,%d,%d,NA,%d,%d,%d,%s,%d,%d,%s,900,%d,%d,%d,2000000\n", m, s, 500 + s * k, 60, 1000000, 2000000, 2100000,
      (s % 7 == 3 ? "NA" : 2900000 - s * 1000), 40000 + s * 200 * k, 350 + s, (s % 5 ? 0 : 1),
      2400000 - s * 1000 * k, 2800000 - s * 2000, 3200000 - s * 500 }'
}

# schedstat: tid run_ns wait_ns slices last_cpu name, at the replay's start and end
sched() {
  p=$1 e=$2 k=$3
  printf '%d %d %d 10 0 SDLActivity\n' "$p" $((5000000000 + e * 900000000 * k)) $((100000000 + e * 40000000))
  printf '%d %d %d 10 7 SDLThread\n' $((p + 1)) $((9000000000 + e * 30000000000 * k)) $((200000000 + e * 2500000000))
  printf '%d %d %d 10 6 SDLThread\n' $((p + 2)) $((1000000000 + e * 31000000000)) $((100000000 + e * 100000000))
  printf '%d %d %d 10 5 hle-pb\n' $((p + 3)) $((2000000000 + e * 12000000000)) $((300000000 + e * 1700000000 * k))
  printf '%d %d %d 10 4 hle.render\n' $((p + 4)) $((3000000000 + e * 8000000000)) $((50000000 + e * 600000000))
  printf '%d %d %d 10 3 apu.frame\n' $((p + 5)) $((4000000000 + e * 2000000000)) $((10000000 + e * 90000000))
  printf '%d %d %d 10 2 Binder:%d_2\n' $((p + 6)) $((100000000 + e * 100000000)) 0 "$p"
  [ "$e" = 1 ] && printf '%d %d %d 10 1 hle-pb\n' $((p + 7)) 500000000 400000000   # started after the first snapshot
  [ "$e" = 1 ] && printf '%d %d %d 10 1 hle.render\n' $((p + 8)) 1 1                 # (a tid reused: below its start)
  [ "$e" = 0 ] && printf '%d %d %d 10 1 old\n' $((p + 8)) 999999999999 999999999999
  :
}

# sflatency.txt: a block every 2 s (12:<m>:06 to :44), each the last 127
# frames before it, 16.7 ms apart with a 50 ms gap every 60 frames; present
# times on a monotonic clock 1000 s behind... a fixed offset
sflat() {
  awk -v m="$1" 'BEGIN {
    for (s = 6; s <= 44; s += 2) {
      printf "## 12:%s:%02d SurfaceView[com.rfandango.haku_x.debug/com.rfandango.haku_x.MainActivity]@0(BLAST)#3%d\n", m, s, m
      print "16666666"
      end = (s - 0.5) * 1e9 + 1000e9           # the newest frame half a second before the block
      for (i = 126; i >= 0; i--) {
        f = int((end - 1000e9) / 16666667) - i
        t = 1000e9 + f * 16666667 + int(f / 60) * 33333333
        printf "%d\t%d\t%d\n", t - 5000000, t, t - 1000000
      }
      print "0\t9223372036854775807\t0"         # a pending frame: skipped
    }
  }'
}

timestats() {
  printf 'SurfaceFlinger TimeStats:\nlayerName = com.other/Main#1\ntotalFrames = 9000\npresent2present histogram is as below:\n16ms=9000\n'
  printf 'layerName = SurfaceView[com.rfandango.haku_x.debug/x]@0(BLAST)#12\ntotalFrames = 1500\n'
  printf 'present2present histogram is as below:\n0ms=0 16ms=1300 17ms=120 33ms=60 50ms=15 100ms=5\n'
  printf 'layerName = SurfaceView[com.rfandango.haku_x.debug/x]@0(BLAST)#11\ntotalFrames = 20\n'
  printf 'present2present histogram is as below:\n16ms=20\n'
}

run() {   # dir variant kind scene pid minute k done_ms
  R=$B/$1; mkdir -p "$R"
  {
    echo "variant=$2"; echo "kind=$3"; echo "scene=$4"; echo "slot=1"; echo "debug.hakux.watch=0x862494"
    echo "mods_expected=60fps"; echo "mods_required=60fps"; echo "start=Wed Nov 25 12:$6:00 UTC 2026"
    echo "start_gpuss_C=$((38 + $7))"; echo "mods_applied=60fps"
  } > "$R/run.txt"
  { runlog "$5" "$6" "$7"; [ -z "$8" ] || done_line "$5" "$6" "$8"; } > "$R/logcat.txt"
}

run 01-lookout-a a measure lookout 1001 10 1 36000
sensors 10 1 > "$B/01-lookout-a/sensors.csv"
sched 1001 0 1 > "$B/01-lookout-a/schedstat_start.txt"; sched 1001 1 1 > "$B/01-lookout-a/schedstat_end.txt"
sflat 10 > "$B/01-lookout-a/sflatency.txt"
echo "pbspin_applied=50" >> "$B/01-lookout-a/run.txt"

run 02-lookout-b b measure lookout 2001 11 2 36100
sensors 11 2 > "$B/02-lookout-b/sensors.csv"
sched 2001 0 2 > "$B/02-lookout-b/schedstat_start.txt"; sched 2001 1 2 > "$B/02-lookout-b/schedstat_end.txt"
printf '## 12:11:20 \n' > "$B/02-lookout-b/sflatency.txt"     # no layer listed: timestats instead
timestats > "$B/02-lookout-b/sftimestats.txt"

run 03-lookout-a a measure lookout 3001 12 3 35900
sensors 12 3 > "$B/03-lookout-a/sensors.csv"
sflat 12 > "$B/03-lookout-a/sflatency.txt"
sed -i 's/^mods_applied=60fps$/mods_applied=/' "$B/03-lookout-a/run.txt"

run 04-lookout-probe-perfetto a perfetto lookout 4001 13 1 36000
printf 'probe_exit=0\nprobe_output_bytes=12345\n' >> "$B/04-lookout-probe-perfetto/run.txt"
echo trace > "$B/04-lookout-probe-perfetto/trace.pftrace"

run 05-bower-a a measure bower 5001 14 2 36000
sensors 14 1 > "$B/05-bower-a/sensors.csv"
sched 5001 0 1 > "$B/05-bower-a/schedstat_start.txt"; sched 5001 1 1 > "$B/05-bower-a/schedstat_end.txt"

run 06-bower-b b measure bower 6001 15 1 ""                    # cut short: no "pad script: done"

run 07-bower-a a measure bower 7001 16 1 36000
echo "failed=mods: the variant's are '60fps', the core applied 'none'" >> "$B/07-bower-a/run.txt"

mkdir -p "$B/08-bower-b"                                          # the replay never started
printf 'variant=b\nkind=measure\nscene=bower\n' > "$B/08-bower-b/run.txt"
L "12:17:00.000" hakuX-native-usb 8001 "pad script: 3 steps" > "$B/08-bower-b/logcat.txt"

run 09-bower-probe-simpleperf a simpleperf bower 9001 18 1 36000
printf 'probe_exit=0\nprobe_output_bytes=777\nprobe_Samples=4000\n' >> "$B/09-bower-probe-simpleperf/run.txt"
echo "simpleperf: some output" > "$B/09-bower-probe-simpleperf/simpleperf.txt"
echo data > "$B/09-bower-probe-simpleperf/perf.data"
