## qnice_local.xdc -- constraints of the menu processor on the FPGA (QNICE_SOC, its SD controller and
## the emulated SD card sd_emu).  build.tcl adds this file unless LXSHELL=1: with the shell on the
## Linux module (G_LXSHELL) these cells are not built.  The names carry the generate labels
## (qnice_wrapper gen_soc_local, top g_sd_emu); check_build_log.py fails the build if any of these
## commands matches nothing.

## QNICE's SD controller clock (SimpleSDHC, 25 MHz)
create_generated_clock -name sdcard_clk -source [get_pins i_framework/i_clk_m2m/i_clk_qnice/CLKOUT0] -divide_by 2 \
   [get_pins i_framework/i_qnice_wrapper/gen_soc_local.QNICE_SOC/sd_card/Slow_Clock_25MHz_reg/Q]

## M2M common.xdc: QNICE's EAE combinatorial division networks take longer than the regular clock
## period (see EAE.vhd, UG903 chapter 5 / UG911 p. 25)
set_multicycle_path -from [get_cells -include_replicated {i_framework/i_qnice_wrapper/gen_soc_local.QNICE_SOC/eae_inst/op*_reg[*]}] \
   -to [get_cells -include_replicated {i_framework/i_qnice_wrapper/gen_soc_local.QNICE_SOC/eae_inst/res_reg[*]}] -setup 3
set_multicycle_path -from [get_cells -include_replicated {i_framework/i_qnice_wrapper/gen_soc_local.QNICE_SOC/eae_inst/op*_reg[*]}] \
   -to [get_cells -include_replicated {i_framework/i_qnice_wrapper/gen_soc_local.QNICE_SOC/eae_inst/res_reg[*]}] -hold 2

## sd_emu (clk) <-> SimpleSDHC (25 MHz sdcard_clk): 2-FF synchronised inputs; MISO
## changes >= 50 ns before SimpleSDHC samples it.
set_false_path -to   [get_cells -hierarchical -filter {NAME =~ g_sd_emu.i_sd_emu/*in_s1_reg*}]
set_false_path -from [get_cells g_sd_emu.i_sd_emu/miso_r_reg]
