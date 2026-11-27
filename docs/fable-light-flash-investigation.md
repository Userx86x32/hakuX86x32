# Fable: the random one-frame light flash (investigation log)

Status: **open**. Written for hand-off; newest findings first in section 1.
Device: Galaxy S24+ (Adreno 750), driver PurpleVK 26.3 (Turnip-based), hakuX
`master` at build 33, Fable: The Lost Chapters (4D5300D1 v1), 60 fps mod,
Bloom off. Played on a TV through DeX.

## 1. Where it stands

**Symptom.** A large soft purple/white glow blazes for exactly one frame,
then is gone. Seen in Hobbe caves (near puddles, during staff fights) and at
Greatwood Gorge's bridge (near the hanging lantern, at night). Steadier on the
TV than on the phone's own screen.

**What it is in the game.** Fable's light glows are faded by a visibility
test: the game draws a small disc at the light (triangle fan), asks the GPU
how many samples passed the depth test, and uses `count / expected area`,
clamped to 1, as brightness (`0x12F600`, see section 3). A count that is too
high for one frame makes a hidden glow blaze for that frame.

**Leading theory (not yet confirmed): the GPU's sample counter is disturbed
when another GPU client interrupts hakuX in the middle of a test.**
Evidence:
- The driver now and then returns a *negative* count, equal to minus a
  running total (−30 thousand to −101 million raw samples). A count can only
  be negative if the hardware counter went backwards between the test's
  begin and end, i.e. it was reset or replaced in between.
- A flash on video matched a logged negative count to 11 ms, although that
  count had already been zeroed by hakuX. So the same event also makes
  another test read too *high*, which hakuX cannot tell from a real count.
- The rate follows other GPU activity, not hakuX's own settings: about 20-30
  negatives a minute while Android's screen recorder was running (builds
  29/30, the fight log), about 2-3 a minute without it (builds 31/32), none
  in a 13 s quiet walk. Earlier conclusions that "GPU-side resets cut it
  10x" are confounded by this: the recorder was on in the "before" runs and
  off in the "after" runs.
- The phone's own (Qualcomm) driver showed the effect more, and DeX (a
  second display to compose) shows it more than the phone screen. Both fit
  a cause below the driver: KGSL switching contexts (preemption) without
  preserving the sample counter.
- Not the cause, each tested: pool size (4096/16384/65536 slots), reset
  method by itself, tiling vs direct rendering (`TU_DEBUG=sysmem`, if it was
  honoured), the report-gate wait, bloom, FLARE_POINT flares.

**Other pattern, unexplained:** in the per-test fight log, 7 of 8 negative
counts were tests alone in their own small submission (the guest blocked on a
result, so hakuX submitted at once). Median submission holds 30 tests.

**Next step (no build needed): the priority experiment, section 5.**

## 1a. What the driver's source says (Mesa main, read 2026-11-27)

`src/freedreno/vulkan/tu_query_pool.cc`, `tu_autotune.cc` (PurpleVK is a
fork; its code may differ):

- On the A750 (`has_event_write_sample_count`) a query is two `ZPASS_DONE`
  events: begin writes the hardware sample counter to `slot.begin`; end
  writes it to `slot.end` and has the firmware add `end - begin` to
  `slot.result`. The slot is {available, pad, begin, result, end, pad}.
- "ZPASS_DONE with write_accum_sample_count_diff accumulates the result
  asynchronously, and WFI/WFM/WAIT_FOR_MEM_WRITES don't wait for that write
  to land." Availability is written through `RB_DONE_TS` for that reason,
  and a GPU-side reset first waits for it (`tu7_wait_for_rb_done`).
- A reset (CPU or GPU) clears `available` and `result` only; `begin` and
  `end` keep their old values.
- "ZPASS_DONE events should come in begin-end pairs": the firmware
  "misbehaves" on nested events. The driver's autotuner counts samples per
  render pass with its own `ZPASS_DONE` pair (default algorithm
  `bandwidth`), and emits fake events to keep pairs un-nested when a pass
  holds an application query. Passes under 5 draws are not tuned.
  `TU_AUTOTUNE_ALGO=prefer_gmem|prefer_sysmem` skips the measuring.
- Inside a render pass both events go to the draw stream, replayed per tile.

So a negative result means `end < begin` as the firmware saw them: the
counter went back, the pairing slipped, or a value had not landed. Two
candidates follow, both testable without a build: (a) interruption by other
GPU work (section 1), (b) the autotuner's events nesting with hakuX's.

## 2. History of fixes (all in `master`)

| Build | Change | Result |
|---|---|---|
| 26 | Visibility counts no longer divided by the AA sample count (`cmd_vis_end`): D3D divides itself; Fable inlines that (x1/4 at 4 samples). Fable does render with 4-sample AA. | The steady pulsing went. Correct regardless. |
| 28 | A negative driver count is taken as 0; counts capped at INT32_MAX. | Removes the flashes whose *own* count was negative (read as ~4 billion before). |
| 29 | Fable mod "Flares off": skips the FLARE_POINT loop at `0x34F5F1`. | Did not remove the flash: the flashing glow is not made there. |
| 30 | Every negative count logged (20/s cap) with a running total. | Diagnostics. |
| 31 | Query slots reset on the GPU ahead of use (`vis_cb_begin`), not from the CPU; `debug.hakux.visreset host` for A/B. Pool 16384. | Fewer flashes seen, but see the recorder confound above. |
| 32 | Pool 65536. | No difference; reverted to 16384 (build 33). |

Runtime switches: `debug.hakux.visall 1` (all tests visible), `vislog <n>`
(log next n results), `vispx 1` (old per-pixel count), `visreset host`,
`visoff 1`, `tu_debug <flags>` (Turnip's TU_DEBUG, at game start),
`kgslprio <1..15|0>` (KGSL context priority, at game start),
`visgate_us` (report-gate wait).

## 3. Fable's side (default.xbe, XDK 5849)

- Test manager object at `[0x994B80]`: table of results at `+0x4014`/`+0x4018`
  (8 bytes each: count, flags; bit 31 done, bit 30 pending with the D3D
  report-ring slot in the low bits), ring position `+0x400C` (2048 slots),
  frame number `+0x4010`.
- `0x12F6E0` begin (push-buffer `0x817C8`: clear report, enable z-pass count;
  inlined at five other sites). `0x12F720` end: takes a ring slot, first
  resolving the slot's previous owner if it is still pending.
  `0x12E640` result of a table index (lazy). `0x12F7F0` reads the D3D report,
  spinning until its status leaves −1, then scales by the multisample type
  (`[0x994B40]+0x190`: 0x1222 -> x1/4, 0x2233 -> x1/9).
- Glow tests: requests of 0x1C bytes at manager `+0x24024..+0x24028`
  (centre xyz, radius, `+0x10` fan vertex count, `+0x14` expected pixel
  area, `+0x18` table index). `0x12ED00` culls each against the frustum,
  computes the expected area and draws the fan inside a test.
  `0x12F600` returns `min(count / expected, 1.0)` in xmm0 (index in eax,
  manager in edi; no stack arguments).
- A guaranteed way to remove these glows (and the flash) as a mod:
  `0x0012F600: 51 8B 97 30 -> 0F 57 C0 C3` (xorps xmm0,xmm0; ret). Untested.
  It would remove every occlusion-faded glow, not only the faulty frames.
- Other users of tests (not yet tied to an effect): `0x15D730`, `0x18C100`
  (called from `0x18BF9D`), `0x192697`, `0x19EBC6`, `0x1BC7F5`, `0x1C7F00`,
  `0x12FCB0`, `0x1670D0`.

## 4. hakuX's side

- Front end (`hw/xbox/hle/pb/pbdraw.c`, `pbmode.c`): ZPASS enable -> 
  `HLE_OP_VIS_BEGIN`; `GET_REPORT` -> `HLE_OP_VIS_END` with the report's
  guest address. Begin/end are paired there.
- Back end (`hw/xbox/hle/vk/back.c`): one Vulkan occlusion query per render
  pass a test's draws fall in (`vis_draw`, `vis_pass_end`), parked at
  `cmd_vis_end`, stamped with the next submit's timeline value
  (`vis_stamp`), summed and written to the guest's report once that value
  completes (`vis_reap`). Draw batching is flushed before query begin/end
  (`batch_wrap.h`). No draws were dropped in any log (`dropped: ... 0`).
- Submit boundaries: the front end kicks every 4 ms and whenever a report
  ended and the guest waits; back-to-back boundaries merge (`pend_*`).

## 5. Experiment to run next: `tools/diag/flashtest.bat`

Four runs of 90 s on the Gorge bridge with the screen recorder on (it raises
the rate about tenfold, so short runs suffice). The script sets each
variant, restarts the game, asks for the flashes seen, and counts the
"taken as 0" lines into `flashtest-results.txt`:

| Run | Setting | If the bad counts go |
|---|---|---|
| baseline | defaults | (reference) |
| priority-1 | `debug.hakux.kgslprio 1` | interruption by other GPU work (a) |
| prefer-gmem | `TU_AUTOTUNE_ALGO=prefer_gmem` (via `debug.hakux.env`) | the autotuner's events (b) |
| prefer-sysmem | `TU_AUTOTUNE_ALGO=prefer_sysmem` | the autotuner's events (b) |

`debug.hakux.tu_debug startup` is set so the driver logs its autotune
configuration; no such line in the results means PurpleVK lacks this code or
did not read the variable, and the two autotune runs say nothing.

## 6. Fix candidates once the cause is confirmed

1. **Count in the fragment shader instead of the hardware counter.** Test
   draws get a pipeline variant with early depth tests forced and an
   `atomicAdd` into a per-test slot of a storage buffer. Memory-based, so a
   context switch cannot disturb it; no per-pass parts either. The real fix,
   and the largest change (shader generation, pipeline key, result read).
2. **A priority hakuX is not preempted at**, if one exists that does not
   starve the compositor (priority 1 made the compositor late in earlier
   measurements; 2 or 3 untried).
3. **The Fable mod in section 3**: no glows, no flash. A fallback.

## 7. Material

Logs (per-test: quiet walk, Hobbe fight; negatives: builds 30-32), three of
five recordings, `default.xbe` and the disassembly helpers (`xd.py`) are in
the session's scratch space, not in the repository. The driver's source
(Mesa `src/freedreno/vulkan/tu_query.cc`) could not be fetched from this
environment; reading its a7xx occlusion path would settle section 1.
