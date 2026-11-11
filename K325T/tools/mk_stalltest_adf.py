#!/usr/bin/env python3
"""mk_stalltest_adf.py OUT.adf -- boot-block floppy that checks MACHINE-TIME determinism (A1200/DDR3
study, stage 1: a stoppable Amiga clock must be invisible to the Amiga).

The boot block takes the machine over (interrupts and DMA off, supervisor via TRAP #0) and then
  1. plays a steady 976.6 Hz sine (16-byte sample, period 227 = one line, so that the audio DMA
     requests repeat with the frame parity) on Paula channel 0 (left) and 1 (right): audio DMA
     takes slots the blitter would use, and a period not locked to the line made the workload's
     timing differ from frame to frame (measured: 1182 of 1207 frames, also on the phase-2 core),
  2. counts CIA-A E-clocks (timer A -> timer B cascade) over 50 frames (copper interrupts),
  3. runs, once per frame, the same bus-contended workload, started by the copper interrupt (line
     $40) out of STOP: blitter clear of 4 KB, then a blitter copy (A -> D, minterm $F0 on even
     frames, $0F on odd ones) while the CPU reads the beam position (VHPOSR) and the blit
     destination 1024 times, with 5 lores bitplanes on (they steal CPU slots).  The checksum of what
     the CPU read depends on every bus cycle of the frame: one lost or added cycle anywhere (CPU,
     blitter, bitplane, copper DMA) changes the beam positions the CPU sees and the blitter progress
     it observes.
Rows of 32 bit cells (white = 1, mostly as mk_sysinfo_adf.py; decode a capture with --decode):
     0  marker $FFFFFFFF
     1  frames run (live)
     2  checksum of the first even frame        3  checksum of the first odd frame
     4  frames whose checksum differs from the first frame of the same parity (must stay 0)
     5  VHPOSR at the interrupt entry of frame 0 << 16 | frames with another entry position
     6  end of the workload in frame 0: VPOSR << 16 | VHPOSR
     7  CIA-A timer B << 16 | timer A after 50 frames (both counted down from $FFFF; E-clocks =
        ($FFFF - B) x 65536 + ($FFFF - A); 50 PAL frames = 710,510 E-clocks)
     8  checksum of the frame just run (live)    9  its end position (live)
    10 / 11  VPOSR:VHPOSR right after the CIA timers start / right before they stop: the E-clock
        window in beam terms (50 frames of 313 x 227 colour clocks + end - start; E = cck / 5)
    12  start sync: frames waited for E phase 0 << 16 | the E phase of the first frame looked at
        (before the workload the program waits for the frame whose E-clock phase against the beam
        is 0, then enables audio at the copper interrupt: every boot starts in the same state)
The rows are also copied to $C0 (68000 vectors 48-60, unused) after every frame: the K325T core's
result mailbox shows them without a picture (stallmon.py mbox; --mbox "LONGS" decodes them).
The checksums are pure machine-time quantities: equal values with the stall injector off and on (any
setting) prove that stalls are invisible to the Amiga.  Row 1 lets a clip of the HDMI output show
dropped or repeated frames.
"""
import os, struct, subprocess, sys, tempfile

ROWS = 13

ASM = r"""
        .text
start:  lea     super(%pc),%a0
        move.l  %a0,0x80.w                  | TRAP #0 -> supervisor, never returns
        trap    #0
super:  lea     0xdff000,%a6
        move.w  #0x7fff,0x9a(%a6)           | INTENA off
        move.w  #0x7fff,0x9c(%a6)           | INTREQ clear
        move.w  #0x7fff,0x96(%a6)           | DMACON off
        move.l  #0x60000,%d0                | X = $60000, or $40000 if this code is there
        lea     start(%pc),%a0
        cmp.l   %d0,%a0
        bcs.s   xok
        cmp.l   #0x70000,%a0
        bcc.s   xok
        move.l  #0x40000,%d0
xok:    move.l  %d0,%a5
        lea     0x3ff0(%a5),%sp
        lea     vars(%pc),%a4
        move.l  %a5,vx-vars(%a4)
        move.l  %a5,%a0                     | clear X .. X+$C000
        move.w  #0x2fff,%d1
c1:     clr.l   (%a0)+
        dbra    %d1,c1
        lea     0x4000(%a5),%a0             | blit source: address pattern
        move.w  #8191,%d1
c2:     move.w  %a0,%d0
        eor.w   #0x5a3c,%d0
        move.w  %d0,(%a0)+
        dbra    %d1,c2
        lea     0x180(%a6),%a0              | palette: plane 1 set = white, else dark blue
        moveq   #15,%d1
c3:     move.w  #0x0006,(%a0)+
        move.w  #0x0fff,(%a0)+
        dbra    %d1,c3
        lea     0x2a00(%a5),%a2             | audio: 16-byte sine
        move.l  %a2,%a0
        lea     sine(%pc),%a1
        moveq   #3,%d1
c4:     move.l  (%a1)+,(%a0)+
        dbra    %d1,c4
        lea     0xa0(%a6),%a1
        moveq   #1,%d1
c5:     move.l  %a2,(%a1)                   | AUDxLC
        move.w  #8,4(%a1)                   | AUDxLEN (words)
        move.w  #227,6(%a1)                 | AUDxPER = one line: 3546895 / (227 x 16) = 976.6 Hz
        move.w  #64,8(%a1)                  | AUDxVOL
        lea     16(%a1),%a1
        dbra    %d1,c5
        lea     0x2800(%a5),%a0             | copper list
        move.l  #0x01005200,(%a0)+          | 5 planes lores
        move.l  #0x01020000,(%a0)+
        move.l  #0x01040000,(%a0)+
        move.l  #0x01080000,(%a0)+
        move.l  #0x010a0000,(%a0)+
        move.l  #0x008e2c81,(%a0)+
        move.l  #0x00902cc1,(%a0)+
        move.l  #0x00920038,(%a0)+
        move.l  #0x009400d0,(%a0)+
        move.l  %a5,%d0                     | plane 1 = X (the cells), planes 2..5 = the blit areas
        move.w  #0xe0,%d2
        move.l  #0x4000,%d3
        moveq   #4,%d1
c6:     move.w  %d2,(%a0)+
        swap    %d0
        move.w  %d0,(%a0)+
        swap    %d0
        addq.w  #2,%d2
        move.w  %d2,(%a0)+
        move.w  %d0,(%a0)+
        addq.w  #2,%d2
        add.l   %d3,%d0
        move.l  #0x2000,%d3
        dbra    %d1,c6
        move.l  #0x4001fffe,(%a0)+          | line $40: copper interrupt
        move.l  #0x009c8010,(%a0)+
        move.l  #0xfffffffe,(%a0)+
        lea     handler(%pc),%a0
        move.l  %a0,0x6c.w                  | level 3 autovector
        lea     0x2800(%a5),%a0
        move.l  %a0,0x80(%a6)               | COP1LC
        move.w  %d0,0x88(%a6)               | COPJMP1
        lea     0xbfe001,%a3                | CIA-A: timer A free-running, timer B counts its underflows
        moveq   #-1,%d0
        move.b  %d0,0x400(%a3)
        move.b  %d0,0x500(%a3)
        move.b  %d0,0x600(%a3)
        move.b  %d0,0x700(%a3)
        clr.b   0xe00(%a3)
        clr.b   0xf00(%a3)
        move.w  #0x83c0,0x96(%a6)           | DMA: master, bitplanes, copper, blitter (audio later)
        | single-valued start: the E clock (CPU / 10) runs free from reset; one frame is 71051
        | colour clocks = 1 mod 5, so the E phase against the beam steps by one colour clock per
        | frame and depends on how many frames the (real-time) loader took.  Wait for the frame
        | whose E phase is 0: at line $10 (no bitplane / copper / audio DMA there) touch the CIA
        | (the access ends on an E edge), read the beam, phase = (V x 227 + H) mod 5.
        moveq   #0,%d6                      | frames waited
        moveq   #-1,%d7                     | the first phase seen
es0:    move.w  6(%a6),%d0                  | wait for line $0F ...
        lsr.w   #8,%d0
        cmp.w   #0x0f,%d0
        bne.s   es0
es1:    move.w  6(%a6),%d0                  | ... then for line $10
        lsr.w   #8,%d0
        cmp.w   #0x10,%d0
        bne.s   es1
        tst.b   (%a3)                       | CIA-A access: E-clock synchronous
        move.w  6(%a6),%d0
        moveq   #0,%d1
        move.b  %d0,%d1                     | H (colour clocks)
        lsr.w   #8,%d0                      | V (lines < 256 here)
        mulu    #227,%d0
        add.l   %d1,%d0
        divu    #5,%d0
        swap    %d0                         | remainder = the E phase
        tst.l   %d7
        bpl.s   es2
        moveq   #0,%d7
        move.w  %d0,%d7                     | first phase
es2:    tst.w   %d0
        beq.s   es3
        addq.w  #1,%d6
        bra.s   es0
es3:    swap    %d6
        or.l    %d7,%d6
        move.l  %d6,r_esync-vars(%a4)       | frames waited << 16 | first phase
        move.w  #0xc010,0x9a(%a6)           | INTENA: master + COPER
        move.w  #0x0010,0x9c(%a6)
        stop    #0x2000                     | sync to the copper interrupt (line $40, same frame)
        move.w  #0x8003,0x96(%a6)           | audio 0, 1 on: at a fixed beam position
        move.b  #0x51,0xf00(%a3)            | CRB: start, load, count timer A underflows
        move.b  #0x11,0xe00(%a3)            | CRA: start, load, continuous, E clock
        move.l  4(%a6),r_vp0-vars(%a4)      | VPOSR:VHPOSR right after the start
        moveq   #49,%d1
c7:     stop    #0x2000
        dbra    %d1,c7
        move.l  4(%a6),r_vp1-vars(%a4)      | ... and right before the stop (same code path)
        clr.b   0xe00(%a3)                  | stop timer A (B stops with it)
        move.b  0x700(%a3),%d0
        lsl.w   #8,%d0
        move.b  0x600(%a3),%d0
        swap    %d0
        move.b  0x500(%a3),%d0
        lsl.w   #8,%d0
        move.b  0x400(%a3),%d0
        move.l  %d0,r_cia-vars(%a4)
        move.w  #1,mode-vars(%a4)
| one workload per frame (handler), the bookkeeping here
loop:   move.w  #0x2700,%sr
        move.w  #0x0010,0x9c(%a6)           | a COPER already pending: skip this frame
        stop    #0x2000
        move.w  #0x2700,%sr
        move.l  cur-vars(%a4),%d0
        move.l  r_frames-vars(%a4),%d1
        lea     r_even-vars(%a4),%a0
        btst    #0,%d1
        beq.s   b1
        addq.l  #4,%a0
b1:     cmp.l   #2,%d1
        bcc.s   b2
        move.l  %d0,(%a0)                   | frames 0, 1: the references
        tst.l   %d1
        bne.s   b3
        move.w  ent-vars(%a4),r_sync-vars(%a4)
        move.l  endp-vars(%a4),r_end-vars(%a4)
        bra.s   b3
b2:     cmp.l   (%a0),%d0
        beq.s   b4
        addq.l  #1,r_mism-vars(%a4)
b4:     move.w  ent-vars(%a4),%d0
        cmp.w   r_sync-vars(%a4),%d0
        beq.s   b3
        addq.w  #1,r_syncm-vars(%a4)
b3:     addq.l  #1,r_frames-vars(%a4)
        lea     vars(%pc),%a0               | the rows also to $C0-$F3 (the K325T result mailbox,
        lea     0xc0.w,%a1                  | readable without a picture: stallmon.py mbox)
        moveq   #ROWS-1,%d0
mb:     move.l  (%a0)+,(%a1)+
        dbra    %d0,mb
        | draw the rows: 32 cells of 8 pixels x 6 lines, 8 lines per row, from line 16, byte 4
        lea     vars(%pc),%a0
        lea     16*40+4(%a5),%a1
        moveq   #ROWS-1,%d7
row:    move.l  (%a0)+,%d1
        moveq   #31,%d6
        move.l  %a1,%a2
cell:   moveq   #0,%d0
        btst    %d6,%d1
        beq.s   cz
        moveq   #-1,%d0
cz:     move.b  %d0,(%a2)
        move.b  %d0,40(%a2)
        move.b  %d0,80(%a2)
        move.b  %d0,120(%a2)
        move.b  %d0,160(%a2)
        move.b  %d0,200(%a2)
        addq.l  #1,%a2
        dbra    %d6,cell
        lea     8*40(%a1),%a1
        dbra    %d7,row
        bra     loop

| level 3 (copper, line $40): mode 0 = acknowledge only; mode 1 = the measured workload
handler:
        movem.l %d0-%d7/%a0-%a6,-(%sp)
        lea     0xdff000,%a6
        move.w  6(%a6),%d5                  | the beam at the entry
        move.w  #0x0010,0x9c(%a6)
        move.w  #0x0010,0x9c(%a6)
        lea     vars(%pc),%a4
        tst.w   mode-vars(%a4)
        beq     hret
        move.l  vx-vars(%a4),%a5
        tst.w   2(%a6)
w1:     btst    #6,2(%a6)                   | blitter idle
        bne.s   w1
        move.l  #0x01000000,0x40(%a6)       | clear: D only, minterm 0
        moveq   #-1,%d0
        move.l  %d0,0x44(%a6)
        move.l  %a5,%a0
        add.l   #0x8000,%a0
        move.l  %a0,0x54(%a6)
        clr.w   0x66(%a6)
        move.w  #0x1020,0x58(%a6)           | 64 x 32 words (4 KB)
        tst.w   2(%a6)
w2:     btst    #6,2(%a6)
        bne.s   w2
        move.w  #0x09f0,%d0                 | copy A -> D: even frames A, odd frames NOT A
        btst    #0,r_frames+3-vars(%a4)
        beq.s   h1
        move.w  #0x090f,%d0
h1:     move.w  %d0,0x40(%a6)
        lea     0x4000(%a5),%a1
        move.l  %a1,0x50(%a6)
        move.l  %a0,0x54(%a6)
        clr.w   0x64(%a6)
        move.w  #0x1020,0x58(%a6)
        moveq   #0,%d6
        moveq   #0,%d7
        move.w  #511,%d2
h2:     move.w  6(%a6),%d0                  | the beam
        add.w   %d0,%d7
        rol.l   #1,%d7
        move.w  (%a0)+,%d1                  | the blit destination
        eor.w   %d1,%d6
        dbra    %d2,h2
        move.l  4(%a6),%d4                  | VPOSR:VHPOSR at the end
        swap    %d6
        eor.l   %d6,%d7
        move.l  %d7,cur-vars(%a4)
        move.w  %d5,ent-vars(%a4)
        move.l  %d4,endp-vars(%a4)
        move.w  #0x0010,0x9c(%a6)           | a copper interrupt during an overlong workload: skipped
hret:   movem.l (%sp)+,%d0-%d7/%a0-%a6
        rte

        .even
sine:   .byte   0,38,71,92,100,92,71,38,0,-38,-71,-92,-100,-92,-71,-38
        .even
vars:   .long   0xffffffff
r_frames: .long 0
r_even: .long   0
r_odd:  .long   0
r_mism: .long   0
r_sync: .word   0
r_syncm: .word  0
r_end:  .long   0
r_cia:  .long   0
cur:    .long   0
endp:   .long   0
r_vp0:  .long   0
r_vp1:  .long   0
r_esync: .long  0
mode:   .word   0
ent:    .word   0
vx:     .long   0
"""


def assemble():
    with tempfile.TemporaryDirectory() as d:
        src = os.path.join(d, "s.s")
        open(src, "w").write(ASM.replace("ROWS", str(ROWS)))
        subprocess.check_call(["m68k-linux-gnu-as", "-m68000", "-o", d + "/s.o", src])
        subprocess.check_call(["m68k-linux-gnu-objcopy", "-O", "binary", d + "/s.o", d + "/s.bin"])
        return open(d + "/s.bin", "rb").read()


def bootblock():
    b = bytearray(1024)
    b[0:4] = b"DOS\0"
    b[8:12] = struct.pack(">I", 880)
    c = assemble()
    assert len(c) <= 1012, len(c)
    b[12:12 + len(c)] = c
    s = 0
    for i in range(0, 1024, 4):
        s += struct.unpack(">I", b[i:i + 4])[0]
        if s > 0xFFFFFFFF:
            s = (s & 0xFFFFFFFF) + 1
    b[4:8] = struct.pack(">I", (~s) & 0xFFFFFFFF)
    return bytes(b), len(c)


NAMES = ["marker", "frames", "sum_even", "sum_odd", "mismatch", "entry_syncmism", "end_pos", "cia",
         "sum_now", "end_now", "vp_start", "vp_end", "esync"]


def decode(png):
    """rows from a capture (as mk_sysinfo_adf.py): the marker row gives the cell grid"""
    from PIL import Image
    im = png if not isinstance(png, str) else Image.open(png)
    im = im.convert("L")
    w, h = im.size
    white = lambda x, y: im.getpixel((x, y)) > 128
    y0 = next(y for y in range(h) if sum(white(x, y) for x in range(0, w, 4)) > w // 16)
    xs = [x for x in range(w) if white(x, y0 + 2)]
    x0, x1 = xs[0], xs[-1] + 1
    y1 = next(y for y in range(y0, h) if not white((x0 + x1) // 2, y))
    lh = (y1 - y0) / 6.0
    cw = (x1 - x0) / 32.0
    vals = []
    for r in range(ROWS):
        y = int(y0 + (8 * r + 3) * lh)
        v = 0
        for b in range(32):
            x = int(x0 + (b + 0.5) * cw)
            v = (v << 1) | (1 if white(x, y) else 0)
        vals.append(v)
    return vals


def explain(v):
    d = dict(zip(NAMES, v))
    b, a = d["cia"] >> 16, d["cia"] & 0xFFFF
    e = (0xFFFF - b) * 65536 + (0xFFFF - a)
    return ("frames %d, checksums even %08x odd %08x, mismatching frames %d, entry VHPOSR $%04x "
            "(other entry positions: %d), workload end VPOSR:VHPOSR $%08x, CIA E-clocks in 50 frames %d "
            "(PAL: 710510)" % (d["frames"], d["sum_even"], d["sum_odd"], d["mismatch"],
                               d["entry_syncmism"] >> 16, d["entry_syncmism"] & 0xFFFF, d["end_pos"], e)
            + window(d, e)
            + ("; start sync: %d frames waited, first E phase %d" % (d["esync"] >> 16, d["esync"] & 0xFFFF)
               if "esync" in d else ""))


def window(d, e):
    if "vp_end" not in d:
        return ""
    def cck(v):
        return (((v >> 16) & 1) << 8 | (v >> 8) & 0xFF) * 227 + (v & 0xFF)
    w = 50 * 313 * 227 + cck(d["vp_end"]) - cck(d["vp_start"])
    return ("; window: beam $%08x -> $%08x = %d cck = %.1f E-clocks if 50 frames passed "
            "(measured - expected %+.1f)" % (d["vp_start"], d["vp_end"], w, w / 5.0, e - w / 5.0))


if __name__ == "__main__":
    if sys.argv[1] in ("--decode", "--mbox"):
        v = decode(sys.argv[2]) if sys.argv[1] == "--decode" else \
            [int(x, 16) for x in sys.argv[2].split()][:ROWS]
        print(" ".join("%s=%08x" % (k, x) for k, x in zip(NAMES, v)))
        print(explain(v))
        sys.exit(0)
    bb, n = bootblock()
    open(sys.argv[1], "wb").write(bb + bytes(901120 - 1024))
    print("wrote", sys.argv[1], "(boot code %d bytes)" % n)
