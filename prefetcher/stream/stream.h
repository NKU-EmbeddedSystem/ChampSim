#ifndef PREFETCHER_STREAM_H
#define PREFETCHER_STREAM_H

#include <cstdint>
#include <deque>
#include <vector>

#include "modules.h"
#include "pythia_adapter.h"
#include "pythia_compat.h"

struct stream : public pythia::PrefetcherAdapter {
  using PrefetcherAdapter::PrefetcherAdapter;

  struct StreamTracker {
    uint64_t page;
    uint32_t last_offset;
    int32_t last_dir;
    uint8_t conf;
    StreamTracker(uint64_t p, uint32_t off) : page(p), last_offset(off), last_dir(0), conf(0) {}
  };

  struct {
    uint64_t called = 0;
    struct { uint64_t missed=0,evict=0,insert=0,hit=0,same_offset=0,dir_match=0,dir_mismatch=0; } tracker;
    struct { uint64_t dir_match=0,total=0; } pred;
  } stats;

  uint32_t streamer_num_trackers = 64;
  uint32_t streamer_pref_degree = 4;
  std::deque<StreamTracker*> trackers;

  void invoke_prefetcher(uint64_t pc, uint64_t address, uint8_t cache_hit, uint8_t type,
                         std::vector<uint64_t>& pref_addr) override;
  void dump_stats() override;
  void print_config() override;
};

#endif
