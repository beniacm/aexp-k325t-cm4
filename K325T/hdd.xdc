## hdd.xdc -- the hard disk link (CORE/i_hdd_spi, built only with G_HDD = the Radxa CM3 variant).
## build.tcl adds this file after core_k325t.xdc (main_clk) for build.sh radxacm3; check_build_log.py
## fails the build if any of these commands matches nothing.
## a1200-ide: hdd_spi.vhd crossings (fclk = the top's clk162, mclk = main_clk).  Toggle handshakes: the
## data (engine command, result) is stable for many clocks when the other side samples it; the
## 16-sector buffer is a dual-clock block RAM (no path between its ports).
set_max_delay 10 -datapath_only -from [get_cells -hierarchical -filter {NAME =~ CORE/i_hdd_spi/e_*_reg* || NAME =~ CORE/i_hdd_spi/req_tgl_reg}] \
    -to [get_clocks main_clk]
set_max_delay 10 -datapath_only -from [get_cells -hierarchical -filter {NAME =~ CORE/i_hdd_spi/result_reg* || NAME =~ CORE/i_hdd_spi/ack_tgl_reg}] \
    -to [get_clocks clk162]
## the ide request bits and the menu's IDE bit (both main_clk registers) into their two-flop synchronisers
set_max_delay 10 -datapath_only -from [get_clocks main_clk] \
    -to [get_cells -hierarchical -filter {NAME =~ CORE/i_hdd_spi/idereq_s1_reg* || NAME =~ CORE/i_hdd_spi/en_s_reg[0]}]
