#!/usr/bin/env python3
"""mk_akikotest.py -- test of the Akiko chunky-to-planar helper (branch a1200-akiko), own code.

One payload (68020; it takes the machine over like mk_cputime.py) that
  1. reports what graphics.library knows (only when booted from the ADF under Kickstart: the boot block
     opens graphics.library and hands GfxBase over in A3): version, GfxBase->ChunkyToPlanarPtr (offset
     $1FC, V40+), and where in GfxBase the long $00B80038 is (a scan of the first $300 bytes);
  2. detects the chip: $B80000.L = $C0CACAFE (what the CD32's graphics.library checks: $CAFE at $B80002);
  3. converts known chunky patterns and compares every planar longword with the Python reference
     (embedded expected data, and the bench dump is checked again here by `check`):
       V1  long accesses (write 8 longs to $B80038, read 8 longs): all patterns -- zero, all-ones, a
           ramp, 0..255, every single bit of every pixel (256 blocks), 512 random blocks
       V2  word accesses ($B80038 / $B8003A alternately), 64 random blocks
       V3  only planes 0..3 read back (the V40 autodoc allows stopping early), 64 random blocks; the
           other 4 longs of every output block must keep their $DEADBEEF fill
       V4  every block read twice (16 reads after 8 writes: the second 8 must equal the first)
  4. measures the conversion in machine time (colour clocks from VPOSR/VHPOSR, all DMA off):
       S1  128 blocks (4096 pixels): 8 x move.l (a0)+,(a2) + 8 x move.l (a2),(a1)+   (a2 = $B80038)
       S2  the same instruction stream with a2 = a chip RAM longword (what a chip access costs)
       S3  a whole 320 x 256 x 8-bit chunky picture into 8 bitplanes (the realistic loop: each plane
           long to its own plane), timed in 20 strips of 128 blocks
  5. shows that picture (8 planes lores, FMODE 3, 256 colours of mk_agatest's palette) and writes
     DONE_MAGIC to DONE_ADDR after 3 frames.  `check` compares the bench frame with the reference image.
Without the chip (ID differs) steps 3/4 are skipped and the picture is not drawn (DONE all the same).

Results: 16 longs at RESULT (and the same 16 longs in the mailbox $C0..$FF of stallmon.py mbox):
   0 $AC1C0000 | b0 chip found | b1 graphics.library V40+ | b2 ChunkyToPlanarPtr = $B80038
   1 $B80000.L as read      2 GfxBase (0 = bench boot ROM, no Kickstart)    3 version << 16 | revision
   4 ChunkyToPlanarPtr       5 offset of $00B80038 in GfxBase ($FFFFFFFF = not found)
   6 longs compared          7..10 wrong longs V1..V4       11 S1 CCK   12 S2 CCK   13 S3 CCK
  14 $600D0000 all right / $BAD00000 | wrong count (or $00000000 without the chip)    15 $600DF00D
The planar output (V1..V4) follows RESULT directly: --dump 0x%(res)X <len> FILE covers both.

Usage:  mk_akikotest.py build OUTDIR    -> akikotest.bin (ORG, for the bench), akikotest.adf, bootrom.bin
        mk_akikotest.py check DUMP [FRAME.ppm]   -- verify a bench dump (and frame) against the reference
        mk_akikotest.py mbox "16 HEX LONGS"      -- decode a mailbox reading
"""
import json, os, random, struct, sys
sys.path.insert(0, os.path.dirname(os.path.abspath(__file__)))
import mk_agatest as M

ORG = M.ORG                # 0x1C0000
RESULT = 0x0FFFC0          # 16 longs, then the planar output
OUTB = 0x100000
SCREEN = 0x020000          # 8 planes x 10240 bytes (non-interleaved, FMODE 3: 64-bit aligned)
PSIZE = 40 * 256
COPPER = M.COPPER
SCRATCH = 0x0F0000         # S2: the chip RAM stand-in for the C2P register
S1OUT = 0x140000
W, H = 320, 256
NS = 128                   # blocks per speed measurement / picture strip


def c2p_ref(block):
    """32 chunky bytes -> 8 planar longs (plane p: bit 31 = pixel 0's bit p ... bit 0 = pixel 31's)"""
    assert len(block) == 32
    out = []
    for p in range(8):
        v = 0
        for n in range(32):
            v |= ((block[n] >> p) & 1) << (31 - n)
        out.append(v)
    return out


def patterns():
    rnd = random.Random(0xA1C0)
    blocks = [bytes(32), bytes([255] * 32), bytes(range(32))]
    blocks += [bytes(range(32 * i, 32 * i + 32)) for i in range(8)]                 # 0..255
    for n in range(32):                                                            # single bits
        for b in range(8):
            blk = bytearray(32)
            blk[n] = 1 << b
            blocks.append(bytes(blk))
    rnd_blocks = [bytes(rnd.randrange(256) for _ in range(32)) for _ in range(512)]
    return blocks + rnd_blocks, rnd_blocks


def picture():
    return bytes(((x + 7 * y + 1 + ((x * y) >> 4)) & 255) for y in range(H) for x in range(W))


def layout():
    v1, rb = patterns()
    v2 = rb[:64]
    v3 = rb[64:128]
    v4 = rb[128:144]
    exp = bytearray()
    for b in v1 + v2:
        exp += struct.pack(">8I", *c2p_ref(b))
    for b in v3:
        exp += struct.pack(">8I", *(c2p_ref(b)[:4] + [0xDEADBEEF] * 4))
    for b in v4:
        r = c2p_ref(b)
        exp += struct.pack(">16I", *(r + r))
    inp = b"".join(v1) + b"".join(v2) + b"".join(v3) + b"".join(v4)
    sizes = dict(n1=len(v1), n2=len(v2), n3=len(v3), n4=len(v4))
    return inp, bytes(exp), sizes


ASM = r"""
        .text
        .equ    CUSTOM, 0xdff000
start:  move.w  #0x2700,%%sr
        lea     0x1fff00,%%sp
        lea     CUSTOM,%%a6
        move.w  #0x7fff,0x9a(%%a6)
        move.w  #0x7fff,0x9c(%%a6)
        move.w  #0x7fff,0x96(%%a6)
        move.l  #0,0x%(done)x
        moveq   #1,%%d0
        movec   %%d0,%%cacr                 | 68020 I-cache on (Kickstart has it on already)
        move.w  #0,0x1fc(%%a6)
        move.w  #0x0c00,0x106(%%a6)
        move.w  #0x0011,0x10c(%%a6)
        move.w  #0x0000,0x180(%%a6)
| ---- result block cleared ----
        lea     0x%(res)x,%%a4
        moveq   #15,%%d0
1:      clr.l   (%%a4)+
        dbra    %%d0,1b
        lea     0x%(res)x,%%a4
        move.l  #0xac1c0000,(%%a4)
        move.l  #0xffffffff,20(%%a4)
| ---- 1: graphics.library (A3 = GfxBase from the boot block, which sets D7 = 'GFXB'; else none) ----
        cmp.l   #0x47465842,%%d7
        beq.s   0f
        sub.l   %%a3,%%a3
0:      move.l  %%a3,8(%%a4)
        move.l  %%a3,%%d0
        beq.s   gdone
        move.l  20(%%a3),12(%%a4)           | LIB_VERSION.w, LIB_REVISION.w
        cmp.w   #40,20(%%a3)
        bcs.s   gscan
        or.l    #2,(%%a4)
        move.l  0x1fc(%%a3),16(%%a4)        | ChunkyToPlanarPtr (V40+)
        cmp.l   #0x00b80038,16(%%a4)
        bne.s   gscan
        or.l    #4,(%%a4)
gscan:  moveq   #0,%%d0                     | where is $00B80038 in GfxBase (first $300 bytes, even offsets)?
2:      cmp.l   #0x00b80038,0(%%a3,%%d0.l)
        beq.s   3f
        addq.l  #2,%%d0
        cmp.l   #0x300,%%d0
        bcs.s   2b
        bra.s   gdone
3:      move.l  %%d0,20(%%a4)
gdone:
| ---- 2: detection ----
        lea     0xb80000,%%a5
        move.l  (%%a5),4(%%a4)
        cmp.l   #0xc0cacafe,4(%%a4)
        bne     report
        or.l    #1,(%%a4)
        lea     0x38(%%a5),%%a2             | the C2P register
| ---- 3: conversion ----
        lea     0x%(outb)x,%%a1             | output (V3 area pre-filled with $DEADBEEF)
        move.l  #%(nout)d-1,%%d0
4:      move.l  #0xdeadbeef,(%%a1)+
        subq.l  #1,%%d0
        bpl.s   4b
        lea     inp,%%a0
        lea     0x%(outb)x,%%a1
        move.w  #%(n1)d,%%d7               | V1: long accesses
v1:     move.l  (%%a0)+,(%%a2)
        move.l  (%%a0)+,(%%a2)
        move.l  (%%a0)+,(%%a2)
        move.l  (%%a0)+,(%%a2)
        move.l  (%%a0)+,(%%a2)
        move.l  (%%a0)+,(%%a2)
        move.l  (%%a0)+,(%%a2)
        move.l  (%%a0)+,(%%a2)
        move.l  (%%a2),(%%a1)+
        move.l  (%%a2),(%%a1)+
        move.l  (%%a2),(%%a1)+
        move.l  (%%a2),(%%a1)+
        move.l  (%%a2),(%%a1)+
        move.l  (%%a2),(%%a1)+
        move.l  (%%a2),(%%a1)+
        move.l  (%%a2),(%%a1)+
        subq.w  #1,%%d7
        bne.s   v1
        move.w  #%(n2)d,%%d7               | V2: word accesses, high word ($B80038) then low ($B8003A)
v2:     moveq   #7,%%d6
5:      move.w  (%%a0)+,(%%a2)
        move.w  (%%a0)+,2(%%a2)
        dbra    %%d6,5b
        moveq   #7,%%d6
6:      move.w  (%%a2),(%%a1)+
        move.w  2(%%a2),(%%a1)+
        dbra    %%d6,6b
        subq.w  #1,%%d7
        bne.s   v2
        move.w  #%(n3)d,%%d7               | V3: planes 0..3 only
v3:     moveq   #7,%%d6
7:      move.l  (%%a0)+,(%%a2)
        dbra    %%d6,7b
        moveq   #3,%%d6
8:      move.l  (%%a2),(%%a1)+
        dbra    %%d6,8b
        lea     16(%%a1),%%a1
        subq.w  #1,%%d7
        bne.s   v3
        move.w  #%(n4)d,%%d7               | V4: 8 writes, 16 reads
v4:     moveq   #7,%%d6
9:      move.l  (%%a0)+,(%%a2)
        dbra    %%d6,9b
        moveq   #15,%%d6
10:     move.l  (%%a2),(%%a1)+
        dbra    %%d6,10b
        subq.w  #1,%%d7
        bne.s   v4
| compare each part with the expected longs
        lea     0x%(outb)x,%%a0
        lea     exp,%%a1
        lea     28(%%a4),%%a3               | wrong counts V1..V4
        move.l  #%(l1)d,%%d0
        bsr     cmpl
        move.l  #%(l2)d,%%d0
        bsr     cmpl
        move.l  #%(l3)d,%%d0
        bsr     cmpl
        move.l  #%(l4)d,%%d0
        bsr     cmpl
        move.l  #%(lall)d,24(%%a4)
| ---- 4: speed (all DMA off) ----
        lea     inp,%%a0              | S1: 128 blocks through Akiko
        lea     0x%(s1out)x,%%a1
        bsr     syncl30
        move.l  4(%%a6),%%d5
        bsr     s1loop
        move.l  4(%%a6),%%d6
        bsr     delta
        move.l  %%d0,44(%%a4)
        lea     inp,%%a0              | S2: the same with a chip RAM longword for the register
        lea     0x%(s1out)x,%%a1
        lea     0x%(scratch)x,%%a2
        bsr     syncl30
        move.l  4(%%a6),%%d5
        bsr     s1loop
        move.l  4(%%a6),%%d6
        bsr     delta
        move.l  %%d0,48(%%a4)
        lea     0x38(%%a5),%%a2
        lea     pic,%%a0              | S3: the picture into the 8 planes, 20 strips
        lea     0x%(screen)x,%%a1
        lea     0x%(screen4)x,%%a3
        moveq   #0,%%d4
        moveq   #%(nstrips)d-1,%%d3
        bsr     syncl30
11:     move.l  4(%%a6),%%d5
        bsr     s3loop
        move.l  4(%%a6),%%d6
        bsr     delta
        add.l   %%d0,%%d4
        dbra    %%d3,11b
        move.l  %%d4,52(%%a4)
| ---- the verdict ----
        move.l  28(%%a4),%%d0
        add.l   32(%%a4),%%d0
        add.l   36(%%a4),%%d0
        add.l   40(%%a4),%%d0
        bne.s   12f
        move.l  #0x600d0000,56(%%a4)
        bra.s   13f
12:     or.l    #0xbad00000,%%d0
        move.l  %%d0,56(%%a4)
13:
| ---- 5: show the picture: palette (BPLCON3 banks, LOCT), 8 planes lores FMODE 3 ----
        lea     palw,%%a0
        moveq   #0,%%d1
14:     move.w  %%d1,%%d2
        ror.w   #3,%%d2
        or.w    #0x0c00,%%d2
        move.w  %%d2,0x106(%%a6)
        lea     0x180(%%a6),%%a1
        moveq   #31,%%d0
15:     move.w  (%%a0),(%%a1)+
        addq.l  #4,%%a0
        dbra    %%d0,15b
        lea     -128(%%a0),%%a0
        or.w    #0x0200,%%d2
        move.w  %%d2,0x106(%%a6)
        lea     0x180(%%a6),%%a1
        moveq   #31,%%d0
16:     move.w  2(%%a0),(%%a1)+
        addq.l  #4,%%a0
        dbra    %%d0,16b
        addq.w  #1,%%d1
        cmp.w   #8,%%d1
        bne.s   14b
        move.w  #0x0c00,0x106(%%a6)
        lea     coplst,%%a0
        lea     0x%(copper)x,%%a1
        moveq   #%(ncop)d-1,%%d0
17:     move.l  (%%a0)+,(%%a1)+
        dbra    %%d0,17b
        move.w  #0x0211,0x100(%%a6)
        move.w  #0,0x102(%%a6)
        move.w  #0x0024,0x104(%%a6)
        move.w  #3,0x1fc(%%a6)
        move.w  #0x2c81,0x8e(%%a6)
        move.w  #0x2cc1,0x90(%%a6)
        move.w  #0x0038,0x92(%%a6)
        move.w  #0x00b8,0x94(%%a6)
        move.l  #0x%(copper)x,0x80(%%a6)
        move.w  #0,0x88(%%a6)
        move.w  #0x8380,0x96(%%a6)
        bra.s   showw
report: move.l  #0,56(%%a4)                 | no chip: nothing converted, no picture
showw:
| the results in the mailbox $C0..$FF as well
        lea     0xc0.w,%%a1
        move.l  %%a4,%%a0
        moveq   #14,%%d0
19:     move.l  (%%a0)+,(%%a1)+
        dbra    %%d0,19b
        move.l  #0x600df00d,(%%a1)
        move.l  #0x600df00d,60(%%a4)
        moveq   #3,%%d3                     | 3 frames, then done
20:     move.l  4(%%a6),%%d0
        and.l   #0x1ff00,%%d0
        cmp.l   #0x13000,%%d0
        bne.s   20b
21:     move.l  4(%%a6),%%d0
        and.l   #0x1ff00,%%d0
        cmp.l   #0x13000,%%d0
        beq.s   21b
        dbra    %%d3,20b
        move.l  #0x%(magic)x,0x%(done)x
22:     bra.s   22b

| ---- subroutines ----
cmpl:                                       | a0 out, a1 expected, d0 longs -> (a3)+ wrong count
        moveq   #0,%%d1
1:      cmpm.l  (%%a0)+,(%%a1)+
        beq.s   2f
        addq.l  #1,%%d1
2:      subq.l  #1,%%d0
        bne.s   1b
        move.l  %%d1,(%%a3)+
        rts

        .balign 16
s1loop: move.w  #%(ns)d,%%d7
1:      move.l  (%%a0)+,(%%a2)
        move.l  (%%a0)+,(%%a2)
        move.l  (%%a0)+,(%%a2)
        move.l  (%%a0)+,(%%a2)
        move.l  (%%a0)+,(%%a2)
        move.l  (%%a0)+,(%%a2)
        move.l  (%%a0)+,(%%a2)
        move.l  (%%a0)+,(%%a2)
        move.l  (%%a2),(%%a1)+
        move.l  (%%a2),(%%a1)+
        move.l  (%%a2),(%%a1)+
        move.l  (%%a2),(%%a1)+
        move.l  (%%a2),(%%a1)+
        move.l  (%%a2),(%%a1)+
        move.l  (%%a2),(%%a1)+
        move.l  (%%a2),(%%a1)+
        subq.w  #1,%%d7
        bne.s   1b
        rts

        .balign 16
s3loop: move.w  #%(ns)d,%%d7               | a0 chunky, a1 plane 0, a3 plane 4 (planes PSIZE apart)
1:      move.l  (%%a0)+,(%%a2)
        move.l  (%%a0)+,(%%a2)
        move.l  (%%a0)+,(%%a2)
        move.l  (%%a0)+,(%%a2)
        move.l  (%%a0)+,(%%a2)
        move.l  (%%a0)+,(%%a2)
        move.l  (%%a0)+,(%%a2)
        move.l  (%%a0)+,(%%a2)
        move.l  (%%a2),(%%a1)
        move.l  (%%a2),%(psize)d(%%a1)
        move.l  (%%a2),%(psize2)d(%%a1)
        move.l  (%%a2),%(psize3)d(%%a1)
        move.l  (%%a2),(%%a3)
        move.l  (%%a2),%(psize)d(%%a3)
        move.l  (%%a2),%(psize2)d(%%a3)
        move.l  (%%a2),%(psize3)d(%%a3)
        addq.l  #4,%%a1
        addq.l  #4,%%a3
        subq.w  #1,%%d7
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

delta:                                      | (d6 - d5) beam positions -> CCK in d0 (less than a frame)
        move.l  %%d5,%%d0
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


BOOT = r"""
| boot block: load the payload (sectors 2..), open graphics.library (GfxBase -> A3 for the payload),
| enter supervisor mode, take the machine, copy the payload to ORG, jump there.
        .text
        .ascii  "DOS"
        .byte   0
        .long   0                           | checksum (patched)
        .long   880
        move.l  %%a1,%%a5                   | IOStdReq
        move.l  #%(size)d,%%d0
        move.l  #0x10002,%%d1               | MEMF_CHIP | MEMF_CLEAR
        jsr     -198(%%a6)                  | AllocMem
        tst.l   %%d0
        beq.s   fail
        move.l  %%d0,%%a4
        move.l  %%a5,%%a1
        move.w  #2,28(%%a1)                 | CMD_READ
        move.l  %%a4,40(%%a1)               | io_Data
        move.l  #%(size)d,36(%%a1)          | io_Length
        move.l  #1024,44(%%a1)              | io_Offset
        jsr     -456(%%a6)                  | DoIO
        move.l  %%a5,%%a1
        move.w  #9,28(%%a1)                 | TD_MOTOR off
        clr.l   36(%%a1)
        jsr     -456(%%a6)
        lea     gname(%%pc),%%a1
        moveq   #0,%%d0
        jsr     -552(%%a6)                  | OpenLibrary("graphics.library", 0)
        move.l  %%d0,%%a3
        move.l  #0x47465842,%%d7            | 'GFXB': A3 holds GfxBase
        jsr     -150(%%a6)                  | SuperState
        move.w  #0x2700,%%sr
        move.w  #0x7fff,0xdff09a
        move.w  #0x7fff,0xdff096
        move.l  %%a4,%%a0
        lea     0x%(org)x,%%a1
        move.l  #(%(size)d/4)-1,%%d0
1:      move.l  (%%a0)+,(%%a1)+
        subq.l  #1,%%d0
        bpl.s   1b
        jmp     0x%(org)x
fail:   moveq   #-1,%%d0
        rts
gname:  .asciz  "graphics.library"
"""


def make_adf(payload):
    size = (len(payload) + 511) & ~511
    bb = bytearray(M.assemble(BOOT % dict(size=size, org=ORG), 0))
    assert len(bb) <= 1024, len(bb)
    bb += bytes(1024 - len(bb))
    s = 0
    for i in range(0, 1024, 4):
        s += struct.unpack(">I", bb[i:i + 4])[0]
        if s > 0xFFFFFFFF:
            s = (s + 1) & 0xFFFFFFFF
    struct.pack_into(">I", bb, 4, (~s) & 0xFFFFFFFF)
    adf = bytearray(901120)
    adf[0:1024] = bb
    adf[1024:1024 + len(payload)] = payload
    return bytes(adf)


def build_payload():
    inp, exp, sz = layout()
    pic = picture()
    pal = []
    for i in range(256):
        r, g, b = M.pal_t1(i)
        pal.append(struct.pack(">HH", ((r >> 4) << 8) | ((g >> 4) << 4) | (b >> 4),
                               ((r & 15) << 8) | ((g & 15) << 4) | (b & 15)))
    cop = [0x0108, 0, 0x010A, 0]
    for p in range(8):
        a = SCREEN + p * PSIZE
        cop += [0xE0 + 4 * p, a >> 16, 0xE2 + 4 * p, a & 0xFFFF]
    cop += [0xFFFF, 0xFFFE]
    l1, l2, l3, l4 = sz["n1"] * 8, sz["n2"] * 8, sz["n3"] * 8, sz["n4"] * 16
    src = ASM % dict(done=M.DONE_ADDR, magic=M.DONE_MAGIC, res=RESULT, outb=OUTB, nout=l1 + l2 + l3 + l4,
                     l1=l1, l2=l2, l3=l3, l4=l4, lall=l1 + l2 + l3 + l4, s1out=S1OUT, scratch=SCRATCH,
                     screen=SCREEN, screen4=SCREEN + 4 * PSIZE, nstrips=(W * H // 32) // NS, ns=NS,
                     psize=PSIZE, psize2=2 * PSIZE, psize3=3 * PSIZE, copper=COPPER,
                     ncop=len(cop) // 2, **sz)
    assert (W * H // 32) % NS == 0
    src += "\n" + M.words_asm("coplst", b"".join(struct.pack(">H", w) for w in cop), 4) + "\n"
    src += "\n" + M.words_asm("palw", b"".join(pal), 4) + "\n"
    src += "\n" + M.words_asm("inp", inp, 4) + "\n"
    src += "\n" + M.words_asm("exp", exp, 4) + "\n"
    src += "\n" + M.words_asm("pic", pic, 4) + "\n"
    return M.assemble(src, ORG), sz


def build(outdir):
    os.makedirs(outdir, exist_ok=True)
    payload, sz = build_payload()
    open(os.path.join(outdir, "akikotest.bin"), "wb").write(payload)
    open(os.path.join(outdir, "akikotest.adf"), "wb").write(make_adf(payload))
    open(os.path.join(outdir, "bootrom.bin"), "wb").write(M.make_bootrom())
    n = sz["n1"] * 8 + sz["n2"] * 8 + sz["n3"] * 8 + sz["n4"] * 16
    print("akikotest %d bytes; output %d longs (dump: --dump 0x%X %d FILE)" % (len(payload), n, RESULT, 64 + 4 * n))
    if ORG + len(payload) > 0x1F0000:
        sys.exit("payload too large")


NAMES = ["flags", "id", "gfxbase", "version", "c2pptr", "c2pofs", "longs", "wrong_v1", "wrong_v2",
         "wrong_v3", "wrong_v4", "s1_cck", "s2_cck", "s3_cck", "verdict", "end"]


def decode(longs):
    r = dict(zip(NAMES, longs))
    out = {k: "%08x" % v for k, v in r.items()}
    f = r["flags"]
    out.update(chip_found=bool(f & 1), gfx_v40=bool(f & 2), c2pptr_akiko=bool(f & 4),
               gfx_version="%d.%d" % (r["version"] >> 16, r["version"] & 0xFFFF))
    for k in ("longs", "wrong_v1", "wrong_v2", "wrong_v3", "wrong_v4", "s1_cck", "s2_cck", "s3_cck"):
        out[k] = r[k]
    cck_ns = 1e9 / 3546895.0                       # PAL colour clock (281.94 ns)
    if r["s3_cck"]:
        t = r["s3_cck"] * cck_ns * 1e-9
        out["s3_ms"] = round(t * 1e3, 3)
        out["s3_pixels_per_s"] = round(W * H / t)
        out["s3_frames_50hz"] = round(t * 50, 2)
    for k, n in (("s1", NS), ("s2", NS)):
        if r[k + "_cck"]:
            out[k + "_cck_per_block"] = round(r[k + "_cck"] / n, 2)
    return out


def check(dump_fn, frame_fn=None):
    b = open(dump_fn, "rb").read()
    longs = list(struct.unpack(">16I", b[:64]))
    res = decode(longs)
    inp, exp, sz = layout()
    n = len(exp) // 4
    got = b[64:64 + len(exp)]
    if len(got) < len(exp):
        res["error"] = "dump too short: %d of %d bytes" % (len(got), len(exp))
        return res
    if res["chip_found"]:
        bad = []
        parts = [("V1", sz["n1"] * 8), ("V2", sz["n2"] * 8), ("V3", sz["n3"] * 8), ("V4", sz["n4"] * 16)]
        o = 0
        for name, cnt in parts:
            w = sum(1 for i in range(o, o + cnt) if got[4 * i:4 * i + 4] != exp[4 * i:4 * i + 4])
            res["py_wrong_" + name] = w
            if w and len(bad) < 8:
                for i in range(o, o + cnt):
                    if got[4 * i:4 * i + 4] != exp[4 * i:4 * i + 4]:
                        bad.append("%s long %d: got %s exp %s" % (name, i - o, got[4 * i:4 * i + 4].hex(),
                                                                  exp[4 * i:4 * i + 4].hex()))
                        if len(bad) >= 8:
                            break
            o += cnt
        res["py_longs"] = n
        res["py_words_checked"] = 2 * n
        res["py_wrong_words"] = sum(1 for i in range(2 * n) if got[2 * i:2 * i + 2] != exp[2 * i:2 * i + 2])
        res["py_first_bad"] = bad
    if frame_fn:
        res["frame"] = check_frame(frame_fn)
    return res


def check_frame(fn, xscale=2):
    """compare the bench picture (2 columns per lores pixel, one row per line) with the reference"""
    im = M.load_frame(fn)
    Wd, Hd = im.size
    px = im.load()
    pic = picture()
    pal = [M.pal_t1(i) for i in range(256)]
    row0 = [pal[pic[x]] for x in range(16)]
    org = None
    for y in range(Hd):
        for x in range(Wd - 16 * xscale):
            if all(px[x + int((i + 0.5) * xscale), y] == row0[i] for i in range(16)) and \
                    (x == 0 or px[x - 1, y] != row0[0]):
                org = (x, y)
                break
        if org:
            break
    if not org:
        return {"error": "row 0 of the picture not found"}
    bad = 0
    first = []
    for y in range(H):
        for x in range(W):
            xx, yy = org[0] + int((x + 0.5) * xscale), org[1] + y
            if xx >= Wd or yy >= Hd:
                bad += 1
                continue
            e = pal[pic[y * W + x]]
            g = px[xx, yy]
            if g != e:
                bad += 1
                if len(first) < 8:
                    first.append((x, y, "exp %02x%02x%02x got %02x%02x%02x" % (e + g)))
    return {"origin": org, "pixels": W * H, "wrong_pixels": bad, "first_bad": first}


if __name__ == "__main__":
    a = sys.argv
    if len(a) >= 3 and a[1] == "build":
        build(a[2])
    elif len(a) >= 3 and a[1] == "check":
        print(json.dumps(check(a[2], a[3] if len(a) > 3 else None), indent=1))
    elif len(a) >= 3 and a[1] == "mbox":
        print(json.dumps(decode([int(x, 16) for x in a[2].replace(",", " ").split()][:16]), indent=1))
    else:
        print(__doc__ % dict(res=RESULT))
