# sta_post_route.tcl — standalone OpenSTA sign-off on the routed design
# Usage: sta scripts/sta_post_route.tcl
# Env:   LIB_FILE  NETLIST  SPEF  SDC  [TOP=mm_accel]
set top [expr {[info exists ::env(TOP)] ? $::env(TOP) : "mm_accel"}]

read_liberty $::env(LIB_FILE)
read_verilog $::env(NETLIST)
link_design  $top
read_sdc     $::env(SDC)
if {[info exists ::env(SPEF)] && [file exists $::env(SPEF)]} {
  read_spef $::env(SPEF)
}

puts "==== setup ===="
report_checks -path_delay max -group_path_count 5 -format full_clock_expanded \
  -fields {slew cap input_pins} -digits 3
puts "==== hold ===="
report_checks -path_delay min -group_path_count 5 -digits 3
puts "==== summary ===="
report_wns
report_tns
report_worst_slack -max
report_worst_slack -min
report_check_types -max_slew -max_capacitance -max_fanout -violators
exit
