#!/usr/bin/env python3
"""
Post-process raw simulation outputs into structured JSON + geomean comparison table.
Follows multi-run convention: saves results under reports/<run-name>/.
"""
import json, os, re, math, sys, glob
from collections import defaultdict

def extract_ipc(raw_path):
    """Extract final cumulative IPC from a ChampSim raw output file."""
    if not os.path.exists(raw_path):
        return None
    try:
        with open(raw_path) as f:
            for line in f:
                m = re.search(r'cumulative IPC:\s*([\d.]+)', line)
                if m:
                    return float(m.group(1))
    except:
        pass
    return None

def geomean(vals):
    if not vals: return 0
    return math.exp(sum(math.log(v) for v in vals if v > 0) / len(vals))

def main():
    if len(sys.argv) < 2:
        print("Usage: generate_comparison_report.py <run_dir> [report_name]")
        sys.exit(1)

    run_dir = sys.argv[0]
    report_name = sys.argv[2] if len(sys.argv) > 2 else "comparison"

    # Detect run directory
    stage_dir = os.path.dirname(os.path.dirname(os.path.abspath(__file__)))
    reports_dir = os.path.join(stage_dir, "reports", report_name)
    os.makedirs(reports_dir, exist_ok=True)

    # Configuration detection
    raw_files = glob.glob(os.path.join(run_dir, "*.raw"))
    if not raw_files:
        # Try latest symlink
        latest = os.path.join(os.path.dirname(run_dir), "latest")
        if os.path.islink(latest):
            run_dir = os.path.realpath(latest)
            raw_files = glob.glob(os.path.join(run_dir, "*.raw"))

    print(f"Processing {len(raw_files)} raw files from {run_dir}")

    # Parse filenames: {benchmark}_{config}_{policy}.raw
    results = defaultdict(lambda: defaultdict(dict))  # config -> policy -> [ipcs]
    per_benchmark = defaultdict(lambda: defaultdict(dict))  # benchmark -> config -> policy -> ipc

    for f in sorted(raw_files):
        basename = os.path.basename(f).replace('.raw', '')
        # Split: benchmark_config_policy (config may contain '+')
        # Find the policy suffix
        policies = ['rpp', 'mockingjay', 'lru']
        policy = None
        for p in policies:
            if basename.endswith('_' + p):
                policy = p
                break
        if not policy:
            continue

        # Everything before _policy is benchmark_config
        prefix = basename[:-(len(policy)+1)]

        # Find benchmark name (first segment)
        benchmarks = ['astar','cactusADM','h264ref','libquantum','mcf','milc',
                      'omnetpp','perlbench','soplex','sphinx3','xalancbmk','zeusmp']
        bmark = None
        for b in benchmarks:
            if prefix.startswith(b + '_'):
                bmark = b
                break
        if not bmark:
            continue

        config = prefix[len(bmark)+1:]  # e.g. "Rnd+Nomig+NoPF"

        ipc = extract_ipc(f)
        if ipc is None:
            print(f"  WARNING: no IPC found in {basename}")
            continue

        results[config][policy].append(ipc)
        per_benchmark[bmark][config][policy] = ipc
        print(f"  {basename}: IPC={ipc:.4f}")

    # ── Structured JSON output ──
    json_output = {
        "geomean": {},
        "per_benchmark": {},
    }

    for config, policies_data in sorted(results.items()):
        json_output["geomean"][config] = {}
        for policy, ipcs in sorted(policies_data.items()):
            gm = geomean(ipcs)
            json_output["geomean"][config][policy] = round(gm, 4)

    for bmark, configs in sorted(per_benchmark.items()):
        json_output["per_benchmark"][bmark] = {}
        for config, policies in sorted(configs.items()):
            json_output["per_benchmark"][bmark][config] = {}
            for policy, ipc in sorted(policies.items()):
                json_output["per_benchmark"][bmark][config][policy] = round(ipc, 4)

    # Save JSON
    json_path = os.path.join(reports_dir, "results.json")
    with open(json_path, 'w') as f:
        json.dump(json_output, f, indent=2)
    print(f"\nSaved: {json_path}")

    # ── Geomean comparison table (Markdown) ──
    md_lines = []
    md_lines.append("# 3-Config Comparison: Random vs Sort-Heat vs FCFS")
    md_lines.append("")
    md_lines.append("**Warmup:** 50M | **Sim:** 100M | **DRAM:CXL:** 1:2 | **No Prefetch, No Migration**")
    md_lines.append("")
    md_lines.append("## Geomean IPC (12 benchmarks)")
    md_lines.append("")
    md_lines.append("| Config | LRU | MJ | RPP | MJ/LRU | RPP/LRU | RPP/MJ |")
    md_lines.append("|--------|-----|----|-----|--------|---------|--------|")

    for config in sorted(results.keys()):
        data = json_output["geomean"][config]
        lru = data.get('lru', 0)
        mj = data.get('mockingjay', 0)
        rpp = data.get('rpp', 0)
        mj_lru = mj / lru if lru > 0 else 0
        rpp_lru = rpp / lru if lru > 0 else 0
        rpp_mj = rpp / mj if mj > 0 else 0
        md_lines.append(f"| {config} | {lru:.4f} | {mj:.4f} | {rpp:.4f} | {mj_lru:.4f} | {rpp_lru:.4f} | {rpp_mj:.4f} |")

    # Per-benchmark RPP IPC table
    md_lines.append("")
    md_lines.append("## Per-Benchmark RPP IPC")
    md_lines.append("")
    configs_list = sorted(results.keys())
    hdr = "| Benchmark | " + " | ".join(configs_list) + " |"
    md_lines.append(hdr)
    md_lines.append("|" + "|".join(["-----------"] * (len(configs_list) + 1)) + "|")

    benchmarks_sorted = sorted(per_benchmark.keys())
    for bmark in benchmarks_sorted:
        row = f"| {bmark} |"
        for config in configs_list:
            ipc = per_benchmark[bmark].get(config, {}).get('rpp', 'N/A')
            if isinstance(ipc, float):
                row += f" {ipc:.4f} |"
            else:
                row += f" {ipc} |"
        md_lines.append(row)

    # Save Markdown
    md_path = os.path.join(reports_dir, "COMPARISON.md")
    with open(md_path, 'w') as f:
        f.write('\n'.join(md_lines))
    print(f"Saved: {md_path}")

    # Print to stdout
    print("\n" + "\n".join(md_lines))

if __name__ == '__main__':
    main()
