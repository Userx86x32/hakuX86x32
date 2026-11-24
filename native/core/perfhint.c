/*
 * hakuX native core — Android's performance hints (perfhint.h).
 */
#include "native/core/perfhint.h"
#include "native/core/irq.h"
#include "native/core/nc.h"
#include "native/dev/dev.h"
#include "hw/xbox/hle/host.h"
#include "hw/xbox/hle/prop.h"

#include <dlfcn.h>
#include <pthread.h>
#include <stdbool.h>
#include <stdlib.h>
#include <string.h>
#include <sys/system_properties.h>
#include <time.h>
#include <unistd.h>

#define TAG "hakuX-native-perf"

/* libandroid's APerformanceHint_* (android/performance_hint.h, API 33; the
 * build's platform is older, so they are looked up) */
typedef struct APerformanceHintManager APerformanceHintManager;
typedef struct APerformanceHintSession APerformanceHintSession;
static struct {
    APerformanceHintManager *(*get_manager)(void);
    APerformanceHintSession *(*create)(APerformanceHintManager *, const int32_t *, size_t, int64_t);
    int (*update_target)(APerformanceHintSession *, int64_t);
    int (*report)(APerformanceHintSession *, int64_t);
    void (*close)(APerformanceHintSession *);
    int (*set_threads)(APerformanceHintSession *, const int32_t *, size_t);     /* API 34 */
} g_api;

static pthread_once_t g_once = PTHREAD_ONCE_INIT;
static APerformanceHintManager *g_mgr;
static int32_t g_tid[NC_PERF_SLOTS];        /* 0: not started */
static unsigned g_tid_gen;                  /* bumped when a thread joins */

/* the vCPU's (only it reports: the flips are its vblank handler's) */
static APerformanceHintSession *g_session;
static unsigned g_session_gen;
static int64_t g_target_ns;
static uint64_t g_last_flip_ns, g_last_idle_ns;
static uint8_t g_ivl[32];                   /* recent flip intervals, vblanks */
static unsigned g_nivl;
static bool g_on = true;
static unsigned g_polls;
static struct {
    uint64_t t, n, work_ns, over;
} g_stat;

static uint64_t now_ns(void)
{
    struct timespec ts;
    clock_gettime(CLOCK_MONOTONIC, &ts);
    return (uint64_t)ts.tv_sec * 1000000000ull + (uint64_t)ts.tv_nsec;
}

static void load(void)
{
    void *lib = dlopen("libandroid.so", RTLD_NOW);
    if (!lib) {
        return;
    }
    g_api.get_manager = dlsym(lib, "APerformanceHint_getManager");
    g_api.create = dlsym(lib, "APerformanceHint_createSession");
    g_api.update_target = dlsym(lib, "APerformanceHint_updateTargetWorkDuration");
    g_api.report = dlsym(lib, "APerformanceHint_reportActualWorkDuration");
    g_api.close = dlsym(lib, "APerformanceHint_closeSession");
    g_api.set_threads = dlsym(lib, "APerformanceHint_setThreads");
    if (g_api.get_manager && g_api.create && g_api.update_target && g_api.report && g_api.close) {
        g_mgr = g_api.get_manager();
    }
    nc_log(TAG, "performance hints %s", g_mgr ? "available" : "not available (Android 13 and up)");
}

void nc_perf_thread(int slot)
{
    if (slot < 0 || slot >= NC_PERF_SLOTS) {
        return;
    }
    pthread_once(&g_once, load);
    __atomic_store_n(&g_tid[slot], (int32_t)gettid(), __ATOMIC_RELEASE);
    __atomic_fetch_add(&g_tid_gen, 1, __ATOMIC_ACQ_REL);
}

/* debug.hakux.adpf: 0 off, anything else (or unset) on */
static void poll_prop(void)
{
    if (g_polls++ % 64) {
        return;
    }
    char v[PROP_VALUE_MAX] = "";
    const bool on = !(hle_prop_get("debug.hakux.adpf", v) > 0 && !strcmp(v, "0"));
    if (on != g_on) {
        g_on = on;
        nc_log(TAG, "performance hints %s (debug.hakux.adpf)", on ? "on" : "off");
        if (!on && g_session) {
            g_api.close(g_session);
            g_session = NULL;
        }
    }
}

/* The session's threads: those started so far (created or updated). */
static bool session_threads(void)
{
    const unsigned gen = __atomic_load_n(&g_tid_gen, __ATOMIC_ACQUIRE);
    if (g_session && gen == g_session_gen) {
        return true;
    }
    int32_t tids[NC_PERF_SLOTS];
    size_t n = 0;
    for (int i = 0; i < NC_PERF_SLOTS; i++) {
        const int32_t t = __atomic_load_n(&g_tid[i], __ATOMIC_ACQUIRE);
        if (t) {
            tids[n++] = t;
        }
    }
    if (!n) {
        return false;
    }
    if (g_session && g_api.set_threads && g_api.set_threads(g_session, tids, n) == 0) {
        g_session_gen = gen;
    } else {
        if (g_session) {
            g_api.close(g_session);
        }
        g_session = g_api.create(g_mgr, tids, n, g_target_ns);
        g_session_gen = gen;
        if (!g_session) {
            nc_log(TAG, "no hint session for %zu threads", n);
            return false;
        }
    }
    nc_log(TAG, "hint session: %zu threads (vCPU %d, render %d, decode %d, present %d), target %.1f ms",
           n, g_tid[0], g_tid[1], g_tid[2], g_tid[3], g_target_ns / 1e6);
    return true;
}

void hle_host_perf_thread(int slot)
{
    nc_perf_thread(slot);
}

void nc_perf_flip(void)
{
    pthread_once(&g_once, load);
    if (!g_mgr) {
        return;
    }
    if (!__atomic_load_n(&g_tid[0], __ATOMIC_ACQUIRE)) {
        nc_perf_thread(0);                  /* the flips are the vCPU's (the monitor may be off) */
    }
    poll_prop();
    const uint64_t t = now_ns(), idle = nc_irq_idle_ns();
    const uint64_t dt = t - g_last_flip_ns, didle = idle - g_last_idle_ns;
    const bool first = !g_last_flip_ns;
    g_last_flip_ns = t;
    g_last_idle_ns = idle;
    if (first || !g_on || dt > 250000000ull) {
        return;                             /* the first, off, or after a pause or a load */
    }
    /* the target: the best interval of the last 32 flips, in vblanks (1-4) */
    const int64_t vb = hle_host_vblank_period_ns() > 0 ? hle_host_vblank_period_ns() : 16683333;
    unsigned k = (unsigned)((dt + (uint64_t)vb / 2) / (uint64_t)vb);
    k = k < 1 ? 1 : k > 4 ? 4 : k;
    g_ivl[g_nivl++ % 32] = (uint8_t)k;
    unsigned best = 4;
    for (unsigned i = 0; i < (g_nivl < 32 ? g_nivl : 32); i++) {
        best = g_ivl[i] < best ? g_ivl[i] : best;
    }
    const int64_t target = (int64_t)best * vb;
    if (!g_target_ns) {
        g_target_ns = target;
    }
    if (!session_threads()) {
        return;
    }
    if (target != g_target_ns) {
        g_target_ns = target;
        g_api.update_target(g_session, target);
        nc_log(TAG, "target %.1f ms (%u vblanks)", target / 1e6, best);
    }
    /* the frame's work: its time less the vCPU's idle waits */
    const int64_t work = didle < dt ? (int64_t)(dt - didle) : 1;
    g_api.report(g_session, work);
    g_stat.n++;
    g_stat.work_ns += (uint64_t)work;
    g_stat.over += work > target;
    if (!g_stat.t) {
        g_stat.t = t;
    } else if (t - g_stat.t >= 10000000000ull) {
        nc_log(TAG, "last 10 s: %llu frames, work %.1f ms average, %llu over the %.1f ms target",
               (unsigned long long)g_stat.n, g_stat.work_ns / 1e6 / (double)g_stat.n,
               (unsigned long long)g_stat.over, g_target_ns / 1e6);
        memset(&g_stat, 0, sizeof(g_stat));
        g_stat.t = t;
    }
}
