#!/usr/bin/env python3
"""Extract B1 best IPC from batch run eval files."""
import os, re, sys

run_dir = sys.argv[1] if len(sys.argv) > 1 else "artifacts/runs/l1d-baseline-batch/20260801-121706"
champsim_root = os.path.abspath(os.path.join(os.path.dirname(__file__), "..", ".."))
run_dir = os.path.join(champsim_root, run_dir) if not os.path.isabs(run_dir) else run_dir

ipc_re = re.compile(r"cumulative IPC:\s*([\d.]+)")

print(f"{'Trace':<22} {'B0':>8} {'B1':>8} {'B2':>8} {'B1_name':<16} {'B2>B1':>6}")
print("-" * 75)

b2_wins = 0
total = 0

for tname in sorted(os.listdir(run_dir)):
    tdir = os.path.join(run_dir, tname)
    if not os.path.isdir(tdir) or tname.startswith("."):
        continue
    eval_dir = os.path.join(tdir, "eval")
    if not os.path.isdir(eval_dir):
        continue

    total += 1
    b0_ipc = b2_ipc = 0.0
    best_ipc = 0.0
    best_name = ""

    for fn in os.listdir(eval_dir):
        if not fn.endswith(".txt"):
            continue
        path = os.path.join(eval_dir, fn)
        with open(path) as f:
            text = f.read()
        matches = ipc_re.findall(text)
        if not matches:
            continue
        ipc = float(matches[-1])

        if fn == "b0_no.txt":
            b0_ipc = ipc
        elif fn == "b2_hint.txt":
            b2_ipc = ipc
        else:
            if ipc > best_ipc:
                best_ipc = ipc
                best_name = fn.replace(".txt", "")

    verdict = "Y" if b2_ipc > best_ipc else "N"
    if b2_ipc > best_ipc:
        b2_wins += 1

    print(f"{tname:<22} {b0_ipc:>8.4f} {best_ipc:>8.4f} {b2_ipc:>8.4f} {best_name:<16} {verdict:>6}")

print("-" * 75)
print(f"B2 > B1: {b2_wins} / {total} traces")
