#!/usr/bin/env python3
"""
Parse 'objdump -d' output into a PC→instruction index.

Parsing logic:
  - Each function starts with a line like: 00000000004c36e0 <Perl_pp_add>:
  - Each instruction line looks like:  4c36e6: 55  push %rbp
  - Only records instructions within named functions (skips unnamed/plt stubs)

Output JSON structure (index.json):
{
  "function_names": ["Perl_pp_add", ...],
  "instructions": {
    "0x4c36e6": {
      "mnemonic": "push",
      "operands": "%rbp",
      "full_text": "push %rbp",
      "function_idx": 0
    },
    ...
  },
  "pc_list": [0x4c36e6, 0x4c36e7, ...],    // sorted, for binary search
  "load_pcs": [0x4c36f3, ...]               // PCs with memory read instructions
}
"""

import argparse
import json
import re
import subprocess
import sys

# Patterns for x86-64 objdump output
FUNC_RE = re.compile(r'^([0-9a-f]+)\s+<(.+)>:\s*$')
INSN_RE = re.compile(r'^\s*([0-9a-f]+):\s+((?:[0-9a-f]{2} )+)\s+(.+)$')

# Instructions that read memory (loads)
LOAD_MNEMONICS = {
    "mov", "movzx", "movsx", "movsxd", "movdqu", "movdqa", "movaps", "movups",
    "movsd", "movss", "movq", "movl", "movw", "movb",
    "add", "sub", "and", "or", "xor", "cmp", "test",
    "adc", "sbb", "imul",
    "addsd", "subsd", "mulsd", "divsd",
    "addss", "subss", "mulss", "divss",
    "cvtsi2sd", "cvtsi2ss", "cvttsd2si", "cvtss2si",
    "lea", "pop", "ret", "call", "jmp",
    "fld", "fst", "fadd", "fsub", "fmul", "fdiv",
    "vaddsd", "vsubsd", "vmulsd", "vdivsd",
    "vaddss", "vsubss", "vmulss", "vdivss",
    "vmovdqu", "vmovdqa", "vmovaps", "vmovups",
    "vmovsd", "vmovss",
    "vgatherdpd", "vgatherqpd", "vgatherdps", "vgatherqps",
    "vpgatherdd", "vpgatherqd", "vpgatherdq", "vpgatherqq",
    "prefetcht0", "prefetcht1", "prefetcht2", "prefetchnta",
}

def looks_like_memory_operand(operands: str) -> bool:
    """Heuristic: does this instruction likely touch memory? (has '(' indicating ptr)"""
    return "(" in operands


def is_load(mnemonic: str, operands: str) -> bool:
    """
    Determine if an instruction is a memory load.
    We use a conservative heuristic: the mnemonic is in LOAD_MNEMONICS
    AND operands contain a memory reference (parentheses).
    We exclude: lea (not a real load), call/jmp (code fetch, not data), pop/ret.
    """
    mnemonic_lower = mnemonic.lower()

    # Explicitly exclude these
    if mnemonic_lower in {"lea", "call", "jmp", "jcc", "je", "jne", "jl", "jg",
                           "jle", "jge", "jb", "ja", "jbe", "jae", "jo", "jno",
                           "js", "jns", "jcxz", "jecxz", "jrcxz", "loop",
                           "ret", "iret", "syscall", "int", "int3", "into",
                           "push", "pushf", "pusha", "enter",
                           "nop", "mfence", "lfence", "sfence",
                           "prefetcht0", "prefetcht1", "prefetcht2", "prefetchnta"}:
        return False

    if mnemonic_lower in LOAD_MNEMONICS:
        return looks_like_memory_operand(operands)

    return False


def run_objdump(binary_path: str) -> str:
    """Run objdump -d on a binary and return the output."""
    try:
        result = subprocess.run(
            ["objdump", "-d", binary_path],
            capture_output=True, text=True, timeout=300
        )
        if result.returncode != 0:
            print(f"ERROR: objdump failed: {result.stderr}", file=sys.stderr)
            sys.exit(1)
        return result.stdout
    except FileNotFoundError:
        print("ERROR: objdump not found. Install binutils.", file=sys.stderr)
        sys.exit(1)
    except subprocess.TimeoutExpired:
        print("ERROR: objdump timed out (5 min)", file=sys.stderr)
        sys.exit(1)


def parse_objdump_output(text: str):
    """Parse objdump output into an instruction index."""
    functions = []       # list of function names
    func_idx = -1        # current function index (-1 = unnamed)
    instructions = {}    # PC hex string → instruction dict
    load_pcs = []        # PCs of load instructions

    for line in text.split("\n"):
        # Check for function header
        func_match = FUNC_RE.match(line)
        if func_match:
            addr = func_match.group(1).lstrip("0") or "0"
            func_name = func_match.group(2)
            functions.append(func_name)
            func_idx = len(functions) - 1
            continue

        # Check for instruction line
        insn_match = INSN_RE.match(line)
        if insn_match:
            pc_str = insn_match.group(1)
            raw_bytes = insn_match.group(2).strip()
            full_text = insn_match.group(3).strip()

            # Split mnemonic from operands
            parts = full_text.split(None, 1)
            mnemonic = parts[0] if parts else ""
            operands = parts[1] if len(parts) > 1 else ""

            # Normalize PC to hex string with 0x prefix
            pc_int = int(pc_str, 16)
            pc_hex = f"0x{pc_int:x}"

            insn_info = {
                "pc_hex": pc_hex,
                "pc_int": pc_int,
                "mnemonic": mnemonic,
                "operands": operands,
                "full_text": full_text,
                "raw_bytes": raw_bytes,
                "function_idx": func_idx if func_idx >= 0 else None,
            }
            instructions[pc_hex] = insn_info

            if is_load(mnemonic, operands):
                load_pcs.append(pc_hex)

    return {
        "function_names": functions,
        "instructions": instructions,
        "pc_list": sorted(instructions.keys(), key=lambda x: int(x, 16)),
        "load_pcs": sorted(load_pcs, key=lambda x: int(x, 16)),
    }


def main():
    parser = argparse.ArgumentParser(description="Parse objdump disassembly into JSON index")
    parser.add_argument("--binary", required=True, help="Path to ELF binary")
    parser.add_argument("--output", required=True, help="Output JSON file path")
    args = parser.parse_args()

    print(f"Running objdump -d on {args.binary} ...")
    asm_text = run_objdump(args.binary)

    print(f"Parsing assembly output ({len(asm_text)} bytes) ...")
    index = parse_objdump_output(asm_text)

    total = len(index["instructions"])
    loads = len(index["load_pcs"])
    funcs = len(index["function_names"])
    print(f"Indexed {total} instructions, {loads} loads, {funcs} functions")

    with open(args.output, "w") as f:
        json.dump(index, f, indent=2)
    print(f"Saved → {args.output}")


if __name__ == "__main__":
    main()
