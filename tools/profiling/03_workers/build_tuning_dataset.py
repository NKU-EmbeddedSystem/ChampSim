#!/usr/bin/env python3
"""
Merge assembly context with ground truth labels into instruction-tuning dataset.

Input:
  --context   : JSONL from extract_assembly_context.py
  --labels    : JSONL from aggregate_ground_truth.py

Output: JSONL file, one training sample per matched Load PC:
  {"instruction": "<assembly context formatted as prompt>",
   "label": "<best_prefetch>:<best_degree>",
   "pc": "0x4c36f3"}
"""

import argparse
import json
import sys


def load_jsonl(path: str) -> dict:
    """Load a JSONL file, index by 'pc' field."""
    data = {}
    with open(path) as f:
        for line in f:
            line = line.strip()
            if not line:
                continue
            obj = json.loads(line)
            pc = obj.get("pc", "").lower()
            data[pc] = obj
    return data


def format_instruction(context: dict) -> str:
    """Format assembly context as a natural language instruction prompt."""
    before = "\n".join(context.get("context_before", []))
    after = "\n".join(context.get("context_after", []))
    load_insn = context.get("load_insn", "???")
    func = context.get("function", "unknown")

    return (
        f"Given the following x86-64 assembly context for a load instruction "
        f"in function '{func}', predict the optimal prefetch policy.\n\n"
        f"Instructions before load:\n{before}\n\n"
        f"Load instruction:\n  {load_insn}\n\n"
        f"Instructions after load:\n{after}\n\n"
        f"Available prefetch policies: no, next_line, ip_stride, spp_dev, va_ampm_lite"
    )


def main():
    parser = argparse.ArgumentParser(description="Build instruction-tuning dataset")
    parser.add_argument("--context", required=True, help="Assembly context JSONL")
    parser.add_argument("--labels", required=True, help="Ground truth labels JSONL")
    parser.add_argument("--output", required=True, help="Output JSONL training dataset")
    args = parser.parse_args()

    contexts = load_jsonl(args.context)
    labels = load_jsonl(args.labels)

    matched = 0
    no_label = 0
    no_context = 0

    with open(args.output, "w") as out:
        for pc, label_data in labels.items():
            ctx = contexts.get(pc)
            if ctx is None:
                no_context += 1
                continue

            instruction = format_instruction(ctx)
            label = f"{label_data['best_prefetch']}:{label_data['best_degree']}"

            sample = {
                "instruction": instruction,
                "label": label,
                "pc": pc,
            }
            out.write(json.dumps(sample, ensure_ascii=False) + "\n")
            matched += 1

    print(f"Training dataset: {matched} samples")
    if no_context:
        print(f"  {no_context} labels had no assembly context")
    print(f"Saved → {args.output}")


if __name__ == "__main__":
    main()
