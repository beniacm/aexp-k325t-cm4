/* fsuae_capture.c -- LD_PRELOAD frame capture for FS-UAE on a PC without a display (reference
 * recordings of A1200 demos for the stage-3 groundwork).  Own code.
 *
 * FS-UAE runs with SDL_VIDEODRIVER=offscreen (OpenGL through EGL, no window); this library wraps
 * SDL_GL_SwapWindow and reads every rendered frame back (glReadPixels of the back buffer before
 * the swap):
 *   CAP_VIDEO=FILE    every CAP_SKIP-th frame (default 1) piped into ffmpeg (H.264, CRF 14)
 *   CAP_PPM=PREFIX    every CAP_PPM_EVERY-th frame also as PREFIX_<frame>.ppm (raw, for checks)
 *   CAP_FRAMES=N      after N frames: SIGINT to the process (FS-UAE quits cleanly)
 *   CAP_FPS=F         frame rate written into the video (default 50 / CAP_SKIP)
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
static int finished = 0;   /* after CAP_FRAMES: no more capture (FS-UAE still swaps while it quits;
                              a new ffmpeg would truncate the video) */

void SDL_GL_SwapWindow(void *win)
{
    static swap_fn real = NULL;
    static getsize_fn getsize = NULL;
    static readpixels_fn rp = NULL;
    static readbuffer_fn rb = NULL;
    static pixelstore_fn ps = NULL;
    if (!real) {
        real = (swap_fn)dlsym(RTLD_NEXT, "SDL_GL_SwapWindow");
        getsize = (getsize_fn)dlsym(RTLD_NEXT, "SDL_GL_GetDrawableSize");
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
    frame++;
    if (maxf && frame == maxf) {
        if (vid) { pclose(vid); vid = NULL; }
        fprintf(stderr, "[capture] %ld swaps, %ld video frames (%dx%d), %ld frames of another size skipped\n",
                frame, nvid, v0w, v0h, nskip);
        finished = 1;
        kill(getpid(), SIGINT);
    }
}
