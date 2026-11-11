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
- Settings persist in `/amiga/aexp-V1.cfg` (74 bytes; a new file of 74 x `$FF` = defaults).
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
- Demos (user's Kickstart, 512 KB chip + 512 KB slow): Phenomena *Enigma*, Sanity *Arte*,
  TBL *Eon* (disk 1, then disk 2), Batman Group *Batman Rises* (disk 1 to "INSERT DISK 2", then
  disk 2) run; Spaceballs *State of the Art* stops after its first picture (see below).
- Core switching MEGA65 <-> Amiga (slot 1) with Ctrl+Alt+F1/F2/F12 and `m65ctl core`.
- FPGA temperature with the Amiga core: 51 C (JTAG sysmon).

## Open / not verified

- *State of the Art* (Spaceballs, The Party 1992 version from scene.org): shows its first white
  shape and then waits (~80 s), turns dark and stays.  Same with Slow RAM off.  Not resolved;
  upstream lists the demo as working, a comparison on a MEGA65 is not possible here.
- No RTC (the MEGA65's I2C RTC is not on this board): the Amiga clock reads as not set.
- HDMI audio is produced by the core but was not measured (the capture dongle's audio device is
  not accessible to the PC user).
- Analog video / audio DAC outputs of the MEGA65 do not exist on this board.
- The Luckfox variant is prepared (pin file section) but not built or tested.
