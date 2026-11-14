## a1200-fc8 (FCCEN=1 debug builds, added by build.tcl): the fast CPU's census counters (fc_cen.vhd, CPU clock)
## the bridge's VIDEO byte into fc_cen's 2-flop synchroniser (as lat_meter's cfg_s1)
set_false_path -to [get_cells -hierarchical -filter {NAME =~ CORE/i_main/*i_fc_cen/cfg_s1_reg*}]
## the census word into lat_meter's aux register: quasi-static (the snapshot changes only when $D8 is selected, the tools
## read each word twice) -- covered by qmtech_k325t_cm4.xdc's CORE/* -> i_lat_meter/aux_reg* false path; the guard flag
## (main_clk) into fc_cen: core_k325t.xdc's main_clk <-> CPU clock bound
