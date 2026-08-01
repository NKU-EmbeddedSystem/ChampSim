#ifndef PREFETCHER_AMPM_H
#define PREFETCHER_AMPM_H

#include <bitset>
#include <cstdint>
#include <deque>
#include <vector>

#include "modules.h"
#include "pythia_adapter.h"
#include "pythia_compat.h"

#define AMPM_MAX_OFFSETS 64

struct ampm : public pythia::PrefetcherAdapter {
  using PrefetcherAdapter::PrefetcherAdapter;

  struct PageEntry {
    uint64_t page_id = 0xdeadbeef;
    std::bitset<64> bitmap;
    PageEntry() { bitmap.reset(); }
  };

  struct {
    uint64_t invoke_called = 0;
    struct { uint64_t hit = 0, evict = 0, insert = 0; } pb;
    struct {
      uint64_t pos_histogram[AMPM_MAX_OFFSETS] = {};
      uint64_t neg_histogram[AMPM_MAX_OFFSETS] = {};
      uint64_t total = 0, degree_reached_pos = 0, degree_reached_neg = 0;
    } pred;
    struct { uint64_t hit = 0, dropped = 0, insert = 0, issued = 0; } pref_buffer;
    struct { uint64_t total = 0; } pref;
  } stats;

  // Config knobs
  uint32_t ampm_pb_size = 64;
  uint32_t ampm_pred_degree = 4;
#ifndef AMPM_PREF_DEGREE
#define AMPM_PREF_DEGREE 4
#endif
  uint32_t ampm_pref_degree = AMPM_PREF_DEGREE;
  uint32_t ampm_pref_buffer_size = 256;
  bool ampm_enable_pref_buffer = true;
  uint32_t ampm_max_delta = 16;

  // State
  std::deque<PageEntry*> page_buffer;
  std::deque<uint64_t> pref_buffer;

  void invoke_prefetcher(uint64_t pc, uint64_t address, uint8_t cache_hit, uint8_t type,
                         std::vector<uint64_t>& pref_addr) override;
  void dump_stats() override;
  void print_config() override;

private:
  void buffer_prefetch(std::vector<uint64_t> predicted_addrs);
  void issue_prefetch(std::vector<uint64_t>& pref_addr);
};

#endif
