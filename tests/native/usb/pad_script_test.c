/*
 * Host test of the pad recording (NC_PAD_RECORD) and its replay
 * (NC_PAD_SCRIPT) in native/dev/xid.c: a route recorded frame by frame,
 * then replayed in a second run (the scripts load once a process).
 *
 *   gcc -O1 -I. tests/native/usb/pad_script_test.c native/dev/usb.c native/dev/xid.c -lpthread -o pad_script_test
 *   ./pad_script_test record /tmp/route.txt && ./pad_script_test replay /tmp/route.txt
 */
#include <stdarg.h>
#include <stdio.h>
#include <stdlib.h>
#include <string.h>

#include "native/dev/usb.h"

void nc_log(const char *tag, const char *fmt, ...)
{
    va_list ap;
    va_start(ap, fmt);
    printf("  [%s] ", tag);
    vprintf(fmt, ap);
    printf("\n");
    va_end(ap);
}

/* What xid.c reads from the core, stubbed. */
static uint64_t g_swaps;
uint64_t hle_back_swap_count(void)
{
    return g_swaps;
}
bool nc_paused(void)
{
    return false;
}
static bool g_state_loaded;
bool nc_core_state_loaded(void)
{
    return g_state_loaded;
}

static int g_fail;
#define CHECK(c)                                                                                                       \
    do {                                                                                                               \
        if (!(c)) {                                                                                                    \
            printf("FAIL %s:%d %s\n", __FILE__, __LINE__, #c);                                                       \
            g_fail++;                                                                                                  \
        }                                                                                                              \
    } while (0)

/* A route: what player 1 holds at frame f (with noise inside the dead zone). */
static NcPadState route_input(uint64_t f)
{
    NcPadState p = {0};
    p.lx = (int16_t)((f % 7) * 300 - 900);
    if (f >= 10 && f < 20) {
        p.analog[0] = 0xff;
    }
    if (f >= 15 && f < 40) {
        p.ly = 20000;
    }
    if (f >= 30 && f < 33) {
        p.buttons |= NC_PAD_START;
    }
    if (f == 50) {
        p.analog[7] = 0x80;
        p.rx = -32767;
    }
    return p;
}

/* "record <file>": the route into file, the boot before the savestate's
 * left out (NC_PAD_STATE=1). */
static int record_main(const char *file)
{
    setenv("NC_PAD_RECORD", file, 1);
    setenv("NC_PAD_STATE", "1", 1);
    NcPadState junk = {.buttons = NC_PAD_BACK};
    g_swaps = 500;
    nc_pad_set(0, &junk);           /* the boot: not recorded */
    g_state_loaded = true;
    for (g_swaps = 0; g_swaps < 60; g_swaps++) {
        NcPadState p = route_input(g_swaps);
        nc_pad_set(0, &p);
        nc_pad_set(0, &p);          /* the same input again: no new step */
    }
    nc_pad_record_flush();
    FILE *f = fopen(file, "r");
    char text[2048] = "";
    if (f) {
        text[fread(text, 1, sizeof(text) - 1, f)] = 0;
        fclose(f);
    }
    printf("%s", text);
    CHECK(strstr(text, "\n10f:a:5f\n"));
    CHECK(strstr(text, "\n15f:a+ly=20480:5f\n"));
    CHECK(strstr(text, "\n20f:ly=20480:10f\n"));
    CHECK(strstr(text, "\n30f:start+ly=20480:3f\n"));
    CHECK(strstr(text, "\n50f:rt+rx=-32767:1f\n"));
    CHECK(!strstr(text, "back") && !strstr(text, "lx="));
    printf(g_fail ? "record: %d FAILED\n" : "record: all passed\n", g_fail);
    return g_fail != 0;
}

/* "replay <file>": the reports replaying it carry the route, rounded. */
static int replay_main(const char *file)
{
    char env[512];
    snprintf(env, sizeof(env), "@%s", file);
    setenv("NC_PAD_SCRIPT", env, 1);
    setenv("NC_PAD_STATE", "1", 1);
    NcUsbDev *d = nc_xid_gamepad_new(0);
    uint8_t r[20];
    g_swaps = 12;
    CHECK(d->data(d, true, 2, r, 20) == 20);
    CHECK(r[4] == 0);               /* the boot: no replay */
    g_state_loaded = true;
    for (g_swaps = 0; g_swaps < 60; g_swaps++) {
        d->data(d, true, 2, r, 20);
        const NcPadState w = route_input(g_swaps);
        const uint16_t buttons = nc_rd16(r + 2);
        const int16_t lx = (int16_t)nc_rd16(r + 12), ly = (int16_t)nc_rd16(r + 14), rx = (int16_t)nc_rd16(r + 16);
        const bool ok = buttons == w.buttons && (r[4] != 0) == (w.analog[0] != 0) &&
                        (r[11] != 0) == (w.analog[7] > 0x40) && lx == 0 && ly == (w.ly ? 20480 : 0) &&
                        rx == (w.rx ? -32767 : 0);
        if (!ok) {
            printf("frame %llu: buttons %04x a %02x rt %02x lx %d ly %d rx %d\n", (unsigned long long)g_swaps,
                   buttons, r[4], r[11], lx, ly, rx);
        }
        CHECK(ok);
    }
    printf(g_fail ? "replay: %d FAILED\n" : "replay: all passed\n", g_fail);
    return g_fail != 0;
}

int main(int argc, char **argv)
{
    setvbuf(stdout, NULL, _IONBF, 0);
    if (argc == 3 && !strcmp(argv[1], "record")) {
        return record_main(argv[2]);
    }
    if (argc == 3 && !strcmp(argv[1], "replay")) {
        return replay_main(argv[2]);
    }
    fprintf(stderr, "usage: pad_script_test record|replay <file>\n");
    return 2;
}
