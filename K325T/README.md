# AExp on the QMTech XC7K325T CM4 carrier (`K325T/`)

AExp (Amiga 500 OCS/PAL for the MEGA65, by sy2002, based on MiSTer's Minimig) ported to the
**QMTech XC7K325T "CM4" carrier** with a Rockchip module (Radxa CM3 or Luckfox Core3566) in its
CM4 socket.  The module serves the SD card, keyboard, joysticks and mouse over one SPI link
(`rk_bridge`); the board's DDR3 replaces the MEGA65's HyperRAM.  Same recipe as the C64MEGA65
port (`c64mega65`, `K325T/`); see `PORTING.md` for the feasibility notes and why the port is
cycle-equivalent to upstream.  Not affiliated with the AExp author.

Board harness (Rockchip daemons, scripts, write-up): `mega65-k325t-cm4` (beniacm), sections
"C64 core", "Standalone" and "Amiga core".

## What the port adds

| file | role |
|---|---|
| `top_qmtech_k325t_cm4.tpl.vhd`, `gen_top.py` | board top generated from M2M's R6 top: clocks, MIG, Rockchip bridge, SD emulator, flash, warm boot |
| `avm_mig.vhd`, `mig_ddr3.prj` | M2M Avalon memory bus (HyperRAM interface) -> MIG DDR3 native UI |
| `m65kbd_emu.vhd` | the MEGA65 keyboard's serial link, answered from the bridge's key matrix |
| `amiga_mouse.vhd` (+ `sim/tb_amiga_mouse.vhd`) | Amiga quadrature mouse from the bridge's position counters (new; the C64 port has a 1351 path) |
| `qmtech_k325t_cm4.xdc`, `qmtech_k325t_cm4_radxacm3_bus.xdc` | pins + timing; CM-bus section per module |
| `build.sh`, `build.tcl`, `gen_sources.py` | Vivado batch build (sources taken from `CORE/CORE-R6.xpr`) |
| `tools/mk_writetest_adf.py` | builds a boot-block floppy that writes a sector (write-back test without Workbench) |
| `tools/aexp_demo_test.py` | mounts demo ADFs one by one, records a clip + frames from the HDMI capture dongle |
| M2M `framework.vhd`, `av_pipeline.vhd`, `digital_pipeline.vhd` | the C64 port's generics `G_EXT_HR`, `G_TMDS_INVERT`, `G_NO_I2C` (defaults = upstream) |

Rockchip bridge core id **3** (STATUS byte 52): m65d switches to the Amiga key map and mouse.

## Build

Once: the QNICE assembler and the monitor's dist_kit (the firmware is assembled every build):
```
(cd M2M/QNICE/assembler && cc -O2 -o qasm qasm.c && cc -O2 -o qasm2rom qasm2rom.c)
(cd M2M/QNICE/monitor && bash compile_and_distribute.sh)
```
Then
```
K325T/build.sh radxacm3   # Radxa CM3 module   -> K325T/bin/aexp_k325t_cm4_radxacm3.bit
K325T/build.sh            # Luckfox Core3566   -> K325T/bin/aexp_k325t_cm4.bit
```
(Vivado 2025.2.1, `VIVADODIR` overrides `~/Xilinx/2025.2.1/Vivado`; 8 jobs.)  The two variants
differ only in the "CM bus" section of the pin file.  Do not load one module's bitstream with
the other module fitted.

## Load and run

Over JTAG (volatile): `scripts/program.sh K325T/bin/aexp_k325t_cm4_radxacm3.bit` in the harness.
From flash: slot 1 (`m65flash.py write 1 aexp_k325t_cm4_radxacm3.bit` on the module), then set
`M65_SLOT1=amiga` in `/root/m65/m65d.env`; Ctrl+Alt+F2 / `m65ctl core slot1` starts it,
Ctrl+Alt+F1 returns to the MEGA65.

## Kickstart and floppies (SD card = the module's `/root/m65/card.img`)

- **Kickstart 1.3** is mandatory and not included (copyright): put your own dump as
  **`/amiga/kick.rom`** on the card's FAT32 partition: exactly **262,144 bytes**, raw, big
  endian as read from the chips/`.rom` dumps (first bytes `11 11 4E F9 00 FC 00 D2`), **no byte
  swapping**, no header.  Without it the core shows an error screen and does not start.
  With the module's daemons stopped (`m65d_stop.sh`):
  `MTOOLS_SKIP_CHECK=1 mcopy -o -i /root/m65/card.img@@1M kick.rom ::/amiga/kick.rom`.
- **ADF** floppy images go to **`/amiga`** (the file browser starts there).  Help opens the
  menu; "ADF:" + Space opens the browser, Return mounts (df0:, read/write: changes are written
  back to the file on the card in the background), Space on a mounted disk ejects it.
- Settings persist in `/amiga/aexp-V1.cfg` (74 bytes; a new file is all `$FF` = defaults).
- Keyboard: m65d maps a PC keyboard for AExp's **Amiga** keyboard mode (menu: Keyboard >
  Amiga): the PC caps are right on the Kickstart's US keymap; Win = Left Amiga, Menu/right
  Win = Right Amiga, Alt = Left Alt, AltGr = Right Alt, PrtSc = Help (also opens the menu),
  F1-F10 = F1-F10.  Mouse: USB mouse on port 1, pads: first pad on port 2.
