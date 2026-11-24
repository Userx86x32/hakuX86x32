/*
 * hakuX native core — Android's performance hints (ADPF) for the threads a
 * frame waits on.
 *
 * One hint session holds the guest CPU's thread, the push-buffer decoder,
 * the render thread and the presenter. At each flip of the title's the vCPU
 * reports how long its frame worked: the time since the last flip less the
 * time it waited idle for an interrupt (nc_irq_idle_wait); time it waited for
 * a host core counts as work, which is the stall the hints are for. The
 * target is the title's recent best flip interval in whole vblanks (1/60 s
 * at 60 fps). The scheduler (WALT and its boosts) then raises the session's
 * threads' clocks and cores before a frame is late, instead of after.
 *
 * Android 13 (API 33) and up, looked up in libandroid at run time; without
 * them nothing happens. debug.hakux.adpf 0 turns the hints off (and on again
 * with 1), read now and then.
 *
 * The vCPU's thread also runs on the fastest cores (the highest
 * cpuinfo_max_freq: the prime core); debug.hakux.vcpucore 0 lets it run on
 * every core again.
 */
#ifndef NATIVE_CORE_PERFHINT_H
#define NATIVE_CORE_PERFHINT_H

#include <stdint.h>

#ifdef __cplusplus
extern "C" {
#endif

/* The calling thread joins the session (slots: hw/xbox/hle/hitch.h's
 * HLE_HT_VCPU, _RENDER, _DECODE, then NC_PERF_PRESENT). */
enum { NC_PERF_PRESENT = 3, NC_PERF_SLOTS = 4 };
void nc_perf_thread(int slot);
/* The title flipped (its vblank handler: on the vCPU's thread). */
void nc_perf_flip(void);

#ifdef __cplusplus
}
#endif

#endif
