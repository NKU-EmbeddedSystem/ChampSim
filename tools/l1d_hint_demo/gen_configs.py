#!/usr/bin/env python3
"""Generate L1D-only profiling configs for each (prefetcher, degree) combination."""

import json
import os
import sys

CHAMPSIM_ROOT = os.path.dirname(os.path.dirname(os.path.dirname(os.path.abspath(__file__))))
OUTPUT_DIR = os.path.join(CHAMPSIM_ROOT, "configs", "l1d-profile")

# Candidate set: 4 families x 3 degree tiers (low/mid/high) + 'no' baseline.
# Must match enum class PrefetchPolicy in prefetcher/hint_dispatch/hint_dispatch.h
# and PREFETCH_POLICIES in tools/l1d_hint_demo/oracle_gen.py.
PROFILING_MATRIX = {
    "sandbox": [1, 4, 8],
    "dspatch": [1, 16, 64],
    "mlop": [1, 8, 16],
    "stream": [1, 4, 8],
    "no": [1],  # B0 baseline only — not part of the 12-policy hint candidate set
}

DEGREE_MACROS = {
    "sandbox": "SANDBOX_PREF_DEGREE",
    "dspatch": "DSPATCH_PREF_DEGREE",
    "mlop": "MLOP_PREF_DEGREE",
    "stream": "STREAM_PREF_DEGREE",
}

BASE_CONFIG = {
    "block_size": 64,
    "page_size": 4096,
    "heartbeat_frequency": 10000000,
    "num_cores": 1,
    "ooo_cpu": [{
        "frequency": 4000, "ifetch_buffer_size": 64, "decode_buffer_size": 32,
        "dispatch_buffer_size": 32, "register_file_size": 128, "rob_size": 352,
        "lq_size": 128, "sq_size": 72, "fetch_width": 6, "decode_width": 6,
        "dispatch_width": 6, "execute_width": 4, "lq_width": 2, "sq_width": 2,
        "retire_width": 5, "mispredict_penalty": 1, "scheduler_size": 128,
        "decode_latency": 1, "dispatch_latency": 1, "schedule_latency": 0,
        "execute_latency": 0, "branch_predictor": "bimodal", "btb": "basic_btb"
    }],
    "DIB": {"window_size": 16, "sets": 32, "ways": 8},
    "L1I": {
        "sets": 64, "ways": 8, "rq_size": 64, "wq_size": 64, "pq_size": 32,
        "mshr_size": 8, "latency": 4, "max_tag_check": 2, "max_fill": 2,
        "prefetch_as_load": False, "virtual_prefetch": True,
        "prefetch_activate": "LOAD,PREFETCH", "prefetcher": "no"
    },
    "L1D": {
        "sets": 64, "ways": 12, "rq_size": 64, "wq_size": 64, "pq_size": 8,
        "mshr_size": 16, "latency": 5, "max_tag_check": 2, "max_fill": 2,
        "prefetch_as_load": False, "virtual_prefetch": False,
        "prefetch_activate": "LOAD,PREFETCH"
    },
    "L2C": {
        "sets": 1024, "ways": 8, "rq_size": 32, "wq_size": 32, "pq_size": 16,
        "mshr_size": 32, "latency": 10, "max_tag_check": 1, "max_fill": 1,
        "prefetch_as_load": False, "virtual_prefetch": False,
        "prefetch_activate": "LOAD,PREFETCH", "prefetcher": "no"
    },
    "ITLB": {"sets": 16, "ways": 4, "rq_size": 16, "wq_size": 16, "pq_size": 0, "mshr_size": 8, "latency": 1, "max_tag_check": 2, "max_fill": 2, "prefetch_as_load": False},
    "DTLB": {"sets": 16, "ways": 4, "rq_size": 16, "wq_size": 16, "pq_size": 0, "mshr_size": 8, "latency": 1, "max_tag_check": 2, "max_fill": 2, "prefetch_as_load": False},
    "STLB": {"sets": 128, "ways": 12, "rq_size": 32, "wq_size": 32, "pq_size": 0, "mshr_size": 16, "latency": 8, "max_tag_check": 1, "max_fill": 1, "prefetch_as_load": False},
    "PTW": {"pscl5_set": 1, "pscl5_way": 2, "pscl4_set": 1, "pscl4_way": 4, "pscl3_set": 2, "pscl3_way": 4, "pscl2_set": 4, "pscl2_way": 8, "rq_size": 16, "mshr_size": 5, "max_read": 2, "max_write": 2},
    "LLC": {
        "frequency": 4000, "sets": 2048, "ways": 16, "rq_size": 32, "wq_size": 32,
        "pq_size": 32, "mshr_size": 64, "latency": 20, "max_tag_check": 1, "max_fill": 1,
        "prefetch_as_load": False, "virtual_prefetch": False,
        "prefetch_activate": "LOAD,PREFETCH", "prefetcher": "no", "replacement": "lru"
    },
    "physical_memory": {
        "data_rate": 3200, "channels": 1, "ranks": 1, "bankgroups": 8, "banks": 4,
        "bank_rows": 65536, "bank_columns": 1024, "channel_width": 8,
        "wq_size": 64, "rq_size": 64, "tCAS": 24, "tRCD": 24, "tRP": 24, "tRAS": 52,
        "refresh_period": 32, "refreshes_per_period": 8192
    },
    "virtual_memory": {"pte_page_size": 4096, "num_levels": 5, "minor_fault_penalty": 200, "randomization": 1},
}


def generate():
    import copy
    import glob
    os.makedirs(OUTPUT_DIR, exist_ok=True)
    configs = []

    expected = {f"champsim_l1d_{pref}_d{deg}.json"
                for pref, degrees in PROFILING_MATRIX.items() for deg in degrees}
    for stale in glob.glob(os.path.join(OUTPUT_DIR, "champsim_l1d_*.json")):
        if os.path.basename(stale) not in expected:
            os.remove(stale)

    for pref, degrees in PROFILING_MATRIX.items():
        for deg in degrees:
            cfg = copy.deepcopy(BASE_CONFIG)
            name = f"champsim_l1d_{pref}_d{deg}"
            cfg["executable_name"] = name

            if pref == "no":
                cfg["L1D"]["prefetcher"] = "no"
            else:
                cfg["L1D"]["prefetcher"] = {"path": pref, "class": pref}

            path = os.path.join(OUTPUT_DIR, f"{name}.json")
            with open(path, "w") as f:
                json.dump(cfg, f, indent=2)

            macro = DEGREE_MACROS.get(pref)
            # NOTE: the macro is injected for every degree, including 1 — the
            # code-default degrees are 4/8/4/4, NOT 1, so "d1" builds must pin
            # the macro explicitly or they silently run at the default.
            configs.append({
                "name": name,
                "prefetcher": pref,
                "degree": deg,
                "config_path": path,
                "degree_macro": f"-D{macro}={deg}" if macro else None,
            })

    manifest_path = os.path.join(OUTPUT_DIR, "manifest.json")
    with open(manifest_path, "w") as f:
        json.dump(configs, f, indent=2)

    print(f"Generated {len(configs)} configs in {OUTPUT_DIR}")
    print(f"Manifest: {manifest_path}")
    return configs


if __name__ == "__main__":
    generate()
