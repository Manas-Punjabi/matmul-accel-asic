# Top-level Makefile
#   make sim            RTL simulation (Icarus), N in {2,4,8}
#   make lint           Verilator -Wall, all configs
#   make mutate         mutation test of the testbench
#   make synth-check    generic Yosys synthesis (no PDK needed)
#   make gls-generic    gate-level sim of the Yosys generic netlist
#   make verify         lint + sim + mutate + synth-check + gls-generic
#   make asic           full ORFS RTL-to-GDSII on SKY130HD
#   make report         print PPA metrics for the last asic run
#   make sweep          PPA sweep -> results/sweep.csv + docs/ppa_sweep.png
#   make gls-sky130     post-layout GLS of an ORFS netlist with SKY130 cell models (+SDF)
REPO_ROOT := $(abspath .)
# ORFS ships in the Docker image; inside the container this is the correct path.
FLOW_HOME ?= /OpenROAD-flow-scripts/flow
WORK_HOME ?= $(FLOW_HOME)
FLOW_VARIANT ?= base
SPLIT_MUL ?= 0
N ?= 4
export REPO_ROOT

ORFS = $(MAKE) -C $(FLOW_HOME) DESIGN_CONFIG=$(REPO_ROOT)/flow/config.mk \
       FLOW_VARIANT=$(FLOW_VARIANT) WORK_HOME=$(WORK_HOME)
RUN  = sky130hd/mm_accel/$(FLOW_VARIANT)

.PHONY: verify lint sim mutate synth-check gls-generic gls-sky130 asic gui report sweep clean
YOSYS_DAT ?= $(or $(shell yosys-config --datdir 2>/dev/null),$(dir $(shell ls /usr/share/yosys/simcells.v /usr/local/share/yosys/simcells.v 2>/dev/null | head -1)))

verify: lint sim mutate synth-check gls-generic
	@echo "== verify: all RTL-level checks done =="

lint:
	@for s in 0 1; do for n in 2 4 8; do \
	  verilator --lint-only -Wall -Irtl -GN=$$n -GSPLIT_MUL=$$s rtl/mm_accel.sv --top-module mm_accel \
	    && echo "lint clean N=$$n SPLIT_MUL=$$s" || exit 1; \
	done; done

mutate:
	./scripts/mutate.sh

sim:
	@mkdir -p build
	@for s in 0 1; do for n in 2 4 8; do \
	  iverilog -g2012 -P tb_mm_accel.N=$$n -P tb_mm_accel.SPLIT_MUL=$$s -s tb_mm_accel \
	    -o build/sim_$${n}_$$s rtl/*.sv tb/tb_mm_accel.sv || exit 1; \
	  vvp -n build/sim_$${n}_$$s | grep -E "^PASS|^FAIL" | tee build/sim.out; \
	  grep -q "^PASS" build/sim.out || exit 1; \
	done; done

synth-check:
	@mkdir -p build
	yosys -q -p "read_verilog -sv rtl/mm_pe.sv rtl/mm_accel.sv; chparam -set N $(N) -set SPLIT_MUL $(SPLIT_MUL) mm_accel; \
	  synth -top mm_accel -flatten; tee -o build/synth_stat.txt stat"

asic:
	$(ORFS)

gui:
	$(ORFS) gui_final

report:
	python3 scripts/parse_reports.py --logs $(WORK_HOME)/logs/$(RUN) --reports $(WORK_HOME)/reports/$(RUN)

sweep:
	FLOW_HOME=$(FLOW_HOME) WORK_HOME=$(WORK_HOME) ORFS_EXTRA="$(ORFS_EXTRA)" python3 scripts/sweep.py \
	  --periods 6 7 8 10 12 --sizes 4 --split 0 1 --out results/sweep.csv
	python3 scripts/plot_sweep.py results/sweep.csv docs/ppa_sweep.png

gls-generic:
	@mkdir -p build
	@test -f "$(YOSYS_DAT)/simcells.v" || { echo "simcells.v not found; set YOSYS_DAT=<yosys share dir>"; exit 1; }
	@for s in 0 1; do \
	  yosys -q -p "read_verilog -sv rtl/mm_pe.sv rtl/mm_accel.sv; chparam -set N $(N) -set SPLIT_MUL $$s mm_accel; \
	    synth -top mm_accel -flatten; opt_clean -purge; write_verilog -noattr build/mm_accel_gl_$$s.v" && \
	  iverilog -g2012 -DGLS -P tb_mm_accel.N=$(N) -P tb_mm_accel.SPLIT_MUL=$$s -s tb_mm_accel \
	    -o build/gls_$$s build/mm_accel_gl_$$s.v $(YOSYS_DAT)/simcells.v tb/tb_mm_accel.sv || exit 1; \
	  vvp -n build/gls_$$s | grep -E "^PASS|^FAIL" | sed "s/^/GLS: /" | tee build/gls.out; \
	  grep -q "^GLS: PASS" build/gls.out || exit 1; \
	done

# Post-layout GLS with the SKY130 cell models.
#   make gls-sky130 WORK_HOME=<orfs work dir> FLOW_VARIANT=base [SPLIT_MUL=0] [PDK_ROOT=~/.volare]
#   make gls-sky130 ... SDF=build/mm_accel_base_tt.sdf [HALF_PERIOD=6] [RD_SETTLE=7]
# Without SDF: functional models (-DFUNCTIONAL, unit delay). With SDF: delays back-annotated
# (Icarus needs a patched cell library and OpenSTA's min::max SDF needs -Tmax; timing checks
# are not performed - see docs/verification.md).
PDK_ROOT ?= $(HOME)/.volare
CELLS = $(PDK_ROOT)/sky130A/libs.ref/sky130_fd_sc_hd/verilog
NETLIST = $(WORK_HOME)/results/$(RUN)/6_final.v
HALF_PERIOD ?= 5
RD_SETTLE ?= 1
gls-sky130:
	@mkdir -p build
	@test -f "$(NETLIST)" || { echo "no netlist at $(NETLIST)"; exit 1; }
ifeq ($(SDF),)
	iverilog -g2012 -DGLS -DFUNCTIONAL -DUNIT_DELAY="#1" -P tb_mm_accel.N=$(N) -P tb_mm_accel.SPLIT_MUL=$(SPLIT_MUL) \
	  -s tb_mm_accel -o build/gls_sky130 $(CELLS)/primitives.v $(CELLS)/sky130_fd_sc_hd.v $(NETLIST) tb/tb_mm_accel.sv
	vvp -n build/gls_sky130 | grep -E "^PASS|^FAIL" | sed "s/^/GLS-sky130 $(FLOW_VARIANT): /"
else
	python3 scripts/sky130_icarus_sdf_lib.py $(CELLS)/sky130_fd_sc_hd.v build/sky130_fd_sc_hd_icarus_sdf.v
	python3 scripts/sdf_dedot.py $(NETLIST) $(SDF) build/6_final_dedot.v build/sdf_dedot.sdf
	iverilog -g2012 -gspecify -Tmax -DGLS -DSDF -P tb_mm_accel.N=$(N) -P tb_mm_accel.SPLIT_MUL=$(SPLIT_MUL) \
	  -P tb_mm_accel.HALF_PERIOD=$(HALF_PERIOD) -P tb_mm_accel.RD_SETTLE=$(RD_SETTLE) \
	  -s tb_mm_accel -o build/gls_sdf $(CELLS)/primitives.v build/sky130_fd_sc_hd_icarus_sdf.v build/6_final_dedot.v tb/tb_mm_accel.sv
	vvp -n build/gls_sdf +sdf=build/sdf_dedot.sdf | grep -E "^PASS|^FAIL" | sed "s/^/GLS-sky130+SDF $(FLOW_VARIANT) @$$(( 2*$(HALF_PERIOD) ))ns: /"
endif

clean:
	rm -rf build
