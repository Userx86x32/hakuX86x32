# tools/diag: the route runner

Measures a game on an Android phone over and over, alternating the settings
to compare (A B A B ...), and reports them side by side. The method is in
`docs/optimization-playbook.md`; hakuX's batches and what they measure are
in `docs/diag-suite.md`.

| File | Where it runs | What it is |
|---|---|---|
| `route.bat` | the Windows PC | pushes the runner to the phone, starts it detached, follows it, pulls and uploads the results; install, backup, restore, queue |
| `route.sh` | the phone (`sh`, mksh) | the core: batches, runs, sensors, threads, SurfaceFlinger, probes, properties put back |
| `route_report.sh` | the phone or any PC (`sh`, POSIX awk) | the core's report: `summary.csv` and `report.txt` of a batch |
| `route_trace.pbtx` | the phone | the Perfetto probe's config (its `atrace_apps` set to the adapter's package) |
| `adapters/<name>.sh` | the phone (and the report) | what is particular to an emulator or app |
| `adapters/<name>.cmd` | the PC | its side of `route.bat`: package, test APK, backup |
| `route.cfg.example` | | settings; copy to `route.cfg` beside `route.bat` |
| `session.sh` | the phone | a manual play session's logs and sensors (no runner) |

`route.bat` pushes what is beside it: copy the whole folder (with
`adapters\`) to the PC's test folder (`C:\hakuX-tests`).

## Core and adapters

The **core** knows nothing of any emulator. It runs batches and the queue
(`route queue`), alternates the variants, takes `scenes=` and `runs=` per
batch, cools down to a start temperature, samples clocks, caps, GPU load
and temperatures every second, snapshots each thread's
`/proc/<pid>/task/*/schedstat` at the window's start and end, reads what
SurfaceFlinger presented of the app's layer (its exact name re-read each
sample; `--timestats` when that gives nothing), runs the Perfetto and
simpleperf probes, stops a batch when a variant fails its check twice,
writes the build identity to `batch.txt`, survives adb going away (the
batch runs detached; a cut-off batch resumes), saves and puts back the
properties it sets, and writes the report and `summary.csv`, uploaded to
the `diag-results` branch by `route.bat`.

An **adapter** says how to start the game, put it where a run begins
(a savestate), make it play the same thing each time (an input replay),
check that the run is what the variant asked for, and what its own logs say.
`route.cfg`'s `ADAPTER=` picks it (`HAKUX_ADAPTER` in the environment
overrides; `hakux` when neither says).

- **hakux** (`adapters/hakux.sh`, `hakux.cmd`): replays a recorded route
  from a savestate (`NC_PAD_SCRIPT` / `NC_PAD_RECORD` / `NC_PAD_STATE`
  through `debug.hakux.env` and `env2`), checks the mods applied, the
  replay's wait for the savestate and `NC_IRQ_SCHED=1`, and reports the
  stutters with their causes, vblank latency, late interrupts, the decoder
  and the presentation interval watch. Its commands: `tour`, `record`,
  `save`, `load`.
- **generic** (`adapters/generic.sh`, `generic.cmd`): any app, no hooks.
  Each run force-stops the app, starts it (`am start`), waits `APP_WAIT`
  seconds and measures `APP_SECS` seconds: the core's metrics only (fps and
  gaps from SurfaceFlinger, threads, clocks, temperatures), plus the
  busiest threads by name. Variants are properties (`debug.<name>=value`)
  or labels alone (`base1 base2`: the noise).

```
# route.cfg for any game
ADAPTER=generic
APP_PKG=com.example.game
APP_WAIT=20
APP_SECS=60
RUNS=6
```

Then `route preflight` (the app starts and stays up, SurfaceFlinger shows
its layer, its threads can be read) and `route suite base1 base2`.

## The phone

The core's sampler is laid out for the target phone, the Galaxy S24+
(Snapdragon 8 Gen 3; the owner's device profile, v1.4): CPU frequencies and
caps of `policy0` (A520), `policy2` and `policy5` (A720) and `policy7`
(X4), the hottest of the `gpuss` thermal zones 32-39 (the cool-down's and
`max_gpuss_C`), and the Adreno's `/sys/class/kgsl/kgsl-3d0`. That is the
phone, not the emulator: every adapter gets the same sensors. On another
phone those columns read NA until the sampler (`start_capture`, `gpuss_c`
in `route.sh`) names its policies and zones. `battery_dC` reads
`/sys/class/power_supply/battery/temp`, which the S24+'s shell can't read
(NA; `dumpsys battery` has it).

## Writing an adapter

Copy `adapters/generic.sh` to `adapters/<name>.sh` (and `generic.cmd` to
`<name>.cmd` for `route.bat`), set `ADAPTER=<name>` in `route.cfg`, then
replace what the new emulator does better than "start it and wait". `tools/`
is in `.gitignore`: add new files with `git add -f`.

The adapter is sourced by `route.sh` and by `route_report.sh`: it only
defines variables and functions, and runs nothing when sourced. It is plain
`sh` for the phone's mksh (no `local`, no arrays, no bash): its functions
share the core's variables, so name its own with a prefix. A hook the
adapter doesn't define does what the table says (`-`: nothing); the four
marked **required** have no default.

### Settings (variables)

Set plainly, or with `: "${NAME=default}"` for one `route.cfg` may set
(`route.cfg` is read before the adapter).

| Variable | What | hakuX | generic |
|---|---|---|---|
| `PKG` **required** | the package | `com.rfandango.haku_x.debug` | `APP_PKG` |
| `PROC` **required** | the process measured (`pidof`) | `$PKG:native` | `APP_PROCESS`, else `$PKG` |
| `SCENES` | the scenes, `name:slot` | `bower:1 wood:2` | `app` |
| `LOG_TAGS` | logcat's tags (`-s`: no other tag is kept) | `hakuX-hle-hitch:V hakuX-native:V ...` | `ActivityManager:I AndroidRuntime:E DEBUG:F libc:F` |
| `THREADS` | the schedstat table: `column=thread name` (`@main`: the process's main thread) | `vcpu=SDLThread decode=hle-pb render=hle.render main=SDLActivity apu=apu.frame` | `APP_THREADS`, else `main=@main render=RenderThread` |
| `THREAD_LABELS` | their headings, `top/bottom` (`_` a space) | `vCPU_run/SDLThread ...` | column / name |
| `SAVED_PROPS` | properties put back after a batch | `debug.hakux.env env2 vcpucore adpf` | - |
| `RUNNER_PROPS` | properties cleared after a batch | `debug.hakux.opts perf perfsec` | - |
| `STATE_PROP` | a property cleared after each run | `debug.hakux.state` | - |
| `PROP_PREFIX`, `QUIET_PROPS` | how "put back:" names them | `debug.hakux.`, env and env2 left out | - |
| `SF_LAYER`, `SF_LAYER_ANY`, `SF_TIMESTATS_LAYER` | the SurfaceFlinger layer: the one whose name holds this; a second choice; for `--timestats` | `SurfaceView[$PKG/` | the same, else any `$PKG/` layer (`APP_LAYER`) |
| `PROC_RUNAS` | `/proc` through `run-as` (1), directly (0), either (`auto`) | 1 | `auto` |
| `AUTO_VARIANTS` | what `route auto` runs | `x4:vcpucore=1 all:vcpucore=0` | `base1 base2` |
| `VARIANT_KEYS` | the variant names it takes (for errors) | `scale, mod, env, pbspin, ...` | none |
| `RUN_OVERHEAD` | a run's seconds besides its length (batch estimate) | 30 | `APP_WAIT` + 15 |
| `NAME_WHAT`, `NAME_MAX` | what a scene is called, its longest name | route, 20 | scene, 40 |
| `ADAPTER_APP`, `ADAPTER_RUN`, `RUNNING_SAY`, `SKIP_HINT` | words for the console | game, the replay, replaying... | app, the app, measuring... |

### Hooks (functions)

`rd` is the run's folder (`run.txt`, `logcat.txt` in it). A hook prints
what `run.txt` should keep where the table says so; `die "<why>"` stops the
batch (the properties are put back first), `say` writes to the console.

| Hook | When | Does | Default |
|---|---|---|---|
| `ad_check_config` | before a batch or preflight | `die`s on missing settings | - |
| `ad_wait_app` | before a batch's first run | the app ready (hakuX: the game running) | - |
| `ad_scene_check scene slot` | before a suite, per scene | `die`s when a scene can't run (no route recorded) | - |
| `ad_scene_missing scene slot` | before a scene | prints why it is skipped (no savestate), or nothing | - |
| `ad_scene_ready scene slot` | before a scene's runs | its inputs in place (the route pushed, `debug.hakux.env` set) | - |
| `ad_run_check scene` | `route run` | `die`s when the scene can't run | - |
| `ad_run_secs scene [estimate]` **required** | the probe's middle, the estimate | prints a run's length in seconds | |
| `ad_batch_begin variants...` | before `save_props` | notes the batch's kinds of variant | - |
| `ad_batch_info`, `ad_settings` | `batch.txt`, the console | print the adapter's settings | - |
| `ad_save`, `ad_restore` | with the properties | saves / puts back the adapter's own state (hakuX: the mod choices) | - |
| `ad_saved_value prop value` | saving a property | prints what is put back (hakuX: env without `NC_PAD_`) | the value |
| `ad_clean` | `route clean` | clears what a cut-off batch left | - |
| `ad_apk_fields file` | `batch.txt`'s build | prints fields read from the APK's name | - |
| `ad_variant_prop name` | saving | prints the property a variant name sets; 1: not a property | 1 |
| `ad_variant_knows name` | before a batch | 0 when the adapter takes the name (else only `x.y` properties) | 1 |
| `ad_variant_begin v slot` / `ad_variant_set name value v slot` / `ad_variant_end v slot` | each run, into `run.txt` | sets a variant up; `ad_variant_set` returns 1 for a name it doesn't take | - / 1 / - |
| `ad_run_header` | each run, into `run.txt` | per-run settings (hakuX: the guest word watch) | - |
| `ad_checksums scene slot` | each run | prints `<name>_sha256=` of each file the run starts from (the report keeps runs with other inputs apart) | - |
| `ad_run_prepare rd scene slot` | before the capture | the app started or stopped as a run needs | - |
| `ad_run_start rd scene slot` **required** | the capture running | starts the run (a savestate's load; the app's start) | |
| `ad_run_started rd` **required** | | 0 once the measured part begins (`pad script: started`); else the run didn't start | |
| `ad_check_run rd` | the run started | the run's preconditions; 1 with `run_failed rd "<why>"` | 0 |
| `ad_run_wait_done rd` **required** | after any probe | returns when the measured part ends | |
| `ad_check_run_end rd` | after the run | checks at its end; 1 with `run_failed` | 0 |
| `ad_run_end rd` | after the run | (hakuX: the state request cleared) | - |
| `ad_probe kind rd` | a probe kind not the core's | 1 when it isn't one (hakuX: `prof`) | 1 |
| `ad_preflight rd scene slot` | `route preflight` | one start, checked (`say "ok: ..."` / `"FAILED: ..."`); 1 when one failed | a run's start and checks |
| `ad_command args...` | an unknown command | the adapter's own (`record`, `save`); 127: not one | 127 |

A run's **window** is what the report measures: the adapter's
`ad_report_run` prints `window=<start s> <end s> <pid>` (hakuX: from
`pad script: started` to `done` in its log), or else the runner writes
`window_start=`, `window_end=` (HH:MM:SS) and `pid=` to `run.txt` (the
generic adapter, in `ad_run_started` and `ad_run_wait_done`).

### The report

| | What | Default |
|---|---|---|
| `REPORT_TITLE` | the report's first line | `route report` |
| `SUMMARY_COLUMNS` | `summary.csv`'s columns, in order (any the core or the adapter fills; missing: NA) | the core's: run, variant, kind, secs, frames, fps, stutters, per_min, worst_ms, temperatures and caps, `<thread>_run_ms`/`_wait_ms`, sf_* |
| `REPORT_SECTIONS` | `report.txt`'s sections in order: the core's `main threads display busiest failed probes perrun`, or the adapter's `ad_section_<name>` | `main threads display busiest failed probes perrun` |
| `SF_LABEL`, `MAIN_NOTE`, `WINDOW_WORD`, `PERRUN_AWK` | the display section's words, a note under the main table, the threads table's "over the ...", a second line per run (awk) | |
| `ad_report_begin` | before the runs (`$B`: the batch) | - |
| `ad_report_run rd run variant kind` | per run: prints `name=value` lines (the window, its own columns); 1 leaves the run out | - |
| `ad_report_pin rd pid` | prints `<tid> <thread name>`: the thread of that name to count (hakuX: the vCPU's tid from its log) | - |
| `ad_report_extra rd pid t0 t1` | per run, after the core's: more `name=value` lines | - |
| `ad_section_<name>` | a section: awk over `$SUM` with `"$COLS"` gives `c("column")` | |

Without its own frame log the core takes the frames, fps, stutters (gaps
over 1.5 times the median interval) and the worst gap from SurfaceFlinger.

### route.bat's side (`adapters/<name>.cmd`)

`route.bat` calls it with a hook's name as `%1` (`goto %1` at its top); it
sees `route.bat`'s variables (`ADB`, `PKG`, `BK`, `Q`, `HERE`).

| Hook | Does |
|---|---|
| `init` | sets `PKG`, `APK_URL` (the default `route install`), `BKNAME`, `BACKUP_WHAT`, `BACKUP_PATHS` (relative to the app's folder, read through `run-as`; empty: no backup), `PREFLIGHT_WHAT`; `exit /b 1` stops `route.bat` |
| `installed`, `reinstalled` | what to do next, said after an install |
| `after_backup`, `after_restore` | checks of the archive and the phone (`exit /b 1`: failed) |
| `queue_default` | writes the first `queue.txt` (`%Q%`) |

### Checklist for a new emulator

- Every run checks its own preconditions (`ad_check_run`): the right build,
  the settings and mods applied, the replay started from the savestate.
  Fail loudly; a variant failing twice stops the batch.
- Record what each run starts from (`ad_checksums`): a savestate or route
  saved again mid-batch otherwise mixes two scenes into one number.
- Put back everything the variants change (`SAVED_PROPS`, `ad_save` /
  `ad_restore`), also after a batch killed by Auto Blocker (`route clean`).
- A test with the phone mocked, like `tests/diag/route_generic_test.sh`.

## Tests

On any Linux or macOS host with `sh` and `awk` (no phone):

```
sh tests/diag/route_report_test.sh     # the report, against tests/diag/golden (seconds)
sh tests/diag/route_test.sh            # hakuX, the phone mocked (about 12 minutes)
sh tests/diag/route_generic_test.sh    # the generic adapter, the phone mocked (about 4 minutes)
```

`tests/diag/golden/` holds what `route_report.sh` made of
`report_fixture.sh`'s batch before the split into a core and adapters: the
hakuX adapter's report must stay byte for byte the same.
