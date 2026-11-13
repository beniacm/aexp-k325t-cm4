## prefetch.xdc -- the cache prefetchers' counters (G_PREFETCH, build.sh PREFETCH=1; without them the
## registers are not built).  build.tcl adds this file only with PREFETCH=1.
## The prefetch counters (source clock) read by lat_meter (quasi-static, read twice).
set_false_path -from [get_cells -hierarchical -filter {NAME =~ CORE/i_chip_cache/pf_iss_reg* || NAME =~ CORE/i_chip_cache/pf_use_reg* || NAME =~ CORE/i_chip_cache/pf_wst_reg*}] \
               -to   [get_cells -hierarchical -filter {NAME =~ i_lat_meter/aux_reg*}]
