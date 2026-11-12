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
# core constraints: K325T/core_k325t.xdc = CORE/CORE.xdc with the stoppable clock (stall_clk.vhd)
add_files -fileset constrs_1 -norecurse [list $xdc $here/core_k325t.xdc]
# DDR3: MIG 7-series, the board's proven MT41K128M16 setup (DDR3-800, 4:1, 200 MHz system
# clock, no XADC) -- the same .prj as the MEGA65 core port
create_ip -name mig_7series -vendor xilinx.com -library ip -module_name mig_ddr3
set_property CONFIG.XML_INPUT_FILE [file normalize $here/mig_ddr3.prj] [get_ips mig_ddr3]
generate_target {instantiation_template synthesis implementation} [get_ips mig_ddr3]
set_property top qmtech_k325t_cm4 [current_fileset]
# a1200-ide: the hard disk SPI pins are driven only on the Radxa CM3 (SPI0 M0 + BCM7)
if {$suffix eq "_radxacm3"} { set_property generic {G_HDD=true} [current_fileset] }
# run settings as in CORE-R6.xpr
set_property STEPS.SYNTH_DESIGN.ARGS.FLATTEN_HIERARCHY none [get_runs synth_1]
set_property strategy Performance_ExtraTimingOpt [get_runs impl_1]
# at most $VIVADO_JOBS (default 4) jobs/threads per build: two builds may share this PC
set jobs [expr {[info exists env(VIVADO_JOBS)] ? $env(VIVADO_JOBS) : 4}]
set_param general.maxThreads $jobs
# the runs are child processes: give every step the same limit through a pre-step hook
file mkdir $here/.Xil
set mt [open $here/.Xil/maxthreads.tcl w]
puts $mt "set_param general.maxThreads $jobs"
close $mt
foreach {run step} {synth_1 SYNTH_DESIGN impl_1 OPT_DESIGN impl_1 PLACE_DESIGN impl_1 PHYS_OPT_DESIGN
                    impl_1 ROUTE_DESIGN impl_1 POST_ROUTE_PHYS_OPT_DESIGN impl_1 WRITE_BITSTREAM} {
    set_property STEPS.$step.TCL.PRE [file normalize $here/.Xil/maxthreads.tcl] [get_runs $run]
}

launch_runs synth_1 -jobs $jobs
wait_on_run synth_1
if {[get_property PROGRESS [get_runs synth_1]] ne "100%"} { error "synthesis failed" }
launch_runs impl_1 -to_step write_bitstream -jobs $jobs
wait_on_run impl_1
if {[get_property PROGRESS [get_runs impl_1]] ne "100%"} { error "implementation failed" }
open_run impl_1
report_timing_summary -max_paths 20 -file $here/timing$suffix.txt
report_utilization -file $here/utilization$suffix.txt
file mkdir $here/bin
file copy -force [glob $root/CORE/CORE-K325T.runs/impl_1/*.bit] $here/bin/aexp_k325t_cm4$suffix.bit
puts "BITSTREAM: $here/bin/aexp_k325t_cm4$suffix.bit"
