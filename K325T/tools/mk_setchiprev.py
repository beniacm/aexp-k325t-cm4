#!/usr/bin/env python3
"""mk_setchiprev.py OUT -- a 96-byte AmigaDOS executable (own code) that switches graphics.library
to the best chipset (SetChipRev(SETCHIPREV_BEST)), the one thing Workbench's SetPatch does that AGA
demos check for (GfxBase->ChipRevBits0 AA bits; Kickstart 3.x boots in the ECS-compatible mode).
For boot disks / directories that start a demo from a startup-sequence without Workbench files:
    setchiprev
    demo.exe
"""
import os, struct, subprocess, sys, tempfile

SRC = r"""
        .text
        move.l  4.w,%a6
        lea     gfx(%pc),%a1
        moveq   #39,%d0
        jsr     -552(%a6)               | OpenLibrary("graphics.library", 39)
        tst.l   %d0
        beq.s   1f
        move.l  %d0,%a6
        moveq   #-1,%d0                 | SETCHIPREV_BEST
        jsr     -888(%a6)               | SetChipRev
        move.l  %a6,%a1
        move.l  4.w,%a6
        jsr     -414(%a6)               | CloseLibrary
1:      moveq   #0,%d0
        rts
gfx:    .asciz  "graphics.library"
        .balign 4
"""


def build():
    with tempfile.TemporaryDirectory() as d:
        open(d + "/s.s", "w").write(SRC)
        subprocess.check_call(["m68k-linux-gnu-as", "-m68000", "-o", d + "/s.o", d + "/s.s"])
        subprocess.check_call(["m68k-linux-gnu-objcopy", "-O", "binary", d + "/s.o", d + "/s.bin"])
        code = open(d + "/s.bin", "rb").read()
    code += b"\0" * (-len(code) % 4)
    n = len(code) // 4
    # HUNK_HEADER: no resident libs, 1 hunk (0..0), size; HUNK_CODE; HUNK_END
    return (struct.pack(">IIIII", 0x3F3, 0, 1, 0, 0) + struct.pack(">I", n) +
            struct.pack(">II", 0x3E9, n) + code + struct.pack(">I", 0x3F2))


if __name__ == "__main__":
    if len(sys.argv) < 2:
        sys.exit(__doc__)
    b = build()
    open(sys.argv[1], "wb").write(b)
    os.chmod(sys.argv[1], 0o755)
    print("%s: %d bytes" % (sys.argv[1], len(b)))
