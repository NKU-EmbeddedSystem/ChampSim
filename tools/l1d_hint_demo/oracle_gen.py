#!/usr/bin/env python3
"""Generate binary hint file from aggregated ground truth labels."""

import argparse
import json
import struct
import sys

HINT_MAGIC = 0x544E4948
HINT_VERSION = 1
ENTRY_STRUCT = struct.Struct("<QBBBB4x")

# Candidate set: 4 families x 3 degree tiers (low/mid/high).
# Must match enum class PrefetchPolicy in prefetcher/hint_dispatch/hint_dispatch.h
# and PROFILING_MATRIX in tools/l1d_hint_demo/gen_configs.py.
PREFETCH_POLICIES = {
    'sandbox_d1': 0, 'sandbox_d4': 1, 'sandbox_d8': 2,
    'dspatch_d1': 3, 'dspatch_d16': 4, 'dspatch_d64': 5,
    'mlop_d1': 6, 'mlop_d8': 7, 'mlop_d16': 8,
    'stream_d1': 9, 'stream_d4': 10, 'stream_d8': 11,
}


def policy_index(pref_name: str, degree) -> int:
    """Map a (family, degree) ground-truth label to a policy index.

    Accepts both the combined form ('sandbox_d4') and the split form
    (best_prefetch='sandbox', best_degree=4). Raises on labels outside the
    12-combination candidate set.
    """
    key = pref_name if f"{pref_name}_d{degree}" not in PREFETCH_POLICIES else f"{pref_name}_d{degree}"
    if key not in PREFETCH_POLICIES:
        raise ValueError(f"label ({pref_name!r}, degree {degree}) is not in the 12-policy candidate set")
    return PREFETCH_POLICIES[key]


# dspatch is exempt from the filter marking (per design decision)
FILTER_EXEMPT_FAMILIES = {"dspatch"}


def worst_policy_filter(rec, selected_idx) -> int:
    """Compute the filter byte for one ground-truth record.

    Uses the no-prefetcher run ('no:1') as the reference: a candidate is
    only worth filtering out when it is strictly WORSE than not
    prefetching at all for this PC. filter = worst_idx + 1 (0 = no
    filter); dspatch-family worsts are left unmarked (design exception).

    Conditions for marking:
    - candidate AMAT > no-prefetcher AMAT (prefetching actively hurts)
    - candidate != the selected policy (a PC must not be blocked from
      training its own chosen prefetcher)
    - AMAT == 0 entries mean "no measurable data" and are ignored.
    """
    all_amats = rec.get("all_amats") or {}
    no_amat = float(all_amats.get("no:1", 0.0))
    if no_amat <= 0.0:
        return 0  # no usable no-prefetch reference for this PC
    cands = []
    for key, amat in all_amats.items():
        try:
            pf, deg = key.rsplit(":", 1)
            idx = policy_index(pf, int(deg))
        except (ValueError, IndexError):
            continue  # 'no' or stale labels — not filter candidates
        if float(amat) <= 0.0:
            continue  # no measurable data under this policy
        cands.append((float(amat), idx, pf))
    if not cands:
        return 0
    # Strictly worse than no-prefetcher, not the selected policy, not
    # exempt (dspatch); pick the worst among those.
    harmful = [c for c in cands
               if c[0] > no_amat and c[1] != selected_idx
               and c[2] not in FILTER_EXEMPT_FAMILIES]
    if not harmful:
        return 0
    harmful.sort()
    return harmful[-1][1] + 1


def best_candidate_index(rec) -> int:
    """Best policy index for one ground-truth record.

    'no' (and any label outside the 12-combination candidate set) cannot be
    dispatched by hint_dispatch; fall back to the best-AMAT candidate from
    all_amats that IS in the candidate set.
    """
    pref_name = rec.get("best_prefetch", "no")
    degree = int(rec.get("best_degree", 1))
    try:
        return policy_index(pref_name, degree), degree
    except ValueError:
        pass
    cands = []
    for key, amat in (rec.get("all_amats") or {}).items():
        try:
            pf, deg = key.rsplit(":", 1)
            idx = policy_index(pf, int(deg))
        except (ValueError, IndexError):
            continue
        if float(amat) <= 0.0:
            continue  # no measurable data under this policy
        cands.append((float(amat), idx, int(deg)))
    if not cands:
        return 0, 1  # sandbox_d1 (lowest tier) as last resort
    _, idx, deg = min(cands)
    return idx, deg


def generate(labels_path: str, output_path: str, use_filter: bool = False):
    entries = []
    with open(labels_path) as f:
        for line in f:
            line = line.strip()
            if not line:
                continue
            rec = json.loads(line)
            pc_str = rec["pc"]
            pc = int(pc_str, 16) if isinstance(pc_str, str) else int(pc_str)
            pref_idx, degree = best_candidate_index(rec)
            filt = worst_policy_filter(rec, pref_idx) if use_filter else int(rec.get("filter_policy", 0))
            entries.append((pc, pref_idx, degree, filt))

    entries.sort(key=lambda e: e[0])

    with open(output_path, "wb") as f:
        f.write(struct.pack("<IIII", HINT_MAGIC, HINT_VERSION, len(entries), 0))
        for pc, pref_idx, degree, filt in entries:
            f.write(ENTRY_STRUCT.pack(pc, 0, pref_idx, degree, filt))

    print(f"Wrote {len(entries)} hint entries to {output_path}")
    if use_filter:
        n = sum(1 for e in entries if e[3] > 0)
        print(f"Filter marking: {n}/{len(entries)} PCs ({100*n/max(len(entries),1):.1f}%) carry a worst-policy filter")

    from collections import Counter
    idx_to_name = {v: k for k, v in PREFETCH_POLICIES.items()}
    dist = Counter(idx_to_name[e[1]] for e in entries)
    print("Prefetcher distribution:")
    for name, count in dist.most_common():
        print(f"  {name}: {count} PCs ({100*count/len(entries):.1f}%)")


def validate(path: str):
    with open(path, "rb") as f:
        magic, version, count, _ = struct.unpack("<IIII", f.read(16))
        assert magic == HINT_MAGIC, f"Bad magic: 0x{magic:08X}"
        assert version == HINT_VERSION, f"Bad version: {version}"
        print(f"Valid hint file: {count} entries (version {version})")
        idx_to_name = {v: k for k, v in PREFETCH_POLICIES.items()}
        for i in range(min(count, 5)):
            pc, repl, pref, degree, filt = ENTRY_STRUCT.unpack(f.read(16))
            filt_str = f"filter={idx_to_name.get(filt-1, filt-1)}" if filt > 0 else "filter=none"
            print(f"  PC=0x{pc:016X} pref={idx_to_name.get(pref, pref)} degree={degree} {filt_str}")


if __name__ == "__main__":
    parser = argparse.ArgumentParser()
    sub = parser.add_subparsers(dest="cmd", required=True)

    gen = sub.add_parser("generate")
    gen.add_argument("--labels", required=True)
    gen.add_argument("--output", default="hint.bin")
    gen.add_argument("--filter", action="store_true",
                     help="mark each PC's worst-AMAT policy in the filter byte "
                          "(dspatch worsts left unmarked); runtime skips training "
                          "that prefetcher with this PC's demand accesses")

    val = sub.add_parser("validate")
    val.add_argument("--input", required=True)

    args = parser.parse_args()
    if args.cmd == "generate":
        generate(args.labels, args.output, use_filter=getattr(args, "filter", False))
    elif args.cmd == "validate":
        validate(args.input)
