#!/usr/bin/env python3
"""Run the ORFS flow across clock periods / sizes and tabulate PPA.

Example:
  python3 scripts/sweep.py --periods 10 12 15 --sizes 2 4 --out results/sweep.csv

Extra ORFS make variables can be passed through ORFS_EXTRA, e.g. ORFS_EXTRA="LEC_CHECK=0".
"""
import argparse, csv, os, shlex, subprocess, sys
sys.path.insert(0, os.path.dirname(__file__))
from parse_reports import collect

REPO = os.path.abspath(os.path.join(os.path.dirname(__file__), ".."))

def run(period, n, dw, util, split, flow_home, work_home):
    variant = f"n{n}_dw{dw}_s{split}_p{str(period).replace('.', 'p')}_u{util}"
    cmd = ["make", "-C", REPO, "asic",
           f"CLOCK_PERIOD={period}", f"MM_N={n}", f"MM_DW={dw}",
           f"CORE_UTILIZATION={util}", f"FLOW_VARIANT={variant}",
           f"SPLIT_MUL={split}",
           f"FLOW_HOME={flow_home}", f"WORK_HOME={work_home}"]
    cmd += shlex.split(os.environ.get("ORFS_EXTRA", ""))
    print(">>", " ".join(cmd), flush=True)
    ok = subprocess.run(cmd).returncode == 0
    base = os.path.join(work_home, "{}", "sky130hd", "mm_accel", variant)
    row = collect(base.format("logs"), base.format("reports"))
    row.update(variant=variant, period_ns=period, N=n, DW=dw, util_target=util, split_mul=split,
               flow_ok=ok)
    if row.get("wns_ns") is not None:
        # Achievable period = target minus slack, for slack of either sign: positive slack
        # means the design could run faster than the target. Same as OpenROAD's period_min.
        row["fmax_mhz_est"] = round(1000.0 / (period - float(row["wns_ns"])), 2)
    return row

def main():
    ap = argparse.ArgumentParser()
    ap.add_argument("--periods", nargs="+", type=float, default=[12.0])
    ap.add_argument("--sizes", nargs="+", type=int, default=[4])
    ap.add_argument("--dw", type=int, default=32)
    ap.add_argument("--utils", nargs="+", type=int, default=[35])
    ap.add_argument("--split", nargs="+", type=int, default=[0])
    ap.add_argument("--work-home", default=os.environ.get("WORK_HOME", ""))
    ap.add_argument("--flow-home", default=os.environ.get("FLOW_HOME", ""))
    ap.add_argument("--out", default="results/sweep.csv")
    a = ap.parse_args()
    if not a.flow_home:
        sys.exit("set --flow-home or FLOW_HOME to OpenROAD-flow-scripts/flow")
    work = a.work_home or a.flow_home
    rows = [run(p, n, a.dw, u, s, a.flow_home, work)
            for n in a.sizes for s in a.split for p in a.periods for u in a.utils]
    os.makedirs(os.path.dirname(a.out) or ".", exist_ok=True)
    keys = sorted({k for r in rows for k in r})
    with open(a.out, "w", newline="") as fh:
        w = csv.DictWriter(fh, fieldnames=keys); w.writeheader(); w.writerows(rows)
    print(f"wrote {a.out} ({len(rows)} runs)")

if __name__ == "__main__":
    main()
