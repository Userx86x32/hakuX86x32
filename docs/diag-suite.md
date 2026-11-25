# hakuX diagnostics suite (Fable, Galaxy S24+)

A plan for the automation runner (the `diag-results` uploads): what to collect
on every run, which deep-dive runs to add, and which variants to test, each
aimed at a possible cause of stutters and dropped frames. Built for 30-minute
batches in two scenes, Bowerstone and Great Wood.

## Principles

- **Two kinds of runs.** *Measurement runs* collect only cheap data and are the
  only ones counted in A/B statistics. *Probe runs* add heavy collectors
  (Perfetto, simpleperf) to explain what the measurement runs show; their
  stutter counts are not compared, because the collectors cost CPU.
- **One variable per batch.** Run-to-run noise is large (85-112 stutters/min in
  identical runs), so a 30-minute batch tests one change against the baseline.
- **Alternate variants** (A B A B ...) so heat drifts over the batch affect both.
- **Same start temperature.** Cool down between runs until the hottest gpuss
  zone is under 45 C (at most 90 s), and record the start temperature.
- **Survive adb drops.** Push the runner to the phone and start it there
  (`adb shell nohup sh /data/local/tmp/runner.sh ... &`), writing everything
  under `/sdcard/hakux_diag/`; the tower only pulls and uploads the results,
  and resumes pulling after a reconnect. An adb disconnect then doesn't end
  the batch.

## 1. Every run (measurement and probe)

Already collected: hakuX logcat, sensors every 5 s, `run.txt`.

Add:

| What | How | Cause it targets |
|---|---|---|
| Log tags `hakuX-hle-hitch`, `-native-perf`, `-native-vbl`, `-native-watch`, `-native-mods`, `-hle-pipe`, `-native` (the `translations of ... dropped` lines) | logcat filter | stutter causes, vblank latency, interval changes, shader compiles, JIT invalidation |
| `debug.hakux.watch 0x862494` | setprop before launch | Fable changing its presentation interval |
| Sensors **every 1 s**: CPU cur freq per policy, CPU max (cap) per policy, GPU `clock_mhz`, `gpu_busy_percentage`, gpuss 32-39 max. Thermal status every 5 s only (dumpsys is heavy) | sysfs reads in the loop | clocks/caps around a stutter; thermal limits |
| **Per-thread scheduler stats** of the hakuX process at the start and end of the route: `/proc/<pid>/task/<tid>/schedstat` (time on CPU, **time waiting for a CPU**, timeslices) and `comm`; also `/proc/<pid>/task/<tid>/stat` field 39 (last CPU) | `pidof com.rfandango.haku_x.debug`, then cat per tid | host starvation, measured directly: run-queue wait per thread |
| The thread IDs from `hint session: ... (vCPU N, render N, decode N, present N)` | logcat | which tid is which in the stats above |
| **Display timing**: `dumpsys SurfaceFlinger --latency "<layer>"` every 2 s (127 frames each), the layer being hakuX's SurfaceView from `dumpsys SurfaceFlinger --list` | dumpsys | what the compositor (and DeX/HDMI) actually presented vs. what hakuX flipped |
| Display mode at start: `dumpsys display | findstr mActiveMode` (refresh), whether DeX/HDMI is in use | dumpsys | 60 vs 120 Hz output, external display |
| Charging/pass-through at start and end: `dumpsys battery` (AC/USB powered, status, level) and `settings get system pass_through` | dumpsys / settings | heat from charging |
| Build identity: APK name, `lastUpdateTime`, and the `hakuX-native-mods` lines | dumpsys package / logcat | which build and mod ran |
| Count of `cpu: translations of ... dropped` per run, and per 10 s | logcat | FEX code invalidation (Fable's pager) |

Summary columns to add per run: run-queue wait ms per thread (vCPU, render,
decode, present), vblank answer avg / max / over 2 ms / over 8 ms /
unanswered, flip delay avg / max, interval changes, JIT drops, SurfaceFlinger
presented-frame count and gaps over 20 ms, start temperature.

## 2. Probe runs (one or two per batch, not counted in A/B)

**P1: Perfetto system trace (20 s, mid-route).**
`adb shell perfetto -c - --txt -o /data/misc/perfetto-traces/<run>.pftrace`
with a config holding: `linux.ftrace` (`sched/sched_switch`, `sched/sched_wakeup`,
`sched/sched_waking`, `power/cpu_frequency`, `power/cpu_idle`,
`thermal/thermal_temperature`, `power/gpu_frequency`; atrace categories
`gfx`, `view`, `sched`, `freq`), `linux.process_stats`, `linux.sys_stats`,
duration 20000 ms, buffer 128 MB. Copy it to `/sdcard/hakux_diag/` and
upload. Shows each hakuX thread's core placement, wake-up-to-run delay and
clocks around each stutter on one timeline.

**P2: CPU profile (20 s, mid-route).** The debug APK is debuggable, so:
`adb shell simpleperf record -p <pid> -g --duration 20 -o /data/local/tmp/perf.data`
then `simpleperf report -i /data/local/tmp/perf.data --sort dso,symbol --percent-limit 0.5`
and the same with `--sort comm,dso` (per thread). Upload both reports. Shows
where the vCPU's time goes: FEX's JIT code, FEX's dispatcher and compiler,
the HLE (decoder, renderer), the Vulkan driver, the kernel.
(libhakuxcore.so is stripped in the APK, so its symbols may show as
addresses: upload `perf.data` too; it can be symbolized against an
unstripped build.)

**P3: hakuX's HLE profiler (10 s).** `setprop debug.hakux.perfsec 10` then a
new value of `debug.hakux.perf` (e.g. the run name) mid-route; it logs
`hakuX-hle-prof` lines (milliseconds of render back end and submits per
second). Cheap enough for a measurement run, but keep it out of A/B counts.

## 3. Variants (one per batch; baseline = v3, 60 fps mod, X4 on, hints on, async shaders on, prebuild on)

| Batch | Variant (setprop or setting) | Hypothesis tested |
|---|---|---|
| V1 | `debug.hakux.adpf 0` vs 1 | scheduler hints reduce run-queue waits |
| V2 | 40 fps mod vs 60 fps (mod toggle in the app, or two installs) | late flips with frames ready are a 60 fps pacing issue vs. the emulator's |
| V3 | `debug.hakux.asyncpipe 0` vs 1 | skipped draws / pop-in and hitches from shader compiles |
| V4 | first run after an app restart vs. later runs (`am force-stop` before each) | cold caches (shaders, JIT) vs. warm |
| V5 | stock Qualcomm driver vs custom `vulkan.purple` (app setting) | GPU driver behaviour, GPU clock ramp-up |
| V6 | render scale 2x vs 3x (app setting) | GPU headroom: cost of a sharper image |
| V7 | unplugged vs charging (pass-through on) | heat from charging, clock caps |
| V8 | `debug.hakux.vcpucore 0` vs 1 (repeat with more runs) | X4 placement (batch 1: -18% vCPU work, stutters within noise) |

Order: V1, V2, V4 first (they bear on the dominant "flipped late though
ready" stutters); V3, V5 for pop-in and GPU; V6-V8 as time allows.

## 4. 30-minute batch layout

| Minutes | Bowerstone (savestate + route) | Great Wood (savestate + route) |
|---|---|---|
| 0-1 | setup: build check, setprops, sensors on, display mode | |
| 1-13 | A, B, A, B, A, B (about 1:45 route + 15 s load + up to 60 s cool-down each) | |
| 13-14 | P1 Perfetto (baseline) | |
| 14-27 | | A, B, A, B, A, B |
| 27-29 | | P2 simpleperf (baseline) |
| 29-30 | pull, `report.txt`, `summary.csv`, upload | |

If a batch runs long, drop a probe run, not a measurement run. Alternate
the probes between scenes across batches (Perfetto in Great Wood next time).

## 5. What to upload per batch (diag-results, routes/auto-<date>-<time>/)

- `batch.txt`: build (APK name, lastUpdateTime), variant, setprops, display
  mode, charging state, caps at start.
- `report.txt`, `summary.csv`: with the new columns above.
- Per run: `logcat.txt`, `sensors.csv` (1 s), `run.txt`, `schedstat_start.txt`,
  `schedstat_end.txt`, `sflatency.txt`.
- Probe runs: the Perfetto trace, simpleperf reports and `perf.data`.
