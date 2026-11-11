#!/usr/bin/env python3
"""mk_a500probe.py -- OCS/ECS behaviour probes for the MiSTer-port patches of class (b), own code.

One 68000 payload (bench: preloaded at ORG and started by mk_agatest's boot ROM, A500 configuration)
that measures, with all DMA and interrupts off, and stores longs at RESULT (dump them):
  0  marker $A5000001
  1  CIA-A timer A, INMODE=1 (count CNT pulses; CNT is not driven): continuous from $0040, read
     back after 2 frames.  E-clock counting (no INMODE) underflows long before; CNT counting keeps
     $0040 (patch 0016, MiSTer b013ce3).
  2  CIA-A timer A, INMODE=0, one-shot from $1000: the value read 1, 2 and 3 E-clock periods after
     START (packed bytes, timer low bytes): shows the start-up delay (patch 0026, MiSTer 2bddf21).
  3  VHPOSR read right after the line counter changed from $40 to $41 (polled), low byte of the 2
     reads = the beam's H at the read (patch 0018, MiSTer 06f30af) and VPOSR's line (0021, 2764b51)
  4  word read at $D80006 << 16 | word read at $DE1006 (custom-register holes: VHPOSR's offset,
     non-zero if the access reaches the register; patch 0019, #235)
  5  word read at $C80006 (custom register mirror without slow RAM, patch 0027, #254)
  6  blitter freeze (patch 0020, #236): a D-only inclusive-fill blit, BLTCON1 rewritten with fill off
     while it runs; DMACONR (BBUSY bit 14) sampled 2 frames later << 16 | after a new BLTSIZE + wait
  7  blitter nasty + CPU write (patch 0028, #287): beam ticks (CCK) between two VHPOSR reads around a
     write to BLTAFWM while a 64 x 64 D-only blit runs with BLTPRI (a D-only blit leaves every second
     bus cycle free: a 68000 gets those, also with BLTPRI)
  6b DMACONR right after the BLTCON1 write of 6
  7b DMACONR before << 16 | after the BLTAFWM write of 7
Usage: mk_a500probe.py OUTDIR   (OUTDIR/a500probe.bin, ORG = 0x40000, RESULT = 0x70000)
       mk_a500probe.py decode DUMP
"""
import os, struct, sys
sys.path.insert(0, os.path.dirname(os.path.abspath(__file__)))
import mk_agatest as M

ORG = 0x40000
RESULT = 0x70000

SRC = r"""
        .text
        .equ    CUSTOM, 0xdff000
        .equ    CIAA, 0xbfe001
start:  move.w  #0x2700,%%sr
        lea     0x3ff00,%%sp
        lea     CUSTOM,%%a6
        lea     CIAA,%%a5
        move.w  #0x7fff,0x9a(%%a6)
        move.w  #0x7fff,0x9c(%%a6)
        move.w  #0x7fff,0x96(%%a6)
        lea     0x%(res)x,%%a4
        move.l  #0xa5000001,(%%a4)+
        move.b  #0x7f,0xd00(%%a5)           | CIA-A ICR: all off
| 1: INMODE=1 one-shot from $0040
        move.b  #0x20,0xe00(%%a5)           | CRA: continuous, INMODE=1 (b5), stopped
        move.b  #0x40,0x400(%%a5)           | TALO
        move.b  #0x00,0x500(%%a5)           | TAHI (stopped: loads the counter)
        move.b  #0x21,0xe00(%%a5)           | START
        bsr     frame
        bsr     frame
        moveq   #0,%%d0
        move.b  0x500(%%a5),%%d0
        lsl.w   #8,%%d0
        move.b  0x400(%%a5),%%d0
        move.l  %%d0,(%%a4)+
        move.b  #0x00,0xe00(%%a5)
| 2: start-up delay, INMODE=0, one-shot from $1000
        move.b  #0x08,0xe00(%%a5)           | one-shot, stopped, INMODE=0
        move.b  #0x00,0x400(%%a5)
        move.b  #0x10,0x500(%%a5)           | TAHI: loads and starts (one-shot)
        move.b  0x400(%%a5),%%d1            | TALO immediately
        lsl.l   #8,%%d1
        move.b  0x400(%%a5),%%d1            | one bus cycle later
        lsl.l   #8,%%d1
        move.b  0x400(%%a5),%%d1
        lsl.l   #8,%%d1
        move.b  0x500(%%a5),%%d1
        move.l  %%d1,(%%a4)+
        move.b  #0x00,0xe00(%%a5)
| 3: beam read right after line $40 -> $41
1:      move.w  6(%%a6),%%d0
        lsr.w   #8,%%d0
        cmp.b   #0x40,%%d0
        bne.s   1b
2:      move.w  6(%%a6),%%d0
        move.w  %%d0,%%d1
        lsr.w   #8,%%d1
        cmp.b   #0x40,%%d1
        beq.s   2b
        move.w  6(%%a6),%%d1                | the next read
        swap    %%d0
        move.w  %%d1,%%d0
        move.l  %%d0,(%%a4)+
| 4/5: custom register holes and mirror
        move.w  0xd80006,%%d0               | VHPOSR's offset: non-zero if it reaches the register
        swap    %%d0
        move.w  0xde1006,%%d0
        move.l  %%d0,(%%a4)+
        moveq   #0,%%d0
        move.w  0xc80006,%%d0
        move.l  %%d0,(%%a4)+
| 6: blitter freeze: D-only inclusive fill (BLTCON0 $0100, BLTCON1 IFE b3), BLTCON1 = 0 mid-blit
        move.w  #0x8240,0x96(%%a6)          | DMAEN + BLTEN
        move.l  #0x01000008,0x40(%%a6)      | BLTCON0 $0100 / BLTCON1 $0008 (IFE)
        move.l  #-1,0x44(%%a6)
        move.l  #0x50000,0x54(%%a6)         | BLTDPT
        move.w  #0,0x66(%%a6)
        move.w  #0x0000,0x74(%%a6)          | BLTADAT
        move.w  #0x1020,0x58(%%a6)          | 64 lines x 32 words
        move.w  #20,%%d0
3:      dbra    %%d0,3b
        move.w  #0x0000,0x42(%%a6)          | BLTCON1 = 0: fill off while busy
        move.w  2(%%a6),%%d2                | DMACONR right after (BBUSY = b14)
        bsr     frame
        bsr     frame
        move.w  2(%%a6),%%d7                | DMACONR 2 frames later
        swap    %%d7
        move.w  #0x0041,0x58(%%a6)          | a new BLTSIZE releases the freeze
        bsr     frame
        move.w  2(%%a6),%%d7
        move.l  %%d7,(%%a4)+
        move.l  %%d2,(%%a4)+                | 8: DMACONR right after the BLTCON1 write
        move.w  #0x7fff,0x96(%%a6)
| 7: nasty D-only blit (one idle bus cycle per word), CPU write to BLTAFWM during the blit
        move.w  #0x8640,0x96(%%a6)          | DMAEN + BLTEN + BLTPRI
        move.l  #0x01000000,0x40(%%a6)      | BLTCON0 $0100: D only, minterm 0
        move.l  #0x60000,0x50(%%a6)
        move.l  #0x50000,0x54(%%a6)
        move.l  #0,0x64(%%a6)
        move.w  #0x1000,0x58(%%a6)          | 64 lines x 64 words
        move.w  #20,%%d0
3:      dbra    %%d0,3b
        move.w  2(%%a6),%%d3                | DMACONR before the write
        move.l  4(%%a6),%%d5
        move.w  #0xffff,0x44(%%a6)          | the write
        move.l  4(%%a6),%%d6
        move.w  2(%%a6),%%d4                | DMACONR after the write
        bsr     delta
        move.l  %%d0,(%%a4)+
        swap    %%d3
        move.w  %%d4,%%d3
        move.l  %%d3,(%%a4)+                | 9: DMACONR before<<16|after the BLTAFWM write
        bsr     bwait
        move.w  #0x7fff,0x96(%%a6)
        move.l  #0x600df00d,0x1ffff0        | done (the bench's --stop word, chip RAM mirror)
        move.l  #0x600df00d,0x7fff0
9:      bra.s   9b

frame:                                      | wait for the next line $30
1:      move.l  4(%%a6),%%d0
        and.l   #0x1ff00,%%d0
        cmp.l   #0x02f00,%%d0
        bne.s   1b
2:      move.l  4(%%a6),%%d0
        and.l   #0x1ff00,%%d0
        cmp.l   #0x03000,%%d0
        bne.s   2b
        rts
esync:  move.b  0x400(%%a5),%%d0            | an E-clock edge (TALO of a free-running timer B would do;
        rts                                 |  here: a CIA access synchronises the 68000 to E)
bwait:  btst    #6,2(%%a6)
1:      btst    #6,2(%%a6)
        bne.s   1b
        rts
delta:  move.l  %%d5,%%d0
        lsr.l   #8,%%d0
        and.l   #0x1ff,%%d0
        move.l  %%d6,%%d1
        lsr.l   #8,%%d1
        and.l   #0x1ff,%%d1
        sub.l   %%d0,%%d1
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
"""


def build(outdir):
    os.makedirs(outdir, exist_ok=True)
    b = M.assemble(SRC % dict(res=RESULT), ORG)
    open(os.path.join(outdir, "a500probe.bin"), "wb").write(b)
    open(os.path.join(outdir, "bootrom_a500probe.bin"), "wb").write(M.make_bootrom(ORG))
    print("a500probe.bin %d bytes" % len(b))


NAMES = ["marker", "1 CIA INMODE=1 TA after 2 frames", "2 TA lo x3, hi after START",
         "3 VHPOSR at line 40->41 (first/next)", "4 [$D80006]<<16|[$DE1006]", "5 [$C80006]",
         "6 DMACONR 2 frames later<<16|after BLTSIZE", "6b DMACONR right after the BLTCON1 write",
         "7 CCK around a BLTAFWM write, nasty blit", "7b DMACONR before<<16|after the write"]


def decode(fn):
    b = open(fn, "rb").read()
    for i, n in enumerate(NAMES):
        print("%-42s %08x" % (n, struct.unpack(">I", b[4 * i:4 * i + 4])[0]))


if __name__ == "__main__":
    if len(sys.argv) == 3 and sys.argv[1] == "decode":
        decode(sys.argv[2])
    elif len(sys.argv) == 2:
        build(sys.argv[1])
    else:
        print(__doc__)
