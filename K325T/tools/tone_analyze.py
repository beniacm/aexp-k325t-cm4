#!/usr/bin/python3
"""tone_analyze.py WAV [F0] -- a steady test tone recorded from the HDMI capture dongle (arecord):
frequency, phase jitter (whole record and short-term), residual after removing the tone and its harmonics, worst sample.
(numpy: run with /usr/bin/python3.)  Used for the stall test (mk_stalltest_adf.py plays 976.6 Hz).

Method: the record is demodulated at the FFT peak f0 in 10 ms blocks; the block phases, unwrapped,
are fitted with a line (frequency) and their RMS deviation from it is the phase jitter (also given
as time).  The fitted tone + harmonics 2..40 are subtracted by least squares; what remains is
noise + distortion that is not a harmonic (e.g. jitter sidebands, clicks), as dB below the tone.
"""
import sys
import wave

import numpy as np


def load(path):
    w = wave.open(path)
    n, ch, sr = w.getnframes(), w.getnchannels(), w.getframerate()
    x = np.frombuffer(w.readframes(n), dtype=np.int16).reshape(-1, ch).astype(float)
    return x, sr


def analyze(x, sr, f0=None, skip=1.0):
    x = x[int(skip * sr):]                  # the capture device's start-up (silence, ramp)
    x = x - x.mean()
    n = len(x)
    if f0 is None:
        sp = np.abs(np.fft.rfft(x * np.hanning(n)))
        k = np.argmax(sp[10:]) + 10
        f0 = k * sr / n
    blk = sr // 100
    t = np.arange(n) / sr
    z = x * np.exp(-2j * np.pi * f0 * t)
    nb = n // blk
    ph = np.unwrap(np.angle(z[:nb * blk].reshape(nb, blk).mean(axis=1)))
    tb = (np.arange(nb) + 0.5) * blk / sr
    a, b = np.polyfit(tb, ph, 1)
    f = f0 + a / (2 * np.pi)
    jit = ph - (a * tb + b)
    # short-term jitter: 2 ms block phases, each 100 ms segment detrended by its own line (removes
    # the HDMI flicker-free loop's slow 976.6 <-> 978.7 Hz pitch dither, keeps us-scale time jitter)
    b2 = sr // 500
    n2 = n // b2
    ph2 = np.unwrap(np.angle(z[:n2 * b2].reshape(n2, b2).mean(axis=1)))
    seg = 50
    st, fl = [], []
    for i in range(0, n2 - seg + 1, seg):
        tt = np.arange(seg) * b2 / sr
        p1 = np.polyfit(tt, ph2[i:i + seg], 1)
        st.append(ph2[i:i + seg] - np.polyval(p1, tt))
        fl.append(f0 + p1[0] / (2 * np.pi))
    fl = np.array(fl)
    # segments with a pitch switch inside have an intermediate frequency: keep only the segments at
    # one of the two dither frequencies (or all, without dither)
    lo, hi = np.median(fl[fl <= np.median(fl)]), np.median(fl[fl >= np.median(fl)])
    keep = [k for k in range(len(fl)) if min(abs(fl[k] - lo), abs(fl[k] - hi)) < 0.05]
    nseg = len(fl)
    st = np.concatenate([st[k] for k in keep])
    # least squares: harmonics 1..40 of f
    cols = []
    for h in range(1, 41):
        if h * f >= sr / 2:
            break
        cols += [np.cos(2 * np.pi * h * f * t), np.sin(2 * np.pi * h * f * t)]
    A = np.stack(cols, axis=1)
    c, *_ = np.linalg.lstsq(A, x, rcond=None)
    res = x - A @ c
    amp1 = np.hypot(c[0], c[1])
    harm = np.sqrt(np.sum(c[2:] ** 2) / 2)
    return {
        "f": f, "amp": amp1, "jit_rad": jit.std(), "jit_ns": jit.std() / (2 * np.pi * f) * 1e9,
        "jit_pp_ns": (jit.max() - jit.min()) / (2 * np.pi * f) * 1e9,
        "res_db": 20 * np.log10(res.std() / (amp1 / np.sqrt(2))),
        "harm_db": 20 * np.log10(harm / (amp1 / np.sqrt(2))) if harm > 0 else -999,
        "res_max": np.abs(res).max(), "secs": n / sr,
        "st_ns": st.std() / (2 * np.pi * f) * 1e9, "st_max_ns": np.abs(st).max() / (2 * np.pi * f) * 1e9,
        "f_lo": lo, "f_hi": hi, "seg_used": len(keep), "seg_all": nseg,
    }


if __name__ == "__main__":
    x, sr = load(sys.argv[1])
    f0 = float(sys.argv[2]) if len(sys.argv) > 2 else None
    for c in range(x.shape[1]):
        r = analyze(x[:, c], sr, f0)
        print("%s ch%d: %.1f s, f = %.4f Hz, amplitude %.0f, phase jitter %.2e rad RMS = %.1f ns RMS "
              "(%.1f ns p-p over 10 ms blocks), harmonics %.1f dB, residual (noise + non-harmonic) "
              "%.1f dB, worst residual sample %.0f" %
              (sys.argv[1].rsplit("/", 1)[-1], c, r["secs"], r["f"], r["amp"], r["jit_rad"], r["jit_ns"],
               r["jit_pp_ns"], r["harm_db"], r["res_db"], r["res_max"]))
        print("   short-term (2 ms phases, 100 ms segments detrended, %d of %d segments without a pitch "
              "switch): jitter %.1f ns RMS, %.1f ns max; local frequencies %.3f / %.3f Hz" %
              (r["seg_used"], r["seg_all"], r["st_ns"], r["st_max_ns"], r["f_lo"], r["f_hi"]))
