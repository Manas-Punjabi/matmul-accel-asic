# OpenROAD-flow-scripts design config (SKY130HD)
# Invoked from the repo Makefile, which sets REPO_ROOT.
export DESIGN_NAME     = mm_accel
export DESIGN_NICKNAME = mm_accel
export PLATFORM        = sky130hd

export VERILOG_FILES   = $(REPO_ROOT)/rtl/mm_pe.sv $(REPO_ROOT)/rtl/mm_accel.sv
export SDC_FILE        = $(REPO_ROOT)/flow/constraint.sdc

# Architecture knobs (overridable: make asic MM_N=2 MM_DW=16)
MM_N  ?= 4
MM_DW ?= 32
SPLIT_MUL ?= 0
export VERILOG_TOP_PARAMS = N $(MM_N) DW $(MM_DW) SPLIT_MUL $(SPLIT_MUL)

# Timing knob, read by constraint.sdc
export CLOCK_PERIOD ?= 12.0

# Floorplan / placement knobs
export CORE_UTILIZATION ?= 35
export PLACE_DENSITY    ?= 0.60
export TNS_END_PERCENT  = 100

# Cells from the PDK's libs.tech/openlane/sky130_fd_sc_hd/drc_exclude.cells list.
# a2111oi_0 and buf_16 were each caught failing Magic DRC (licon.8a) inside the cell itself;
# the rest of the list that this flow has never picked is excluded pre-emptively. The four
# exclude-list cells the flow does use (o21ai_0, a21boi_0, and2_0, o311ai_0) passed Magic's
# full deck and stay allowed.
export DONT_USE_CELLS += sky130_fd_sc_hd__a2111oi_0 sky130_fd_sc_hd__buf_16 \
  sky130_fd_sc_hd__clkdlybuf4s15_1 sky130_fd_sc_hd__clkdlybuf4s18_1 \
  sky130_fd_sc_hd__fa_4 sky130_fd_sc_hd__mux4_4 sky130_fd_sc_hd__or2_0 \
  sky130_fd_sc_hd__xor3_1 sky130_fd_sc_hd__xor3_2 sky130_fd_sc_hd__xor3_4 \
  sky130_fd_sc_hd__xnor3_1 sky130_fd_sc_hd__xnor3_2 sky130_fd_sc_hd__xnor3_4

# Pre-route repair_design works on global-route estimates; antenna jumpers and detailed-route
# detours then push a few long two-pin nets just past the max-slew/max-cap limits. Aiming 20 %
# under the limits absorbs that (base: 2 violating nets -> 0, WNS +0.20 ns, area +0.01 %).
export SLEW_MARGIN = 20
export CAP_MARGIN  = 20
