# AExp on the QMTech XC7K325T + CM4 carrier: feasibility and porting notes

Target: the QMTech XC7K325T "CM4" carrier (Kintex-7 `xc7k325tffg676-1`) with a Rockchip
module in its CM4 socket (Radxa CM3 on the bench board, Luckfox Core3566 on the first
board). SD card, keyboard, joysticks and mouse are not wired to the FPGA: the module serves
them over one SPI link (`rk_bridge`, see the harness repository `mega65-k325t-cm4`). The
C64MEGA65 core was ported to this board before (`c64mega65`, branch `qmtech-k325t-cm4`,
directory `K325T/`); AExp is built on the same MiSTer2MEGA65 (M2M) framework, so this port
follows that recipe file for file.

Upstream: sy2002/AExp V1 (2026-07-26), M2M V2.0.1 with six AExp framework extensions
(interlace, core-io hook, screen-center, osm-hotkey, osm-scale, raw-joyports).

## What AExp needs, and where it comes from on the K325T

| need (upstream, MEGA65 R3-R6) | K325T | source |
|---|---|---|
| 100 MHz board clock `clk_i` | 50 MHz crystal (F22) -> MMCM x24/12 = 100.000 MHz (exact ratio) | C64 port's top (`top_qmtech_k325t_cm4.tpl.vhd`) |
| Amiga core clock 28.375 MHz (`CORE/vhdl/clk.vhd`, two MMCMs + BUFGMUX for the HDMI flicker-free dither) | unchanged; VCO 1135 / 1137.5 MHz is inside the Kintex-7 -1 range (600-1200 MHz) | upstream, untouched |
| Chip RAM 512 KB, Slow RAM 512 KB, Kickstart 256 KB: **block RAM** inside `CORE/vhdl/mega65.vhd` | the same block RAM (the XC7K325T has 445 RAMB36 against the 200T's 365) | upstream, untouched |
| HyperRAM 8 MB (Avalon-MM): ascal HDMI frame buffer, ADF floppy image staging (word 0x200000) | DDR3 MT41K128M16 (256 MB) via MIG + `avm_mig.vhd`, framework generic `G_EXT_HR` | C64 port |
| HDMI (TMDS from the framework) | J11 Sipeed DVI Pmod; green and clock pairs have P/N swapped: `G_TMDS_INVERT => "1010"` | C64 port |
| analog VGA / 15 kHz RGB, audio DAC | not present (audio on HDMI only) | -- |
| SD card (FAT32, `/amiga/kick.rom`, ADFs, settings) | `sd_emu` (SPI-mode SDHC) on the framework's back-slot bus, sectors from the module's `/root/m65/card.img` (m65io) | mega65-core `sd_emu.vhdl`, `rk_bridge.vhdl` |
| MEGA65 keyboard (serial matrix link) | `m65kbd_emu.vhd` answers the link from the bridge's key matrix (USB keyboard on the module, m65d) | C64 port |
| joysticks (DB9, raw lines since AExp's `raw-joyports`) | bridge joyA / joyB (USB pads, m65d) | C64 port |
| mouse: a real Amiga quadrature mouse on DB9 port 1 (userio.v counts the transitions; right/middle button on the pot lines, read through the paddle sampler) | **new**: `amiga_mouse.vhd` turns two position counters + buttons from the bridge (INPUT bytes 13..16, the C64 core's POT bytes) into quadrature transitions on port 1's direction lines, left button on fire, right / middle on POTX / POTY | new |
| RTC (MEGA65 I2C RTC -> Amiga $DC0000 clock, `doc/RTC.md`) | no I2C buses: `G_NO_I2C` (transfers NACK, the clock is never set); the Amiga clock reads as not set | C64 port (generic); an RTC from the module is possible later |
| QNICE UART | bridge monitor channel (TCP 4510 on the module) | C64 port |
| configuration flash, core switching | bridge flash pass-through (0x50) + `rk_iprog` (0x60), core id in STATUS byte 52: **3 = Amiga** | C64 port, new id |

M2M version: AExp's M2M (V2.0.1 + AExp extensions) and the C64 fork's M2M (C64MEGA65 V5.2)
differ only by the AExp extensions; the R6 top (`top_mega65-r6.vhd`) differs by four extra
signals (interlace field, OSM hotkey). The C64 port's three framework patches
(`G_EXT_HR`, `G_TMDS_INVERT`, `G_NO_I2C` in `framework.vhd`, `av_pipeline.vhd`,
`digital_pipeline.vhd`) applied with offsets only, and `gen_top.py` (which builds the board
top from the R6 top) works unchanged.

## Is the port cycle-equivalent to upstream?

Yes for everything the emulated Amiga can observe, by construction:

- **Amiga memory**: chip RAM, slow RAM and Kickstart stay in block RAM, served by
  upstream's unchanged `mega65.vhd` (1-cycle latency on minimig's SRAM-style port, read mux
  registered). No DDR3 is on the Amiga's memory path, so every CPU and DMA access answers in
  the same 28 MHz cycle as on a MEGA65.
- **Clocks and enables**: `clk.vhd`, `main.vhd` (fx68k phase enables, amiga_clk, video CE)
  and the whole Minimig tree are not modified. The core clock is generated from a 100 MHz
  clock exactly as upstream; only the 100 MHz itself comes from a 50 MHz crystal through an
  MMCM (an exact x2 ratio; absolute accuracy = crystal tolerance, ppm level, as on a MEGA65).
  The HDMI flicker-free option (upstream default ON) dithers the core clock between 28.375
  and 28.4375 MHz to lock to 50.000 Hz HDMI exactly as upstream (its control loop runs in the
  memory clock domain, here MIG ui_clk = 100 MHz like the HyperRAM clock); switch it off in
  the menu for a constant 28.375 MHz.
- **What DDR3 replaces**: only the two HyperRAM clients. (a) The ascal scaler's frame buffer:
  decoupled from the core by ascal's own FIFOs and frame buffering (same as upstream, where
  the HyperRAM latency also differs from frame to frame). (b) The ADF image store, read by
  `adf_track_engine` through avm_cache + avm_fifo. Paula's disk DMA runs on its own timing;
  the engine streams MFM to it with flow control (status bit 8), so the memory latency only
  decides whether the engine's data are there in time. DDR3 through `avm_mig` has a longer
  first-word latency than HyperRAM (tens of 100 MHz cycles, i.e. well under 1 us, refresh
  included) while Paula takes one 16-bit MFM word every 32 us (DD: 2 us per bit cell); the
  margin is more than an order of magnitude even before the engine's own buffering. Trackloader demos are the test (see below).
- **Inputs**: keyboard and joystick reach the core through the same M2M paths
  (`m2m_keyb`, debouncer = 2-FF synchroniser); USB latency on the module adds milliseconds
  (like any real key press, not cycle-relevant). The mouse produces real quadrature
  transitions (1 us apart) that userio.v counts exactly as from a DB9 mouse.

Not equivalent: no analog VGA / 15 kHz output, no audio DAC (HDMI audio only), no RTC.

## Resource estimate (and the result)

Upstream R6: 363.5 of 365 RAMB36 (320 for the Amiga memory). The K325T adds the bridge
(~5 RAMB36: SD read cache, sector buffers, UART FIFOs) and the MIG (no BRAM): about
370 / 445 RAMB36. LUTs: the C64 port uses 30 k of 204 k; AExp (fx68k + Minimig OCS +
framework) is in the same range. Clocking: 7 of 10 MMCMs (board, MIG, 2x clk_m2m,
video_out, 2x AExp clk), 2 PLLs (MIG), about 16 of 32 BUFG.

Built (Radxa CM3 variant, Vivado 2025.2.1): 32,640 LUTs (16 %), 25,845 registers, **380.5 of
445 RAMB36** (85.5 %), 64 DSP48; bitstream ~6.4 MB (compressed), fits an 8 MB flash slot.

## Risks

- Timing: upstream's margin is thin on the Artix-7 200T -2 (+0.39 ns, mostly the
  HyperRAM PHY, which is gone here). The Kintex-7 -1 is faster, but the 320 Amiga BRAM tiles
  spread over a larger die; the QNICE kick-ROM port (falling edge, 10 ns) is the known
  critical path.
- MIG UI rules: `avm_mig` carries the two fixes of the C64 port (write data before command;
  no new command with a read's last beat), proven with the C64 core's REU and CRT loader.
- The Kickstart ROM is the user's: never in git; `/amiga/kick.rom` on the card only.

## Upstream files changed (minimal, generic-gated, defaults = upstream behaviour)

- `M2M/vhdl/framework.vhd`, `M2M/vhdl/av_pipeline/av_pipeline.vhd`,
  `M2M/vhdl/av_pipeline/digital_pipeline.vhd`: the C64 port's `G_EXT_HR`, `G_TMDS_INVERT`,
  `G_NO_I2C` (identical patch).
- `.gitignore`: the generated Vivado project `CORE/CORE-K325T.*`.

Everything else is in `K325T/`.
