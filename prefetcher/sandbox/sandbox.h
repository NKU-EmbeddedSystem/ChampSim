#ifndef PREFETCHER_SANDBOX_H
#define PREFETCHER_SANDBOX_H

#include <cstdint>
#include <deque>
#include <unordered_set>
#include <vector>

#include "modules.h"
#include "pythia_adapter.h"
#include "pythia_compat.h"

struct sandbox : public pythia::PrefetcherAdapter {
  using PrefetcherAdapter::PrefetcherAdapter;

  struct Score {
    int32_t offset;
    uint32_t score;
    Score() : offset(0), score(0) {}
    Score(int32_t o) : offset(o), score(0) {}
    Score(int32_t o, uint32_t s) : offset(o), score(s) {}
  };

  std::deque<Score*> evaluated_offsets;
  std::deque<int32_t> non_evaluated_offsets;
  uint32_t pref_degree = 4;
  struct { uint32_t curr_ptr = 0, total_demand = 0, filter_hit = 0; } eval;
  std::unordered_set<uint64_t> filter_set;

  struct {
    uint64_t called = 0;
    struct { uint64_t filter_lookup = 0, filter_hit = 0; } step1;
    struct { uint64_t filter_add = 0; } step2;
    struct { uint64_t end_of_phase = 0, end_of_round = 0; } step3;
    struct { uint64_t pref_generated = 0, pref_generated_pos = 0, pref_generated_neg = 0; } step4;
    uint64_t pref_delta_dist[128] = {};
  } stats;

  // Config knobs
  uint32_t sandbox_pref_degree = 4;
  bool sandbox_enable_stream_detect = false;
  uint32_t sandbox_stream_detect_length = 4;
  uint32_t sandbox_num_access_in_phase = 256;
  uint32_t sandbox_num_cycle_offsets = 4;
  uint32_t sandbox_bloom_filter_size = 2048;
  uint32_t sandbox_seed = 200;
  bool initialized = false;

  void invoke_prefetcher(uint64_t pc, uint64_t address, uint8_t cache_hit, uint8_t type,
                         std::vector<uint64_t>& pref_addr) override;
  void dump_stats() override;
  void print_config() override;

private:
  void init_evaluated_offsets();
  void init_non_evaluated_offsets();
  void reset_eval();
  void get_offset_list_sorted(std::vector<Score*>& pos, std::vector<Score*>& neg);
  void generate_prefetch(std::vector<Score*> offset_list, uint32_t pd, uint64_t page,
                         uint32_t offset, std::vector<uint64_t>& pref_addr);
  void destroy_offset_list(std::vector<Score*> l);
  uint64_t generate_address(uint64_t page, uint32_t offset, int32_t delta, uint32_t lookahead = 1);
  void end_of_round();
  bool filter_lookup(uint64_t address);
  void record_pref_stats(int32_t offset, uint32_t pref_count);
};

#endif
