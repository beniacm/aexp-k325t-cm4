#!/usr/bin/env python3
"""mk_cputime.py -- CPU / chip-bus timing probe for the stage-3 groundwork (68EC020 on AGA), own code.

Measures, in colour clocks (CCK = 281.9 ns, read from VPOSR/VHPOSR), how long fixed instruction
loops take under four bus conditions:
  c0  all DMA off
  c1  8 bitplanes lores FMODE 0 (the display fetch takes every slot of its 8-CCK blocks)
  c2  8 bitplanes lores FMODE 3 (the same picture from 64-bit fetches: 1 slot in 4)
  c3  blitter nasty (BLTPRI): an A -> D copy of 64 x 64 words (every cycle a blitter cycle) started
      right before the loop, all other DMA off
Before the first measurement the program waits for the frame whose CIA E-clock phase against the
beam is 0 (as the determinism test; otherwise the first row took two values on the board, the
real-time floppy load leaving the E clock at any of 5 phases).
Each measurement starts at the start of line $30 (same beam phase every time); a loop runs N=256
iterations of 8 copies of one instruction (L0: an empty DBRA loop of 2048 iterations).
The code runs from chip RAM (no fast RAM: a stock A1200 runs it from chip RAM through the 256-byte
instruction cache of the 68EC020; a loop body of 8 instructions fits in it).
Results: 4 x 11 words at RESULT (chip RAM, for the bench: --dump), and on screen as rows of 32
bit cells (marker row $FFFFFFFF, then one row per result: condition << 24 | loop << 16 | CCK),
1 bitplane lores, cells 8 pixels x 4 lines (row pitch 5 lines), white = 1, so that an emulator screenshot can be
decoded the same way (decode subcommand).
The 68020 build turns the instruction cache on first (MOVEC CACR, as Kickstart does on an A1200).
Usage:  mk_cputime.py build OUTDIR      -> OUTDIR/cputime.bin (ORG, for the bench), cputime.adf,
                                           cputime000.bin (68000 variant without MOVEC)
        mk_cputime.py decode FRAME.png [--xscale N] [--yscale N]
        mk_cputime.py dump FILE         (a --dump of RESULT from the bench)
        mk_cputime.py mbox "PAGE0 LONGS" "PAGE1 LONGS"   (two stallmon.py mbox readings, 16 hex longs
                                        each, one per page; marker $C771000p, 14 longs of results)
"""
import json, os, struct, sys
sys.path.insert(0, os.path.dirname(os.path.abspath(__file__)))
import mk_agatest as M

RESULT = 0x1F0000
SCREEN = 0x030000
COPPER = 0x1B0000
LOOPS = [
    ("L0 dbra (2048x)", None),
    ("L1 add.l d0,d1", "add.l %d0,%d1"),
    ("L2 move.l (a0),d0 chip", "move.l (%a0),%d0"),
    ("L3 move.w (a0),d0 chip", "move.w (%a0),%d0"),
    ("L4 move.l d0,(a0) chip", "move.l %d0,(%a0)"),
    ("L5 move.w d0,(a0) chip", "move.w %d0,(%a0)"),
    ("L6 mulu.w d2,d0", "mulu.w %d2,%d0"),
    ("L7 move.l d0,d1 + divu.w d2,d1", "move.l %d0,%d1\n        divu.w %d2,%d1"),
    ("L8 move.w $dff006,d0", "move.w 0xdff006,%d0"),
    ("L9 move.l (a0)+,d0 chip", "move.l (%a0)+,%d0"),
    ("L10 move.l d0,(a0)+ chip", "move.l %d0,(%a0)+"),
]
CONDS = ["c0 DMA off", "c1 8pl lores FMODE0", "c2 8pl lores FMODE3", "c3 blitter nasty"]


def asm(icache=True):
    # 68020+: instruction cache on (CACR E), as Kickstart leaves it on an A1200; the bench's boot
    # ROM path has no Kickstart.  68000 runs: build with icache=False (MOVEC is illegal there).
    ic = ("        moveq   #1,%%d0\n        movec   %%d0,%%cacr                 | 68020 I-cache on"
          if icache else "")
    s = [r"""
        .text
        .equ    CUSTOM, 0xdff000
start:  move.w  #0x2700,%%sr
        lea     0x1fff00,%%sp
        lea     CUSTOM,%%a6
        move.w  #0x7fff,0x9a(%%a6)
        move.w  #0x7fff,0x9c(%%a6)
        move.w  #0x7fff,0x96(%%a6)
        move.l  #0,0x%(done)x
%(icache)s
        move.w  #0,0x1fc(%%a6)              | FMODE 0
        move.w  #0x0c00,0x106(%%a6)
        move.w  #0x0011,0x10c(%%a6)
        | single-valued start (as mk_stalltest_adf.py): the E clock (CPU / 10) runs free from reset
        | and a frame is 71051 CCK = 1 mod 5, so its phase against the beam depends on when the
        | (real-time) loader finished.  Wait for the frame whose E phase at line $10 is 0: touch
        | CIA-A (the access ends on an E edge), read the beam, phase = (V x 227 + H) mod 5.
        lea     0xbfe001,%%a2
es0:    move.w  6(%%a6),%%d0
        lsr.w   #8,%%d0
        cmp.w   #0x0f,%%d0
        bne.s   es0
es1:    move.w  6(%%a6),%%d0
        lsr.w   #8,%%d0
        cmp.w   #0x10,%%d0
        bne.s   es1
        tst.b   (%%a2)
        move.w  6(%%a6),%%d0
        moveq   #0,%%d1
        move.b  %%d0,%%d1
        lsr.w   #8,%%d0
        mulu    #227,%%d0
        add.l   %%d1,%%d0
        divu    #5,%%d0
        swap    %%d0
        tst.w   %%d0
        bne.s   es0
        lea     0x%(res)x,%%a4             | result pointer
        moveq   #0,%%d4                     | condition
cond:   bsr     setcond
        lea     loops(%%pc),%%a3
        moveq   #0,%%d3                     | loop number
lp:     move.l  (%%a3)+,%%a5
        bsr     setcond                     | (re)start the condition's DMA (bitplane pointers, blit)
        bsr     syncl30
        move.l  4(%%a6),%%d5
        bsr     startblit                   | c3 only: the blit starts with the loop
        lea     0x100000,%%a0
        move.l  #0x00012345,%%d0
        moveq   #0,%%d1
        move.w  #7,%%d2
        jsr     (%%a5)
        move.l  4(%%a6),%%d6
        bsr     bltwait                     | (a blit finishes only while DMA is on)
        move.w  #0x7fff,0x96(%%a6)          | all DMA off
        bsr     delta                       | d0 = CCK
        move.w  %%d0,(%%a4)+
        addq.w  #1,%%d3
        cmp.w   #%(nloops)d,%%d3
        bne.s   lp
        addq.w  #1,%%d4
        cmp.w   #4,%%d4
        bne.s   cond
        bra     show

| ---- conditions ----
setcond:
        move.w  #0x7fff,0x96(%%a6)
        move.w  #0x2c81,0x8e(%%a6)
        move.w  #0x2cc1,0x90(%%a6)
        move.w  #0x0038,0x92(%%a6)
        move.w  #0,0x108(%%a6)
        move.w  #0,0x10a(%%a6)
        move.w  #0x0211,0x100(%%a6)         | 8 planes (data: whatever is at 0x040000..)
        lea     0xe0(%%a6),%%a1
        move.l  #0x040000,%%d0
        moveq   #7,%%d1
1:      move.l  %%d0,(%%a1)+
        add.l   #0x2800,%%d0
        dbra    %%d1,1b
        cmp.w   #1,%%d4
        bne.s   2f
        move.w  #0,0x1fc(%%a6)
        move.w  #0x00d0,0x94(%%a6)
        move.w  #0x8300,0x96(%%a6)          | DMAEN + BPLEN
        rts
2:      cmp.w   #2,%%d4
        bne.s   3f
        move.w  #3,0x1fc(%%a6)
        move.w  #0x00b8,0x94(%%a6)
        move.w  #0x8300,0x96(%%a6)
        rts
3:      move.w  #0,0x1fc(%%a6)
4:      rts

startblit:                                  | c3: blitter nasty, A -> D copy 64 words x 64 lines
        cmp.w   #3,%%d4
        bne.s   1f
        move.w  #0x8640,0x96(%%a6)          | DMAEN + BLTEN + BLTPRI (nasty)
        move.l  #0x09f00000,0x40(%%a6)      | BLTCON0 A -> D copy (every cycle used) / BLTCON1 0
        move.l  #-1,0x44(%%a6)              | BLTAFWM/BLTALWM
        move.l  #0x140000,0x50(%%a6)        | BLTAPT
        move.l  #0x120000,0x54(%%a6)        | BLTDPT
        move.w  #0,0x64(%%a6)               | BLTAMOD
        move.w  #0,0x66(%%a6)               | BLTDMOD
        move.w  #0x1000,0x58(%%a6)          | BLTSIZE 64 lines x 64 words: starts the blit
1:      rts

bltwait:
        btst    #6,2(%%a6)
1:      btst    #6,2(%%a6)
        bne.s   1b
        rts

syncl30:                                    | wait for the start of line $30
1:      move.l  4(%%a6),%%d0
        and.l   #0x1ff00,%%d0
        cmp.l   #0x02f00,%%d0
        bne.s   1b
2:      move.l  4(%%a6),%%d0
        and.l   #0x1ff00,%%d0
        cmp.l   #0x03000,%%d0
        bne.s   2b
        rts

delta:                                      | (d6 - d5) beam positions -> CCK in d0
        move.l  %%d5,%%d0
        lsr.l   #8,%%d0
        and.l   #0x1ff,%%d0
        move.l  %%d6,%%d1
        lsr.l   #8,%%d1
        and.l   #0x1ff,%%d1
        sub.l   %%d0,%%d1                   | lines
        bpl.s   1f
        add.l   #313,%%d1
1:      mulu.w  #227,%%d1
        moveq   #0,%%d0
        move.b  %%d6,%%d0
        add.l   %%d0,%%d1
        moveq   #0,%%d0
        move.b  %%d5,%%d0
        sub.l   %%d0,%%d1
        move.l  %%d1,%%d0
        rts

| ---- show the results as bit rows ----
show:   move.w  #0x7fff,0x96(%%a6)
        lea     0x%(screen)x,%%a0           | clear 40 x 256 bytes
        move.w  #(40*256/4)-1,%%d0
1:      clr.l   (%%a0)+
        dbra    %%d0,1b
        lea     0x%(screen)x+40*4+4,%%a0    | first row at line 4, byte 4
        moveq   #-1,%%d0
        bsr     row
        lea     0x%(res)x,%%a1
        moveq   #0,%%d4
5:      moveq   #0,%%d3
6:      move.l  %%d4,%%d0
        swap    %%d0
        lsl.l   #8,%%d0
        move.l  %%d3,%%d1
        swap    %%d1
        or.l    %%d1,%%d0
        move.w  (%%a1)+,%%d0
        bsr     row
        addq.w  #1,%%d3
        cmp.w   #%(nloops)d,%%d3
        bne.s   6b
        addq.w  #1,%%d4
        cmp.w   #4,%%d4
        bne.s   5b
        move.w  #0x0000,0x180(%%a6)
        move.w  #0x0fff,0x182(%%a6)
        move.w  #0x1201,0x100(%%a6)
        move.w  #0,0x1fc(%%a6)
        move.w  #0x00d0,0x94(%%a6)
        lea     0x%(copper)x,%%a0
        move.l  #0x00e00000+(0x%(screen)x>>16),(%%a0)+
        move.l  #0x00e20000+(0x%(screen)x&0xffff),(%%a0)+
        move.l  #0xfffffffe,(%%a0)+
        move.l  #0x%(copper)x,0x80(%%a6)
        move.w  #0,0x88(%%a6)
        move.w  #0x8380,0x96(%%a6)
        moveq   #3,%%d3
7:      move.l  4(%%a6),%%d0
        and.l   #0x1ff00,%%d0
        cmp.l   #0x13000,%%d0
        bne.s   7b
8:      move.l  4(%%a6),%%d0
        and.l   #0x1ff00,%%d0
        cmp.l   #0x13000,%%d0
        beq.s   8b
        dbra    %%d3,7b
        move.l  #0x%(magic)x,0x%(done)x
| the results also through the result mailbox $C0-$FF (stallmon.py mbox, boards without a picture):
| two pages alternating every 100 frames: $C7710000 | page, 14 longs = result words 28*page.., $600DF00D
        moveq   #0,%%d5
9:      lea     0xc0.w,%%a1
        move.l  #0xc7710000,%%d0
        or.w    %%d5,%%d0
        move.l  %%d0,(%%a1)+
        lea     0x%(res)x,%%a0
        move.w  %%d5,%%d0
        mulu.w  #56,%%d0
        add.l   %%d0,%%a0
        moveq   #13,%%d0
10:     move.l  (%%a0)+,(%%a1)+
        dbra    %%d0,10b
        move.l  #0x600df00d,(%%a1)
        move.w  #99,%%d3
11:     move.l  4(%%a6),%%d0
        and.l   #0x1ff00,%%d0
        cmp.l   #0x13000,%%d0
        bne.s   11b
12:     move.l  4(%%a6),%%d0
        and.l   #0x1ff00,%%d0
        cmp.l   #0x13000,%%d0
        beq.s   12b
        dbra    %%d3,11b
        eor.w   #1,%%d5
        bra.s   9b

row:                                        | d0 -> 32 cells at a0 (8 px x 4 lines), a0 += 5 lines
        moveq   #31,%%d1
1:      moveq   #0,%%d2
        btst    %%d1,%%d0
        beq.s   2f
        moveq   #0x7e,%%d2                  | 6 px of the 8 (gap between cells)
2:      move.l  %%a0,%%a2
        move.b  %%d2,(%%a2)
        move.b  %%d2,40(%%a2)
        move.b  %%d2,80(%%a2)
        move.b  %%d2,120(%%a2)
        addq.l  #1,%%a0
        dbra    %%d1,1b
        lea     5*40-32(%%a0),%%a0
        rts

        .balign 4
loops:
""" % dict(done=M.DONE_ADDR, res=RESULT, nloops=len(LOOPS), screen=SCREEN, copper=COPPER,
           magic=M.DONE_MAGIC, icache=ic % {})]
    s.append("".join("        .long   loop%d\n" % i for i in range(len(LOOPS))))
    for i, (name, ins) in enumerate(LOOPS):
        s.append("| %s\n        .balign 16\nloop%d:" % (name, i))
        if ins is None:
            s.append("        move.w  #2047,%d7\n1:      dbra    %d7,1b\n        rts\n")
        else:
            s.append("        move.w  #255,%%d7\n1:\n%s        dbra    %%d7,1b\n        rts\n"
                     % ("".join("        %s\n" % ins for _ in range(8))))
    return "\n".join(s)


def build(outdir):
    os.makedirs(outdir, exist_ok=True)
    payload = M.assemble(asm(), M.ORG)
    open(os.path.join(outdir, "cputime.bin"), "wb").write(payload)
    open(os.path.join(outdir, "cputime000.bin"), "wb").write(M.assemble(asm(False), M.ORG))
    open(os.path.join(outdir, "cputime.adf"), "wb").write(M.make_adf(payload))
    if not os.path.exists(os.path.join(outdir, "bootrom.bin")):
        open(os.path.join(outdir, "bootrom.bin"), "wb").write(M.make_bootrom())
    print("cputime %d bytes" % len(payload))


def table(vals):
    out = {}
    for c in range(4):
        for l in range(len(LOOPS)):
            out["%s / %s" % (CONDS[c], LOOPS[l][0])] = vals.get((c, l))
    return out


def decode(fn, xscale=2, yscale=1):
    im = M.load_frame(fn)
    W, H = im.size
    px = im.load()
    def white(x, y):
        r, g, b = px[x, y]
        return r + g + b > 384
    # marker row: the first line with 32 white cells of pitch 8 lores px
    pitch = 8 * xscale
    for y in range(H):
        xs = [x for x in range(W) if white(x, y)]
        if len(xs) < 32 * 6 * xscale * 0.8:
            continue
        x0 = xs[0]
        if all(white(int(x0 + i * pitch + 2 * xscale), y) for i in range(32)):
            break
    else:
        return {"error": "marker row not found"}
    vals = {}
    rows = []
    for r in range(1 + 4 * len(LOOPS)):
        yy = int(y + r * 5 * yscale + yscale)
        v = 0
        for i in range(32):
            v = (v << 1) | (1 if white(int(x0 + i * pitch + 3 * xscale), yy) else 0)
        rows.append(v)
    if rows[0] != 0xFFFFFFFF:
        return {"error": "marker row decode %08x" % rows[0]}
    for v in rows[1:]:
        if v == 0:
            continue
        c, l, cck = v >> 24, (v >> 16) & 0xFF, v & 0xFFFF
        vals[(c, l)] = cck
    return table(vals)


def mbox(p0, p1):
    words = [None] * 56
    for txt in (p0, p1):
        ls = [int(x, 16) for x in txt.replace(",", " ").split()]
        if len(ls) < 16 or (ls[0] >> 16) != 0xC771 or ls[15] != 0x600DF00D:
            raise SystemExit("not a cputime mailbox page: %s" % txt[:40])
        page = ls[0] & 1
        for k, l in enumerate(ls[1:15]):
            words[28 * page + 2 * k] = l >> 16
            words[28 * page + 2 * k + 1] = l & 0xFFFF
    vals = {}
    for c in range(4):
        for l in range(len(LOOPS)):
            vals[(c, l)] = words[c * len(LOOPS) + l]
    return table(vals)


def dump(fn):
    b = open(fn, "rb").read()
    vals = {}
    for c in range(4):
        for l in range(len(LOOPS)):
            vals[(c, l)] = struct.unpack(">H", b[(c * len(LOOPS) + l) * 2:(c * len(LOOPS) + l) * 2 + 2])[0]
    return table(vals)


if __name__ == "__main__":
    a = sys.argv
    if len(a) >= 3 and a[1] == "build":
        build(a[2])
    elif len(a) >= 3 and a[1] == "decode":
        xs = float(a[a.index("--xscale") + 1]) if "--xscale" in a else 2
        ys = float(a[a.index("--yscale") + 1]) if "--yscale" in a else 1
        print(json.dumps(decode(a[2], xs, ys), indent=1))
    elif len(a) >= 3 and a[1] == "dump":
        print(json.dumps(dump(a[2]), indent=1))
    elif len(a) >= 4 and a[1] == "mbox":
        print(json.dumps(mbox(a[2], a[3]), indent=1))
    else:
        print(__doc__)
