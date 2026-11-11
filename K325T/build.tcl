# build.tcl -- AExp (Amiga 500 for MEGA65) on the QMTech XC7K325T + CM4 carrier (run via K325T/build.sh).
# The project lives next to the R6 one, as CORE/CORE-K325T.xpr: the core opens its ROM files
# by paths relative to the run directory (e.g. ../../Minimig_MiSTerMEGA65/rtl/fx68k/*.mem,
# ../../../CORE/m2m-rom/m2m-rom.rom from CORE/CORE-K325T.runs/synth_1).
set here [file normalize [file dirname [info script]]]
set root [file dirname $here]
# build.sh passes the pin file and the output suffix ("" = Luckfox, "_radxacm3" = Radxa CM3)
set xdc    [expr {[llength $argv] > 0 ? [lindex $argv 0] : "$here/qmtech_k325t_cm4.xdc"}]
set suffix [expr {[llength $argv] > 1 ? [lindex $argv 1] : ""}]
puts "PIN FILE: $xdc"
cd $root/CORE
create_project -force CORE-K325T $root/CORE -part xc7k325tffg676-1
set_property target_language VHDL [current_project]
source $here/sources.tcl
add_files -fileset constrs_1 -norecurse [list $xdc $root/CORE/CORE.xdc]
# DDR3: MIG 7-series, the board's proven MT41K128M16 setup (DDR3-800, 4:1, 200 MHz system
# clock, no XADC) -- the same .prj as the MEGA65 core port
create_ip -name mig_7series -vendor xilinx.com -library ip -module_name mig_ddr3
set_property CONFIG.XML_INPUT_FILE [file normalize $here/mig_ddr3.prj] [get_ips mig_ddr3]
generate_target {instantiation_template synthesis implementation} [get_ips mig_ddr3]
set_property top qmtech_k325t_cm4 [current_fileset]
# run settings as in CORE-R6.xpr
set_property STEPS.SYNTH_DESIGN.ARGS.FLATTEN_HIERARCHY none [get_runs synth_1]
set_property strategy Performance_ExtraTimingOpt [get_runs impl_1]

launch_runs synth_1 -jobs 8
wait_on_run synth_1
if {[get_property PROGRESS [get_runs synth_1]] ne "100%"} { error "synthesis failed" }
launch_runs impl_1 -to_step write_bitstream -jobs 8
wait_on_run impl_1
if {[get_property PROGRESS [get_runs impl_1]] ne "100%"} { error "implementation failed" }
open_run impl_1
report_timing_summary -max_paths 20 -file $here/timing$suffix.txt
report_utilization -file $here/utilization$suffix.txt
file mkdir $here/bin
file copy -force [glob $root/CORE/CORE-K325T.runs/impl_1/*.bit] $here/bin/aexp_k325t_cm4$suffix.bit
puts "BITSTREAM: $here/bin/aexp_k325t_cm4$suffix.bit"
