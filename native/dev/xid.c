/*
 * hakuX native core — the Xbox gamepad (Duke): an XID device (class 0x58)
 * with a 20-byte input report on interrupt IN 2 and the rumble report on
 * interrupt OUT 2.
 *
 * Input comes from nc_pad_set, and for headless runs from NC_PAD_SCRIPT:
 * "ms:input[+input...]:hold_ms,..." (inputs: a b x y black white lt rt up
 * down left right start back ls rs, or a stick's position lx= ly= rx= ry=
 * -32767..32767), times from the first report; "60f:a:2" counts frames
 * instead (frame 60, held for 2: the HLE GPU's swaps in this process, after
 * a savestate's load the frames since it), the same each run. "@path" reads
 * it from a file (debug.hakux.env holds 91 characters); steps are separated
 * by commas or new lines, "#" starts a comment.
 * NC_PAD_RECORD=<path> writes player 1's input in that format (frames) for
 * NC_PAD_SCRIPT to replay; NC_PAD_STATE=1 makes both wait for a savestate's
 * load (tools/diag/route.ps1).
 */
#include "native/dev/usb.h"
#include "native/core/irq.h"
#include "hw/xbox/hle/vk/back.h"

#include <pthread.h>
#include <stdio.h>
#include <stdlib.h>
#include <string.h>
#include <time.h>

#define XID_PLAYERS 4

typedef struct Xid {
    NcUsbDev dev;
    unsigned player;
} Xid;

static const uint8_t k_dev_desc[18] = {
    18, 1, 0x10, 0x01, /* USB 1.1 */
    0, 0, 0,           /* class per interface */
    0x40,
    0x5e, 0x04, 0x02, 0x02, /* Microsoft, controller (0x0202) */
    0x00, 0x01, 1, 2, 3, 1,
};

static const uint8_t k_cfg_desc[32] = {
    9, 2, 32, 0, 1, 1, 0, 0x80, 50,
    9, 4, 0, 0, 2, 0x58, 0x42, 0, 0,  /* XID interface */
    7, 5, 0x82, 0x03, 0x20, 0, 4,     /* report: interrupt IN 2 */
    7, 5, 0x02, 0x03, 0x20, 0, 4,     /* rumble: interrupt OUT 2 */
};

static const uint8_t k_xid_desc[16] = {
    16, 0x42, 0x00, 0x01, /* XID 1.00 */
    1, 1,                 /* gamepad */
    20, 6,                /* input, output report sizes */
    0xff, 0xff, 0xff, 0xff, 0xff, 0xff, 0xff, 0xff,
};

static const char *const k_strings[] = {"hakuX", "Microsoft Xbox Controller", "1"};

static pthread_mutex_t g_lock = PTHREAD_MUTEX_INITIALIZER;
static NcPadState g_pad[XID_PLAYERS];
static uint16_t g_rumble[XID_PLAYERS][2];

/* NC_PAD_SCRIPT (replay) and NC_PAD_RECORD (recording, in the same format).
 * With NC_PAD_STATE=1 both wait for a process started from a savestate: a
 * savestate's load starts the core again (NativeCoreActivity.restartInto),
 * and the boot before it neither plays the script nor records. */
typedef struct ScriptStep {
    uint32_t at, hold;  /* ms, or frames */
    bool frames;
    uint16_t buttons;
    uint8_t analog;     /* bit n: analog[n] fully pressed */
    uint8_t sticks;     /* bit n: stick[n] (lx ly rx ry) set */
    int16_t stick[4];
} ScriptStep;
static ScriptStep *g_script;
static unsigned g_nscript, g_script_lo;
static bool g_script_sorted;    /* one unit, ascending starts: replay stops at the first future step */
static uint64_t g_script_t0;

bool nc_core_state_loaded(void);    /* native/core/core.h */

static bool pad_state_gate(void)
{
    const char *s = getenv("NC_PAD_STATE");
    return !s || *s != '1' || nc_core_state_loaded();
}

static uint64_t now_ms(void)
{
    struct timespec ts;
    clock_gettime(CLOCK_MONOTONIC, &ts);
    return (uint64_t)ts.tv_sec * 1000 + (uint64_t)ts.tv_nsec / 1000000;
}

static const struct {
    const char *name;
    uint16_t buttons;
    uint8_t analog;
} k_names[] = {
    {"a", 0, 1 << 0}, {"b", 0, 1 << 1}, {"x", 0, 1 << 2}, {"y", 0, 1 << 3},
    {"black", 0, 1 << 4}, {"white", 0, 1 << 5}, {"lt", 0, 1 << 6}, {"rt", 0, 1 << 7},
    {"up", NC_PAD_DPAD_UP, 0}, {"down", NC_PAD_DPAD_DOWN, 0}, {"left", NC_PAD_DPAD_LEFT, 0},
    {"right", NC_PAD_DPAD_RIGHT, 0}, {"start", NC_PAD_START, 0}, {"back", NC_PAD_BACK, 0},
    {"ls", NC_PAD_LTHUMB, 0}, {"rs", NC_PAD_RTHUMB, 0},
};
static const char k_sticks[4][3] = {"lx", "ly", "rx", "ry"};

static bool script_button(const char *name, size_t n, ScriptStep *st)
{
    for (size_t i = 0; i < sizeof(k_names) / sizeof(k_names[0]); i++) {
        if (strlen(k_names[i].name) == n && !strncmp(k_names[i].name, name, n)) {
            st->buttons |= k_names[i].buttons;
            st->analog |= k_names[i].analog;
            return true;
        }
    }
    for (unsigned i = 0; i < 4; i++) {
        if (n > 3 && !strncmp(name, k_sticks[i], 2) && name[2] == '=') {
            const long v = strtol(name + 3, NULL, 10);
            st->stick[i] = (int16_t)(v > 32767 ? 32767 : v < -32767 ? -32767 : v);
            st->sticks |= 1u << i;
            return true;
        }
    }
    return false;
}

/* Separators between steps: commas, white space, and "#" comments to the
 * line's end (a recording is a step a line under a "#" header). */
static const char *script_skip(const char *s)
{
    for (;;) {
        if (*s == ',' || *s == ' ' || *s == '\t' || *s == '\r' || *s == '\n') {
            s++;
        } else if (*s == '#') {
            s += strcspn(s, "\n");
        } else {
            return s;
        }
    }
}

static char *script_read_file(const char *path)
{
    FILE *f = fopen(path, "r");
    if (!f) {
        nc_log("hakuX-native-usb", "pad script: can't read %s", path);
        return NULL;
    }
    size_t cap = 1 << 16, n = 0;
    char *buf = malloc(cap);
    for (size_t got; buf && (got = fread(buf + n, 1, cap - 1 - n, f)) > 0;) {
        n += got;
        if (n + 1 == cap) {
            char *b = realloc(buf, cap *= 2);
            if (!b) {
                free(buf);
                buf = NULL;
            }
            buf = b;
        }
    }
    fclose(f);
    if (buf) {
        buf[n] = 0;
    }
    return buf;
}

static void script_parse(const char *s)
{
    unsigned cap = 0;
    bool sorted = true;
    for (s = script_skip(s); *s; s = script_skip(s)) {
        ScriptStep st = {0};
        char *end;
        st.at = (uint32_t)strtoul(s, &end, 10);
        st.frames = *end == 'f';
        end += st.frames;
        if (end == s || *end != ':') {
            nc_log("hakuX-native-usb", "pad script: stopped at '%.20s'", s);
            break;
        }
        s = end + 1;
        while (*s && !strchr(":,# \t\r\n", *s)) {
            size_t n = strcspn(s, "+:,# \t\r\n");
            if (!script_button(s, n, &st)) {
                nc_log("hakuX-native-usb", "pad script: unknown input '%.*s'", (int)n, s);
            }
            s += n;
            if (*s == '+') {
                s++;
            }
        }
        st.hold = st.frames ? 9 : 150;
        if (*s == ':') {
            st.hold = (uint32_t)strtoul(s + 1, &end, 10);
            s = end + (*end == 'f');
        }
        if (g_nscript == cap) {
            cap = cap ? cap * 2 : 64;
            ScriptStep *n = realloc(g_script, cap * sizeof(*n));
            if (!n) {
                break;
            }
            g_script = n;
        }
        if (g_nscript) {
            const ScriptStep *p = &g_script[g_nscript - 1];
            sorted &= p->frames == st.frames && p->at <= st.at;
        }
        g_script[g_nscript++] = st;
    }
    g_script_sorted = sorted;
}

static void script_load(void)
{
    const char *s = getenv("NC_PAD_SCRIPT");
    if (!s || g_nscript) {
        return;
    }
    char *file = NULL;
    if (*s == '@') {
        s = file = script_read_file(s + 1);
    }
    if (s) {
        script_parse(s);
    }
    free(file);
    if (!g_nscript) {
        nc_log("hakuX-native-usb", "pad script: no steps");
        return;
    }
    const ScriptStep *l = &g_script[g_nscript - 1];
    nc_log("hakuX-native-usb", "pad script: %u steps, the last ending at %s %u%s", g_nscript,
           l->frames ? "frame" : "ms", l->at + l->hold,
           getenv("NC_PAD_STATE") ? " (waits for a savestate's load)" : "");
}

/* The script's input at this moment over p (player 1). */
static void script_apply(NcPadState *p)
{
    if (!g_script_t0) {
        g_script_t0 = now_ms();
        nc_log("hakuX-native-usb", "pad script: started (frame %llu)",
               (unsigned long long)hle_back_swap_count());
    }
    const uint64_t ms = now_ms() - g_script_t0, frame = hle_back_swap_count();
    if (g_script_sorted) {
        /* the steps before lo all ended (one unit: their ends stay ended) */
        while (g_script_lo < g_nscript) {
            const ScriptStep *st = &g_script[g_script_lo];
            if ((st->frames ? frame : ms) < (uint64_t)st->at + st->hold) {
                break;
            }
            if (++g_script_lo == g_nscript) {
                nc_log("hakuX-native-usb", "pad script: done (frame %llu, %llu ms)",
                       (unsigned long long)frame, (unsigned long long)ms);
            }
        }
    }
    for (unsigned i = g_script_sorted ? g_script_lo : 0; i < g_nscript; i++) {
        const ScriptStep *st = &g_script[i];
        const uint64_t t = st->frames ? frame : ms;
        if (t < st->at) {
            if (g_script_sorted) {
                break;
            }
            continue;
        }
        if (t < (uint64_t)st->at + st->hold) {
            p->buttons |= st->buttons;
            for (unsigned b = 0; b < 8; b++) {
                if (st->analog & (1u << b)) {
                    p->analog[b] = 0xff;
                }
            }
            int16_t *axis[4] = {&p->lx, &p->ly, &p->rx, &p->ry};
            for (unsigned a = 0; a < 4; a++) {
                if (st->sticks & (1u << a)) {
                    *axis[a] = st->stick[a];
                }
            }
        }
    }
}

/* NC_PAD_RECORD=<path>: player 1's input as the script's steps, timed in
 * frames (the HLE GPU's swaps, as "60f:" replays them): one step for each
 * stretch of the same input, idle stretches left out. Sticks are rounded
 * to steps of 2048 with a dead zone, analog buttons count as pressed past
 * a quarter. Written a second at a time (a kill loses at most the last). */
#define REC_STICK_STEP 2048
#define REC_DEADZONE   4000
static struct {
    bool init, on;
    FILE *f;
    NcPadState cur;     /* the stretch's input, rounded */
    uint64_t since;     /* its first frame */
    uint64_t flushed_ms;
    unsigned steps;
} g_rec;

static int16_t rec_axis(int16_t v)
{
    if (v > -REC_DEADZONE && v < REC_DEADZONE) {
        return 0;
    }
    int r = (v + (v < 0 ? -REC_STICK_STEP / 2 : REC_STICK_STEP / 2)) / REC_STICK_STEP * REC_STICK_STEP;
    return (int16_t)(r > 32767 ? 32767 : r < -32767 ? -32767 : r);
}

static NcPadState rec_round(const NcPadState *s)
{
    NcPadState r = {.buttons = s->buttons};
    for (unsigned b = 0; b < 8; b++) {
        r.analog[b] = s->analog[b] > 0x40 ? 0xff : 0;
    }
    r.lx = rec_axis(s->lx);
    r.ly = rec_axis(s->ly);
    r.rx = rec_axis(s->rx);
    r.ry = rec_axis(s->ry);
    return r;
}

/* The stretch from g_rec.since to frame as one step (nothing when idle). */
static void rec_emit(uint64_t frame)
{
    const NcPadState *c = &g_rec.cur;
    char line[160];
    int n = snprintf(line, sizeof(line), "%lluf:", (unsigned long long)g_rec.since);
    const int start = n;
    for (size_t i = 0; i < sizeof(k_names) / sizeof(k_names[0]); i++) {
        const bool on = k_names[i].buttons ? (c->buttons & k_names[i].buttons) != 0
                                           : c->analog[__builtin_ctz(k_names[i].analog)] != 0;
        if (on) {
            n += snprintf(line + n, sizeof(line) - n, "%s%s", n > start ? "+" : "", k_names[i].name);
        }
    }
    const int16_t axis[4] = {c->lx, c->ly, c->rx, c->ry};
    for (unsigned a = 0; a < 4; a++) {
        if (axis[a]) {
            n += snprintf(line + n, sizeof(line) - n, "%s%s=%d", n > start ? "+" : "", k_sticks[a], axis[a]);
        }
    }
    if (n == start) {
        return;
    }
    const uint64_t hold = frame > g_rec.since ? frame - g_rec.since : 1;
    fprintf(g_rec.f, "%s:%lluf\n", line, (unsigned long long)hold);
    g_rec.steps++;
}

/* Under g_lock. */
static void rec_pad(const NcPadState *s)
{
    if (!g_rec.init) {
        const char *path = getenv("NC_PAD_RECORD");
        if (!path || !*path) {
            g_rec.init = true;
            return;
        }
        if (!pad_state_gate()) {
            return;     /* the boot before the savestate's: not yet */
        }
        g_rec.init = true;
        g_rec.f = fopen(path, "w");
        if (!g_rec.f) {
            nc_log("hakuX-native-usb", "pad record: can't write %s", path);
            return;
        }
        g_rec.on = true;
        g_rec.since = hle_back_swap_count();
        g_rec.flushed_ms = now_ms();
        fprintf(g_rec.f, "# hakuX pad recording (NC_PAD_SCRIPT, frames%s), from frame %llu\n",
                nc_core_state_loaded() ? " since the savestate's load" : " since boot",
                (unsigned long long)g_rec.since);
        nc_log("hakuX-native-usb", "pad record: to %s from frame %llu", path, (unsigned long long)g_rec.since);
    }
    if (!g_rec.on) {
        return;
    }
    const NcPadState r = rec_round(s);
    const uint64_t frame = hle_back_swap_count();
    if (memcmp(&r, &g_rec.cur, sizeof(r))) {
        rec_emit(frame);
        g_rec.cur = r;
        g_rec.since = frame;
    }
    const uint64_t ms = now_ms();
    if (ms - g_rec.flushed_ms >= 1000) {
        /* the stretch in progress too, cut here and picked up again (a
         * kill keeps everything up to the last second) */
        rec_emit(frame);
        g_rec.since = frame;
        fflush(g_rec.f);
        g_rec.flushed_ms = ms;
    }
}

static void make_report(unsigned player, uint8_t r[20])
{
    NcPadState p;
    pthread_mutex_lock(&g_lock);
    p = g_pad[player];
    pthread_mutex_unlock(&g_lock);

    if (player == 0 && g_nscript && pad_state_gate()) {
        script_apply(&p);
    }

    r[0] = 0;  /* report id */
    r[1] = 20; /* length */
    nc_wr16(r + 2, p.buttons);
    memcpy(r + 4, p.analog, 8);
    nc_wr16(r + 12, (uint16_t)p.lx);
    nc_wr16(r + 14, (uint16_t)p.ly);
    nc_wr16(r + 16, (uint16_t)p.rx);
    nc_wr16(r + 18, (uint16_t)p.ry);
}

static void take_rumble(unsigned player, const uint8_t *r, int len)
{
    if (len < 6) {
        return;
    }
    pthread_mutex_lock(&g_lock);
    g_rumble[player][0] = nc_rd16(r + 2);
    g_rumble[player][1] = nc_rd16(r + 4);
    pthread_mutex_unlock(&g_lock);
}

static int xid_control(NcUsbDev *d, const uint8_t *s, uint8_t *data, int len)
{
    Xid *x = (Xid *)d;
    const uint8_t type = s[0], req = s[1];
    const uint16_t value = nc_rd16(s + 2);
    switch ((type << 8) | req) {
    case 0xA101: /* HID GET_REPORT */
        if (value != 0x0100) {
            return NC_USB_STALL;
        }
        {
            uint8_t r[20];
            make_report(x->player, r);
            memcpy(data, r, MIN(len, 20));
            return MIN(len, 20);
        }
    case 0x2109: /* HID SET_REPORT */
        if (value != 0x0200) {
            return NC_USB_STALL;
        }
        take_rumble(x->player, data, len);
        return 0;
    case 0xC106: /* XID GET_DESCRIPTOR */
        if (value != 0x4200) {
            return NC_USB_STALL;
        }
        memcpy(data, k_xid_desc, MIN(len, (int)sizeof(k_xid_desc)));
        return MIN(len, (int)sizeof(k_xid_desc));
    case 0xC101: /* XID GET_CAPABILITIES: every bit and axis is live */
        if (value == 0x0100) {
            memset(data, 0xff, MIN(len, 20));
            data[0] = 0;
            if (len > 1) {
                data[1] = 20;
            }
            return MIN(len, 20);
        }
        if (value == 0x0200) {
            memset(data, 0xff, MIN(len, 6));
            data[0] = 0;
            if (len > 1) {
                data[1] = 6;
            }
            return MIN(len, 6);
        }
        return NC_USB_STALL;
    default:
        nc_log("hakuX-native-usb", "xid: unhandled request %02x %02x value %04x", type, req, value);
        return NC_USB_STALL;
    }
}

static int xid_data(NcUsbDev *d, bool in, int ep, uint8_t *buf, int len)
{
    Xid *x = (Xid *)d;
    if (ep != 2) {
        return NC_USB_STALL;
    }
    if (in) {
        static bool polled[XID_PLAYERS];
        if (!polled[x->player]) {
            polled[x->player] = true;
            nc_log("hakuX-native-usb", "gamepad %u: polled", x->player);
        }
        uint8_t r[20];
        make_report(x->player, r);
        {   /* button changes as the title reads them (a few a second at most) */
            static uint16_t s_last[XID_PLAYERS];
            static unsigned s_logged;
            const uint16_t b = (uint16_t)(r[2] | r[3] << 8);
            if (b != s_last[x->player] && s_logged < 200) {
                s_logged++;
                nc_log("hakuX-native-usb", "gamepad %u: buttons %04x -> %04x (A %02x)", x->player,
                       s_last[x->player], b, r[4]);
            }
            s_last[x->player] = b;
        }
        const int n = MIN(len, 20);
        memcpy(buf, r, n);
        return n;
    }
    take_rumble(x->player, buf, len);
    return len;
}

NcUsbDev *nc_xid_gamepad_new(unsigned player)
{
    Xid *x = calloc(1, sizeof(Xid));
    x->player = player % XID_PLAYERS;
    x->dev.name = "gamepad";
    x->dev.dev_desc = k_dev_desc;
    x->dev.dev_desc_len = sizeof(k_dev_desc);
    x->dev.cfg_desc = k_cfg_desc;
    x->dev.cfg_desc_len = sizeof(k_cfg_desc);
    x->dev.strings = k_strings;
    x->dev.nstrings = 3;
    x->dev.control = xid_control;
    x->dev.data = xid_data;
    x->dev.pending_addr = -1;
    script_load();
    return &x->dev;
}

void nc_pad_set(unsigned player, const NcPadState *s)
{
    if (player < XID_PLAYERS) {
        pthread_mutex_lock(&g_lock);
        g_pad[player] = *s;
        if (player == 0) {
            rec_pad(s);
        }
        pthread_mutex_unlock(&g_lock);
    }
}

void nc_pad_record_flush(void)
{
    pthread_mutex_lock(&g_lock);
    if (g_rec.on) {
        const uint64_t frame = hle_back_swap_count();
        rec_emit(frame);
        g_rec.since = frame;
        fflush(g_rec.f);
        g_rec.flushed_ms = now_ms();
        nc_log("hakuX-native-usb", "pad record: %u steps to frame %llu", g_rec.steps, (unsigned long long)frame);
    }
    pthread_mutex_unlock(&g_lock);
}

void nc_pad_rumble(unsigned player, uint16_t *left, uint16_t *right)
{
    if (player < XID_PLAYERS) {
        pthread_mutex_lock(&g_lock);
        *left = g_rumble[player][0];
        *right = g_rumble[player][1];
        pthread_mutex_unlock(&g_lock);
    }
    /* Paused (the menu open, the device asleep), the motors stop: the
     * title's last strengths went on shaking the controller meanwhile. Its
     * strengths come back with the emulation. */
    if (nc_paused()) {
        *left = *right = 0;
    }
}
