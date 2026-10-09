# Verification

Five RTL-level checks run in under three minutes with `make verify`; two more run against the
routed netlist once the physical flow has produced one. Every check has a pass criterion and a
command.

| Check | Tool | Pass criterion | Result |
|---|---|---|---|
| Lint | Verilator 5.020 | zero warnings, 6 configurations | clean |
| RTL simulation | Icarus 12.0 | every configuration prints PASS | 166 / 490 / 1786 checks |
| Mutation testing | `scripts/mutate.sh` | 9 of 10 injected bugs caught | 9 killed, 1 equivalent |
| Generic synthesis | Yosys 0.33 | no latches, flop count matches architecture | 61,315 cells, 0 latches |
| Generic gate-level simulation | Yosys + Icarus | PASS, both modes | 489 checks ×2 |
| Post-layout simulation, functional | Icarus + SKY130 models | PASS, both modes | 489 checks ×2 |
| Post-layout simulation, SDF | Icarus + SKY130 models + OpenSTA SDF | PASS at the target period | PASS at 12/10/8 ns, FAIL at 6 ns (control) |

Each stage depends on the one before it: gate-level simulation of a netlist that failed lint
would prove nothing. `make verify` stops with a non-zero exit status at the first failed check,
so a script or CI job can rely on it.

---

## Lint

```bash
make lint
```

`verilator --lint-only -Wall` across N ∈ {2, 4, 8} × SPLIT_MUL ∈ {0, 1}. Zero warnings in all
six configurations.

One suppression exists: `UNUSEDSIGNAL` on `pe_v[N-1:1]`. All PEs share identical timing, so the
design reads only `pe_v[0]`; the waiver is local and documented in the RTL.

## RTL simulation

```bash
make sim                                  # 6 configurations
```

The testbench is self-checking against its own golden model,
`C[i][j] = Σk A[i][k]·B[k][j] mod 2^DW`. For a waveform:

```bash
iverilog -g2012 -P tb_mm_accel.N=4 -P tb_mm_accel.SPLIT_MUL=1 -s tb_mm_accel \
  -o build/sim rtl/*.sv tb/tb_mm_accel.sv && vvp -n build/sim +vcd
gtkwave build/tb_mm_accel.vcd
```

### Test catalog

| ID | Test | Stimulus | Checks |
|---|---|---|---|
| T0 | reset_state | reset held 3 cycles | `busy=done=0`; PE valids known-0 (whitebox, skipped under GLS) |
| T1 | identity | A = I, B random | C = B |
| T2 | overflow | A = B = all-ones | modulo-2^DW wraparound |
| T3 | zeros | A = 0, B random | C = 0, overwriting the previous result |
| T4 | random ×20 | random A, B | golden match; back-to-back runs without reset |
| T5 | latency | every run | `done` on edge N+4+SPLIT_MUL |
| T6 | done_pulse | every run | `done` high exactly one cycle; no second pulse; `busy` low afterwards |
| T7 | load_while_busy | `we_a`/`we_b` driven with inverted data every cycle of a run | result still matches |
| T7b | rerun_no_reload | `start` again without reloading | result matches, proving A/B were not corrupted in T7 |
| T8 | start_while_busy | extra `start` in cycle 2 | one `done`, correct result and latency |
| T9 | reset_mid_run | `rst_n` asserted 2 cycles into a run | `busy`/`done` clear, no activity until the next `start`, next run correct |
| T10 | busy_flag | every run | `busy` high on every cycle before `done` |

T5, T6 and T10 are assertions inside `run_case`, so they apply to all 27 runs per configuration.

### Expected output

| N | SPLIT_MUL | Checks | Latency |
|---|---|---|---|
| 2 | 0 | 166 | 6 |
| 4 | 0 | 490 | 8 |
| 8 | 0 | 1786 | 12 |
| 2 | 1 | 166 | 7 |
| 4 | 1 | 490 | 9 |
| 8 | 1 | 1786 | 13 |

```
PASS: 166 checks, N=2 DW=32 SPLIT_MUL=0
PASS: 490 checks, N=4 DW=32 SPLIT_MUL=0
PASS: 1786 checks, N=8 DW=32 SPLIT_MUL=0
PASS: 166 checks, N=2 DW=32 SPLIT_MUL=1
PASS: 490 checks, N=4 DW=32 SPLIT_MUL=1
PASS: 1786 checks, N=8 DW=32 SPLIT_MUL=1
```

`DW` is also parameterizable (`-P tb_mm_accel.DW=16`); with `SPLIT_MUL=1` it must be even.

## Mutation testing

```bash
make mutate
```

Ten known bugs are injected one at a time into a copy of the RTL and the testbench is re-run.
A mutant is *killed* if the testbench reports FAIL — this measures whether the tests actually
detect defects, rather than merely passing.

| ID | Injected bug | Caught by | Result |
|---|---|---|---|
| M1 | A accepts writes while busy | T7b | killed |
| M2 | B accepts writes while busy | T7 / T7b | killed |
| M3 | `done` one row early | T4, T5 | killed |
| M4 | B columns and rows swapped | T1, T4 | killed |
| M5 | FSM stuck in DONE | T6 | killed |
| M6 | PE valid register not reset | – | survives (equivalent) |
| M7 | wrong shift in the split multiplier | T2, T4 | killed |
| M8 | row tag off by one | T4 | killed |
| M9 | `busy` stuck low | T10 | killed |
| M10 | adder drops one term | T4 | killed |

M6 is an equivalent mutant, not a test gap: `feed_v` is 0 throughout reset, so the valid shift
register fills with zeros within LAT cycles whether or not the reset is present. The reset is
kept because it removes the dependence on the reset lasting LAT cycles.

Pass criterion: `killed 9 / 10`, with only M6 surviving.

## Generic synthesis

```bash
make synth-check N=4 SPLIT_MUL=0          # statistics in build/synth_stat.txt
```

Technology-independent Yosys `synth -flatten`, used as a structural check before committing to
a PDK.

| Configuration | Generic cells | Flops |
|---|---|---|
| N=4, SPLIT_MUL=0 | 61,315 | 2,836 |
| N=4, SPLIT_MUL=1 | ~61.3k | ~3.6k |

Pass criteria: no errors; **zero latches** (`$_DLATCH` count 0); flop count consistent with the
architecture — 3·N²·DW of storage plus the PE pipeline registers.

## Generic gate-level simulation

```bash
make gls-generic N=4
```

Synthesizes each mode to generic gates and runs the **same testbench** against the netlist with
`+define+GLS`, using Yosys `simcells.v`. This catches simulation/synthesis mismatches — missing
sensitivity, inferred latches, X-dependent behaviour — that RTL simulation cannot.

```
GLS: PASS: 489 checks, N=4 DW=32 SPLIT_MUL=0
GLS: PASS: 489 checks, N=4 DW=32 SPLIT_MUL=1
```

The count is one lower than RTL simulation because the whitebox T0 check is skipped.

---

## Post-layout simulation

The same testbench again, now against the routed netlist with real SKY130 cell models — first
functionally, then with SDF back-annotated delays from OpenSTA.

```bash
# functional: -DFUNCTIONAL cell models, unit delay
make gls-sky130 WORK_HOME=$WORK_HOME FLOW_VARIANT=base
make gls-sky130 WORK_HOME=$WORK_HOME FLOW_VARIANT=p8_split SPLIT_MUL=1

# SDF: write it from OpenSTA (see implementation.md), then simulate at the target period
make gls-sky130 WORK_HOME=$WORK_HOME FLOW_VARIANT=base \
  SDF=build/mm_accel_base_tt.sdf HALF_PERIOD=6 RD_SETTLE=7
```

`N` and `SPLIT_MUL` must match the flow run — they are baked into the netlist. `RD_SETTLE` is
the delay between driving `raddr` and sampling the combinational `rdata`: 1 ns for zero-delay
runs, the SDC's 60 % I/O budget (7 ns at a 12 ns period) for SDF runs.

### Results — `base` variant

| Run | Result |
|---|---|
| functional, `SPLIT_MUL=0` | PASS 489 |
| functional, `SPLIT_MUL=1` (`p8_split` netlist) | PASS 489 |
| SDF @ 12 ns — the target period | **PASS 489** |
| SDF @ 10 ns | PASS 489 |
| SDF @ 8 ns | PASS 489 |
| SDF @ 6 ns | **FAIL 381 / 489** |

Full output: [`reports/gls_postlayout_base.txt`](reports/gls_postlayout_base.txt).

The 6 ns run is a deliberate control. A design whose critical path arrives at 9.48 ns cannot
work at a 6 ns period, and it does not — the first failure is T2 (all-ones operands, the
heaviest multiplier switching), while T1 (identity, trivial switching) still passes. That
asymmetry confirms the annotated delays are genuinely in effect.

The 8 ns pass, where STA reports negative slack for this netlist, is the expected
STA-versus-simulation gap: STA is worst-case across all input transitions, while simulation
exercises only the transitions the testbench generates.

### Scope and limitations

Delays from the SDF — both IOPATH and interconnect — are applied. Setup, hold, recovery and
width **checks are not performed**: Icarus Verilog does not implement timing checks. A path that
is too slow therefore appears as an incorrect result rather than a timing-check violation.
Check-based post-layout simulation would require a simulator implementing `$setuphold` and
`$recrem`.

Three adaptations are required for Icarus and are applied automatically by `make gls-sky130`:

| Issue | Handled by |
|---|---|
| The SKY130 flop models drive their UDPs from `*_delayed` wires that only a timing-check implementation would drive, so every flop outputs X | `scripts/sky130_icarus_sdf_lib.py` generates a library copy tying `X_delayed` to `X` |
| The models' specify paths are edge-sensitive (`posedge CLK => (Q : CLK)`) while OpenSTA emits `(IOPATH CLK Q ...)`; Icarus matches neither and applies zero delay | the same script rewrites them level-sensitive |
| Icarus splits SDF instance names on `.` even when escaped, leaving ~1,300 flops unannotated | `scripts/sdf_dedot.py` rewrites netlist and SDF with `_` |
| OpenSTA writes `(min::max)` with an empty typical value; Icarus selects typical by default, yielding zero delay silently | `iverilog -Tmax` |

The functional runs require none of this.
