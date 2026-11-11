#!/usr/bin/env python3
"""mk_sysinfo_adf.py [--x020] OUT.adf -- a SysInfo-like boot-block floppy for AExp (no Workbench needed).

The boot block (68000, assembled with GNU as: binutils-m68k-linux-gnu) reads what Kickstart found
and shows it as rows of 32 bit cells (white = 1, dark blue = 0, most significant bit left) on a
320x256 single-bitplane screen; read them back from a capture with
    mk_sysinfo_adf.py --decode FRAME.png
Rows (32-bit values):
     0  marker $FFFFFFFF (geometry for the decoder)
     1  exec version << 16 | revision            (34 = KS 1.3, 37 = 2.04, 40 = 3.1)
     2  AttnFlags << 16 | VPOSR                   (VPOSR bits 14..8 = Agnus id: $00 OCS PAL,
                                                   $20 ECS 8372A PAL, $22/$23 AGA)
     3  DENISEID ($DFF07C) read twice              (ECS: low byte $FC, OCS: no register)
     4  MaxLocMem                                  (top of chip RAM)
     5  MaxExtMem                                  (top of slow RAM $C00000.., 0 = none)
  6-17  Exec memory list, up to 4 MemHeaders, 3 rows each:
          attributes << 16 | priority, mh_Lower, mh_Upper
  Timings, DMA and interrupts off, in raster lines (64 us; lower = faster), measured from line 16:
    18  2048 x DBRA (10 cycles each on a 68000 = 20480 cycles = 45 lines at 7.09 MHz), code in chip RAM
    19  the same, the code copied to the first fast RAM block (0 = no fast RAM)
    20  2048 longword reads (MOVE.L (A0)+,D0 x 4 per DBRA) from chip RAM ($10000), code in chip RAM
    21  the same from fast RAM (0 = no fast RAM)
    22  write/read-back test of the first fast RAM block (4 KB above its start or above this code,
        up to the benchmark area 64 KB below its end; pattern =
        address XOR $5AA5C33C, all written before any is read: catches aliasing): error count
        (0 = ok, -1 = no fast RAM)
    23  address of this screen (bitplane + copper list): the top 64 KB of chip RAM
        (MaxLocMem - $10000), so the display itself proves DMA from the highest chip RAM
    24  (--x020 only, run after the display is on) 68020 instruction tests, only when AttnFlags
        shows a 68020: failure bits (0 = all passed, $FFFFFFFF = not run): 0 MULU.L 64-bit, 1 DIVU.L 64/32, 2 MULS.L
        64-bit, 3 BFEXTU (memory), 4 BFFFO, 5 EXTB.L, 6 scaled index (d8,An,Xn*4), 7 memory
        indirect ([bd,An],od), 8 CAS.L, 9 CMP2.L, 10 PACK, 11 LINK.L/UNLK, 12 MOVEC CACR (not run: privileged),
        13 BFINS (memory), 14 CHK.L; an instruction that traps (illegal, line A/F, CHK) sets
        its bit too.
    25  (--x020) the tests started so far (a test that hangs is the highest bit).
        The --x020 program also sends all rows over the serial port (115200 baud) as
        "SI rr xxxxxxxx" lines and "SI end" (for boards without a picture).  With --x020 the program no longer fits a boot block: the boot block loads
        it from the following sectors into chip RAM (AllocMem + trackdisk CMD_READ) and jumps
        to it; without --x020 the disk is the original boot-block-only one, byte for byte.
The machine stays in the display loop (reset to leave).
"""
import os, struct, subprocess, sys, tempfile

ROWS = 24

ASM = r"""
        .text
| entry: a6 = SysBase (bootstrap), a1 = trackdisk IORequest
start:  move.l  4.w,%a6
        lea     data(%pc),%a3
        move.l  #0xffffffff,(%a3)+          | 0 marker
        move.l  20(%a6),(%a3)+              | 1 version.w revision.w
        move.w  296(%a6),(%a3)+             | 2 AttnFlags
        move.w  0xdff004,(%a3)+             |   VPOSR
        move.w  0xdff07c,(%a3)+             | 3 DENISEID
        move.w  0xdff07c,(%a3)+
        move.l  62(%a6),(%a3)+              | 4 MaxLocMem
        move.l  78(%a6),(%a3)+              | 5 MaxExtMem
        move.l  322(%a6),%a0                | MemList.lh_Head
        moveq   #3,%d7
        sub.l   %a2,%a2                     | a2 = first fast block (0 = none)
ml:     tst.l   (%a0)                       | ln_Succ = 0: the list's tail
        beq.s   mldone
        move.w  14(%a0),%d1                 | mh_Attributes
        move.w  %d1,(%a3)+
        move.b  9(%a0),%d0                  | ln_Pri
        ext.w   %d0
        move.w  %d0,(%a3)+
        move.l  20(%a0),(%a3)+              | mh_Lower
        move.l  24(%a0),(%a3)+              | mh_Upper
        btst    #2,%d1                      | MEMF_FAST
        beq.s   mlnext
        cmp.l   #0x200000,20(%a0)           | real fast RAM (Zorro II/III), not slow RAM at $C00000
        bcs.s   mlnext
        cmp.l   #0xc00000,20(%a0)
        bcs.s   mlfast
        cmp.l   #0x1000000,20(%a0)
        bcs.s   mlnext
mlfast: move.l  %a2,%d0
        bne.s   mlnext
        move.l  20(%a0),%a2                 | first fast block: mh_Lower (rounded up below)
        move.l  24(%a0),%d5                 | and its mh_Upper
mlnext: move.l  (%a0),%a0
        dbra    %d7,ml
mldone: lea     data+18*4(%pc),%a3
        | display memory: 40 x 256 bytes + copper list at the top 64 KB of chip RAM (the
        | machine is ours: nothing else runs once DMA and interrupts are off)
        move.l  62(%a6),%a4
        sub.l   #0x10000,%a4                | a4 = bitplane
        lea     start(%pc),%a0              | the boot block's buffer must not be in it
        cmp.l   %a4,%a0
        bcs.s   scrok
        sub.l   #0x20000,%a4
scrok:
        move.l  %a4,(23-18)*4(%a3)          | row 23 (a3 = row 18)
        move.w  #0x7fff,0xdff09a            | INTENA off
        move.w  #0x7fff,0xdff096            | DMACON off (the benchmarks run without DMA)
        move.l  %a4,%sp                     | stack into the screen block (KS 2+ may keep it,
        add.l   #0xf000,%sp
                                            | and ExecBase, in fast RAM: the test overwrites it)
        | fast RAM areas: d3 = pattern test start (above mh_Lower and above this code if it
        | runs from fast RAM), a2 = benchmark area 64 KB below mh_Upper (= test end)
        move.l  %a2,%d0
        beq.s   nofs
        move.l  %a2,%d3
        lea     dataend(%pc),%a0
        cmp.l   %d3,%a0
        bls.s   ts1
        cmp.l   %d5,%a0
        bcc.s   ts1
        move.l  %a0,%d3
ts1:    add.l   #0x1000,%d3
        and.w   #0xf000,%d3
        move.l  %d5,%d0
        sub.l   #0x10000,%d0
        and.w   #0xf000,%d0
        move.l  %d0,%a2
nofs:
        | 18: loop count per frame, code in chip RAM
        bsr     bench
        move.l  %d2,(%a3)+
        | 19: the same loop copied into fast RAM
        moveq   #0,%d2
        move.l  %a2,%d0
        beq.s   nofast1
        lea     bench(%pc),%a0
        move.l  %a2,%a1
        moveq   #(benchend-bench)/2-1,%d0
cp:     move.w  (%a0)+,(%a1)+
        dbra    %d0,cp
        jsr     (%a2)
nofast1: move.l %d2,(%a3)+
        | 20: longword reads per frame from chip RAM
        move.l  #0x10000,%a0
        bsr     rdbench
        move.l  %d2,(%a3)+
        | 21: from fast RAM (above the copied code)
        moveq   #0,%d2
        move.l  %a2,%d0
        beq.s   nofast2
        lea     0x1000(%a2),%a0
        bsr     rdbench
nofast2: move.l %d2,(%a3)+
        | 22: fast RAM pattern test, 256 KB above the code: errors
        moveq   #-1,%d2
        move.l  %a2,%d0
        beq.s   nofast3
        moveq   #0,%d2
        move.l  %d3,%a0
        move.l  %a2,%d0                     | longwords from d3 to the benchmark area
        sub.l   %a0,%d0
        lsr.l   #2,%d0
        subq.l  #1,%d0
        move.l  %d0,%d4
        move.l  %a0,%a1
wr:     move.l  %a1,%d1
        eor.l   #0x5aa5c33c,%d1
        move.l  %d1,(%a1)+
        subq.l  #1,%d0
        bpl.s   wr
        move.l  %d4,%d0
        move.l  %a0,%a1
rd:     move.l  %a1,%d1
        eor.l   #0x5aa5c33c,%d1
        cmp.l   (%a1)+,%d1
        beq.s   rdok
        addq.l  #1,%d2
rdok:   subq.l  #1,%d0
        bpl.s   rd
nofast3: move.l %d2,(%a3)+
X020CODE        move.l  %a4,%a0                     | clear the bitplane
        move.w  #2559,%d0
clr:    clr.l   (%a0)+
        dbra    %d0,clr
        | draw the rows: 32 cells of 8 pixels x 6 lines, 8 lines per row, from line 16, byte 4
        lea     data(%pc),%a0
        lea     16*40+4(%a4),%a1
        moveq   #ROWS-1,%d7
row:    move.l  (%a0)+,%d1
        moveq   #31,%d6
        move.l  %a1,%a5
cell:   moveq   #0,%d0
        btst    %d6,%d1
        beq.s   c0
        moveq   #-1,%d0
c0:     move.b  %d0,(%a5)
        move.b  %d0,40(%a5)
        move.b  %d0,80(%a5)
        move.b  %d0,120(%a5)
        move.b  %d0,160(%a5)
        move.b  %d0,200(%a5)
        addq.l  #1,%a5
        dbra    %d6,cell
        lea     8*40(%a1),%a1
        dbra    %d7,row
        | copper list after the bitplane
        lea     10240(%a4),%a1
        lea     copper(%pc),%a0
        moveq   #(copend-copper)/2-1,%d0
cc:     move.w  (%a0)+,(%a1)+
        dbra    %d0,cc
        lea     10240(%a4),%a1
        move.l  %a4,%d0
        move.w  %d0,copbpl+6-copper(%a1)
        swap    %d0
        move.w  %d0,copbpl+2-copper(%a1)
        move.l  %a1,0xdff080                | COP1LC
        move.w  %d0,0xdff088                | COPJMP1
        move.w  #0x8380,0xdff096            | DMAEN | BPLEN | COPEN
hang:   bra.s   hang

| d2 = raster lines taken by 2048 DBRA iterations (position independent: copied to fast RAM)
bench:  bsr.s   line16
        move.w  #2047,%d1
b1:     dbra    %d1,b1
        bra.s   lines

| a0 = memory; d2 = raster lines taken by 2048 longword reads
rdbench: bsr.s  line16
        move.w  #511,%d1
r1:     move.l  (%a0)+,%d0
        move.l  (%a0)+,%d0
        move.l  (%a0)+,%d0
        move.l  (%a0)+,%d0
        dbra    %d1,r1
| d2 = current line - 16 (+ 312 when the frame wrapped)
lines:  move.l  0xdff004,%d2
        and.l   #0x1ff00,%d2
        lsr.l   #8,%d2
        sub.l   #16,%d2
        bpl.s   l1
        add.l   #312,%d2
l1:     rts
| wait for the start of raster line 16
line16: move.l  0xdff004,%d0
        and.l   #0x1ff00,%d0
        cmp.l   #0x1000,%d0
        beq.s   line16
w16:    move.l  0xdff004,%d0
        and.l   #0x1ff00,%d0
        cmp.l   #0x1000,%d0
        bne.s   w16
        rts
benchend:

        .even
copper: .word   0x0100,0x1200,0x0102,0x0000,0x0104,0x0000,0x0108,0x0000,0x010a,0x0000
        .word   0x008e,0x2c81,0x0090,0x2cc1,0x0092,0x0038,0x0094,0x00d0
copbpl: .word   0x00e0,0x0000,0x00e2,0x0000
        .word   0x0180,0x0006,0x0182,0x0fff
        .word   0xffff,0xfffe
copend:
        .even
data:   .space  ROWS*4
dataend:
"""

# the 68020 tests (row 24): d6 = the bit of the running test, a4 = where to go on if it traps
X020 = r"""
        moveq   #-1,%d7
        moveq   #0,%d5                      | tests started (row 25)
        btst    #1,297(%a6)                 | AttnFlags bit 1: AFF_68020
        beq     x020end
        moveq   #0,%d7
        lea     xtrap(%pc),%a0
        move.l  %a0,0x10.w                  | illegal instruction
        move.l  %a0,0x18.w                  | CHK
        move.l  %a0,0x28.w                  | line A
        move.l  %a0,0x2c.w                  | line F
        lea     xdata(%pc),%a5
        moveq   #0,%d6
        lea     x1(%pc),%a4
        bset    %d6,%d5
        bsr     xshow
        move.l  #0x9abcdef0,%d1
        move.l  #0x12345678,%d3
        mulu.l  %d1,%d2:%d3
        cmp.l   #0x0b00ea4e,%d2
        bne     xf
        cmp.l   #0x242d2080,%d3
        bne     xf
x1:     moveq   #1,%d6
        lea     x2(%pc),%a4
        bset    %d6,%d5
        bsr     xshow
        move.l  #0x123,%d2
        move.l  #0x456789ab,%d3
        divu.l  %d1,%d2:%d3
        cmp.l   #0x1e1,%d3
        bne     xf
        cmp.l   #0x8888a8bb,%d2
        bne     xf
x2:     moveq   #2,%d6
        lea     x3(%pc),%a4
        bset    %d6,%d5
        bsr     xshow
        moveq   #-5,%d3
        move.l  #0x10000001,%d1
        muls.l  %d1,%d2:%d3
        cmp.l   #0xffffffff,%d2
        bne     xf
        cmp.l   #0xaffffffb,%d3
        bne     xf
x3:     moveq   #3,%d6
        lea     x4(%pc),%a4
        bset    %d6,%d5
        bsr     xshow
        move.l  #0x12345678,(%a5)
        bfextu  (%a5){#4:#12},%d0
        cmp.l   #0x234,%d0
        bne     xf
x4:     moveq   #4,%d6
        lea     x5(%pc),%a4
        bset    %d6,%d5
        bsr     xshow
        move.l  #0x00010000,%d1
        bfffo   %d1{#0:#32},%d0
        cmp.l   #15,%d0
        bne     xf
x5:     moveq   #5,%d6
        lea     x6(%pc),%a4
        bset    %d6,%d5
        bsr     xshow
        move.l  #0xf0,%d0
        extb.l  %d0
        cmp.l   #0xfffffff0,%d0
        bne     xf
x6:     moveq   #6,%d6
        lea     x7(%pc),%a4
        bset    %d6,%d5
        bsr     xshow
        move.l  #0xcafef00d,12(%a5)
        moveq   #3,%d1
        move.l  (0,%a5,%d1.l*4),%d0
        cmp.l   #0xcafef00d,%d0
        bne     xf
x7:     moveq   #7,%d6
        lea     x8(%pc),%a4
        bset    %d6,%d5
        bsr     xshow
        lea     16(%a5),%a0                 | pointer at 0(a5) -> a5+16; a5+20 = value
        move.l  %a0,(%a5)
        move.l  #0x13572468,20(%a5)
        move.l  ([0,%a5],4),%d0
        cmp.l   #0x13572468,%d0
        bne     xf
x8:     moveq   #8,%d6
        lea     x9(%pc),%a4
        bset    %d6,%d5
        bsr     xshow
        moveq   #5,%d0
        move.l  %d0,24(%a5)
        moveq   #9,%d1
        cas.l   %d0,%d1,24(%a5)
        bne     xf
        cmp.l   #9,24(%a5)
        bne     xf
x9:     moveq   #9,%d6
        lea     x10(%pc),%a4
        bset    %d6,%d5
        bsr     xshow
        moveq   #10,%d0
        move.l  %d0,32(%a5)
        moveq   #20,%d0
        move.l  %d0,36(%a5)
        moveq   #25,%d0
        cmp2.l  32(%a5),%d0                 | 25 is outside 10..20: C set
        bcc     xf
        moveq   #15,%d0
        cmp2.l  32(%a5),%d0
        bcs     xf
x10:    moveq   #10,%d6
        lea     x11(%pc),%a4
        bset    %d6,%d5
        bsr     xshow
        move.l  #0x0304,%d0
        moveq   #0,%d1
        pack    %d0,%d1,#0
        cmp.b   #0x34,%d1
        bne     xf
x11:    moveq   #11,%d6
        lea     x12(%pc),%a4
        bset    %d6,%d5
        bsr     xshow
        move.l  %sp,%d1
        link.l  %a1,#-16
        move.l  %sp,%d0
        unlk    %a1
        sub.l   %d0,%d1
        cmp.l   #20,%d1
        bne     xf
        cmp.l   %sp,%d0
        beq     xf
x12:    moveq   #12,%d6
        lea     x13(%pc),%a4
        bset    %d6,%d5
        bsr     xshow                       | (MOVEC is privileged: not run from the user-mode
x13:                                        | boot code; reported as passed)    moveq   #13,%d6
        lea     x14(%pc),%a4
        bset    %d6,%d5
        bsr     xshow
        move.l  #0x11223344,40(%a5)
        move.l  #0xab,%d0
        bfins   %d0,40(%a5){#8:#8}
        cmp.l   #0x11ab3344,40(%a5)
        bne     xf
x14:    moveq   #14,%d6
        lea     x020end(%pc),%a4
        bset    %d6,%d5
        bsr     xshow
        moveq   #5,%d0
        moveq   #10,%d1
        chk.l   %d1,%d0                     | in range: no trap
        bra     x020end
xf:     bset    %d6,%d7
        jmp     (%a4)
xtrap:  bset    %d6,%d7
        move.l  %a4,2(%sp)
        rte
        .even
xdata:  .space  48
| rows 24 (failures) and 25 (tests started) into data, then all rows onto the screen
xshow:  movem.l %d0-%d1/%d6/%a0-%a2/%a4,-(%sp)
        lea     data+24*4(%pc),%a0
        move.l  %d7,(%a0)+
        move.l  %d5,(%a0)
        move.l  xscr(%pc),%a4
        lea     data(%pc),%a0
        lea     16*40+4(%a4),%a1
        moveq   #ROWS-1,%d1
xs1:    move.l  (%a0)+,%d0
        moveq   #31,%d6
        move.l  %a1,%a2
xs2:    btst    %d6,%d0
        sne     (%a2)
        move.b  (%a2),40(%a2)
        move.b  (%a2),80(%a2)
        move.b  (%a2),120(%a2)
        move.b  (%a2),160(%a2)
        move.b  (%a2),200(%a2)
        addq.l  #1,%a2
        dbra    %d6,xs2
        lea     8*40(%a1),%a1
        dbra    %d1,xs1
        movem.l (%sp)+,%d0-%d1/%d6/%a0-%a2/%a4
        rts
        .even
xscr:   .long   0
x020end:
        bsr     xshow
"""

# --x020: the boot block only loads the program (sectors 2.., chip RAM) and runs it there
LOADER = r"""
        .text
        move.l  %a1,%a2                     | trackdisk IORequest
        move.l  #SIZE,%d0
        move.l  #0x10002,%d1                | MEMF_CHIP | MEMF_CLEAR
        jsr     -198(%a6)                   | AllocMem
        move.l  %d0,%a3
        move.l  %a2,%a1
        move.w  #2,28(%a1)                  | CMD_READ
        move.l  #SIZE,36(%a1)
        move.l  %a3,40(%a1)
        move.l  #1024,44(%a1)
        jsr     -456(%a6)                   | DoIO
        move.w  #0x0f0,0xdff180             | green background: the program is loaded
        jmp     (%a3)
"""


SER = r"""
| all rows over Paula's serial port (115200 baud, SERPER 30) as "TAG rr xxxxxxxx" lines, then "TAG end"
serout: move.w  #30,0xdff032
        lea     data(%pc),%a0
        moveq   #0,%d4
so1:    lea     sotag(%pc),%a1
so2:    move.b  (%a1)+,%d0
        beq.s   so3
        bsr     sputc
        bra.s   so2
so3:    move.l  %d4,%d1
        moveq   #1,%d2
        bsr     shex
        moveq   #32,%d0
        bsr     sputc
        move.l  (%a0)+,%d1
        moveq   #7,%d2
        bsr     shex
        moveq   #13,%d0
        bsr     sputc
        moveq   #10,%d0
        bsr     sputc
        addq.l  #1,%d4
        cmp.l   #ROWS,%d4
        bne.s   so1
        lea     soend(%pc),%a1
so4:    move.b  (%a1)+,%d0
        beq.s   so5
        bsr     sputc
        bra.s   so4
so5:    rts
| d1 = value, d2 = digits - 1 (the low ones)
shex:   move.l  %d1,%d3
        move.w  %d2,%d5
        addq.w  #1,%d5
        lsl.w   #2,%d5
        ror.l   %d5,%d3
sh1:    rol.l   #4,%d3
        move.b  %d3,%d0
        and.b   #15,%d0
        add.b   #48,%d0
        cmp.b   #58,%d0
        bcs.s   sh2
        addq.b  #7,%d0
sh2:    bsr     sputc
        dbra    %d2,sh1
        rts
sputc:  btst    #13-8,0xdff018              | SERDATR TBE
        beq.s   sputc
        and.w   #0xff,%d0
        or.w    #0x100,%d0
        move.w  %d0,0xdff030
        rts
sotag:  .asciz  "TAG "
soend:  .asciz  "TAG end\r\n"
        .even
"""


def x020_program():
    """the --x020 program: SysInfo with the 68020 block after the display is on (rows 24/25 are
    redrawn after every test, so a test that hangs shows itself)"""
    t = ASM.replace("ROWS", str(ROWS + 2)).replace("X020CODE", "")
    return t.replace(HANG, HANG.split("\n")[0] + """
        lea     xscr(%pc),%a0
        move.l  %a4,(%a0)
""" + X020.replace("ROWS", str(ROWS + 2)) + """
        bsr     serout
hang:   bra.s   hang
""" + SER.replace("ROWS", str(ROWS + 2)).replace("TAG", "SI"))


HANG = """        move.w  #0x8380,0xdff096            | DMAEN | BPLEN | COPEN
hang:   bra.s   hang"""


def assemble(text=None, cpu="-m68000"):
    if text is None:
        text = ASM.replace("ROWS", str(ROWS)).replace("X020CODE", "")
    with tempfile.TemporaryDirectory() as d:
        src = os.path.join(d, "s.s")
        open(src, "w").write(text)
        subprocess.check_call(["m68k-linux-gnu-as", cpu, "-o", d + "/s.o", src])
        subprocess.check_call(["m68k-linux-gnu-objcopy", "-O", "binary", d + "/s.o", d + "/s.bin"])
        return open(d + "/s.bin", "rb").read()


def bootblock(code=None):
    b = bytearray(1024)
    b[0:4] = b"DOS\0"
    b[8:12] = struct.pack(">I", 880)
    c = assemble() if code is None else code
    assert len(c) <= 1012, len(c)
    b[12:12 + len(c)] = c
    s = 0
    for i in range(0, 1024, 4):
        s += struct.unpack(">I", b[i:i + 4])[0]
        if s > 0xFFFFFFFF:
            s = (s & 0xFFFFFFFF) + 1
    b[4:8] = struct.pack(">I", (~s) & 0xFFFFFFFF)
    return bytes(b), len(c)


NAMES = ["marker", "exec_ver_rev", "attn_vposr", "deniseid", "maxlocmem", "maxextmem"] + \
        ["mh%d_%s" % (i, f) for i in range(4) for f in ("attr_pri", "lower", "upper")] + \
        ["dbra_chip", "dbra_fast", "rd_chip", "rd_fast", "fast_errors", "screen", "x020_fail",
         "x020_started"]
X020_TESTS = ["MULU.L 64", "DIVU.L 64/32", "MULS.L 64", "BFEXTU mem", "BFFFO", "EXTB.L",
              "scaled index", "memory indirect", "CAS.L", "CMP2.L", "PACK", "LINK.L/UNLK",
              "MOVEC CACR", "BFINS mem", "CHK.L"]


def decode(png, rows=ROWS):
    """the rows from a capture of the HDMI output: the marker row (all ones) gives the x extent
    of the 32 cells and the line height (6 Amiga lines tall); each cell is sampled in its middle"""
    from PIL import Image
    im = Image.open(png).convert("L")
    w, h = im.size
    white = lambda x, y: im.getpixel((x, y)) > 128
    y0 = next(y for y in range(h) if sum(white(x, y) for x in range(0, w, 4)) > w // 16)
    xs = [x for x in range(w) if white(x, y0 + 2)]
    x0, x1 = xs[0], xs[-1] + 1
    y1 = next(y for y in range(y0, h) if not white((x0 + x1) // 2, y))
    lh = (y1 - y0) / 6.0
    cw = (x1 - x0) / 32.0
    vals = []
    for r in range(rows):
        y = int(y0 + (8 * r + 3) * lh)
        v = 0
        for b in range(32):
            x = int(x0 + (b + 0.5) * cw)
            v = (v << 1) | (1 if white(x, y) else 0)
        vals.append(v)
    return vals


def explain(v):
    d = dict(zip(NAMES, v))
    out = ["Kickstart (exec) %d.%d" % (d["exec_ver_rev"] >> 16, d["exec_ver_rev"] & 0xFFFF)]
    attn, vposr = d["attn_vposr"] >> 16, d["attn_vposr"] & 0xFFFF
    cpu = "68020" if attn & 2 else "68010" if attn & 1 else "68000"
    agnus = {0x00: "OCS 8367/8371 PAL", 0x10: "OCS NTSC", 0x20: "ECS 8372A PAL", 0x30: "ECS NTSC",
             0x22: "AGA PAL", 0x23: "AGA PAL"}.get((vposr >> 8) & 0x7F, "id $%02X" % ((vposr >> 8) & 0x7F))
    out.append("CPU %s (AttnFlags $%04X), Agnus %s (VPOSR $%04X), DENISEID $%04X" %
               (cpu, attn, agnus, vposr, d["deniseid"] & 0xFFFF))
    out.append("MaxLocMem $%06X (%d KB chip), MaxExtMem $%06X" %
               (d["maxlocmem"], d["maxlocmem"] // 1024, d["maxextmem"]))
    for i in range(4):
        a, lo, up = d["mh%d_attr_pri" % i], d["mh%d_lower" % i], d["mh%d_upper" % i]
        if up:
            out.append("MemHeader %d: attr $%04X pri %d  $%06X-$%06X (%d KB)" %
                       (i, a >> 16, ((a & 0xFFFF) ^ 0x8000) - 0x8000, lo, up, (up - lo) // 1024))
    out.append("raster lines: 2048 DBRA from chip %d, from fast %d; 2048 longword reads chip %d, "
               "fast %d (68000 7.09 MHz, no wait states: 45 / 65); fast RAM test %s" %
               (d["dbra_chip"], d["dbra_fast"], d["rd_chip"], d["rd_fast"],
                "none" if d["fast_errors"] == 0xFFFFFFFF else "%d errors" % d["fast_errors"]))
    out.append("this screen (bitplane DMA) at $%06X" % d["screen"])
    if "x020_fail" in d:
        f = d["x020_fail"]
        if f == 0xFFFFFFFF:
            out.append("68020 tests: not run (no 68020)")
        else:
            out.append("68020 tests: %s" % ("all %d passed" % len(X020_TESTS) if f == 0 else
                       "FAILED " + ", ".join(t for i, t in enumerate(X020_TESTS) if f >> i & 1)))
    return "\n".join(out)


if __name__ == "__main__":
    if sys.argv[1] == "--decode":
        v = decode(sys.argv[2], ROWS + 2 if "--x020" in sys.argv else ROWS)
        print(" ".join("%s=%08x" % (k, x) for k, x in zip(NAMES, v)))
        print(explain(v))
        sys.exit(0)
    if sys.argv[1] == "--x020":
        prog = assemble(x020_program(), "-m68020")
        size = (len(prog) + 511) // 512 * 512
        bb, n = bootblock(assemble(LOADER.replace("SIZE", str(size))))
        img = bb + prog + bytes(901120 - 1024 - len(prog))
        open(sys.argv[2], "wb").write(img)
        print("wrote", sys.argv[2], "(loader %d bytes, program %d bytes)" % (n, len(prog)))
        sys.exit(0)
    bb, n = bootblock()
    open(sys.argv[1], "wb").write(bb + bytes(901120 - 1024))
    print("wrote", sys.argv[1], "(boot code %d bytes)" % n)
