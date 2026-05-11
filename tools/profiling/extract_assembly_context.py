#!/usr/bin/env python3
"""
Extract assembly context (surrounding instructions) for a list of Load PCs.

Input:
  --index     : JSON from parse_disassembly.py (PC→instruction mapping)
  --load-pcs  : JSON from trace_reader.py (list of Load PC hex strings)
  --before N  : Number of instructions before the Load PC (default 8)
  --after N   : Number of instructions after the Load PC (default 4)

Output: JSONL file, one line per Load PC:
  {"pc": "0x4c36f3", "load_insn": "mov rax, QWORD PTR [rbp-0x10]",
   "function": "Perl_pp_add", "context_before": [...], "context_after": [...]}
"""

import argparse
import json
import sys


def load_index(index_path: str):
    with open(index_path) as f:
        data = json.load(f)

    # Build sorted int-PC list for binary search
    pc_list_int = [int(pc, 16) for pc in data["pc_list"]]
    pc_to_insn = data["instructions"]
    functions = data.get("function_names", [])

    return pc_list_int, pc_to_insn, functions


def get_context(pc_hex: str, pc_list_int: list, pc_to_insn: dict,
                functions: list, before: int, after: int):
    """Extract surrounding instructions for a given PC."""
    pc_int = int(pc_hex, 16)

    # Binary search to find position in ordered PC list
    import bisect
    pos = bisect.bisect_left(pc_list_int, pc_int)
    if pos >= len(pc_list_int) or pc_list_int[pos] != pc_int:
        return None  # PC not found in disassembly

    total = len(pc_list_int)

    def format_insn(pc_int_val):
        pc_str = f"0x{pc_int_val:x}"
        insn = pc_to_insn.get(pc_str)
        if insn is None:
            return f"{pc_str}: ???"
        return f"{pc_str}: {insn['full_text']}"

    # Context before
    start = max(0, pos - before)
    context_before = [format_insn(pc_list_int[i]) for i in range(start, pos)]

    # The load instruction itself
    load_insn = pc_to_insn.get(pc_hex, {})
    load_text = load_insn.get("full_text", "???")

    # Context after
    end = min(total, pos + after + 1)
    context_after = [format_insn(pc_list_int[i]) for i in range(pos + 1, end)]

    # Function name
    func_idx = load_insn.get("function_idx")
    func_name = functions[func_idx] if func_idx is not None and func_idx < len(functions) else "unknown"

    return {
        "pc": pc_hex,
        "load_insn": load_text,
        "function": func_name,
        "context_before": context_before,
        "context_after": context_after,
    }


def main():
    parser = argparse.ArgumentParser(description="Extract assembly context for Load PCs")
    parser.add_argument("--index", required=True, help="Disassembly index JSON")
    parser.add_argument("--load-pcs", required=True, help="Load PC list JSON")
    parser.add_argument("--output", required=True, help="Output JSONL file")
    parser.add_argument("--before", type=int, default=8, help="Instructions before load")
    parser.add_argument("--after", type=int, default=4, help="Instructions after load")
    args = parser.parse_args()

    pc_list_int, pc_to_insn, functions = load_index(args.index)

    with open(args.load_pcs) as f:
        load_pcs = json.load(f)

    matched = 0
    missing = 0
    with open(args.output, "w") as out:
        for pc_hex in load_pcs:
            ctx = get_context(pc_hex, pc_list_int, pc_to_insn, functions,
                             args.before, args.after)
            if ctx is None:
                missing += 1
                continue
            matched += 1
            out.write(json.dumps(ctx) + "\n")

    print(f"Assembly context: {matched} matched, {missing} not found in disassembly")
    print(f"Saved → {args.output}")


if __name__ == "__main__":
    main()
