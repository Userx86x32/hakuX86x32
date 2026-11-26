# Game optimization playbook (Android emulators and ports)

A repeatable way to find and fix what limits a game's frame rate on an
Android phone, learned optimizing Fable: The Lost Chapters under hakuX on a
Galaxy S24+ (Great Wood: 50 fps and 422 stutters a minute to 59 fps and 31).
Written to be handed to a person or a Claude session starting on a new game
or emulator.

Companion documents:
- `docs/diag-suite.md`: the hakuX diagnostics suite and batch layout.
- The device profile (`Galaxy_S24_Plus_Device_Profile_v1.4.md`, kept by the
  owner): the phone's limits, sustained-load behaviour, and the pitfalls below.
- `tools/diag/`: the route runner (`route.bat` on the PC, `route.sh` on the
  phone, an adapter per emulator; `tools/diag/README.md`) and `session.sh`
  (a manual play session's logs and sensors).

## The loop

1. **Baseline**: reproducible scenes, fixed conditions.
2. **Measure**: what each frame waits on.
3. **Diagnose**: put each stutter in one class.
4. **Experiment**: one change at a time, A/B, repeated.
5. **Decide and record**: keep what wins, write it down.

Each idea then costs one 30-minute batch, not an evening of playing.

## 1. Baseline

**Scenes.** Pick 2-3: one easy (a sanity check), one or two known to be
heavy. Heavy scenes give the clearest signal; in Fable the forest (many
occlusion tests) told us more than the town.

**Make them repeatable.**
- A savestate at a fixed spot, made with the exact settings and mods to be
  tested. A savestate keeps game state that settings change only on the
  next load or area change: Fable's per-area frame pacing came back from a
  savestate made with the 60 fps mod off.
- An input route replayed from the savestate, timed in **game frames**, not
  seconds, so slower runs replay the same game. hakuX: `NC_PAD_SCRIPT` /
  `NC_PAD_STATE` and recording (`route record`). Elsewhere: Dolphin movies
  (DTM), PCSX2 / PPSSPP input recording, RetroArch BSV replays, or "stand
  still for 60 s" when nothing else exists.
- Walking routes replay reliably; fights don't (AI isn't deterministic). Test
  fights as fixed scenes with short inputs.

**Fix the conditions** and record them in every batch:
- build (APK file name, commit, signing certificate) and settings,
- the display mode (`dumpsys display`: 60 or 120 Hz; resolution),
- charging and pass-through, power saving, the CPU caps
  (`cat /sys/devices/system/cpu/cpufreq/policy*/scaling_max_freq`),
- the start temperature (cool down between runs to the same point).

## 2. Measure

**Cheap, on every run** (any app, no root; costs too little to disturb it):

| What | How |
|---|---|
| Frames shown | `dumpsys SurfaceFlinger --timestats`, or `--latency "<exact layer name with #id>"` re-read from `--list` each sample; or the emulator's own counter |
| CPU clocks and caps | `/sys/devices/system/cpu/cpufreq/policy*/scaling_cur_freq`, `scaling_max_freq`, every 1 s |
| GPU clock, load, temperature | `/sys/class/kgsl/kgsl-3d0/{clock_mhz,gpu_busy_percentage,temp,max_clock_mhz}` (Adreno) |
| Thermal | `/sys/class/thermal/thermal_zone*/temp`; `dumpsys thermalservice` every 5 s at most |
| Per-thread CPU time and **CPU wait** | `/proc/<pid>/task/<tid>/schedstat` (run ns, wait ns, slices) and `comm`, at start and end |
| The emulator's own diagnostics | its log tags (logcat `-s TAG:V` for each: a filter drops every tag it doesn't name) |

**Heavy, in separate probe runs** (they cost CPU; keep them out of statistics):
- **Perfetto** (any app): `adb shell perfetto -c - --txt` with `linux.ftrace`
  (sched_switch, sched_wakeup, cpu_frequency, cpu_idle, thermal),
  `linux.process_stats`; 20 s, 128 MB buffer. Shows thread placement,
  wake-up delays and clocks around a stutter. Open at ui.perfetto.dev.
- **simpleperf** (debuggable builds only):
  `simpleperf record --app <pkg> -g --duration 20`, then
  `simpleperf report --sort comm,dso` and `--sort dso,symbol`. Shows where
  each thread's time goes.

**Add diagnostics to the emulator** when the question needs them (open
source): cheap counters logged every few seconds, switchable with
`setprop debug.<name>`. In hakuX the decisive ones were the stutter monitor
(each late frame with its cause), interrupt-latency reasons and a guest
memory watch.

## 3. Diagnose

Put every late frame in one class; the class decides the fix.

| Class | Signs | Typical fixes |
|---|---|---|
| **Work too long** (CPU-bound) | the thread runs the whole frame; schedstat run time high, wait low | faster code paths, build for the CPU (`-march`), fewer threads competing |
| **Work too long** (GPU-bound) | GPU busy near 100% at a high clock | lower resolution or effects, driver choice |
| **Waiting on something** | the thread is neither running nor waiting for a CPU (run + wait well below wall time) | find what it waits for: another thread, the GPU, I/O, a lock; shorten or stop that wait |
| **Starved of a CPU** | schedstat wait high; Perfetto shows it runnable but not running | performance hints (ADPF), don't pin to one core, fewer busy-spinning threads |
| **Throttled** | caps falling over the batch; thermal status rising | lower the frame target, cooling, no charging |
| **The game's own pacing** | frames at exact multiples of the refresh; the game's interval setting | a frame-rate mod for that game |
| **Compiles and caches** | hitches on first sight of an effect; cold vs warm runs differ | async compilation, prebuilt caches |

Fable's main problem was in the **waiting** class: the emulated CPU waited
up to 30 ms on GPU occlusion-query results, taking no interrupts, so vblanks
and flips came late. Tools for the other classes (CPU speed, scheduling)
moved it little; the per-thread "ran only 2-3 ms of a 13-19 ms delay" was
the clue.

## 4. Experiment

- **Settings first** (cheapest): async shaders, render scale, driver (stock
  vs Turnip), CPU affinity, the emulator's hacks.
- **Then code** (open-source emulators): every change behind a switch read
  at run time (`setprop debug.<emu>.<name>`), defaulting to the old
  behaviour, so one build tests all values.
- **Game patches last**: they need the game's executable, a disassembler
  and its title / version check (patches that check the old bytes first).
- **Batches**: 30 minutes, 2 scenes, 6 measurement runs per scene
  alternating A and B, plus 1 probe run per scene. Run an A/A batch for each
  new scene to learn its noise (2-15% here). Trust only differences larger
  than the noise; repeat small ones.
- **Every run checks its own preconditions** (right build, mods applied,
  switches set, replay started) and fails loudly. Two batches were wasted on
  a setting that silently didn't apply.
- **Surprising results are information**: making a thread sleep sooner freed
  CPU and made stutters worse, which exposed the real wait.

## 5. Decide and record

- Make the winner the default; keep the switch for later tests.
- Merge into `master` through a pull request; build from `master`.
- Per game: a page with scenes, savestates, routes, settings, mods and the
  numbers before and after.
- Phone-wide lessons go into the device profile (thermal limits, scheduler
  behaviour, tools that work).

## Porting the runner to another emulator

The runner (`tools/diag/`) is a generic core plus one adapter per emulator:
`adapters/<name>.sh` on the phone (sourced by `route.sh` and
`route_report.sh`) and `adapters/<name>.cmd` for `route.bat`, picked by
`ADAPTER=` in `route.cfg`. `tools/diag/README.md` lists every hook and
variable; these are the ones a port is about:

| Hook | What | hakuX (`hakux`) | any app (`generic`) |
|---|---|---|---|
| `PKG`, `PROC` | package and the process measured | `com.rfandango.haku_x.debug`, `$PKG:native` | `APP_PKG` (`APP_PROCESS`) |
| `ad_wait_app`, `ad_run_prepare` | start the game | the app's last game (`am start -d <dvdUri>`), again when it closed | `am force-stop`, then `am start` (its launcher activity) every run |
| `ad_run_start` | load a savestate | `setprop debug.hakux.state load:<slot>` (a new process) | the start alone |
| `ad_scene_ready`, `ad_run_started`, `ad_run_wait_done` | start input playback; the measured window | `NC_PAD_SCRIPT=@<route>` in `debug.hakux.env`, `NC_PAD_STATE=1` in `env2`; from `pad script: started` to `done` | `APP_WAIT` s after the start, then `APP_SECS` s |
| `ad_command` (`route record`) | record input | `NC_PAD_RECORD=<file>` in `debug.hakux.env` | none |
| `ad_check_run`, `ad_check_run_end` | the run's preconditions (failing twice stops the batch) | the `hakuX-native-mods` lines (the 60 fps mod required), `(waits for a savestate's load)`, `NC_IRQ_SCHED=1`, the variant's opts, `env=` and `pbspin=` | the process lasted the window |
| `ad_checksums` | what a run starts from (changed mid-batch: reported apart) | the route's and the savestate's sha256 | none |
| `LOG_TAGS` | log tags to capture | `hakuX-hle-hitch`, `hakuX-native-*`, `hakuX-hle-pb`, ... | `ActivityManager`, crashes |
| `ad_variant_set`, `SAVED_PROPS` | settings a variant can change (put back after) | `debug.hakux.*`, `mod=` (the app's mod choices), `env=` (`debug.hakux.env2`), `scale=` and the app's options (`debug.hakux.opts`) | any `debug.*` property |
| `THREADS` | thread names for the schedstat table | `SDLThread` (vCPU), `hle-pb`, `hle.render`, `SDLActivity`, `apu.frame` | the main thread, `RenderThread` (`APP_THREADS`); the busiest by name |
| `ad_report_run`, `ad_report_extra`, `ad_section_*` | per-frame metrics and report sections from its logs | stutters with causes (`hakuX-hle-hitch`), vblank latency (`hakuX-native-vbl`), late interrupts (`hakuX-native-irq`), the decoder (`hakuX-hle-pb`), interval changes (`hakuX-native-watch`) | none: fps and gaps from SurfaceFlinger |
| `.cmd`: `APK_URL`, `BACKUP_PATHS` | the test APK; what a backup holds | the debug build; savestates, settings, mod choices, saves | none |

The core (batches and the queue, A/B, `scenes=` and `runs=`, cool-downs,
sensors, schedstat, Perfetto, simpleperf, SurfaceFlinger, failed runs, the
build in `batch.txt`, report, upload, adb reconnects, properties put back)
stays the same. Start a new emulator on the generic adapter (it measures
any game as it is), then write its adapter as its hooks become available:
a savestate load by intent or property, an input replay, its own counters.

## Phone and toolchain pitfalls (Galaxy S24+, Android 17)

- **Auto Blocker** greys out USB debugging and drops adb after ~30 min: run
  batches on the phone (`nohup`) and pull results afterwards.
- **Data cables**: multi-tip and long charge cables carry no data.
- **Signing**: an update installs only over the same key. Name the debug
  keystore to Gradle explicitly in CI and check the APK's certificate.
  Back up a debug app's data (`run-as`) and verify the archive before any
  uninstall.
- **Windows → adb quoting**: send a remote command as one double-quoted
  argument.
- The device shell is `mksh` (`r` is a built-in).
- **Thermals**: in 30-minute batches the big cores fell to ~1.6-2.0 GHz;
  charging adds heat. Alternate variants so both see the same heat.
- **Don't pin a busy thread to one core**: it waits for that core.
