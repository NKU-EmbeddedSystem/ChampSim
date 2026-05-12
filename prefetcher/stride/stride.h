#ifndef PREFETCHER_STRIDE_H
#define PREFETCHER_STRIDE_H

#include <cstdint>
#include <deque>
#include <vector>

#include "modules.h"
#include "pythia_adapter.h"
#include "pythia_compat.h"

struct stride : public pythia::PrefetcherAdapter {
  using PrefetcherAdapter::PrefetcherAdapter;

  // ── Internal types ────────────────────────────────────────────────
  struct Tracker {
    uint64_t pc = 0;
    uint64_t last_cl_addr = 0;
    int64_t last_stride = 0;
  };

  struct Stats {
    struct { uint64_t lookup = 0, evict = 0, insert = 0, hit = 0; } tracker;
    struct { uint64_t pos = 0, neg = 0, zero = 0; } stride_stats;
    struct { uint64_t stride_match = 0, generated = 0; } pref;
  };

  // ── Config knobs ──────────────────────────────────────────────────
  uint32_t stride_num_trackers = 64;
  uint32_t stride_pref_degree = 4;

  // ── State ─────────────────────────────────────────────────────────
  std::deque<Tracker*> trackers;
  Stats stats;

  // ── Overrides ─────────────────────────────────────────────────────
  void invoke_prefetcher(uint64_t pc, uint64_t address, uint8_t cache_hit, uint8_t type,
                         std::vector<uint64_t>& pref_addr) override;
  void dump_stats() override;
  void print_config() override;

  // ── Helpers ───────────────────────────────────────────────────────
  uint32_t generate_prefetch(uint64_t address, int32_t stride, std::vector<uint64_t>& pref_addr);
};

#endif
