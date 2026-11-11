#!/usr/bin/env python3
"""mk_writetest_adf.py OUT.adf -- a floppy write test for AExp (no Workbench needed).

The ADF's boot block (hand-assembled 68000 code below) writes 512 bytes of a known pattern to
sector WRITE_SECTOR through trackdisk.device (CMD_WRITE, CMD_UPDATE, motor off), switches the
display DMA off and fills the screen GREEN if both commands succeeded, RED if not.  After the
core has written the track back to the SD card, check the sector in the ADF file:
    mk_writetest_adf.py --check FILE.adf      (exit 0 = the pattern is there)
The disk has no file system (boot block only); Kickstart 1.3 runs a valid boot block anyway."""
import struct, sys

WRITE_SECTOR = 1000                      # track 45, inside the 880 KB
PATTERN = (b"AExp K325T floppy write test, sector %d. " % WRITE_SECTOR * 16)[:512]
BUF = 256                                # buffer offset inside the boot block

def w(*words):
    return b"".join(struct.pack(">H", x) for x in words)

def code():
    c = b""
    c += w(0x2449)                                   # movea.l a1,a2        (IOStdReq)
    c += w(0x41FA, 0)                                # lea BUF(pc),a0       (patched below)
    lea_at = 12 + len(c) - 2
    c += w(0x2548, 0x0028)                           # move.l a0,40(a2)     io_Data
    c += w(0x257C, 0x0000, 0x0200, 0x0024)           # move.l #512,36(a2)   io_Length
    off = WRITE_SECTOR * 512
    c += w(0x257C, off >> 16, off & 0xFFFF, 0x002C)  # move.l #off,44(a2)   io_Offset
    c += w(0x357C, 0x0003, 0x001C)                   # move.w #3,28(a2)     CMD_WRITE
    c += w(0x224A, 0x4EAE, 0xFE38)                   # movea.l a2,a1; jsr DoIO(a6)
    c += w(0x2E00)                                   # move.l d0,d7
    c += w(0x357C, 0x0004, 0x001C)                   # move.w #4,28(a2)     CMD_UPDATE
    c += w(0x224A, 0x4EAE, 0xFE38)                   # movea.l a2,a1; jsr DoIO(a6)
    c += w(0x8E80)                                   # or.l d0,d7
    c += w(0x357C, 0x0009, 0x001C)                   # move.w #9,28(a2)     TD_MOTOR
    c += w(0x42AA, 0x0024)                           # clr.l 36(a2)         off
    c += w(0x224A, 0x4EAE, 0xFE38)                   # movea.l a2,a1; jsr DoIO(a6)
    c += w(0x33FC, 0x7FFF, 0x00DF, 0xF09A)           # move.w #$7fff,$dff09a  INTENA off
    c += w(0x33FC, 0x7FFF, 0x00DF, 0xF096)           # move.w #$7fff,$dff096  DMACON off
    c += w(0x323C, 0x00F0)                           # move.w #$0f0,d1      green
    c += w(0x4A87, 0x6704)                           # tst.l d7; beq.s +4
    c += w(0x323C, 0x0F00)                           # move.w #$f00,d1      red
    c += w(0x33C1, 0x00DF, 0xF180)                   # loop: move.w d1,$dff180
    c += w(0x60F8)                                   # bra.s loop
    c = bytearray(c)
    disp = BUF - (lea_at)                            # PC = address of the extension word
    c[lea_at - 12:lea_at - 12 + 2] = struct.pack(">h", disp)
    return bytes(c)

def bootblock():
    b = bytearray(1024)
    b[0:4] = b"DOS\0"
    b[8:12] = struct.pack(">I", 880)
    c = code()
    assert 12 + len(c) <= BUF
    b[12:12 + len(c)] = c
    b[BUF:BUF + 512] = PATTERN
    s = 0
    for i in range(0, 1024, 4):
        s += struct.unpack(">I", b[i:i + 4])[0]
        if s > 0xFFFFFFFF:
            s = (s & 0xFFFFFFFF) + 1
    b[4:8] = struct.pack(">I", (~s) & 0xFFFFFFFF)
    return bytes(b)

if __name__ == "__main__":
    if sys.argv[1] == "--check":
        d = open(sys.argv[2], "rb").read()
        ok = d[WRITE_SECTOR * 512:WRITE_SECTOR * 512 + 512] == PATTERN
        print("WRITE_TEST %s: sector %d %s" % ("PASS" if ok else "FAIL", WRITE_SECTOR,
              "has the pattern" if ok else "does not have the pattern"))
        sys.exit(0 if ok else 1)
    img = bootblock() + bytes(901120 - 1024)
    open(sys.argv[1], "wb").write(img)
    print("wrote", sys.argv[1])
