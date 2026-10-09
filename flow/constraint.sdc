# constraint.sdc — mm_accel
current_design mm_accel

set clk_name      core_clock
set clk_port_name clk
set clk_period    12.0
if {[info exists ::env(CLOCK_PERIOD)]} { set clk_period $::env(CLOCK_PERIOD) }
set clk_io_pct    0.2

set clk_port [get_ports $clk_port_name]
create_clock -name $clk_name -period $clk_period $clk_port

# Jitter plus the skew the clock tree will introduce. This is applied before CTS, so it has to
# be pessimistic enough that closure survives the real tree being built at clock-tree synthesis.
set_clock_uncertainty 0.25 [get_clocks $clk_name]

# I/O budgets: 20% of the period on each side, leaving 60% for the internal path. That 60% is
# what the combinational raddr -> rdata readback has to fit into.
set non_clock_inputs [all_inputs -no_clocks]
set_input_delay  [expr {$clk_period * $clk_io_pct}] -clock $clk_name $non_clock_inputs
set_output_delay [expr {$clk_period * $clk_io_pct}] -clock $clk_name [all_outputs]

# Without a driving cell the inputs are assumed ideal, which under-reports the delay of the
# first stage of logic. buf_2 is a mid-strength library buffer: a realistic external driver.
set_driving_cell -lib_cell sky130_fd_sc_hd__buf_2 $non_clock_inputs

# 0.02 pF is a few gate loads — a nearby on-chip consumer, not a pad or a board trace.
set_load 0.02 [all_outputs]

# rst_n is asynchronous: it has no timing relationship with core_clock, so constraining it
# would report meaningless violations. Reset recovery/removal is not checked as a result.
set_false_path -from [get_ports rst_n]
