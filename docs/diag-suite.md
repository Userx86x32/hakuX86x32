# hakuX diagnostics suite (Fable, Galaxy S24+)

What the automation runner (`tools/diag/route.bat` on the PC, `route.sh` on
the phone) collects on every run, which deep-dive runs it adds, and which
variants to test, each aimed at a possible cause of stutters and dropped
frames. Batches run in two scenes, Bowerstone and Great Wood, and upload to
the `diag-results` branch.

The runner is a core and an adapter per emulator; this suite is the hakuX
adapter's (`tools/diag/adapters/hakux.sh`, the default; `tools/diag/README.md`
for the others and for writing one).

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
| `route install` / `route reinstall` | installs the test APK / backs up (savestates, settings, the mod choices `files/mod_choices.json`, GPU driver, saves), uninstalls, installs, restores and checks the mod choices came back (for a signing-key mismatch) |
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
| Log tags `hakuX-hle-hitch`, `-native-perf`, `-native-vbl`, `-native-watch`, `-native-mods`, `-hle-pipe`, `-native` (the `translations of ... dropped` lines), `-native-usb`, `-app`, `-hle`, `-hle-prof`, `-apu`, `-native-irq`, `-hle-pb` | logcat filter | stutter causes, vblank latency, interval changes, shader compiles, JIT invalidation, late interrupts, the decoder's statistics and spin |
| `NC_IRQ_SCHED=1` (`IRQ_SCHED` in `route.cfg`) | `debug.hakux.env2`, beside the replay's `NC_PAD_STATE=1`, set before every run (read at game start; `debug.hakux.env` holds the replay's path and a property holds 91 characters); checked in the run's `debug.hakux.env:` log lines | a late interrupt's guest thread: waiting for a host CPU, or blocked |
| `debug.hakux.watch 0x862494` | setprop before each run's savestate load (each new game process reads it) | Fable changing its presentation interval |
| Sensors **every 1 s**: CPU cur freq and max (cap) per policy (0, 2, 5, 7), GPU `clock_mhz`, `max_clock_mhz`, `gpu_busy_percentage`, GPU temp, gpuss 32-39 max, battery temp. Thermal status every 5 s only (dumpsys is heavy) | sysfs reads in a loop | clocks/caps around a stutter; thermal limits |
| **Per-thread scheduler stats** of the game's process at the start and end of the replay: `/proc/<pid>/task/<tid>/schedstat` (time on CPU, **time waiting for a CPU**, timeslices), `stat` field 39 (last CPU), `comm`; lines `<tid> <run_ns> <wait_ns> <slices> <last_cpu> <name>` | `run-as` (the app's own `/proc` entries), piped to `schedstat_start.txt` / `schedstat_end.txt` | host starvation, measured directly: run-queue wait per thread |
| Which thread is which: by name. `SDLThread` (the vCPU: the tid hakuX logs as `thread vCPU: tid N` from build 14 on, else the busiest `SDLThread`), `hle-pb` (decoder), `hle.render`, `SDLActivity` (the app's main thread), `apu.frame`; a name several threads share: the busiest | the schedstat files' names (logcat `hakuX-native-perf` for the vCPU's tid where logged) | names for the stats above |
| **Display timing**: `dumpsys SurfaceFlinger --latency "<layer>"` every 2 s (the last 127 frames each). The layer name must be exact, its `#<id>` included (`SurfaceView[com.rfandango.haku_x.debug/com.rfandango.haku_x.NativeCoreActivity]@0(BLAST)#30759`): it is cut out of `dumpsys SurfaceFlinger --list`'s line (`RequestedLayerState{... parentId=...}` on Android 14+) and read again every time (each run's process makes a new layer; the newest `(BLAST)` one). Also `dumpsys SurfaceFlinger --timestats` over the run (`-clear -enable` at the start, `-dump` at the end), the report's fallback | dumpsys, to `sflatency.txt` and `sftimestats.txt` | what the compositor actually presented vs. what hakuX flipped |
| Display at batch start: `mActiveModeId`, `mActiveSfDisplayMode` and each `DisplayDeviceInfo` (refresh, an external/DeX display) | `dumpsys display \| grep` (on the phone: `grep`, not `findstr`) | 60 vs 120 Hz output, external display |
| Charging at run start and end: `dumpsys battery` (AC/USB powered, status, level, temperature) and any system setting whose name has `pass_through`, `protect_battery` or `charging` | dumpsys / `settings list system \| grep` | heat from charging (Samsung's pass-through setting name isn't documented: the list shows whatever the phone has) |
| Build identity: `versionName`, `lastUpdateTime`, `codePath`, the installed APK's sha256 and, when it is the one `route install` installed, its file name with the branch, build number and commit in it (`apk_file`, `apk_branch`, `apk_build`, `apk_commit`); and the `hakuX-native-mods` lines | `dumpsys package`, `pm path` + `sha256sum`, route.bat's record (`route.sh apkrecord`) / logcat | which build and mod ran |
| **The 60 fps mod in every run** (`REQUIRED_MODS`, `60fps` by default): unless its variant sets `mod=`, a run must log `60fps: [default.xbe] 0003f776: 10 bytes`; without it the run fails (the app's mod choices had lost it: the v5 batches ran without it after a reinstall, the log only saying "savestate made with other mods ... 1 of its mods taken back"). The preflight checks it too, so the queue doesn't start | logcat | a baseline that isn't the baseline |
| **Run check**: once the replay starts, the mods the game's process applied (its `hakuX-native-mods` `<mod>: [xbe] ...: N bytes` lines) must be the variant's (`mods_expected` / `mods_applied` in `run.txt`), and a variant's `debug.hakux.opts` must have been read (`hakuX-app` `debug.hakux.opts:` lines). A run that fails gets `failed=` in `run.txt`, is cut short and kept out of the report (listed under "Failed runs"); a variant failing twice stops the batch | logcat | a variant that didn't take effect |
| `cpu: translations of ... dropped`: count per run and the most in any 10 s | logcat | FEX code invalidation (Fable's pager) |

Summary columns per run (`summary.csv`): fps, stutters (and per minute), ms
over the frame time, worst frame, hangs, work ms, max gpuss and battery
temperature, the lowest big/prime caps, average cpu7 and GPU clocks; vblank
answer avg / max / over 2 ms / over 8 ms / unanswered, flip delay avg / max;
presentation interval at the start, its changes and values; run kind; start
temperature; ms on a CPU and waiting for one of the vCPU (`SDLThread`),
decoder (`hle-pb`), `hle.render`, main (`SDLActivity`) and `apu.frame`
threads; JIT drops and the most in 10 s; SurfaceFlinger presented frames,
gaps over 1.5 times the median frame interval, the longest gap, the median
interval and the source (`latency`, or `timestats` when the latency samples
held no frames); the mods the run applied; the decoder's spin (`pbspin_us`);
the late interrupts (`hakuX-native-irq` "line N delivered X ms after it
rose" lines: count, by first reason: an ISR running / interrupts off (IF 0)
/ IRQL at or above it / none: no kernel entry meanwhile; delay avg and max;
the guest CPU's thread's "ran Y ms of it" avg and max; host CPU wait avg);
the `hakuX-hle-pb` statistics lines (count, kicks and words summed, flips
over the replay). `report.txt` shows them in "Late interrupts" and
"Decoder" (with `hle-pb`'s run and wait time beside the spin). `report.txt` also lists every presentation
interval change the watch (`0x862494`) saw during the replays, per scene
(Lookout Point first), with its time into the replay; a change to 2 or
`0x80000002` is marked: Fable itself asked for 30 fps there.

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
driver) are passed to the core as start-up options; the runner overrides
them for one run through `debug.hakux.opts` (builds after 14: build 14 reads
the property but mixes up the app's own options), leaving the app's
settings untouched. Mods are switched in the app's per-game mod choices
instead (any build), and put back at the end.

| Batch | Command (`route suite A B`) | Hypothesis tested |
|---|---|---|
| V1 | `route suite base nohints:adpf=0` | scheduler hints reduce run-queue waits |
| V2 | `route suite fps60:mod=60fps fps40:mod=40fps` | late flips with frames ready are a 60 fps pacing issue vs. the emulator's (`mod=<id>` turns that mod on and every other mod of the game off in the app's own mod choices, `files/mod_choices.json`, which each new game process reads; the 40 fps mod asks for 120 Hz vblanks itself; 40 fps needs a 120 Hz screen to show. The choices are put back after the batch) |
| V3 | `route suite base async0:asyncpipe=0` | skipped draws / pop-in and hitches from shader compiles |
| V4 | `route suite base cold:cold=1` | cold shader and pipeline caches vs. warm. Every run already starts a fresh emulator process (a savestate load restarts the core), so a process restart alone isn't "cold": `cold=1` deletes the caches (`files/native/hle/`) before the run. The B runs after it then rebuild what the route needs, so B is warm again. |
| V5 | `route suite base sysdrv:driver=system` | GPU driver behaviour, GPU clock ramp-up (the phone's Qualcomm driver vs. the custom `vulkan.purple` from the settings) |
| V6 | `route suite base x3:scale=3` | GPU headroom: cost of a sharper image (baseline 2x) |
| V7 | unplugged vs charging: two batches, `route suite base` once plugged in and once unplugged (start it, then unplug; plug back in for `route watch` to pull and upload) | heat from charging, clock caps |
| V8 | `route suite x4:vcpucore=1 all:vcpucore=0` (`route auto`), with `RUNS=10` | X4 placement (batch 1: -18% vCPU work, stutters within noise) |
| V9 (v4) | `route suite spin200:pbspin=200 spin0:pbspin=0`, later `spin200:pbspin=200 spin50:pbspin=50` | the decoder's spin before sleeping (`debug.hakux.pbspin`, us; 200 is the default) keeps a fast core busy beside the vCPU (`hle-pb` run time). Read within a second; reset to `""` at the end. Each run checks the decoder's `decoder spin before sleeping: N us` line (logged only when it isn't 200: no line is 200) |
| V10 (v4) | `route suite base1 base2` | no variant: the noise between two identical halves, with the new logging |
| V11 | `route suite scenes=lookout:3,wood:2 base:vcpucore=0 nogate:vcpucore=0,env=HAKUX_HLE_PB_VISGATE=0` | the decoder's visibility (report) gate: off in B. `env=` goes into `debug.hakux.env2` after `NC_PAD_STATE=1;NC_IRQ_SCHED=1` (read at game start) and is checked in the game's `debug.hakux.env:` lines |
| V12 | `route suite scenes=lookout:3 base1:vcpucore=0 base2:vcpucore=0` | Lookout Point's noise between two identical halves |

**Lookout Point** (slot 3): a savestate on the path from Bowerstone South
towards Lookout Point, just before the uphill slope with the trees (`route
save 3` there), and a route recorded through the slope, 45-60 s (`route
record lookout 3`; a scene outside `TOUR_SCENES`, so no hands-off tour is
made for it: a batch with it and no recorded route doesn't start). Three
scenes take about 34 minutes (bower and wood 75 s routes, lookout ~55 s,
each 6 runs + a probe, ~30 s a run for the load and cool-down), over Auto
Blocker's 30, so these batches run Lookout Point and Great Wood only
(`scenes=` before the variants; `runs=N` likewise). The runner prints its
estimate at the start.

**Properties put back.** At the end of a batch the runner sets back the
properties it saved at the start (`debug.hakux.vcpucore`, `adpf`, the
variants' others; empty if they were unset) and prints them ("put back:").
A batch Auto Blocker killed couldn't: its saved values are kept, and
`route clean` (which the queue runs before each try) or the next batch puts
them back first, so the variant's value (`vcpucore=0` after the X4 batch)
isn't taken for the phone's own.

**v4 queue** (`queue.txt` made by `route queue`; delete an old `queue.txt`
and `queue.done` to get it): V9 (200 vs 0), V8 (`vcpucore` 1 vs 0, 6 runs),
V10, then V9 with 50.

**The APK** is a build of `claude/eager-franklin-417v0b` (release
`build-claude-eager-franklin-417v0b-<n>`: this runner's native side merged
with `optimized-test-v4`'s `debug.hakux.pbspin`), not `optimized-test-v4`'s
own builds: they lack `NC_PAD_STATE`, so a replay wouldn't wait for the
savestate's load. `route install <file or URL>` downloads it into the test
folder under its own name and records that name for `batch.txt`.

**Preflight.** `route queue` first runs `route.sh preflight` (unless a batch
is running): one savestate load of the first scene with a savestate,
checking that the replay's `pad script: ... (waits for a savestate's load)`
line is there and that `debug.hakux.env2` held `NC_IRQ_SCHED=1` and the game
logged `debug.hakux.env: NC_IRQ_SCHED=1` (the app logs both properties'
entries under that one prefix: the runner's own `debug.hakux.env2=` record
tells them apart). It names the installed APK. If a check fails, the queue
doesn't start (`preflight.txt` beside route.bat; the log in
`routes/preflight/`). Every run is checked the same way.

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
  codePath, the APK's sha256, file name, branch, build number, commit), phone, display mode, charging state, caps at start, skipped scenes.
- `report.txt`, `summary.csv`: with the columns above.
- Per run (`<NN>-<scene>-<label>/`): `logcat.txt`, `sensors.csv` (1 s),
  `run.txt` (variant, kind, settings, the mods expected and applied, start/end
  time, start temperature, charging at start and end, `failed=` if its check
  failed), `schedstat_start.txt`, `schedstat_end.txt`, `sflatency.txt`,
  `sftimestats.txt`.
- Probe runs: `simpleperf_symbols.txt`, `simpleperf_threads.txt`; in
  `run.txt` the tool's exit status (`probe_exit`), its output's size
  (`probe_output_bytes`) and simpleperf's sample count; `perfetto.txt` /
  `simpleperf.txt` (their console output) only when they printed something. The Perfetto
  trace (`trace.pftrace`) and `perf.data` are large and stay in
  `C:\hakuX-tests\routes` unless `UPLOAD_TRACES=1` is set before running.

## Signing

Every build is signed with the repository's debug key (the secret
`DEBUG_KEYSTORE_B64`, certificate SHA-256 `2C3E189E…6C67C9D` in
`.github/workflows/build-apk.yml`), so each installs over the last. The
workflow fails without the secret or with another key in it, and checks the
APK's certificate with apksigner. The workflow hands the keystore to
Gradle (`HAKUX_DEBUG_KEYSTORE`, read in `android/app/build.gradle.kts`):
written to `~/.android/debug.keystore` alone it wasn't the one the build
signed with, and every release up to build 21 had a key of its own. Build
22 (`build-claude-eager-franklin-417v0b-22`) is the first with the debug
key: installing it over an earlier build takes one `route reinstall`,
later builds update in place.

## Requirements

- The hakuX debug APK built from `claude/eager-franklin-417v0b`, installed
  with `route install` (so `batch.txt` names it).
  The mod variants, thread stats and display timing work with any build.
- Savestates: slot 1 in Bowerstone, slot 2 in Great Wood.
- Git for Windows on the PC for the uploads.
