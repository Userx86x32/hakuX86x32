# hakuX diagnostics suite (Fable, Galaxy S24+)

What the automation runner (`tools/diag/route.bat` on the PC, `route.sh` on
the phone) collects on every run, which deep-dive runs it adds, and which
variants to test, each aimed at a possible cause of stutters and dropped
frames. Batches run in two scenes, Bowerstone and Great Wood, and upload to
the `diag-results` branch.

Everything is typed on the PC (`C:\hakuX-tests`), never on the phone:
`route.bat` pushes the runner to the phone, starts it there detached, follows
it, and pulls and uploads the results. Settings live in `route.cfg` next to
`route.bat` (start from `tools/diag/route.cfg.example`).

| Command | What it does |
|---|---|
| `route queue` | runs the batches in `queue.txt` (made the first time: V1-V6 and V8, in the order of section 3) one after another. Whenever the phone stops answering adb (Auto Blocker on, cable out, locked, "Allow USB debugging" pending) it waits and says what to check; once the phone answers again it follows a batch still running, uploads one that finished meanwhile, or cleans up and re-runs one that was killed (3 tries). Finished batches are listed in `queue.done`. |
| `route suite A [B]` | the batch below |
| `route auto` | `route suite x4:vcpucore=1 all:vcpucore=0` |
| `route run <route> [runs] [variants]` | one scene (slot `SLOT`), then the probes in `PROBES` |
| `route tour <route> [seconds]` | (re)makes a scene's hands-off route |
| `route record <route>` | records a route you play |
| `route save <slot>` / `route load <slot>` | a savestate of the running game to a slot, or loaded from it |
| `route watch` / `route stop` | follows a batch again after an adb drop / stops it |
| `route clean` | clears the runner's settings on the phone after a cut-off batch |
| `route install` / `route reinstall` | installs the test APK / backs up, uninstalls, installs, restores (for a signing-key mismatch) |
| `route backup` / `route restore` | savestates, settings, GPU driver and save games to and from `hakux-backup.tar` |
| `route pull` / `route upload` | copies the results to the PC / and to the `diag-results` branch |

## Principles

- **Two kinds of runs.** *Measurement runs* collect only cheap data and are the
  only ones counted in A/B statistics. *Probe runs* add heavy collectors
  (Perfetto, simpleperf) to explain what the measurement runs show; their
  stutter counts are not compared, because the collectors cost CPU. The report
  lists them separately and keeps their stutters out of the cause table.
- **One variable per batch.** Run-to-run noise is large (85-112 stutters/min in
  identical runs), so a batch tests one change against the baseline.
- **Alternate variants** (A B A B ...) so heat drifts over the batch affect both.
- **Each run starts from its own variant's settings.** Anything another variant
  set (a property, a core option) is put back before the run.
- **Start temperature.** Before each run, wait until the hottest gpuss zone
  (thermal zones 32-39) is under 45 C, for at most `COOL_MAX` seconds (10),
  and record the start temperature (`run.txt`: `start_gpuss_C`). The game
  runs on during the wait, so waiting barely cools the phone (90 s never got
  it from 50-58 C under 45 C); alternating A and B is what keeps heat fair.
- **Auto Blocker turns itself back on about every 30 minutes** on this phone
  (USB and Wi-Fi debugging alike), ending the batch. A batch of 14 runs takes
  about 25 minutes with the short cool-down; when one is cut off,
  `route queue` waits (beeping about once a minute) until Auto Blocker is
  switched off again, then resumes the same batch: the runs that finished are
  kept and only the cut one is done again.
- **Auto Blocker.** Whether it's on can't be read from adb, but while it's
  on the phone refuses adb completely, so "adb answers" means "Auto Blocker
  is off". `route queue` uses that: it waits whenever adb stops answering and
  carries on by itself once it's back.
- **Survive adb drops.** The runner runs on the phone, detached
  (`setsid nohup`), writing everything under `/sdcard/hakux_diag/routes/`;
  after a reconnect, `route watch` follows it again and pulls and uploads at
  the end. Samsung's Auto Blocker is the exception: when it switches on it
  cuts USB debugging, and Android then ends every process started from adb,
  the runner included. Keep Auto Blocker off during sessions.
- **Phone-side commands that write to `/sdcard` through Android services**
  (`settings`, `cmd`, `run-as`) must go through a pipe (`... | cat > file`):
  Android refuses to let the service write to shared storage directly, and
  the file ends up holding only an error message.

## 1. Every run (measurement and probe)

| What | How | Cause it targets |
|---|---|---|
| Log tags `hakuX-hle-hitch`, `-native-perf`, `-native-vbl`, `-native-watch`, `-native-mods`, `-hle-pipe`, `-native` (the `translations of ... dropped` lines), `-native-usb`, `-app`, `-hle`, `-hle-prof`, `-apu` | logcat filter | stutter causes, vblank latency, interval changes, shader compiles, JIT invalidation |
| `debug.hakux.watch 0x862494` | setprop before each run's savestate load (each new game process reads it) | Fable changing its presentation interval |
| Sensors **every 1 s**: CPU cur freq and max (cap) per policy (0, 2, 5, 7), GPU `clock_mhz`, `max_clock_mhz`, `gpu_busy_percentage`, GPU temp, gpuss 32-39 max, battery temp. Thermal status every 5 s only (dumpsys is heavy) | sysfs reads in a loop | clocks/caps around a stutter; thermal limits |
| **Per-thread scheduler stats** of the game's process at the start and end of the replay: `/proc/<pid>/task/<tid>/schedstat` (time on CPU, **time waiting for a CPU**, timeslices), `stat` field 39 (last CPU), `comm` | `run-as` (the app's own `/proc` entries), piped to `schedstat_start.txt` / `schedstat_end.txt` | host starvation, measured directly: run-queue wait per thread |
| Which tid is which: `thread vCPU: tid N` (and render, decode, present), logged by every build from build 14 on whether performance hints are on or off; older builds only log `hint session: ... (vCPU N, render N, ...)`, which is missing when hints are off | logcat (`hakuX-native-perf`) | names for the stats above |
| **Display timing**: `dumpsys SurfaceFlinger --latency "<layer>"` every 2 s (the last 127 frames each), the layer being hakuX's SurfaceView from `dumpsys SurfaceFlinger --list` (the `(BLAST)` one), found again when it changes | dumpsys, to `sflatency.txt` | what the compositor actually presented vs. what hakuX flipped |
| Display at batch start: `mActiveModeId`, `mActiveSfDisplayMode` and each `DisplayDeviceInfo` (refresh, an external/DeX display) | `dumpsys display \| grep` (on the phone: `grep`, not `findstr`) | 60 vs 120 Hz output, external display |
| Charging at run start and end: `dumpsys battery` (AC/USB powered, status, level, temperature) and any system setting whose name has `pass_through`, `protect_battery` or `charging` | dumpsys / `settings list system \| grep` | heat from charging (Samsung's pass-through setting name isn't documented: the list shows whatever the phone has) |
| Build identity: `versionName`, `lastUpdateTime`, `codePath`, and the `hakuX-native-mods` lines | `dumpsys package` / logcat | which build and mod ran |
| `cpu: translations of ... dropped`: count per run and the most in any 10 s | logcat | FEX code invalidation (Fable's pager) |

Summary columns per run (`summary.csv`): fps, stutters (and per minute), ms
over the frame time, worst frame, hangs, work ms, max gpuss and battery
temperature, the lowest big/prime caps, average cpu7 and GPU clocks; vblank
answer avg / max / over 2 ms / over 8 ms / unanswered, flip delay avg / max;
presentation interval at the start, its changes and values; run kind; start
temperature; run-queue wait ms of the vCPU, render, decode and present
threads and the vCPU's time on a CPU; JIT drops and the most in 10 s;
SurfaceFlinger presented frames, gaps over 20 ms and the longest gap.

## 2. Probe runs (one per scene per batch, not counted in A/B)

Each probe runs for 20 s in the middle of the route, on variant A.

**P1: Perfetto system trace.** `perfetto --txt -c - -o
/data/misc/perfetto-traces/hakux-route.pftrace` with `route_trace.pbtx`:
`linux.ftrace` (`sched/sched_switch`, `sched/sched_waking`,
`sched/sched_wakeup`, `power/cpu_frequency`, `power/cpu_idle`,
`power/gpu_frequency`, `thermal/thermal_temperature`, `thermal/cdev_update`,
`kgsl/kgsl_pwrlevel`, `kgsl/kgsl_clk`; atrace `gfx`, `view`, `input`,
`power`, `sched`, `freq` for the app), `linux.process_stats`,
`linux.sys_stats`, `android.power`; 128 MB buffer; duration set to the probe
length. Copied into the run's folder as `trace.pftrace`. Shows each hakuX
thread's core placement, wake-up-to-run delay and clocks around each stutter
on one timeline. Open it at https://ui.perfetto.dev.

**P2: CPU profile.** The debug APK is debuggable, so simpleperf can profile
it through `run-as` with `--app` (the shell user can't attach to another
app's process with `-p <pid>`):
`simpleperf record --app com.rfandango.haku_x.debug -g -f 1000 --duration 20
-o /data/local/tmp/hakux-perf.data`, then `simpleperf report --sort
dso,symbol --percent-limit 0.5` (`simpleperf_symbols.txt`) and `--sort
comm,dso` (per thread, `simpleperf_threads.txt`). Shows where the vCPU's time
goes: FEX's JIT code, FEX's dispatcher and compiler, the HLE (decoder,
renderer), the Vulkan driver, the kernel. `libhakuxcore.so` is stripped in
the APK, so its symbols may show as addresses: `perf.data` is kept to be
symbolized against an unstripped build.

**P3: hakuX's HLE profiler.** `setprop debug.hakux.perfsec 20`, then a new
value of `debug.hakux.perf` mid-route; it logs `hakuX-hle-prof` lines
(milliseconds of render back end and submits per second). Cheap, but kept out
of A/B counts like the others. Available with `route run` (`PROBES=prof` in
`route.cfg`); `route suite` uses P1 and P2.

In `route suite` the first scene gets P1 and the second P2, swapped every
batch, so both scenes get both probes over two batches.

## 3. Variants (one per batch; baseline = the app's settings: v3, 60 fps mod, X4 on, hints on, async shaders on, prebuild on)

A variant is `label:name=value,name=value`. Properties are set before the
run. The app's settings (render scale, async shaders, prebuild, the GPU
driver, the mods) are passed to the core as start-up options; the runner
overrides them for one run through `debug.hakux.opts` (build 14 and later),
leaving the app's settings untouched.

| Batch | Command (`route suite A B`) | Hypothesis tested |
|---|---|---|
| V1 | `route suite base nohints:adpf=0` | scheduler hints reduce run-queue waits |
| V2 | `route suite fps60:mod=60fps fps40:mod=40fps` | late flips with frames ready are a 60 fps pacing issue vs. the emulator's (`mod=40fps` also sets 120 Hz vblanks, as the mod asks; 40 fps needs a 120 Hz screen to show) |
| V3 | `route suite base async0:asyncpipe=0` | skipped draws / pop-in and hitches from shader compiles |
| V4 | `route suite base cold:cold=1` | cold shader and pipeline caches vs. warm. Every run already starts a fresh emulator process (a savestate load restarts the core), so a process restart alone isn't "cold": `cold=1` deletes the caches (`files/native/hle/`) before the run. The B runs after it then rebuild what the route needs, so B is warm again. |
| V5 | `route suite base sysdrv:driver=system` | GPU driver behaviour, GPU clock ramp-up (the phone's Qualcomm driver vs. the custom `vulkan.purple` from the settings) |
| V6 | `route suite base x3:scale=3` | GPU headroom: cost of a sharper image (baseline 2x) |
| V7 | unplugged vs charging: two batches, `route suite base` once plugged in and once unplugged (start it, then unplug; plug back in for `route watch` to pull and upload) | heat from charging, clock caps |
| V8 | `route suite x4:vcpucore=1 all:vcpucore=0` (`route auto`), with `RUNS=10` | X4 placement (batch 1: -18% vCPU work, stutters within noise) |

Order: V1, V2, V4 first (they bear on the dominant "flipped late though
ready" stutters); V3, V5 for pop-in and GPU; V6-V8 as time allows.

## 4. Batch layout and timing

A run takes about 75 s of route + 15-20 s for the savestate to load + up to
10 s of cool-down, so about 1:45; a probe run the same. Per scene: 6
measurement runs + 1 probe = about 12 minutes. Both scenes: **about 25
minutes**, inside the ~30 minutes Auto Blocker allows. If batches run too long, set `RUNS=4` in
`route.cfg` (A B A B per scene: weaker statistics), or drop a scene
(`SCENES="bower:1"`); keep measurement runs over probe runs.

| Step | Bowerstone (slot 1) | Great Wood (slot 2) |
|---|---|---|
| Start | build check, display mode, charging, caps (`batch.txt`) | |
| Measurement | A, B, A, B, A, B | |
| Probe | P1 Perfetto (P2 next batch) | |
| Measurement | | A, B, A, B, A, B |
| Probe | | P2 simpleperf (P1 next batch) |
| End | report, pull, upload | |

Great Wood needs a savestate in slot 2: until there is one, the scene is
skipped (noted in `batch.txt`). Play to the spot, then `route save 2` on the
PC. The hands-off route for each scene (`bower`, `wood`) is made the first
time it runs and kept; `route tour bower` makes it again, and `route record
wood` (with `SLOT=2` in `route.cfg`) records one you play instead.

## 5. What is uploaded per batch (diag-results, routes/<batch>-<date>-<time>/)

- `batch.txt`: variants, scenes, runs, build (versionName, lastUpdateTime,
  codePath), phone, display mode, charging state, caps at start, skipped scenes.
- `report.txt`, `summary.csv`: with the columns above.
- Per run (`<NN>-<scene>-<label>/`): `logcat.txt`, `sensors.csv` (1 s),
  `run.txt` (variant, kind, settings, start/end time, start temperature,
  charging at start and end), `schedstat_start.txt`, `schedstat_end.txt`,
  `sflatency.txt`.
- Probe runs: `simpleperf_symbols.txt`, `simpleperf_threads.txt`,
  `perfetto.txt` / `simpleperf.txt` (their console output). The Perfetto
  trace (`trace.pftrace`) and `perf.data` are large and stay in
  `C:\hakuX-tests\routes` unless `UPLOAD_TRACES=1` is set before running.

## Requirements

- The hakuX debug APK from build 14 on (`route install`): `debug.hakux.opts`
  for the app-setting variants, the `thread ...: tid` lines.
- Savestates: slot 1 in Bowerstone, slot 2 in Great Wood.
- Git for Windows on the PC for the uploads.
