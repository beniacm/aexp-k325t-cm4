# AExp on the QMTech XC7K325T CM4 carrier (`K325T/`)

AExp (Amiga 500 OCS/PAL for the MEGA65, by sy2002, based on MiSTer's Minimig) ported to the
**QMTech XC7K325T "CM4" carrier** with a Rockchip module (Radxa CM3 or Luckfox Core3566) in its
CM4 socket.  The module serves the SD card, keyboard, joysticks and mouse over one SPI link
(`rk_bridge`); the board's DDR3 replaces the MEGA65's HyperRAM.  Same recipe as the C64MEGA65
port (`c64mega65`, `K325T/`).  `PORTING.md` has the feasibility notes and why the port is
cycle-equivalent to upstream (Amiga memory stays in block RAM, clocks and enables untouched).
Not affiliated with the AExp author.

Board harness (Rockchip daemons, scripts, write-up): `mega65-k325t-cm4` (beniacm), sections
"Amiga core", "C64 core" and "Standalone".

## What the port adds

| file | role |
|---|---|
| `top_qmtech_k325t_cm4.tpl.vhd`, `gen_top.py` | board top generated from M2M's R6 top: clocks, MIG, Rockchip bridge, SD emulator, flash, warm boot |
| `avm_mig.vhd`, `mig_ddr3.prj` | M2M Avalon memory bus (HyperRAM interface) -> MIG DDR3 native UI (from the C64 port) |
| `m65kbd_emu.vhd` | the MEGA65 keyboard's serial link, answered from the bridge's key matrix (from the C64 port) |
| `amiga_mouse.vhd` (+ `sim/tb_amiga_mouse.vhd`) | Amiga quadrature mouse from the bridge's position counters (new) |
| `qmtech_k325t_cm4.xdc`, `qmtech_k325t_cm4_radxacm3_bus.xdc` | pins + timing; the CM-bus section per module |
| `build.sh`, `build.tcl`, `gen_sources.py` | Vivado batch build (source list taken from `CORE/CORE-R6.xpr`) |
| `tools/aexp_demo_test.py` | mounts demo ADFs one after the other, records the HDMI output (clip + frames) |
| `tools/mk_writetest_adf.py` | boot-block floppy that writes a sector (write-back test, no Workbench needed) |
| `tools/mk_inputtest_adf.py` | boot-block floppy showing JOY0DAT/JOY1DAT/CIA-A/POTGOR as bit stripes (mouse, joystick, buttons) |
| `tools/mk_kbdtest_adf.py` | boot-block floppy reading Kickstart's keyboard.device (KBD_READMATRIX) |

Upstream files changed (generic-gated, defaults = upstream): `M2M/vhdl/framework.vhd`,
`M2M/vhdl/av_pipeline/av_pipeline.vhd`, `M2M/vhdl/av_pipeline/digital_pipeline.vhd` (the C64
port's `G_EXT_HR`, `G_TMDS_INVERT`, `G_NO_I2C`), `.gitignore`.  Nothing in `CORE/`.

Rockchip bridge core id **3** (STATUS byte 52).  The module's m65d (harness) then
- maps a PC keyboard for AExp's **Amiga** keyboard mode (menu: Keyboard > Amiga, saved in the
  settings file): the PC caps are right on the Kickstart's US keymap; Win = Left Amiga,
  Menu / right Win = Right Amiga, Alt = Left Alt, AltGr = Right Alt, PrtSc = Help (also opens
  the menu), Backspace / Delete as on the Amiga, F1-F10 = F1-F10, Esc = Esc; the keypad types
  the main-block characters (the MEGA65 keyboard has no keypad codes);
- sends the USB mouse as position counters + buttons (INPUT bytes 13..16, see
  `amiga_mouse.vhd`): mouse on port 1, first pad on port 2 (Ctrl+Alt+J swaps);
- treats Ctrl+Alt+F1 / F2 / F12 / Del as with the other cores (F2 = the core in flash slot 1).

## Phase 2: more than an A500 (K325T only)

The K325T's room is used for options of MiSTer's Minimig that AExp left out (study and ranking:
`PORTING.md`, "Phase 2").  **The defaults are the AExp V1 machine** (A500, OCS, 68000, 512 KB
chip + 512 KB slow, Kickstart 1.3): same memory path and clocks, the demo regression and the
SysInfo test (`tools/mk_sysinfo_adf.py`) give identical results.

| option | where | notes |
|---|---|---|
| **Kickstart 512 KB** (2.04, 3.1 A500/A600: `kick37175.A500`, `kick40063.A600`) | `/amiga/kick.rom`, size detected from the image (`$1111` = 256 KB, `$1114` = 512 KB) | 256 KB ROMs are mirrored at `$F80000`/`$FC0000` as before; 1 MB ROMs (`$E00000` extension: AROS, CD32) are not supported |
| **chipset OCS / ECS** | menu "RAM: ..." > OCS / ECS Chipset | ECS = Agnus 8372A (VPOSR id `$20`) + Denise 8373 (DENISEID `$FC`) |
| **memory**: 512K chip + 512K slow (default) / 512K chip only / 1M chip | menu "RAM: ..." | "1M Chip" uses the slow-RAM block RAM as the upper 512 KB of chip RAM (no slow RAM then) and forces ECS (an 8372A is needed for 1 MB) |

A change in the "RAM" submenu cold-boots the emulated Amiga only (like the V1 Slow RAM toggle).
Settings: see "Kickstart and floppies".

## Build

Once: the QNICE assembler and the monitor's dist_kit (the firmware is assembled every build):
```
(cd M2M/QNICE/assembler && cc -O2 -o qasm qasm.c && cc -O2 -o qasm2rom qasm2rom.c)
(cd M2M/QNICE/monitor && bash compile_and_distribute.sh)
```
Then
```
K325T/build.sh radxacm3   # Radxa CM3 module   -> K325T/bin/aexp_k325t_cm4_radxacm3.bit (~25 min)
K325T/build.sh            # Luckfox Core3566   -> K325T/bin/aexp_k325t_cm4.bit (prepared, not built yet)
```
Vivado 2025.2.1 (`VIVADODIR` overrides `~/Xilinx/2025.2.1/Vivado`), 8 jobs.  The two variants
differ only in the "CM bus" section of the pin file.  Do not load one module's bitstream with
the other module fitted.  Radxa build of 2026-11-11: timing met (WNS +0.114 ns, WHS +0.054 ns),
32,641 LUTs, 380.5 / 445 RAMB36, 5,996,117 bytes.

## Load and run

- Over JTAG (volatile): `scripts/program.sh K325T/bin/aexp_k325t_cm4_radxacm3.bit` (harness).
- From flash: slot 1, on the module
  `python3 /root/m65/m65flash.py write 1 /root/m65/bit/aexp_k325t_cm4_radxacm3.bit` (with
  `m65d_stop.sh` before and `systemctl start m65d` after), then `M65_SLOT1=amiga` in
  `/root/m65/m65d.env` and `m65d_restart.sh`.  Ctrl+Alt+F2 / `m65ctl core slot1` starts it,
  Ctrl+Alt+F1 returns to the MEGA65 (slot 0, unchanged).
- Back to the C64 core in slot 1: `m65flash.py write 1 /root/m65/bit/c64_k325t_cm4_radxacm3.bit`
  and `M65_SLOT1=c64` (or remove the line).  Only one of the two fits slot 1 at a time.

## Kickstart and floppies (SD card = the module's `/root/m65/card.img`, FAT32 at 1 MiB)

- **Kickstart 1.3** is mandatory and not included (copyright): put your own dump as
  **`/amiga/kick.rom`**: exactly **262,144 bytes**, raw, big endian as dumped (starts with
  `11 11 4E F9 00 FC 00 D2`), **no byte swapping**, no header.  Without it the core shows an
  error screen and the Amiga does not start.  On the module, with the daemons stopped:
  `sh /root/m65/m65d_stop.sh; MTOOLS_SKIP_CHECK=1 mcopy -o -i /root/m65/card.img@@1M kick.rom ::/amiga/kick.rom; systemctl start m65d`.
- **ADF** images (880 KB, standard 901,120 bytes) go to **`/amiga`**: the file browser starts
  there.  Help opens the menu; on "ADF:" Space opens the browser (Space on a mounted disk
  ejects it), Return mounts.  The disk is read/write: changes are written back to the file on
  the card a few seconds after the Amiga stops writing.
- Settings persist in `/amiga/aexp-V1.cfg` (84 bytes with the phase-2 menu; the V1 core's file has 74:
  a file of the wrong size is ignored and the defaults apply; a new file of 84 x `$FF` = defaults).
- Reset: Ctrl+Alt+Del (or `m65ctl reset`) resets the Amiga only and keeps the disk mounted,
  like a real A500; `m65ctl hold_reset 1`, 2 s, `hold_reset 0` resets the whole core (disk
  ejected, Kickstart reloaded).

## Verified on the board (Radxa CM3 carrier, 2026-11-11)

- Kickstart 1.3 (user's dump) boots to the insert-disk screen; the M2M menu and file browser
  work; ADF mount; Workbench-free boot-block disks run.
- Floppy write-back: `mk_writetest_adf.py` disk -> green screen, sector 1000 of the file on the
  card holds the pattern, nothing else changed (11 SD sector writes = one track).
- Keyboard: Kickstart's keyboard.device matrix shows held keys (A/S/D/F/G/H/J/K, both shifts,
  Ctrl, both Alts, both Amiga keys) from m65d's matrix and from a (uinput) USB keyboard.
- Mouse: quadrature counts in JOY0DAT follow injected and (uinput) USB mouse moves in both axes
  and directions; left button on CIA-A PRA bit 6, right / middle on POTGOR.  Joystick port 2:
  all four directions in JOY1DAT and fire on PRA bit 7.
- Demos (user's Kickstart 1.3, 512 KB chip + 512 KB slow, from flash slot 1 and over JTAG),
  recorded with `tools/aexp_demo_test.py`: all run through without a hang or visible corruption
  in the sampled frames (every 5-10 s) -- Spaceballs *State of the Art*, Phenomena *Enigma*,
  Sanity *Arte*, TBL *Eon* (party version, disk 2 inserted at its prompt), Batman Group
  *Batman Rises* (disk 2 at "INSERT DISK 2").  No reference recording was compared frame by
  frame.

| demo | file(s) in `/amiga` | source (all freely distributed by the groups) |
|---|---|---|
| Spaceballs, State of the Art (The Party 1992, 1st) | `sota.adf` | archive.scene.org `mirrors/amigascne/Groups/S/Spaceballs/Spaceballs-StateOfTheArt.dms` (the `parties/1992/theparty92/amiga/demo/spb-sota.dms` image hangs after the first picture, also with Slow RAM off) |
| Phenomena, Enigma (1991) | `enigma.adf` | archive.scene.org `mirrors/amigascne/Groups/P/Phenomena/PHENOMENA-Enigma.DMS` |
| Sanity, Arte (The Party 1993) | `arte.adf` | archive.scene.org `mirrors/amigascne/Groups/S/Sanity/Sanity-Arte.dms` |
| TBL, Eon (Revision 2019, party version; needs 512K+512K) | `eon1.adf`, `eon2.adf` | files.scene.org `parties/2019/revision19/amiga-demo/tbl_eon_party_version.zip` |
| Batman Group, Batman Rises (Posadas 2022) | `batman1.adf`, `batman2.adf` | files.scene.org `parties/2022/posadasautumn22/demo/batman_rises.zip` |

DMS archives were unpacked to ADF with `xdms`.  Test disks made here: `wrtest.adf`,
`intest.adf`, `kbmtest.adf`, `kbm12.adf` (`tools/`).
- Core switching MEGA65 <-> Amiga (slot 1) with Ctrl+Alt+F1/F2/F12 and `m65ctl core`.
- FPGA temperature with the Amiga core: 51 C (JTAG sysmon).

## Open / not verified

- Cycle exactness is by construction (upstream's memory, clocks and enables are unchanged, see
  `PORTING.md`); no instruction-level comparison against upstream hardware was possible here
  (no MEGA65 on the bench).
- A JTAG-loaded Amiga core asked to boot flash slot 1 (bridge IPROG to 0x800000, then holding
  the C64) came up as the MEGA65 (configuration fallback); from flash, MEGA65 -> Amiga ->
  MEGA65 works every time.  Not investigated.
- No RTC (the MEGA65's I2C RTC is not on this board): the Amiga clock reads as not set.
- HDMI audio is produced by the core but was not measured (the capture dongle's audio device is
  not accessible to the PC user).
- Analog video / audio DAC outputs of the MEGA65 do not exist on this board.
- The Luckfox variant is prepared (pin file section) but not built or tested.
