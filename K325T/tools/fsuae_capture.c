/* fsuae_capture.c -- LD_PRELOAD frame capture for FS-UAE on a PC without a display (reference
 * recordings of A1200 demos for the stage-3 groundwork).  Own code.
 *
 * FS-UAE runs with SDL_VIDEODRIVER=offscreen (OpenGL through EGL, no window); this library wraps
 * SDL_GL_SwapWindow and reads every rendered frame back.  The same library works for the Unix port of
 * WinUAE 6.1 (SDL3, OpenGL presenter, run on Xvfb): SDL3's SDL_GetWindowSizeInPixels replaces SDL2's
 * SDL_GL_GetDrawableSize (glReadPixels of the back buffer before
 * the swap):
 *   CAP_VIDEO=FILE    every CAP_SKIP-th frame (default 1) piped into ffmpeg (H.264, CRF 14)
 *   CAP_PPM=PREFIX    every CAP_PPM_EVERY-th frame also as PREFIX_<frame>.ppm (raw, for checks)
 *   CAP_FRAMES=N      after N frames: SIGINT to the process (FS-UAE quits cleanly)
 *   CAP_FPS=F         frame rate written into the video (default 50 / CAP_SKIP)
 *   CAP_CLICK=N[,N..] scripted input: a left mouse button press at swap N, released 6 swaps later
 *                     (RN: the right button)
 *                     (SDL_PushEvent into the emulator's own event queue; SDL2 and SDL3 layouts)
 *   CAP_KEY=N:K[,N:K..] scripted key press (SDL2 only, i.e. FS-UAE): function key F<K> (1..12) at swap
 *                     N, released 6 swaps later -- with "keyboard_key_f<K> = action_drive_0_insert_floppy_<i>"
 *                     in the FS-UAE config this swaps disks in a single drive (run_fsuae.py --swap)
 *   CAP_HOTKEY=N:D[,..] scripted WinUAE hotkey (SDL3 only): End held + digit D at swap N (WinUAE's
 *                     "End+1..0: disk swapper slot 1..10 into DF0"), all released 6 swaps later;
 *                     N:F<k>: function key F<k> alone (for a key mapped in the WinUAE configuration)
 * Build: gcc -O2 -shared -fPIC -o fsuae_capture.so fsuae_capture.c -ldl
 */
#define _GNU_SOURCE
#include <dlfcn.h>
#include <signal.h>
#include <stdio.h>
#include <stdlib.h>
#include <string.h>
#include <unistd.h>

typedef void (*swap_fn)(void *);
typedef void (*getsize_fn)(void *, int *, int *);
typedef void *(*getproc_fn)(const char *);
typedef void (*readpixels_fn)(int, int, int, int, unsigned, unsigned, void *);
typedef void (*readbuffer_fn)(unsigned);
typedef void (*pixelstore_fn)(unsigned, int);

#define GL_RGB 0x1907
#define GL_UNSIGNED_BYTE 0x1401
#define GL_BACK 0x0405
#define GL_PACK_ALIGNMENT 0x0D05

static long frame = 0;
static FILE *vid = NULL;
static int vw = 0, vh = 0;
static unsigned char *buf = NULL;
static int v0w = 0, v0h = 0;
static long nvid = 0, nskip = 0;
static int sdl2 = 0;       /* SDL2 (FS-UAE) or SDL3 (WinUAE): the event layouts differ */
static int finished = 0;   /* after CAP_FRAMES: no more capture (FS-UAE still swaps while it quits;
                              a new ffmpeg would truncate the video) */

/* scripted mouse button (CAP_CLICK) */
typedef int (*push_fn)(void *);
typedef unsigned (*winid_fn)(void *);
static void push_button(void *win, int down, int button)
{
    static push_fn push = NULL;
    static winid_fn winid = NULL;
    if (!push) {
        push = (push_fn)dlsym(RTLD_NEXT, "SDL_PushEvent");
        winid = (winid_fn)dlsym(RTLD_NEXT, "SDL_GetWindowID");
    }
    unsigned char ev[128];
    memset(ev, 0, sizeof ev);
    unsigned type = down ? 0x401 : 0x402;    /* SDL_MOUSEBUTTONDOWN/UP = SDL_EVENT_MOUSE_BUTTON_DOWN/UP */
    unsigned id = winid ? winid(win) : 0;
    memcpy(ev, &type, 4);
    if (sdl2) {   /* type, timestamp, windowID, which, button, state, clicks, pad, x, y */
        memcpy(ev + 8, &id, 4);
        ev[16] = button; ev[17] = down ? 1 : 0; ev[18] = 1;
        int xy[2] = {100, 100}; memcpy(ev + 20, xy, 8);
    } else {      /* type, reserved, Uint64 timestamp, windowID, which, button, down, clicks, pad, x, y */
        memcpy(ev + 16, &id, 4);
        ev[24] = button; ev[25] = down ? 1 : 0; ev[26] = 1;
        float xy[2] = {100.0f, 100.0f}; memcpy(ev + 28, xy, 8);
    }
    if (push) {
        int r = push(ev);
        fprintf(stderr, "[capture] swap %ld: mouse button %d %s (push %d)\n", frame, button, down ? "down" : "up", r);
    }
}

static void click(void *win)
{
    const char *c = getenv("CAP_CLICK");
    if (!c) return;
    while (*c) {
        int button = 1;                       /* SDL_BUTTON_LEFT; SDL_BUTTON_RIGHT = 3 */
        if (*c == 'R') { button = 3; c++; }
        long n = strtol(c, (char **)&c, 10);
        if (frame == n) push_button(win, 1, button);
        if (frame == n + 6) push_button(win, 0, button);
        if (*c == ',') c++; else break;
    }
}

/* scripted function key (CAP_KEY), SDL2 layout: type, timestamp, windowID, state, repeat, pad[2],
   keysym { scancode (Sint32), sym (Sint32), mod (Uint16), unused (Uint32) } */
static void push_fkey(void *win, int down, int k)
{
    static push_fn push = NULL;
    static winid_fn winid = NULL;
    if (!push) {
        push = (push_fn)dlsym(RTLD_NEXT, "SDL_PushEvent");
        winid = (winid_fn)dlsym(RTLD_NEXT, "SDL_GetWindowID");
    }
    if (!sdl2 || !push) return;
    unsigned char ev[128];
    memset(ev, 0, sizeof ev);
    unsigned type = down ? 0x300 : 0x301;    /* SDL_KEYDOWN / SDL_KEYUP */
    unsigned id = winid ? winid(win) : 0;
    int scancode = 57 + k;                   /* SDL_SCANCODE_F1 = 58 */
    int sym = scancode | (1 << 30);          /* SDLK_F1 = SDL_SCANCODE_TO_KEYCODE(58) */
    memcpy(ev, &type, 4);
    memcpy(ev + 8, &id, 4);
    ev[12] = down ? 1 : 0;
    memcpy(ev + 16, &scancode, 4);
    memcpy(ev + 20, &sym, 4);
    int r = push(ev);
    fprintf(stderr, "[capture] swap %ld: key F%d %s (push %d)\n", frame, k, down ? "down" : "up", r);
}

static void keys(void *win)
{
    const char *c = getenv("CAP_KEY");
    if (!c) return;
    while (*c) {
        long n = strtol(c, (char **)&c, 10);
        int k = 0;
        if (*c == ':') { c++; k = (int)strtol(c, (char **)&c, 10); }
        if (k >= 1 && k <= 12) {
            if (frame == n) push_fkey(win, 1, k);
            if (frame == n + 6) push_fkey(win, 0, k);
        }
        if (*c == ',') c++; else break;
    }
}

/* SDL3 key event: type, reserved, Uint64 timestamp, windowID, which, scancode, key, mod (16), raw (16),
   down (bool), repeat (bool) */
static void push_key3(void *win, int down, int scancode, int key)
{
    static push_fn push = NULL;
    static winid_fn winid = NULL;
    if (!push) {
        push = (push_fn)dlsym(RTLD_NEXT, "SDL_PushEvent");
        winid = (winid_fn)dlsym(RTLD_NEXT, "SDL_GetWindowID");
    }
    if (sdl2 || !push) return;
    unsigned char ev[128];
    memset(ev, 0, sizeof ev);
    unsigned type = down ? 0x300 : 0x301;    /* SDL_EVENT_KEY_DOWN / UP */
    unsigned id = winid ? winid(win) : 0;
    memcpy(ev, &type, 4);
    memcpy(ev + 16, &id, 4);
    memcpy(ev + 24, &scancode, 4);
    memcpy(ev + 28, &key, 4);
    /* raw: the X11 keycode (evdev + 8) of the few keys used here, for front ends that read it */
    unsigned short raw = 0;
    if (scancode == 77) raw = 115;                                   /* End */
    else if (scancode >= 30 && scancode <= 39) raw = scancode - 20;   /* 1..9, 0 -> evdev 2..11 */
    else if (scancode >= 58 && scancode <= 67) raw = scancode + 9;    /* F1..F10 -> evdev 59..68 */
    memcpy(ev + 34, &raw, 2);
    ev[36] = down ? 1 : 0;
    int r = push(ev);
    fprintf(stderr, "[capture] swap %ld: key sc %d %s (push %d)\n", frame, scancode, down ? "down" : "up", r);
}

static void hotkeys(void *win)
{
    const char *c = getenv("CAP_HOTKEY");
    if (!c) return;
    const int END_SC = 77, END_KEY = 0x4000004D;       /* SDL_SCANCODE_END, SDLK_END */
    while (*c) {
        long n = strtol(c, (char **)&c, 10);
        int d = -1, fk = 0;
        int sh = 0;
        if (*c == ':') { c++; if (*c == 'S') { c++; sh = 1; } if (*c == 'F') { c++; fk = 1; } d = (int)strtol(c, (char **)&c, 10); }
        if (fk && d >= 1 && d <= 12) {               /* N:F<k>: a plain function key */
            if (frame == n) push_key3(win, 1, 57 + d, (57 + d) | (1 << 30));
            if (frame == n + 6) push_key3(win, 0, 57 + d, (57 + d) | (1 << 30));
        } else if (d >= 0 && d <= 9) {
            int sc = d == 0 ? 39 : 29 + d;               /* SDL_SCANCODE_1 = 30 .. _9 = 38, _0 = 39 */
            int key = '0' + d;
            if (frame == n) push_key3(win, 1, END_SC, END_KEY);
            if (sh && frame == n + 1) push_key3(win, 1, 225, 0x400000E1);   /* N:S<d>: End + Shift + digit */
            if (frame == n + 2) push_key3(win, 1, sc, key);
            if (frame == n + 6) push_key3(win, 0, sc, key);
            if (sh && frame == n + 7) push_key3(win, 0, 225, 0x400000E1);
            if (frame == n + 8) push_key3(win, 0, END_SC, END_KEY);
        }
        if (*c == ',') c++; else break;
    }
}

/* --- aexp21_bacon: the emulator's NATIVE picture (the texture upload before scaling) ---
 *   CAP_NAT=PREFIX       PREFIX.log: one line per swap: frame, texture w h, crc32 of the window
 *   CAP_NAT_WIN=x,y,w,h  window in texture pixels (default: whole texture), h = rows taken; CAP_NAT_XS=n:
 *                        every n-th column; CAP_NAT_YS=n: every n-th row (2 = one row of a doubled line);
 *                        the CRC is K325T/fmeas.v's (12-bit pixels, reflected CRC-32)
 *   CAP_NAT_PPM=a,b,c..  also write PREFIX_<frame>.ppm (whole texture, RGB) for these frames
 *   CAP_NAT_EVERY=n      ... and every n-th frame */
typedef void (*texsub_fn)(unsigned, int, int, int, int, int, unsigned, unsigned, const void *);
static unsigned char *nat = NULL; static int natw = 0, nath = 0; static unsigned natfmt = 0, nattype = 0;
static long nuploads = 0;
static texsub_fn real_texsub = NULL;     /* set by the SDL_GL_GetProcAddress hook (FS-UAE) or dlsym (WinUAE) */
void glTexSubImage2D(unsigned target, int level, int x, int y, int w, int h, unsigned fmt, unsigned type,
                     const void *px)
{
    texsub_fn real = real_texsub;
    if (!real) real = real_texsub = (texsub_fn)dlsym(RTLD_NEXT, "glTexSubImage2D");
    static long ncalls = 0;
    if (getenv("CAP_NAT_DEBUG") && ncalls++ < 40) fprintf(stderr, "[nat] call x %d y %d w %d h %d fmt %#x type %#x\n", x, y, w, h, fmt, type);
    if (getenv("CAP_NAT") && px && w >= 320 && h >= 200 && x == 0 && y == 0 && level == 0) {
        if (w != natw || h != nath || !nat) { free(nat); nat = malloc((size_t)w * h * 4); natw = w; nath = h; }
        if (nuploads < 3) fprintf(stderr, "[nat] upload %dx%d fmt %#x type %#x\n", w, h, fmt, type);
        natfmt = fmt; nattype = type;
        memcpy(nat, px, (size_t)w * h * 4);   /* assumes 4 bytes per pixel (checked in the log) */
        nuploads++;
    }
    real(target, level, x, y, w, h, fmt, type, px);
}
/* FS-UAE resolves its GL functions through SDL: hand it the wrapper above */
void *SDL_GL_GetProcAddress(const char *name)
{
    static getproc_fn real = NULL;
    if (!real) real = (getproc_fn)dlsym(RTLD_NEXT, "SDL_GL_GetProcAddress");
    void *p = real(name);
    if (name && getenv("CAP_NAT") && strcmp(name, "glTexSubImage2D") == 0) {
        real_texsub = (texsub_fn)p;
        return (void *)glTexSubImage2D;
    }
    return p;
}
static unsigned crc_tab[256];
static unsigned crc32b(unsigned c, unsigned char b)
{
    if (!crc_tab[1]) for (unsigned i = 0; i < 256; i++) { unsigned r = i; for (int k = 0; k < 8; k++) r = r & 1 ? (r >> 1) ^ 0xEDB88320u : r >> 1; crc_tab[i] = r; }
    return crc_tab[(c ^ b) & 0xff] ^ (c >> 8);
}
static FILE *natlog = NULL;
static void nat_frame(long fr)
{
    const char *pre = getenv("CAP_NAT");
    if (!pre || !nat || finished) return;
    if (!natlog) { char fn[1024]; snprintf(fn, sizeof fn, "%s.log", pre); natlog = fopen(fn, "w"); }
    int x0 = 0, y0 = 0, ww = natw, hh = nath, xs = 1;
    if (getenv("CAP_NAT_WIN")) sscanf(getenv("CAP_NAT_WIN"), "%d,%d,%d,%d", &x0, &y0, &ww, &hh);
    if (getenv("CAP_NAT_XS")) xs = atoi(getenv("CAP_NAT_XS"));
    if (xs < 1) xs = 1;
    int ys = getenv("CAP_NAT_YS") ? atoi(getenv("CAP_NAT_YS")) : 1;
    if (ys < 1) ys = 1;
    unsigned c = 0xffffffffu;
    /* pixel bytes: GL_BGRA (0x80e1) -> b g r a; GL_RGBA (0x1908) -> r g b a.  CRC exactly as K325T/fmeas.v:
     * 12 bits {R[7:4], G[7:4], B[7:4]} fed LSB first into the reflected CRC-32 (rows y0, y0+ys, ..) */
    int bgra = natfmt == 0x80e1;
    for (int y = y0; y < y0 + hh * ys && y < nath; y += ys)
        for (int x = x0; x < x0 + ww && x < natw; x += xs) {
            unsigned char *p = nat + ((size_t)y * natw + x) * 4;
            unsigned char r = bgra ? p[2] : p[0], g = p[1], b = bgra ? p[0] : p[2];
            unsigned d = (unsigned)(r >> 4) << 8 | (unsigned)(g >> 4) << 4 | (unsigned)(b >> 4);
            for (int i = 0; i < 12; i++) c = ((c ^ (d >> i)) & 1) ? (c >> 1) ^ 0xEDB88320u : c >> 1;
        }
    c ^= 0xffffffffu;
    if (natlog) { fprintf(natlog, "%ld %d %d %08x\n", fr, natw, nath, c); fflush(natlog); }
    int dump = 0;
    long ev = getenv("CAP_NAT_EVERY") ? atol(getenv("CAP_NAT_EVERY")) : 0;
    if (ev > 0 && fr % ev == 0) dump = 1;
    const char *l = getenv("CAP_NAT_PPM");
    if (l) { const char *q = l; while (*q) { if (atol(q) == fr) dump = 1; while (*q && *q != ',') q++; if (*q) q++; } }
    if (dump) {
        char fn[1024]; snprintf(fn, sizeof fn, "%s_%06ld.ppm", pre, fr);
        FILE *f = fopen(fn, "wb");
        if (f) {
            fprintf(f, "P6 %d %d 255\n", natw, nath);
            for (size_t i = 0; i < (size_t)natw * nath; i++) {
                unsigned char *p = nat + i * 4; unsigned char o[3] = { bgra ? p[2] : p[0], p[1], bgra ? p[0] : p[2] };
                fwrite(o, 1, 3, f);
            }
            fclose(f);
        }
    }
}

void SDL_GL_SwapWindow(void *win)
{
    static swap_fn real = NULL;
    static getsize_fn getsize = NULL;
    static readpixels_fn rp = NULL;
    static readbuffer_fn rb = NULL;
    static pixelstore_fn ps = NULL;
    if (!real) {
        real = (swap_fn)dlsym(RTLD_NEXT, "SDL_GL_SwapWindow");
        getsize = (getsize_fn)dlsym(RTLD_NEXT, "SDL_GL_GetDrawableSize");        /* SDL2 (FS-UAE) */
        sdl2 = getsize != NULL;
        if (!getsize) getsize = (getsize_fn)dlsym(RTLD_NEXT, "SDL_GetWindowSizeInPixels"); /* SDL3 (WinUAE) */
        getproc_fn gp = (getproc_fn)dlsym(RTLD_NEXT, "SDL_GL_GetProcAddress");
        rp = (readpixels_fn)gp("glReadPixels");
        rb = (readbuffer_fn)gp("glReadBuffer");
        ps = (pixelstore_fn)gp("glPixelStorei");
    }
    const char *video = getenv("CAP_VIDEO");
    const char *ppm = getenv("CAP_PPM");
    long skip = getenv("CAP_SKIP") ? atol(getenv("CAP_SKIP")) : 1;
    long ppm_every = getenv("CAP_PPM_EVERY") ? atol(getenv("CAP_PPM_EVERY")) : 50;
    long maxf = getenv("CAP_FRAMES") ? atol(getenv("CAP_FRAMES")) : 0;
    int w = 0, h = 0;
    getsize(win, &w, &h);
    int want_v = video && skip > 0 && frame % skip == 0;
    int want_p = ppm && ppm_every > 0 && frame % ppm_every == 0;
    if (finished) { want_v = 0; want_p = 0; }
    if ((want_v || want_p) && w > 0 && h > 0) {
        if (w != vw || h != vh || !buf) {
            /* the video keeps the size of its first frame: frames of another size (FS-UAE's
             * start-up) are not written to it, only counted */
            if (vid && (w != vw || h != vh)) nskip++;
            free(buf);
            buf = malloc((size_t)w * h * 3);
            vw = w; vh = h;
        }
        rb(GL_BACK);
        ps(GL_PACK_ALIGNMENT, 1);
        rp(0, 0, w, h, GL_RGB, GL_UNSIGNED_BYTE, buf);
        if (want_v && vid && (w != v0w || h != v0h)) { nskip++; want_v = 0; }
        if (want_v) {
            if (!vid) {
                v0w = w; v0h = h;
                char cmd[2048];
                double fps = getenv("CAP_FPS") ? atof(getenv("CAP_FPS")) : 50.0 / skip;
                snprintf(cmd, sizeof cmd, "nice -n 19 ffmpeg -loglevel error -y -f rawvideo -pix_fmt rgb24 "
                         "-s %dx%d -r %g -i - -vf vflip -c:v libx264 -preset veryfast -crf 14 "
                         "-pix_fmt yuv420p -threads 1 '%s'", w, h, fps, video);
                vid = popen(cmd, "w");
            }
            if (vid) { fwrite(buf, 1, (size_t)w * h * 3, vid); nvid++; }
        }
        if (want_p) {
            char fn[1024];
            snprintf(fn, sizeof fn, "%s_%06ld.ppm", ppm, frame);
            FILE *f = fopen(fn, "wb");
            if (f) {
                fprintf(f, "P6 %d %d 255\n", w, h);
                for (int y = h - 1; y >= 0; y--) fwrite(buf + (size_t)y * w * 3, 1, (size_t)w * 3, f);
                fclose(f);
            }
        }
    }
    if (getenv("CAP_NAT_RB") && w > 0 && h > 0) {
        /* CAP_NAT_RB: the native picture is the window itself (FS-UAE with a 1:1 nearest-neighbour window):
         * read the back buffer and use it as the "texture" */
        static unsigned char *rgb = NULL; static int rw = 0, rh = 0;
        if (w != rw || h != rh) { free(rgb); rgb = malloc((size_t)w * h * 3); rw = w; rh = h; }
        if (w != natw || h != nath || !nat) { free(nat); nat = malloc((size_t)w * h * 4); natw = w; nath = h; }
        rb(GL_BACK); ps(GL_PACK_ALIGNMENT, 1);
        rp(0, 0, w, h, GL_RGB, GL_UNSIGNED_BYTE, rgb);
        for (int y = 0; y < h; y++)
            for (int x = 0; x < w; x++) {
                unsigned char *q = rgb + ((size_t)(h - 1 - y) * w + x) * 3, *o = nat + ((size_t)y * w + x) * 4;
                o[0] = q[2]; o[1] = q[1]; o[2] = q[0]; o[3] = 255;
            }
        natfmt = 0x80e1;
    }
    nat_frame(frame);
    real(win);
    click(win);
    keys(win);
    hotkeys(win);
    frame++;
    if (maxf && frame == maxf) {
        if (vid) { pclose(vid); vid = NULL; }
        if (natlog) { fclose(natlog); natlog = NULL; }
        fprintf(stderr, "[capture] %ld swaps, %ld video frames (%dx%d), %ld frames of another size skipped\n",
                frame, nvid, v0w, v0h, nskip);
        finished = 1;
        kill(getpid(), SIGINT);
    }
}
