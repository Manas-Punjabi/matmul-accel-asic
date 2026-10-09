# Implementation

RTL to GDSII on SKY130HD with OpenROAD-flow-scripts (ORFS), the open-source RTL-to-GDSII flow
built on OpenROAD and Yosys, followed by standalone static timing analysis and physical
verification. All results below are from the `base` variant — N=4, DW=32, `SPLIT_MUL=0`, 12 ns
target — run 2026-09-19 with `openroad/orfs:26Q3-589-gbc5af8cbd`.

## Sign-off summary

| Check | Result | Evidence |
|---|---|---|
| Setup WNS / TNS, tt corner | +3.16 ns / 0 | [sta_base_tt.txt](reports/sta_base_tt.txt) |
| Hold worst slack, tt corner | +0.03 ns | [sta_base_tt.txt](reports/sta_base_tt.txt) |
| Max slew / cap / fanout violators | 0 | [sta_base_tt.txt](reports/sta_base_tt.txt), [flow_metrics_base.txt](reports/flow_metrics_base.txt) |
| Router DRC | 0 | [flow_metrics_base.txt](reports/flow_metrics_base.txt) |
| Antenna | 0 net, 0 pin | [flow_metrics_base.txt](reports/flow_metrics_base.txt) |
| Magic sign-off DRC, full deck | 0 errors | [magic_drc_base.txt](reports/magic_drc_base.txt) |
| Netgen LVS | circuits match uniquely — 29,453 devices, 38,236 nets | [netgen_lvs_base.txt](reports/netgen_lvs_base.txt) |
| Post-layout simulation | PASS, functional and SDF-annotated | [gls_postlayout_base.txt](reports/gls_postlayout_base.txt) |
| Cell area / utilization | 368,923 µm² / 37.9 % | [flow_metrics_base.txt](reports/flow_metrics_base.txt) |
| Total power | 21.5 mW | [flow_metrics_base.txt](reports/flow_metrics_base.txt) |
| Flop count | 2,837 | [flow_metrics_base.txt](reports/flow_metrics_base.txt) |
| Critical path | `a_q[106]` → `prod_q[127]`, S2 multiplier, 9.48 ns arrival | [sta_base_tt.txt](reports/sta_base_tt.txt) |

## Flow

### Running the flow

ORFS runs from its Docker image; the repository is mounted at `/work` and flow outputs go to a
separate folder mounted at `/orfs_work`:

```bash
WORK=$HOME/mm-work; mkdir -p "$WORK"
docker run --rm --user $(id -u):$(id -g) \
  -v "$PWD":/work -v "$WORK":/orfs_work \
  openroad/orfs:26Q3-589-gbc5af8cbd bash -c '
    source /OpenROAD-flow-scripts/env.sh > /dev/null && cd /work &&
    make asic   FLOW_HOME=/OpenROAD-flow-scripts/flow WORK_HOME=/orfs_work \
                CLOCK_PERIOD=12 FLOW_VARIANT=base LEC_CHECK=0 &&
    make report FLOW_HOME=/OpenROAD-flow-scripts/flow WORK_HOME=/orfs_work FLOW_VARIANT=base'
```

`LEC_CHECK=0` skips an optional equivalence check whose binary needs an AVX-512 CPU; it does not
affect any reported result. Inside the container `FLOW_HOME` and `WORK_HOME` are the paths
above; the commands below use them as variables.

| Step | Runs on | Needs |
|---|---|---|
| `make verify` | host | Icarus Verilog 12.0, Verilator 5.020, Yosys 0.33 (Ubuntu 24.04 packages) |
| `make asic`, `make report`, `make sweep`, standalone STA | ORFS Docker image | Docker |
| `make gls-sky130`, Magic DRC, Netgen LVS | host | SKY130 PDK `c6d73a35` via volare; Magic 8.3.683 and Netgen 1.5.323 built from source |
| `plot_sweep.py`, `render_layout.py` | host | matplotlib, KLayout |

```bash
# smoke run first — small, finishes in minutes
make asic FLOW_HOME=$FLOW_HOME WORK_HOME=$WORK_HOME \
  MM_N=2 MM_DW=16 CLOCK_PERIOD=10 FLOW_VARIANT=smoke

# full design
make asic   FLOW_HOME=$FLOW_HOME WORK_HOME=$WORK_HOME CLOCK_PERIOD=12 FLOW_VARIANT=base
make report FLOW_HOME=$FLOW_HOME WORK_HOME=$WORK_HOME FLOW_VARIANT=base
```

| Stage | What happens | Run by | Key output under `$WORK_HOME/.../sky130hd/mm_accel/<variant>/` |
|---|---|---|---|
| 1 Synthesis | Yosys + ABC mapped to `sky130_fd_sc_hd` | `make asic` | `results/1_synth.v`, `reports/synth_stat.txt` |
| 2 Floorplan | die/core sizing (`CORE_UTILIZATION`), I/O pins, tapcells, PDN | `make asic` | `logs/2_*.log` |
| 3 Placement | global placement (`PLACE_DENSITY`), resizing, detailed placement | `make asic` | `logs/3_*.log` |
| 4 CTS | clock tree, hold repair | `make asic` | `reports/4_cts_final.rpt` |
| 5 Routing | global route, antenna repair, detailed route | `make asic` | `reports/5_route_drc.rpt` |
| 6 Finish | fill, extraction, final reports | `make asic` | `results/6_final.{gds,def,v,odb,sdc,spef}` |
| Metrics | timing, area and power summary | `make report` (`scripts/parse_reports.py`) | printed |
| Standalone STA | setup, hold and DRV at any corner | `scripts/sta_post_route.tcl` | [`reports/sta_base_*.txt`](reports/) |
| DRC / LVS | Magic full-deck DRC, Magic extraction + Netgen compare | recipes under [Physical verification](#physical-verification) | [`reports/`](reports/) |
| Post-layout simulation | testbench on the routed netlist, optional SDF | `make gls-sky130` | [`reports/gls_postlayout_base.txt`](reports/gls_postlayout_base.txt) |
| Sweep | the flow across clock periods and multiplier modes | `make sweep` (`scripts/sweep.py`, `scripts/plot_sweep.py`) | [`../results/sweep.csv`](../results/sweep.csv) |

Per-stage pass criteria:

| Stage | Check |
|---|---|
| Synthesis | no unmapped cells, no latches, no `ERROR` |
| Floorplan | utilization near target, PDN built without errors |
| Placement | global placement converges (overflow < 0.1), design fits the core |
| CTS | clock skew reported, hold repaired |
| Global route | no congestion overflow |
| Detailed route | **0 DRC violations** |
| Finish | GDS present, no `ERROR` in any log |

A ~15 min run at N=4, DW=32; peak memory ~3.7 GB. View the result with
`make gui FLOW_VARIANT=base`, or render it headlessly with `scripts/render_layout.py`.

![Routed layout](layout.png)

met4 (orange) and met5 (purple) carry the power grid; signal routing is on met1–met3.
2,837 flops and 368,923 µm² of cells at 37.9 % utilization.

## Timing constraints — `flow/constraint.sdc`

| Constraint | Value | Rationale |
|---|---|---|
| `create_clock core_clock` on `clk` | `CLOCK_PERIOD` env, default 12 ns | lets the sweep vary the target without editing the SDC |
| `set_clock_uncertainty` | 0.25 ns | jitter plus skew margin before CTS |
| `set_input_delay` | 20 % of the period | external logic budget |
| `set_output_delay` | 20 % of the period | external logic budget |
| `set_driving_cell` | `sky130_fd_sc_hd__buf_2` | realistic input slew |
| `set_load` | 0.02 pF | realistic output load |
| `set_false_path -from rst_n` | – | asynchronous reset has no clock relationship |

The combinational `raddr → rdata` readback receives the remaining 60 % of the period. Were it
to become critical at large N, registering `rdata` would cost one cycle of read latency.

## Non-default flow settings

Two settings in `flow/config.mk` deviate from the platform defaults. Both were adopted after
measurement, and both apply to every run quoted in this repository.

### `DONT_USE_CELLS` — 13 cells excluded

```make
export DONT_USE_CELLS += sky130_fd_sc_hd__a2111oi_0 sky130_fd_sc_hd__buf_16 ...
```

`sky130_fd_sc_hd__a2111oi_0` and `sky130_fd_sc_hd__buf_16` each fail the Magic `licon.8a` rule
(poly overlap of poly contact < 0.08 µm) *inside the cell layout itself* — at a fixed offset
within the cell, not at boundaries or in routing. Both appear on the PDK's own
`libs.tech/openlane/sky130_fd_sc_hd/drc_exclude.cells` list. The remaining eleven entries are
cells from that list which this design never selected, excluded pre-emptively so the cell
library is closed under DRC.

Four cells on the exclude list *are* used — `o21ai_0` (~330 instances), `a21boi_0`, `and2_0`,
`o311ai_0` — and passed Magic's full deck unflagged, so they remain permitted. The PDK list is
a conservative "skip checking these" set, not a list of cells known to fail.

### `SLEW_MARGIN` / `CAP_MARGIN` = 20

```make
export SLEW_MARGIN = 20
export CAP_MARGIN  = 20
```

ORFS runs `repair_design` before detailed routing, using global-route parasitic estimates.
Two single-load nets — ~300 µm two-pin routes driven by minimum-size `xnor2_1`/`xor2_1` cells,
carrying 0.06–0.07 pF of wire capacitance — were judged "just under" the max-slew and max-cap
limits by the estimate and came out 9–12 % over once extracted. Setting both margins to 20 %
makes the pre-route repair aim under the limits and buffer such nets.

Effect on `base`: DRV violators 2 → 0, WNS +2.99 → +3.19 ns, cell area +0.01 %.

Every settings change re-maps the whole design, so all variants were re-run under each setup.
[`results/flow_history.csv`](../results/flow_history.csv) lists all four setups (A–D); only the
final setup's numbers are quoted anywhere else.

## Timing closure

| # | Variant | Change | Period (ns) | WNS (ns) | TNS | Hold WS (ns) | Area (µm²) | Power (mW) | Critical path |
|---|---|---|---|---|---|---|---|---|---|
| 1 | base | baseline | 12 | +3.16 | 0 | +0.032 | 368,923 | 21.5 | `a_q[106]` → `prod_q[127]`, S2 multiplier, 9.48 ns |
| 2 | p8 | tighter clock | 8 | +0.18 | 0 | +0.075 | 375,144 | 32.5 | `a_q[4]` → `prod_q[19]`, S2 multiplier, 8.45 ns |
| 3 | p8_split | `SPLIT_MUL=1` | 8 | +0.29 | 0 | +0.039 | 393,491 | 39.8 | `a_q[74]` → `g_split.pl_q[94]`, half-product, 8.43 ns |
| 4 | p8_split_u25 | `CORE_UTILIZATION=25` | 8 | +0.26 | 0 | +0.014 | 400,321 | 39.5 | `a_q[67]` → `g_split.pl_q[93]`, half-product, 8.43 ns |
| 5 | p8_split_d50 | `PLACE_DENSITY=0.50` | 8 | +0.28 | 0 | +0.019 | 395,150 | 40.7 | `a_q[34]` → `g_split.pl_q[57]`, half-product, 8.39 ns |

All five: 0 route DRC, no `ERROR` in any log; 12–16 minutes each. Two runs are not fully clean
and are not sign-off candidates: `p8` has one antenna-violating net (`a_row[100]`) that the
router's repair did not clear, and `p8_split_u25` has 3 max-slew and 1 max-capacitance
violators. The sign-off run `base` has none of either.

The design closes at 8 ns **without** the split multiplier: the resizer brings the S2 path from
9.48 ns arrival at the 12 ns target to +0.18 ns of slack at 8 ns, for 2 % additional cell area.
`SPLIT_MUL=1` contributes a further +0.10 ns at 8 ns, at the cost of 5 % area, 22 % power and
one cycle of latency — so it is not required at this period. Its critical path does move to the
half-product multiplier, as designed.

The utilization and density knobs (rows 4–5) change WNS by under ±0.05 ns here, which is within
run-to-run re-mapping variation.

The `a_q` registers are per-PE in the RTL but hold identical data, so synthesis merges them.
That is why a path can start in `g_pe[0]` and end in `g_pe[2]`.

## Design study — split multiplier

Ten flow runs, periods {6, 7, 8, 10, 12} ns × `SPLIT_MUL` {0, 1}:

```bash
make sweep FLOW_HOME=$FLOW_HOME WORK_HOME=$WORK_HOME [ORFS_EXTRA="LEC_CHECK=0"]
```

![PPA sweep](ppa_sweep.png)

| Period (ns) | `SPLIT_MUL=0` WNS | `SPLIT_MUL=1` WNS |
|---|---|---|
| 12 | +3.16 | +3.87 |
| 10 | +1.01 | +2.01 |
| 8 | +0.18 | +0.29 |
| 7 | **−0.29** | **+0.18** |
| 6 | −1.36 | −0.36 |

| | Full multiplier | Split multiplier |
|---|---|---|
| Closes at | 8 ns | 7 ns |
| Estimated Fmax | ~137 MHz | ~157 MHz |
| Cell area at 8 ns | 375,144 µm² | 393,491 µm² (+5 %) |
| Power at 8 ns | 32.5 mW | 39.8 mW (+22 %) |
| Latency | N + 4 cycles | N + 5 cycles |
| Critical path | S2 32×32 multiplier | half-product multiplier |

**Result:** the split multiplier buys ~15 % frequency for ~5 % area, one cycle of latency and
22 % power. At 8 ns and above the full multiplier already meets timing, so the split is not
needed; at 7 ns only the split meets timing; at 6 ns neither does.

Fmax is estimated as `1000 / (period − WNS)` from post-route STA, the same definition OpenROAD
uses for its minimum-period report (the 12 ns run's `finish__timing__fmax` is 113.14 MHz, as in
the sweep table). Every sweep run: 0 route DRC. Two sweep runs have residual violations: the
8 ns full-multiplier run (the same run as `p8`) has one antenna net, and the 12 ns split run has
10 max-slew and 1 max-capacitance violators. Data: [`../results/sweep.csv`](../results/sweep.csv).

Metrics for any run can be extracted with:

```bash
python3 scripts/parse_reports.py --logs <logs dir> --reports <reports dir> --json
```

The ORFS container has no matplotlib, so run `sweep.py` inside it and `plot_sweep.py` outside.

## Static timing analysis

ORFS reports STA in `reports/6_finish.rpt`. For standalone sign-off:

```bash
export LIB_FILE=$FLOW_HOME/platforms/sky130hd/lib/sky130_fd_sc_hd__tt_025C_1v80.lib
R=$WORK_HOME/results/sky130hd/mm_accel/base
export NETLIST=$R/6_final.v SPEF=$R/6_final.spef SDC=$R/6_final.sdc
sta scripts/sta_post_route.tcl | tee docs/reports/sta_base_tt.txt
```

| Check | Pass criterion |
|---|---|
| Setup — `report_checks -path_delay max`, `report_wns` | WNS ≥ 0 at the target period |
| Setup total — `report_tns` | TNS = 0 |
| Hold — `report_checks -path_delay min`, `report_worst_slack -min` | worst hold slack ≥ 0 |
| Max slew / cap / fanout — `report_check_types -violators` | no violators |

### Results across corners

| Corner | Setup WS | TNS | Hold WS | DRV violators | Critical path |
|---|---|---|---|---|---|
| tt_025C_1v80 | +3.16 ns | 0 | +0.03 ns | **0** | `a_q[106]` → `prod_q[127]`, 9.48 ns arrival |
| ss_100C_1v60 | **−6.31 ns** | −1450 | +0.34 ns | 2,146 max-slew, 135 max-cap | same S2 multiplier path, 19.42 ns arrival |
| ff_n40C_1v95 | +4.83 ns | 0 | **−0.07 ns** | 0 | `raddr[0]` → `rdata[0]`, combinational readback |

Reports: [`reports/sta_base_tt.txt`](reports/sta_base_tt.txt),
[`reports/sta_base_ss.txt`](reports/sta_base_ss.txt),
[`reports/sta_base_ff.txt`](reports/sta_base_ff.txt).

The standalone tt result matches the in-flow value. The ORFS sky130hd platform ships only the
tt library; ss and ff libraries come from the PDK at
`$PDK_ROOT/sky130A/libs.ref/sky130_fd_sc_hd/lib/`. See
[Known limitations](#known-limitations) for what the ss and ff rows mean.

OpenSTA emits a warning per antenna diode when reading the SPEF: ORFS writes `6_final.v`
without physical-only cells, so the 417 router-inserted diodes appear in the DEF and SPEF but
not in the netlist. The worst path is unaffected — the standalone and in-flow results agree.

## Physical verification

### Router DRC and antenna

From the flow itself: `reports/5_route_drc.rpt` must show 0 violations, and the detailed-route
log must report 0 antenna violations.

```bash
grep -i -A3 antenna $WORK_HOME/logs/sky130hd/mm_accel/base/5_*route*.log
```

Result: **0 and 0**, on every run in this repository.

### Tool versions

The PDK techfile requires Magic ≥ 8.3.411, and older Netgen releases mis-parse OpenROAD
netlists. Ubuntu 24.04's packages are unusable for both: `magic` 8.3.105 segfaults on the
techfile, `netgen` is a mesh generator, and `netgen-lvs` 1.5.133 produces thousands of
malformed instance names. Build both from source:

```bash
sudo apt install -y tcl-dev tk-dev libcairo2-dev libglu1-mesa-dev libx11-dev
for t in magic netgen; do
  git clone --depth 1 https://github.com/RTimothyEdwards/$t.git ~/src/$t
  (cd ~/src/$t && ./configure --prefix=$HOME/opt/$t && make -j8 && make install)
done
export PATH=$HOME/opt/magic/bin:$HOME/opt/netgen/bin:$PATH
```

Used here: Magic 8.3.683, Netgen 1.5.323, PDK sky130A `c6d73a35` installed with volare.

### Sign-off DRC — Magic

```bash
export PDK_ROOT=~/.volare
GDS=$WORK_HOME/results/sky130hd/mm_accel/base/6_final.gds
magic -dnull -noconsole -rcfile $PDK_ROOT/sky130A/libs.tech/magic/sky130A.magicrc <<EOF
gds read $GDS
load mm_accel
select top cell
drc euclidean on
drc style drc(full)
drc check
drc catchup
set fh [open build/magic_drc_report.txt w]
foreach {why boxes} [drc listall why] {
  puts \$fh "RULE: \$why  ([llength \$boxes] errors)"
  foreach b \$boxes { puts \$fh "  box \$b" }
}
close \$fh
quit -noprompt
EOF
```

`drc catchup` prints the total; the report lists each rule with error boxes in Magic internal
units (0.005 µm). Roughly 8 minutes on the `base` GDS.

**Result: No errors found.** — [`reports/magic_drc_base.txt`](reports/magic_drc_base.txt).

Reaching zero required the `DONT_USE_CELLS` list described above. Because excluding a cell
changes ABC's mapping across the whole design, every run quoted in this repository was redone
under the final cell list.

### LVS — Magic extraction, Netgen compare

Three prerequisites, without which the comparison fails for reasons unrelated to the design:

1. **Netlist side** — `6_final.v` has no power pins and omits fill, tap and antenna-diode
   instances. Write a complete powered netlist from the final ODB instead.
2. **Layout side** — `extract do local`; `ext2spice` drops transistor-less cells (fill, tap),
   which is expected.
3. **`MAGIC_EXT_USE_GDS=1`** must be in the environment. Only then does the PDK's
   `sky130A_setup.tcl` instruct Netgen to ignore the fill and tap classes that exist on the
   netlist side but not the layout side. Without it the compare reports a device-count
   mismatch.

```bash
# 1. powered netlist with every instance (inside the ORFS container)
openroad -exit <<EOF
read_db $WORK_HOME/results/sky130hd/mm_accel/base/6_final.odb
write_verilog -include_pwr_gnd $WORK_HOME/results/sky130hd/mm_accel/base/6_final_pg.v
EOF

# 2. extract the layout (~1.5 min)
magic -dnull -noconsole -rcfile $PDK_ROOT/sky130A/libs.tech/magic/sky130A.magicrc <<EOF
gds read $GDS
load mm_accel
select top cell
extract do local
extract no capacitance
extract no coupling
extract no resistance
extract no adjust
extract unique
extract
ext2spice lvs
ext2spice -o build/mm_accel_layout.spice
quit -noprompt
EOF

# 3. compare (~10 s)
MAGIC_EXT_USE_GDS=1 netgen -batch lvs "build/mm_accel_layout.spice mm_accel" \
  "$WORK_HOME/results/sky130hd/mm_accel/base/6_final_pg.v mm_accel" \
  $PDK_ROOT/sky130A/libs.tech/netgen/sky130A_setup.tcl build/lvs.log -json
grep "Final result" build/lvs.log
```

**Result: Circuits match uniquely.** 29,453 devices and 38,236 nets on both sides, all ~130
cell classes equal including the 417 antenna diodes, top-level pin lists equivalent.
Summary: [`reports/netgen_lvs_base.txt`](reports/netgen_lvs_base.txt).

## Known limitations

**Single-corner closure.** The ORFS sky130hd platform optimizes at the typical corner only.
At ss_100C_1v60 the same multiplier path takes 19.42 ns, so the design would require a ~20 ns
clock; at ff_n40C_1v95 hold margin is 70 ps negative. Both corners are measured and reported
above rather than omitted. Multi-corner closure — setup repair against the ss library, hold
repair against ff — is not claimed.

**Two library cells excluded.** `a2111oi_0` and `buf_16` are unavailable to synthesis, as
described under [non-default flow settings](#dont_use_cells--13-cells-excluded). The design
closes without them.

**Post-layout simulation performs no timing checks.** Delays are back-annotated but setup,
hold, recovery and width checks are not evaluated — Icarus Verilog does not implement them.
See [verification.md](verification.md#scope-and-limitations).

**Fmax is an estimate.** `1000 / (period − WNS)` extrapolates from a run at a fixed target
period; it is not a closed run at that frequency.

## Troubleshooting

| Symptom | Cause | Fix |
|---|---|---|
| Yosys: `syntax error, unexpected '['` | multi-dimensional packed ports | keep buses flattened — `[k*DW +: DW]` |
| Yosys: `unexpected TOK_INT` | `int'(...)` cast | avoid casts; use `int` parameters |
| `make asic` very slow at N=4, DW=32 | 16 × 32×32 multipliers | smoke with `MM_N=2 MM_DW=16`; allow Docker ≥ 8 GB |
| Global route congestion | utilization or density too high | lower `CORE_UTILIZATION` (35 → 25) or `PLACE_DENSITY` |
| Hold violations after CTS | fast paths between adjacent registers | ORFS repairs hold at CTS; check `4_cts_final.rpt`. Do not reduce clock uncertainty to hide it |
| Setup fails at S2 | multiplier depth | `SPLIT_MUL=1`, or relax `CLOCK_PERIOD` |
| ORFS ignores `WORK_HOME` | older ORFS build | copy outputs from `$FLOW_HOME/{logs,reports,results}` |
| `parse_reports.py` prints `None` | metric key names differ by ORFS version | inspect `logs/.../*.json` and extend `PATTERNS` |
| `simcells.v not found` | Yosys share directory differs | `make gls-generic YOSYS_DAT=/path/to/share/yosys` |
| Testbench reports `FAIL: hang` | `done` never asserted | dump the VCD (`+vcd`) and inspect `state`, `feed_cnt`, `pe_v` |
| ORFS dies at CTS with `illegal instruction` | the flow's equivalence checker requires AVX-512 | pass `LEC_CHECK=0` |
