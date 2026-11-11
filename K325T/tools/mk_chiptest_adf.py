#!/usr/bin/env python3
"""mk_chiptest_adf.py OUT.adf -- boot-block chip-RAM test for the stage-2 cache (A1200 study): writes
a pattern over all chip RAM from $1000 up to MaxLocMem (except this program's own 8 KB and the 12 KB
screen block at $7C000, or $60000 when the program sits up there), reads it back, counts errors, then repeats with the pattern inverted, for
ever.  Interrupts off; bitplane + copper DMA show the result rows (as mk_stalltest_adf.py; decode
with --decode):
     0  marker $FFFFFFFF      1  passes      2  errors (all passes)      3  first error address
     4  MaxLocMem (the top of chip RAM)      5  the last pass's error count
Pattern: address XOR $5AA5C33C (inverted on odd passes), all written before any is read, so
aliasing (a line that comes back from the wrong place) shows up.
"""
import os, struct, subprocess, sys, tempfile
sys.path.insert(0, os.path.dirname(os.path.abspath(__file__)))
import mk_stalltest_adf as ST

ROWS = 6
ASM = r"""
        .text
start:  lea     super(%pc),%a0
        move.l  %a0,0x80.w
        trap    #0
super:  lea     0xdff000,%a6
        move.w  #0x7fff,0x9a(%a6)
        move.w  #0x7fff,0x9c(%a6)
        move.w  #0x7fff,0x96(%a6)
        move.l  4.w,%a0
        move.l  62(%a0),%d6                 | MaxLocMem
        lea     vars(%pc),%a4
        move.l  %d6,r_top-vars(%a4)
        | excluded from the test: this program's page (+1, the code may cross a page) and the screen
        lea     start(%pc),%a5
        move.l  %a5,%d4
        and.w   #0xf000,%d4                 | d4 = the program's page
        move.l  %d4,%d5
        add.l   #0x2000,%d5                 | d5 = its end
        move.l  #0x7c000,%a5                | a5 = screen (bitplane 10 KB + copper, 12 KB), at
        cmp.l   #0x78000,%d4                |   $7C000 or, if the program is up there, $60000
        bcs.s   scrok
        move.l  #0x60000,%a5
scrok:  move.l  %a5,%a3                     | a3 = the screen (excluded)
        lea     0x2fe0(%a5),%sp
        move.l  %a5,%a0
        move.w  #0x0aff,%d1
clr:    clr.l   (%a0)+
        dbra    %d1,clr
        lea     0x180(%a6),%a0
        move.w  #0x0006,(%a0)+
        move.w  #0x0fff,(%a0)+
        lea     0x2800(%a5),%a0             | copper: 1 plane lores
        move.l  #0x01001200,(%a0)+
        move.l  #0x01020000,(%a0)+
        move.l  #0x01080000,(%a0)+
        move.l  #0x008e2c81,(%a0)+
        move.l  #0x00902cc1,(%a0)+
        move.l  #0x00920038,(%a0)+
        move.l  #0x009400d0,(%a0)+
        move.l  %a5,%d0
        move.w  #0x00e0,(%a0)+
        swap    %d0
        move.w  %d0,(%a0)+
        swap    %d0
        move.w  #0x00e2,(%a0)+
        move.w  %d0,(%a0)+
        move.l  #0xfffffffe,(%a0)+
        lea     0x2800(%a5),%a0
        move.l  %a0,0x80(%a6)
        move.w  %d0,0x88(%a6)
        move.w  #0x8380,0x96(%a6)           | bitplane + copper DMA
        bsr     draw                        | the rows once before the first pass (MaxLocMem)
        moveq   #0,%d3                      | pattern xor: 0 / -1
pass:   move.l  #0x5aa5c33c,%d2
        eor.l   %d3,%d2
        move.l  #0x1000,%a0                 | write
wr:     cmp.l   %d4,%a0
        bne.s   w0
        move.l  %d5,%a0
w0:     cmp.l   %a3,%a0
        bne.s   w1
        lea     0x3000(%a0),%a0
w1:     cmp.l   %d6,%a0
        bcc.s   wdone
        move.l  %a0,%d0
        eor.l   %d2,%d0
        move.l  %d0,(%a0)+
        bra.s   wr
wdone:  moveq   #0,%d7                      | read back
        move.l  #0x1000,%a0
rd:     cmp.l   %d4,%a0
        bne.s   r0
        move.l  %d5,%a0
r0:     cmp.l   %a3,%a0
        bne.s   r1
        lea     0x3000(%a0),%a0
r1:     cmp.l   %d6,%a0
        bcc.s   rdone
        move.l  %a0,%d0
        eor.l   %d2,%d0
        cmp.l   (%a0)+,%d0
        beq.s   rd
        addq.l  #1,%d7
        tst.l   r_first-vars(%a4)
        bne.s   rd
        move.l  %a0,%d0
        subq.l  #4,%d0
        move.l  %d0,r_first-vars(%a4)
        bra.s   rd
rdone:  add.l   %d7,r_err-vars(%a4)
        move.l  %d7,r_last-vars(%a4)
        addq.l  #1,r_pass-vars(%a4)
        not.l   %d3
        lea     vars(%pc),%a0               | the rows also to $C0 (result mailbox: stallmon.py mbox)
        lea     0xc0.w,%a1
        moveq   #ROWS-1,%d0
mb:     move.l  (%a0)+,(%a1)+
        dbra    %d0,mb
        bsr     draw
        bra     pass

draw:   lea     vars(%pc),%a0
        lea     16*40+4(%a5),%a1
        moveq   #ROWS-1,%d1
row:    move.l  (%a0)+,%d0
        moveq   #31,%d2
        move.l  %a1,%a2
cell:   btst    %d2,%d0
        sne     (%a2)
        move.b  (%a2),40(%a2)
        move.b  (%a2),80(%a2)
        move.b  (%a2),120(%a2)
        move.b  (%a2),160(%a2)
        move.b  (%a2),200(%a2)
        addq.l  #1,%a2
        dbra    %d2,cell
        lea     8*40(%a1),%a1
        dbra    %d1,row
        rts

        .even
vars:   .long   0xffffffff
r_pass: .long   0
r_err:  .long   0
r_first: .long  0
r_top:  .long   0
r_last: .long   0
"""

NAMES = ["marker", "passes", "errors", "first_error", "maxlocmem", "last_pass_errors"]


def bootblock():
    with tempfile.TemporaryDirectory() as d:
        open(d + "/s.s", "w").write(ASM.replace("ROWS", str(ROWS)))
        subprocess.check_call(["m68k-linux-gnu-as", "-m68000", "-o", d + "/s.o", d + "/s.s"])
        subprocess.check_call(["m68k-linux-gnu-objcopy", "-O", "binary", d + "/s.o", d + "/s.bin"])
        c = open(d + "/s.bin", "rb").read()
    b = bytearray(1024)
    b[0:4] = b"DOS\0"
    b[8:12] = struct.pack(">I", 880)
    assert len(c) <= 1012, len(c)
    b[12:12 + len(c)] = c
    s = 0
    for i in range(0, 1024, 4):
        s += struct.unpack(">I", b[i:i + 4])[0]
        if s > 0xFFFFFFFF:
            s = (s & 0xFFFFFFFF) + 1
    b[4:8] = struct.pack(">I", (~s) & 0xFFFFFFFF)
    return bytes(b), len(c)


if __name__ == "__main__":
    if sys.argv[1] in ("--decode", "--mbox"):
        ST.ROWS = ROWS
        v = ST.decode(sys.argv[2]) if sys.argv[1] == "--decode" else \
            [int(x, 16) for x in sys.argv[2].split()][:ROWS]
        print(" ".join("%s=%08x" % kv for kv in zip(NAMES, v)))
        d = dict(zip(NAMES, v))
        print("passes %d, errors %d (last pass %d), first error at $%06X, chip RAM top $%06X (%d KB)" %
              (d["passes"], d["errors"], d["last_pass_errors"], d["first_error"], d["maxlocmem"],
               d["maxlocmem"] // 1024))
        sys.exit(0)
    bb, n = bootblock()
    open(sys.argv[1], "wb").write(bb + bytes(901120 - 1024))
    print("wrote", sys.argv[1], "(boot code %d bytes)" % n)
