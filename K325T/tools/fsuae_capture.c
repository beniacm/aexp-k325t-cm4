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
        if (*c == ':') { c++; if (*c == 'F') { c++; fk = 1; } d = (int)strtol(c, (char **)&c, 10); }
        if (fk && d >= 1 && d <= 12) {               /* N:F<k>: a plain function key */
            if (frame == n) push_key3(win, 1, 57 + d, (57 + d) | (1 << 30));
            if (frame == n + 6) push_key3(win, 0, 57 + d, (57 + d) | (1 << 30));
        } else if (d >= 0 && d <= 9) {
            int sc = d == 0 ? 39 : 29 + d;               /* SDL_SCANCODE_1 = 30 .. _9 = 38, _0 = 39 */
            int key = '0' + d;
            if (frame == n) push_key3(win, 1, END_SC, END_KEY);
            if (frame == n + 2) push_key3(win, 1, sc, key);
            if (frame == n + 6) push_key3(win, 0, sc, key);
            if (frame == n + 8) push_key3(win, 0, END_SC, END_KEY);
        }
        if (*c == ',') c++; else break;
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
    real(win);
    click(win);
    keys(win);
    hotkeys(win);
    frame++;
    if (maxf && frame == maxf) {
        if (vid) { pclose(vid); vid = NULL; }
        fprintf(stderr, "[capture] %ld swaps, %ld video frames (%dx%d), %ld frames of another size skipped\n",
                frame, nvid, v0w, v0h, nskip);
        finished = 1;
        kill(getpid(), SIGINT);
    }
}
