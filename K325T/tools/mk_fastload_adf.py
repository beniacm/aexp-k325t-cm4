#!/usr/bin/env python3
"""mk_fastload_adf.py OUT.adf -- boot-block floppy that keeps the DDR3 busy through the Zorro II
fast RAM (amiga_fastram.vhd: 16 KB cache, line fills and posted writes on the M2M Avalon bus): it
finds the first fast-RAM block in Exec's memory list and copies 128 KB inside it back and forth for
ever (interrupts and DMA off, COLOR00 changes with every pass).  Used as the background load when
measuring the DDR3 line latency (stall controller page 7, stallmon.py lat).  Without fast RAM (menu
"RAM: ...", fast RAM none) the screen turns red and the program stops.
"""
import os, struct, subprocess, sys, tempfile

ASM = r"""
        .text
start:  move.l  4.w,%a6
        move.l  322(%a6),%a0                | MemList.lh_Head
fl:     tst.l   (%a0)
        beq.s   nofast
        btst    #2,15(%a0)                  | mh_Attributes & MEMF_FAST
        beq.s   next
        move.l  20(%a0),%d0                 | mh_Lower
        cmp.l   #0x200000,%d0
        bcs.s   next
        cmp.l   #0xa00000,%d0
        bcc.s   next
        move.l  24(%a0),%d1                 | mh_Upper
        sub.l   #0x40000,%d1                | 256 KB below the top: two 128 KB areas
        and.w   #0xf000,%d1
        move.l  %d1,%a4
        bra.s   go
next:   move.l  (%a0),%a0
        bra.s   fl
nofast: move.w  #0x7fff,0xdff09a
        move.w  #0x0f00,0xdff180
        bra.s   nofast
go:     move.w  #0x7fff,0xdff09a            | INTENA off
        move.w  #0x7fff,0xdff096            | DMACON off
        moveq   #0,%d7
pass:   move.l  %a4,%a0
        move.l  %a4,%a1
        add.l   #0x20000,%a1
        btst    #0,%d7
        beq.s   p1
        exg     %a0,%a1
p1:     move.w  #0x7fff,%d0                 | 32 K longwords = 128 KB
cp:     move.l  (%a0)+,(%a1)+
        dbra    %d0,cp
        addq.l  #1,%d7
        move.w  %d7,0xdff180
        bra.s   pass
"""


def bootblock():
    with tempfile.TemporaryDirectory() as d:
        open(d + "/s.s", "w").write(ASM)
        subprocess.check_call(["m68k-linux-gnu-as", "-m68000", "-o", d + "/s.o", d + "/s.s"])
        subprocess.check_call(["m68k-linux-gnu-objcopy", "-O", "binary", d + "/s.o", d + "/s.bin"])
        c = open(d + "/s.bin", "rb").read()
    b = bytearray(1024)
    b[0:4] = b"DOS\0"
    b[8:12] = struct.pack(">I", 880)
    b[12:12 + len(c)] = c
    s = 0
    for i in range(0, 1024, 4):
        s += struct.unpack(">I", b[i:i + 4])[0]
        if s > 0xFFFFFFFF:
            s = (s & 0xFFFFFFFF) + 1
    b[4:8] = struct.pack(">I", (~s) & 0xFFFFFFFF)
    return bytes(b), len(c)


if __name__ == "__main__":
    bb, n = bootblock()
    open(sys.argv[1], "wb").write(bb + bytes(901120 - 1024))
    print("wrote", sys.argv[1], "(boot code %d bytes)" % n)
