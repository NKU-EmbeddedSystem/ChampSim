#!/usr/bin/env python3
"""Generate bandwidth-constrained config variants for all L1D profiling configs."""
import json, os, copy, sys

champsim_root = os.path.abspath(os.path.join(os.path.dirname(__file__), "..", ".."))
src_dir = os.path.join(champsim_root, "configs", "l1d-profile")

BW_LEVELS = {
    "bw3200": 3200,   # baseline (unlimited)
    "bw1600": 1600,   # constrained
    "bw800":  800,    # severe
}

BASE_DATA_RATE = 3200
# DRAM timing parameters in the configs are in memory-controller clock cycles,
# not nanoseconds (see config/instantiation_file.py + dram_controller.cc: the raw
# value is multiplied by mc_period). Scale them with data_rate so the *absolute*
# latency stays constant and only bandwidth changes between BW levels.
TIMING_KEYS = ("tCAS", "tRCD", "tRP", "tRAS")

def scale_timings(cfg, data_rate):
    pmem = cfg["physical_memory"]
    for key in TIMING_KEYS:
        pmem[key] = max(1, round(pmem[key] * data_rate / BASE_DATA_RATE))

out_base = os.path.join(champsim_root, "configs", "l1d-bw")
os.makedirs(out_base, exist_ok=True)

manifest = []

# degree_macro per source config (name -> macro), from the l1d-profile manifest
src_manifest_path = os.path.join(src_dir, "manifest.json")
degree_macros = {}
if os.path.isfile(src_manifest_path):
    with open(src_manifest_path) as f:
        for e in json.load(f):
            degree_macros[e["name"]] = e.get("degree_macro")

for bw_name, data_rate in BW_LEVELS.items():
    out_dir = os.path.join(out_base, bw_name)
    os.makedirs(out_dir, exist_ok=True)

    # Drop stale variants from earlier candidate sets (e.g. the 15-policy runs)
    for fn in os.listdir(out_dir):
        if fn.startswith("champsim_l1d_") and fn.endswith(".json"):
            src_exists = os.path.exists(os.path.join(src_dir, fn))
            if not src_exists:
                os.remove(os.path.join(out_dir, fn))

    for fn in sorted(os.listdir(src_dir)):
        if not fn.endswith(".json") or fn == "manifest.json":
            continue
        with open(os.path.join(src_dir, fn)) as f:
            cfg = json.load(f)

        cfg["physical_memory"]["data_rate"] = data_rate
        scale_timings(cfg, data_rate)
        old_name = cfg["executable_name"]
        new_name = f"{old_name}_{bw_name}"
        cfg["executable_name"] = new_name

        out_path = os.path.join(out_dir, fn)
        with open(out_path, "w") as f:
            json.dump(cfg, f, indent=2)

        manifest.append({
            "name": new_name,
            "config_path": out_path,
            "bw_level": bw_name,
            "data_rate": data_rate,
            "base_prefetcher": old_name.replace("champsim_l1d_", ""),
            "degree_macro": degree_macros.get(old_name),
        })

# Also generate bw-variant configs for champsim_no and champsim_hint_eval
for bw_name, data_rate in BW_LEVELS.items():
    if bw_name == "bw3200":
        continue
    out_dir = os.path.join(out_base, bw_name)

    # champsim_no variant
    no_cfg_path = os.path.join(champsim_root, "configs", "stage1", "champsim_config_no.json")
    with open(no_cfg_path) as f:
        cfg = json.load(f)
    cfg["physical_memory"]["data_rate"] = data_rate
    scale_timings(cfg, data_rate)
    cfg["executable_name"] = f"champsim_no_{bw_name}"
    out_path = os.path.join(out_dir, "champsim_config_no.json")
    with open(out_path, "w") as f:
        json.dump(cfg, f, indent=2)
    manifest.append({"name": f"champsim_no_{bw_name}", "config_path": out_path, "bw_level": bw_name, "data_rate": data_rate, "base_prefetcher": "no_baseline"})

    # champsim_hint_eval variant
    hint_cfg_path = os.path.join(champsim_root, "configs", "stage1", "champsim_config_hint_eval.json")
    with open(hint_cfg_path) as f:
        cfg = json.load(f)
    cfg["physical_memory"]["data_rate"] = data_rate
    scale_timings(cfg, data_rate)
    cfg["executable_name"] = f"champsim_hint_eval_{bw_name}"
    out_path = os.path.join(out_dir, "champsim_config_hint_eval.json")
    with open(out_path, "w") as f:
        json.dump(cfg, f, indent=2)
    manifest.append({"name": f"champsim_hint_eval_{bw_name}", "config_path": out_path, "bw_level": bw_name, "data_rate": data_rate, "base_prefetcher": "hint_eval"})

manifest_path = os.path.join(out_base, "manifest.json")
with open(manifest_path, "w") as f:
    json.dump(manifest, f, indent=2)

print(f"Generated {len(manifest)} configs across {len(BW_LEVELS)} bandwidth levels")
print(f"Output: {out_base}")
print(f"Manifest: {manifest_path}")
