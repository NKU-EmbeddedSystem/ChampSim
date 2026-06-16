#!/usr/bin/env python3
from pathlib import Path
import re
import sys

ROOT = Path(__file__).resolve().parents[1]


def read(rel):
    return (ROOT / rel).read_text()


checks = [
    (
        "MemoryMapper exposes a page-level migration update API",
        lambda: "set_page_area(" in read("inc/memory_mapper.h"),
    ),
    (
        "PageMigrationEngine writes migrated assignments back to MemoryMapper",
        lambda: "MemoryMapper::get_instance().set_page_area" in read("src/page_migration.cc"),
    ),
    (
        "TracePageBuffer can skip warmup data references before forward lookahead",
        lambda: re.search(r"\badvance\s*\(", read("inc/trace_page_buffer.h")) is not None,
    ),
    (
        "The trace data-memory stream feeds PageMigrationEngine heat counters",
        lambda: "page_migration.recordAccess" in read("src/ooo_cpu.cc"),
    ),
    (
        "Migration checks run from the trace data-memory stream",
        lambda: "page_migration.maybeMigrate" in read("src/ooo_cpu.cc"),
    ),
    (
        "Forward migration gets an initial lookahead migration at ROI start",
        lambda: "usesForwardLookahead" in read("src/main.cc")
        and "page_migration.forceMigrate" in read("src/main.cc"),
    ),
]


failed = []
for label, predicate in checks:
    if not predicate():
        failed.append(label)

if failed:
    print("migration wiring check failed:")
    for label in failed:
        print(f"  - {label}")
    sys.exit(1)

print(f"migration wiring check passed ({len(checks)} checks)")
