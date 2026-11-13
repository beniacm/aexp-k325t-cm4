## AExp (Amiga 500 for MEGA65) on the QMTech XC7K325T + CM4 carrier: pins and timing.
## Pins are the same as the C64MEGA65 K325T port and the MEGA65 core port (mega65-core).
## The DDR3 pins come from the MIG IP's own constraints.
## Timing: the parts of M2M/common.xdc and CORE/CORE.xdc that do not concern the
## HyperRAM or the R6 board (CORE.xdc is used unchanged).

set_property CFGBVS                         VCCO    [current_design]
set_property CONFIG_VOLTAGE                 3.3     [current_design]
## Unused pins pulled up: several CM4 bus pads are driven by the Rockchip (BT1120 mux).
set_property BITSTREAM.CONFIG.UNUSEDPIN     PULLUP  [current_design]
set_property BITSTREAM.CONFIG.SPI_BUSWIDTH  4       [current_design]
set_property CONFIG_MODE                    SPIx4   [current_design]
set_property BITSTREAM.CONFIG.CONFIGRATE    50      [current_design]
set_property BITSTREAM.GENERAL.COMPRESS     TRUE    [current_design]

## ---------------------------------------------------------------- pins
set_property -dict {PACKAGE_PIN F22 IOSTANDARD LVCMOS33} [get_ports clk_in]
set_property -dict {PACKAGE_PIN U26 IOSTANDARD LVCMOS33} [get_ports reset_button]
set_property -dict {PACKAGE_PIN R26 IOSTANDARD LVCMOS33} [get_ports {led[0]}]
set_property -dict {PACKAGE_PIN P26 IOSTANDARD LVCMOS33} [get_ports {led[1]}]
set_property -dict {PACKAGE_PIN N26 IOSTANDARD LVCMOS33} [get_ports {led[2]}]

## J11 Sipeed DVI Pmod (P balls: red C16, green B17, blue A18, clock B20; the green and
## clock P balls sit on the Pmod's N pins -> inverted in M2M via G_TMDS_INVERT)
set_property -dict {PACKAGE_PIN C16 IOSTANDARD TMDS_33} [get_ports {tmds_data_p[2]}]
set_property -dict {PACKAGE_PIN B16 IOSTANDARD TMDS_33} [get_ports {tmds_data_n[2]}]
set_property -dict {PACKAGE_PIN B17 IOSTANDARD TMDS_33} [get_ports {tmds_data_p[1]}]
set_property -dict {PACKAGE_PIN A17 IOSTANDARD TMDS_33} [get_ports {tmds_data_n[1]}]
set_property -dict {PACKAGE_PIN A18 IOSTANDARD TMDS_33} [get_ports {tmds_data_p[0]}]
set_property -dict {PACKAGE_PIN A19 IOSTANDARD TMDS_33} [get_ports {tmds_data_n[0]}]
set_property -dict {PACKAGE_PIN B20 IOSTANDARD TMDS_33} [get_ports tmds_clk_p]
set_property -dict {PACKAGE_PIN A20 IOSTANDARD TMDS_33} [get_ports tmds_clk_n]

## >>> CM bus: this section is replaced for other modules (qmtech_k325t_cm4_radxacm3_bus.xdc, build.sh)
## Rockchip spi3-m1 (CM4 bus). rk_miso is the only FPGA output on this bus.
set_property -dict {PACKAGE_PIN A8  IOSTANDARD LVCMOS33 PULLDOWN TRUE} [get_ports rk_sck]
set_property -dict {PACKAGE_PIN A9  IOSTANDARD LVCMOS33 PULLDOWN TRUE} [get_ports rk_mosi]
set_property -dict {PACKAGE_PIN B15 IOSTANDARD LVCMOS33 PULLUP TRUE}   [get_ports rk_cs_n]
set_property -dict {PACKAGE_PIN B9  IOSTANDARD LVCMOS33 DRIVE 8}       [get_ports rk_miso]
## <<< CM bus

## a1200-ide: the hard disk's SPI + attention line on the CM4 connector (the same FPGA pins for every
## module; only the Radxa CM3 variant drives them: top generic G_HDD, set in build.tcl).  Radxa CM3:
## SPI0 M0 CLK BCM3 (GPIO0_B5), MOSI BCM2 (GPIO0_B6), MISO BCM6 (GPIO0_C5), CS0 BCM13 (GPIO0_C6);
## attention BCM7 (GPIO4_C5).  MISO and att are high-impedance unless enabled (and MISO unless CS).
set_property -dict {PACKAGE_PIN D18 IOSTANDARD LVCMOS33 PULLDOWN TRUE} [get_ports hd_sck]
set_property -dict {PACKAGE_PIN C18 IOSTANDARD LVCMOS33 PULLDOWN TRUE} [get_ports hd_mosi]
set_property -dict {PACKAGE_PIN E10 IOSTANDARD LVCMOS33 PULLUP TRUE}   [get_ports hd_cs_n]
set_property -dict {PACKAGE_PIN D10 IOSTANDARD LVCMOS33 DRIVE 8}       [get_ports hd_miso]
set_property -dict {PACKAGE_PIN B12 IOSTANDARD LVCMOS33 DRIVE 4}       [get_ports hd_att]
set_false_path -from [get_ports {hd_sck hd_mosi hd_cs_n}]
set_false_path -to   [get_ports {hd_miso hd_att}]

## ---------------------------------------------------------------- clocks
create_clock -period 20.000 -name clk_in [get_ports clk_in]
## "clk" = the 100 MHz clk_i of framework and core (the name M2M's constraints use)
create_generated_clock -name clk    [get_pins i_mmcm/CLKOUT1]
create_generated_clock -name clk162 [get_pins i_mmcm/CLKOUT0]
create_generated_clock -name clk200 [get_pins i_mmcm/CLKOUT2]

create_generated_clock -name qnice_clk       [get_pins i_framework/i_clk_m2m/i_clk_qnice/CLKOUT0]
create_generated_clock -name hr_clk_pll      [get_pins i_framework/i_clk_m2m/i_clk_qnice/CLKOUT1]
create_generated_clock -name audio_clk       [get_pins i_framework/i_clk_m2m/i_clk_audio/CLKOUT0]
create_generated_clock -name tmds_clk        [get_pins i_framework/i_video_out_clock/MMCM/CLKOUT0]
create_generated_clock -name hdmi_clk        [get_pins i_framework/i_video_out_clock/MMCM/CLKOUT1]
create_generated_clock -name div_clk -source [get_pins i_mmcm/CLKOUT1] -divide_by 2 [get_pins i_framework/i_video_out_clock/clki_div_reg/Q]
set_case_analysis 1 [get_pins i_framework/i_video_out_clock/clk_mux_reg/Q]

## sdcard_clk (QNICE's SD controller), QNICE's EAE multicycle and the sd_emu paths exist only with
## the menu processor on the FPGA: qnice_local.xdc, added by build.tcl unless LXSHELL=1

## ---------------------------------------------------------------- M2M (from common.xdc)
set_false_path -from [get_pins i_framework/i_reset_manager/reset_m2m_n_o_reg/C]
set_false_path -from [get_pins i_framework/i_reset_manager/reset_core_n_o_reg/C]
set_max_delay 8 -datapath_only -from [get_generated_clocks] -to [get_pins -hierarchical "*cdc_stable_gen.dst_*_d_reg[*]/D"]
set_max_delay 8 -datapath_only -from [get_clocks clk] -to [get_pins -hierarchical "*cdc_stable_gen.dst_*_d_reg[*]/D"]

set_false_path -quiet -from [get_pins -hierarchical -regexp ".*/i_ascal/i_.*_reg.*/C"]   -to [get_pins -hierarchical -regexp ".*/i_ascal/avl_.*_reg.*/D"]
set_false_path -quiet -from [get_pins -hierarchical -regexp ".*/i_ascal/i_.*_reg.*/C"]   -to [get_pins -hierarchical -regexp ".*/i_ascal/o_.*_reg.*/D"]
set_false_path -quiet -from [get_pins -hierarchical -regexp ".*/i_ascal/avl_.*_reg.*/C"] -to [get_pins -hierarchical -regexp ".*/i_ascal/o_.*_reg.*/D"]
set_false_path -quiet -from [get_pins -hierarchical -regexp ".*/i_ascal/o_.*_reg.*/C"]   -to [get_pins -hierarchical -regexp ".*/i_ascal/i_.*_reg.*/D"]
set_false_path -quiet -from [get_pins -hierarchical -regexp ".*/i_ascal/o_.*_reg.*/C"]   -to [get_pins -hierarchical -regexp ".*/i_ascal/avl_.*_reg.*/D"]

set_false_path -from [get_clocks hdmi_clk]  -to [get_clocks audio_clk]
set_false_path -from [get_clocks audio_clk] -to [get_clocks hdmi_clk]
set_false_path -from [get_clocks qnice_clk] -to [get_clocks hdmi_clk]
set_false_path -through [get_pins i_framework/i_av_pipeline/i_digital_pipeline/i_ascal/reset_na]

## ---------------------------------------------------------------- K325T additions
## rk_bridge's fast side (clk162) talks to its cpuclk side (clk) only through
## synchronisers / dual-clock RAMs.
set_clock_groups -asynchronous -group [get_clocks clk162] -group [get_clocks -include_generated_clocks clk]

## keyboard link (kio8 from the core clock domain, kio10 back; ~1.6 us per half bit)
set_false_path -to   [get_cells -hierarchical -filter {NAME =~ i_kbd_emu/kio8_s_reg*}]
set_false_path -from [get_cells i_kbd_emu/kio10_reg]
## avm_mig's debug state (memory clock) into the stall monitor's probe sampler (debug only)
set_false_path -to [get_cells mig_legacy_s_reg[0]]
## line latency meter: configuration byte from the bridge (clk162) and its readout to the bridge
set_false_path -to   [get_cells -hierarchical -filter {NAME =~ i_lat_meter/cfg_s1_reg*}]
set_false_path -from [get_cells -hierarchical -filter {NAME =~ i_lat_meter/aux_reg* || NAME =~ i_lat_meter/r6_reg*}] \
               -to   [get_clocks clk162]
set_false_path -from [get_cells -hierarchical -filter {NAME =~ i_avm_mig/*}] -to [get_cells -hierarchical -filter {NAME =~ CORE/clk_gen/i_stall_ctrl/pr_d_reg*}]
## joysticks: quasi-static levels into M2M's debouncers
set_false_path -from [get_cells -hierarchical -filter {NAME =~ i_rk_bridge/joy*_reg*}]
## framework's external-memory reset synchroniser
set_false_path -to   [get_cells -hierarchical -filter {NAME =~ i_framework/*ext_rst_sync_reg*}]

set_false_path -from [get_ports {reset_button rk_sck rk_cs_n rk_mosi}]
set_false_path -to   [get_ports {rk_miso led[*]}]
## paddles / mouse: slowly changing values, stable-filtered in rk_bridge's cpuclk domain
set_false_path -from [get_cells -hierarchical -filter {NAME =~ i_rk_bridge/pots_c_reg*}]
## Amiga mouse (amiga_mouse.vhd, clk): quadrature / fire lines into M2M's debouncer (2-FF in the
## core clock, one transition per microsecond), button levels into a 2-FF synchroniser (pots_s1)
## (cells, not the clock: main_clk is created later, in CORE/CORE.xdc)
set_false_path -from [get_cells -hierarchical -filter {NAME =~ i_mouse/*}] \
               -to   [get_cells -hierarchical -filter {NAME =~ i_framework/i_joy_debouncer/j*_s_reg*}]
set_false_path -to   [get_cells -hierarchical -filter {NAME =~ pots_s1_reg*}]
## Zorro II fast RAM (amiga_fastram.vhd): request registers (core clock, held stable while the
## toggle handshake is open) -> memory clock; acknowledge toggle and the cache data array
## (written in the memory clock, read after the acknowledge) -> core clock
set_max_delay 10 -datapath_only -from [get_cells -hierarchical -filter {NAME =~ CORE/i_amiga_fastram/m_req_*}] \
    -to [get_cells -hierarchical -filter {NAME =~ CORE/i_amiga_fastram/hr_* || NAME =~ CORE/i_amiga_fastram/FSM_*hr_state* || NAME =~ CORE/i_amiga_fastram/avm_* || NAME =~ CORE/i_amiga_fastram/dram_*}]
set_max_delay 10 -datapath_only -from [get_cells -hierarchical -filter {NAME =~ CORE/i_amiga_fastram/hr_ack_tgl*}] \
    -to [get_cells -hierarchical -filter {NAME =~ CORE/i_amiga_fastram/m_ack_d_reg*}]
set_max_delay 10 -datapath_only -from [get_cells -hierarchical -filter {NAME =~ CORE/i_amiga_fastram/dram_*}] \
    -to [get_cells -hierarchical -filter {NAME =~ CORE/i_amiga_fastram/m_rdata_reg*}]

## ---------------------------------------------------------------- configuration flash / multiboot
## QSPI flash (S25FL128L), written by the Rockchip through rk_bridge; CCLK via STARTUPE2.
set_property -dict {PACKAGE_PIN B24 IOSTANDARD LVCMOS33 PULLUP TRUE} [get_ports {qspi_db[0]}]
set_property -dict {PACKAGE_PIN A25 IOSTANDARD LVCMOS33 PULLUP TRUE} [get_ports {qspi_db[1]}]
set_property -dict {PACKAGE_PIN B22 IOSTANDARD LVCMOS33 PULLUP TRUE} [get_ports {qspi_db[2]}]
set_property -dict {PACKAGE_PIN A22 IOSTANDARD LVCMOS33 PULLUP TRUE} [get_ports {qspi_db[3]}]
set_property -dict {PACKAGE_PIN C23 IOSTANDARD LVCMOS33}             [get_ports qspi_csn]
set_false_path -to   [get_ports {qspi_csn qspi_db[*]}]
set_false_path -from [get_ports {qspi_db[*]}]
## a slot that fails to configure (CRC / ID error) falls back to the image at address 0
set_property BITSTREAM.CONFIG.CONFIGFALLBACK ENABLE [current_design]
## rk_iprog: request toggle and address come from the bridge clock (synchronised / stable)
set_false_path -to [get_cells -hierarchical -filter {NAME =~ i_iprog/tog_s_reg[0]*}]
set_false_path -to [get_cells -hierarchical -filter {NAME =~ i_iprog/addr_s_reg*}]
## the core's result mailbox (main_clk, changes only when the Amiga writes $C0-$FF) read by lat_meter
set_false_path -from [get_cells -hierarchical -filter {NAME =~ CORE/main_mbox_reg*}] \
               -to   [get_cells -hierarchical -filter {NAME =~ i_lat_meter/aux_reg*}]
## stage 3: the core's debug words read by lat_meter (fast RAM state, memory mode, stall register
## read-back): quasi-static values, read twice by the tools -- not timed from any core register
set_false_path -from [get_cells -hierarchical -filter {NAME =~ CORE/*}] \
               -to   [get_cells -hierarchical -filter {NAME =~ i_lat_meter/aux_reg*}]
## stage 3: the fast RAM debug word (amiga_fastram, the hr_core select; read while the state is frozen)
set_false_path -from [get_cells -hierarchical -filter {NAME =~ CORE/i_amiga_fastram/*}] \
               -to   [get_cells -hierarchical -filter {NAME =~ i_lat_meter/aux_reg*}]
set_false_path -from [get_cells -hierarchical -filter {NAME =~ CORE/hr_blocked_reg* || NAME =~ CORE/hr_nsel_reg* || NAME =~ CORE/hr_non_fall_reg* || NAME =~ CORE/hr_quiet_cnt_reg* || NAME =~ CORE/hr_fast_sel_reg* || NAME =~ CORE/i_cdc_fast_on/*}] \
               -to   [get_cells -hierarchical -filter {NAME =~ i_lat_meter/aux_reg*}]
## the cache's prefetch counters: prefetch.xdc, added by build.tcl with PREFETCH=1
