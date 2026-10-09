#!/usr/bin/env bash
# mutate.sh — inject known bugs into copies of the RTL and confirm the
# testbench catches each one. Expected: every mutant FAILs except M6
# (equivalent mutant: feed_v is 0 during reset, so the valid pipe flushes anyway).
set -u
cd "$(dirname "$0")/.."
W=$(mktemp -d); trap 'rm -rf "$W"' EXIT
pass=0; fail=0; survivors=""

mut() { # name file sed-expr [iverilog-extra]
  local name=$1 file=$2 expr=$3 extra=${4:-}
  cp rtl/*.sv "$W/"
  sed -i "$expr" "$W/$file"
  if cmp -s "rtl/$file" "$W/$file"; then echo "  $name: MUTATION NOT APPLIED"; fail=$((fail+1)); survivors+=" $name(not-applied)"; return; fi
  iverilog -g2012 $extra -s tb_mm_accel -o "$W/sim" "$W"/*.sv tb/tb_mm_accel.sv 2>/dev/null
  local r; r=$(vvp -n "$W/sim" | grep -E '^(PASS|FAIL)' | head -1)
  if [[ $r == FAIL* ]]; then echo "  killed   $name"; pass=$((pass+1));
  else echo "  SURVIVED $name"; fail=$((fail+1)); survivors+=" $name"; fi
}

mut M1_no_A_load_guard  mm_accel.sv 's/if (state == S_IDLE \&\& we_a)/if (we_a)/'
mut M2_no_B_load_guard  mm_accel.sv 's/if (state == S_IDLE \&\& we_b)/if (we_b)/'
mut M3_early_done       mm_accel.sv 's/if (out_cnt == N_LAST) state <= S_DONE;/if (out_cnt == N_LAST - 1'"'"'b1) state <= S_DONE;/'
mut M4_transposed_B     mm_accel.sv 's/mem_b\[(k\*N + j)\*DW +: DW\]/mem_b[(j*N + k)*DW +: DW]/'
mut M5_done_stuck       mm_accel.sv 's/default: state <= S_IDLE;/default: state <= S_DONE;/'
mut M6_valid_no_reset   mm_pe.sv    "s/if (!rst_n) v_sr <= '0;/if (1'b0) v_sr <= '0;/"
mut M7_split_shift      mm_pe.sv    's/(ph_q\[k\*DW +: DW\] << H)/(ph_q[k*DW +: DW] << (H-1))/' "-P tb_mm_accel.SPLIT_MUL=1"
mut M8_tag_off_by_one   mm_accel.sv "s/tag_sr <= {tag_sr\[(LAT-1)\*RW-1:0\], feed_cnt}/tag_sr <= {tag_sr[(LAT-1)*RW-1:0], feed_cnt + 1'b1}/"
mut M9_busy_stuck_low   mm_accel.sv "s/assign busy   = (state == S_RUN);/assign busy   = 1'b0;/"
mut M10_adder_skip      mm_pe.sv    's/for (int k = 0; k < N; k++) sum_c = sum_c + prod_q/for (int k = 1; k < N; k++) sum_c = sum_c + prod_q/'

echo "killed $pass / $((pass+fail))  (M6 is expected to survive)"
# Exactly the equivalent mutant may survive; anything else fails the build.
[[ $survivors == " M6_valid_no_reset" ]] || { echo "FAIL: unexpected survivors:$survivors"; exit 1; }
