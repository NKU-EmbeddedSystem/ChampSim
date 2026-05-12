#ifndef PREFETCHER_DSPATCH_H
#define PREFETCHER_DSPATCH_H

#include <bitset>
#include <cstdint>
#include <deque>
#include <string>
#include <vector>

#include "modules.h"
#include "pythia_adapter.h"
#include "pythia_compat.h"

#define DSPATCH_MAX_BW_LEVEL 4
#define DSPATCH_MAX_REGION_CL 64

// ── Bitmap helper functions (replace Pythia bitmap.h) ──────────────────

using DSPatchBitmap = std::bitset<DSPATCH_MAX_REGION_CL>;

inline int dspatch_popcount(const DSPatchBitmap& bmp, uint32_t size)
{
  int cnt = 0;
  for (uint32_t i = 0; i < size; i++)
    if (bmp[i]) cnt++;
  return cnt;
}

inline int dspatch_count_same(const DSPatchBitmap& a, const DSPatchBitmap& b, uint32_t size)
{
  int cnt = 0;
  for (uint32_t i = 0; i < size; i++)
    if (a[i] == b[i]) cnt++;
  return cnt;
}

inline int dspatch_count_diff(const DSPatchBitmap& a, const DSPatchBitmap& b, uint32_t size)
{
  return (int)size - dspatch_count_same(a, b, size);
}

inline DSPatchBitmap dspatch_bitwise_or(const DSPatchBitmap& a, const DSPatchBitmap& b)
{
  return a | b;
}

inline DSPatchBitmap dspatch_bitwise_and(const DSPatchBitmap& a, const DSPatchBitmap& b)
{
  return a & b;
}

inline DSPatchBitmap dspatch_compress(const DSPatchBitmap& bmp, uint32_t granularity,
                                       uint32_t size)
{
  DSPatchBitmap res;
  for (uint32_t i = 0; i < size; i += granularity) {
    bool val = false;
    for (uint32_t j = 0; j < granularity && (i + j) < size; j++)
      if (bmp[i + j]) val = true;
    res[i / granularity] = val;
  }
  return res;
}

inline DSPatchBitmap dspatch_decompress(const DSPatchBitmap& bmp, uint32_t granularity,
                                         uint32_t size)
{
  DSPatchBitmap res;
  for (uint32_t i = 0; i < size; i += granularity) {
    bool val = bmp[i / granularity];
    for (uint32_t j = 0; j < granularity && (i + j) < size; j++)
      res[i + j] = val;
  }
  return res;
}

inline DSPatchBitmap dspatch_rotate_left(const DSPatchBitmap& bmp, uint32_t amount,
                                          uint32_t size)
{
  DSPatchBitmap res;
  for (uint32_t i = 0; i < size; i++) {
    uint32_t src = (i + amount) % size;
    res[i] = bmp[src];
  }
  return res;
}

inline DSPatchBitmap dspatch_rotate_right(const DSPatchBitmap& bmp, uint32_t amount,
                                           uint32_t size)
{
  DSPatchBitmap res;
  for (uint32_t i = 0; i < size; i++) {
    uint32_t src = (i + size - amount) % size;
    res[i] = bmp[src];
  }
  return res;
}

// ── Hash functions (replace Pythia util.h) ─────────────────────────────

inline uint32_t folded_xor(uint64_t x, int folds)
{
  for (int i = 0; i < folds; i++)
    x = (x >> 32) ^ (x & 0xFFFFFFFFULL);
  return (uint32_t)x;
}

inline uint32_t dspatch_jenkins(uint32_t key)
{
  key = (key + 0x7ed55d16) + (key << 12);
  key = (key ^ 0xc761c23c) ^ (key >> 19);
  key = (key + 0x165667b1) + (key << 5);
  key = (key + 0xd3a2646c) ^ (key << 9);
  key = (key + 0xfd7046c5) + (key << 3);
  key = (key ^ 0xb55a4f09) ^ (key >> 16);
  return key;
}

inline uint32_t dspatch_get_hash(uint32_t key, uint32_t sig_hash_type)
{
  switch (sig_hash_type) {
    case 1:  return key;
    case 2:  return dspatch_jenkins(key);
    default: return key;
  }
}

// ── Counter helper ─────────────────────────────────────────────────────

struct DSPatch_counter {
  uint32_t counter = 0;
  void incr(uint32_t max_val = 0xFFFFFFFF)
  {
    if (counter < max_val) counter++;
  }
  void decr(uint32_t min_val = 0) { if (counter > min_val) counter--; }
  uint32_t value() { return counter; }
  void reset() { counter = 0; }
};

// ── Prefetcher struct ──────────────────────────────────────────────────

struct DSPatch_PBEntry {
  uint64_t page = 0xdeadbeef;
  uint64_t trigger_pc = 0xdeadbeef;
  uint32_t trigger_offset = 0;
  DSPatchBitmap bmp_real;
};

struct DSPatch_SPTEntry {
  uint64_t signature = 0xdeadbeef;
  DSPatchBitmap bmp_cov, bmp_acc;
  DSPatch_counter measure_covP, measure_accP, or_count;
};

enum DSPatch_pref_candidate { NONE = 0, COVP = 1, ACCP = 2, Num_DSPatch_pref_candidates = 3 };

struct dspatch : public pythia::PrefetcherAdapter {
  using PrefetcherAdapter::PrefetcherAdapter;

  // Knobs with defaults
  uint32_t dspatch_log2_region_size = 12;
  uint32_t dspatch_num_cachelines_in_region = 64;
  uint32_t dspatch_pb_size = 64;
  uint32_t dspatch_num_spt_entries = 256;
  uint32_t dspatch_compression_granularity = 4;
  uint32_t dspatch_pred_throttle_bw_thr = 2;
  uint32_t dspatch_bitmap_selection_policy = 3;
  uint32_t dspatch_sig_type = 1;
  uint32_t dspatch_sig_hash_type = 2;
  uint32_t dspatch_or_count_max = 20;
  uint32_t dspatch_measure_covP_max = 15;
  uint32_t dspatch_measure_accP_max = 5;
  uint32_t dspatch_acc_thr = 75;
  uint32_t dspatch_cov_thr = 25;
  bool dspatch_enable_pref_buffer = true;
  uint32_t dspatch_pref_buffer_size = 256;
  uint32_t dspatch_pref_degree = 8;

  // State
  uint8_t bw_bucket = 0;
  std::deque<DSPatch_PBEntry*> page_buffer;
  std::vector<DSPatch_SPTEntry*> spt;
  std::deque<uint64_t> pref_buffer;

  // Stats
  struct {
    struct { uint64_t lookup = 0, hit = 0, evict = 0, insert = 0; } pb;
    struct {
      uint64_t called = 0, selection_dist[Num_DSPatch_pref_candidates] = {};
      uint64_t reset = 0, total = 0;
    } gen_pref;
    struct {
      uint64_t called = 0, none = 0;
      uint64_t accp_reason1 = 0, accp_reason2 = 0;
      uint64_t covp_reason1 = 0, covp_reason2 = 0;
    } dyn_selection;
    struct {
      uint64_t called = 0, or_count_incr = 0;
      uint64_t measure_covP_incr = 0, bmp_cov_reset = 0, bmp_cov_update = 0;
      uint64_t measure_accP_incr = 0, measure_accP_decr = 0, bmp_acc_update = 0;
    } spt;
    struct { uint64_t called = 0, bw_histogram[DSPATCH_MAX_BW_LEVEL] = {}; } bw;
    struct { uint64_t spilled = 0, buffered = 0, issued = 0; } pref_buffer_s;
  } stats = {};
  bool init_done = false;

  void invoke_prefetcher(uint64_t pc, uint64_t address, uint8_t cache_hit, uint8_t type,
                         std::vector<uint64_t>& pref_addr) override;
  void dump_stats() override;
  void print_config() override;

private:
  DSPatch_PBEntry* search_pb(uint64_t page);
  void buffer_prefetch(const std::vector<uint64_t>& paddr);
  void issue_prefetch(std::vector<uint64_t>& pref_addr);
  uint64_t create_signature(uint64_t pc, uint64_t page, uint32_t offset);
  uint32_t get_spt_index(uint64_t signature);
  void add_to_spt(DSPatch_PBEntry* pbentry);
  DSPatch_pref_candidate select_bitmap(DSPatch_SPTEntry* sptentry, DSPatchBitmap& bmp_selected);
  DSPatch_pref_candidate dyn_selection(DSPatch_SPTEntry* sptentry, DSPatchBitmap& bmp_selected);
  void generate_prefetch(uint64_t pc, uint64_t page, uint32_t offset, uint64_t address,
                         std::vector<uint64_t>& pref_addr);
};

#endif
