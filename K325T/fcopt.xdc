## a1200-fc8 (builds without the census, FCCEN /= 1, added by build.tcl): the fast CPU's option register (fc_opt.vhd)
## the bridge's VIDEO byte into fc_opt's 2-flop synchroniser (as fc_cen's and lat_meter's cfg_s1)
set_false_path -to [get_cells -hierarchical -filter {NAME =~ CORE/i_main/*i_fc_opt/cfg_s1_reg*}]
