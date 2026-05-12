#ifndef PREFETCHER_BINGO_H
#define PREFETCHER_BINGO_H

#include <cstdint>
#include <deque>
#include <sstream>
#include <string>
#include <unordered_map>
#include <vector>

#include "modules.h"
#include "pythia_adapter.h"
#include "pythia_compat.h"
#include "bakshalipour_fw.h"

template <class T> std::vector<T> bingo_rotate(const std::vector<T>& x, int n)
{
  std::vector<T> y;
  int len = (int)x.size();
  n = n % len;
  for (int i = 0; i < len; i += 1)
    y.push_back(x[(i - n + len) % len]);
  return y;
}

// ── Bingo-specific tables ──────────────────────────────────────────────

struct FilterTableData {
  uint64_t pc = 0;
  int offset = 0;
};

class FilterTable : public LRUSetAssociativeCache<FilterTableData> {
  using Super = LRUSetAssociativeCache<FilterTableData>;

public:
  FilterTable(int size, int debug_level = 0, int num_ways = 16)
      : Super(size, num_ways, debug_level) {}

  Entry* find_by_region(uint64_t region_number)
  {
    uint64_t key = build_key(region_number);
    Entry* entry = Super::find(key);
    if (!entry) return nullptr;
    Super::set_mru(key);
    return entry;
  }

  void insert_region(uint64_t region_number, uint64_t pc, int offset)
  {
    uint64_t key = build_key(region_number);
    Super::insert(key, {pc, offset});
    Super::set_mru(key);
  }

  Entry* erase_region(uint64_t region_number)
  {
    uint64_t key = build_key(region_number);
    return Super::erase(key);
  }

private:
  uint64_t build_key(uint64_t region_number)
  {
    uint64_t k = region_number & ((1ULL << 37) - 1);
    return bf_hash_index(k, this->index_len);
  }
};

struct AccumulationTableData {
  uint64_t pc = 0;
  int offset = 0;
  std::vector<bool> pattern;
};

class AccumulationTable : public LRUSetAssociativeCache<AccumulationTableData> {
  using Super = LRUSetAssociativeCache<AccumulationTableData>;

public:
  AccumulationTable(int size, int pattern_len, int debug_level = 0, int num_ways = 16)
      : Super(size, num_ways, debug_level), pattern_len(pattern_len) {}

  bool set_pattern(uint64_t region_number, int offset)
  {
    uint64_t key = build_key(region_number);
    Entry* entry = Super::find(key);
    if (!entry) return false;
    entry->data.pattern[offset] = true;
    Super::set_mru(key);
    return true;
  }

  Entry insert_entry(uint64_t region_number, uint64_t pc, int offset)
  {
    uint64_t key = build_key(region_number);
    std::vector<bool> pattern(this->pattern_len, false);
    pattern[offset] = true;
    Entry old_entry = Super::insert(key, {pc, offset, pattern});
    Super::set_mru(key);
    return old_entry;
  }

  Entry* erase_region(uint64_t region_number)
  {
    uint64_t key = build_key(region_number);
    return Super::erase(key);
  }

  int pattern_len;

private:
  uint64_t build_key(uint64_t region_number)
  {
    uint64_t k = region_number & ((1ULL << 37) - 1);
    return bf_hash_index(k, this->index_len);
  }
};

enum class BingoEvent { PC_ADDRESS = 0, PC_OFFSET = 1, MISS = 2 };

struct PatternHistoryTableData {
  std::vector<bool> pattern;
};

class PatternHistoryTable : public LRUSetAssociativeCache<PatternHistoryTableData> {
  using Super = LRUSetAssociativeCache<PatternHistoryTableData>;

public:
  PatternHistoryTable(int size, int pattern_len, int min_addr_width, int max_addr_width,
                      int pc_width, int debug_level = 0, int num_ways = 16)
      : Super(size, num_ways, debug_level), pattern_len(pattern_len),
        min_addr_width(min_addr_width), max_addr_width(max_addr_width), pc_width(pc_width) {}

  void insert_pattern(uint64_t pc, uint64_t address, const std::vector<bool>& pattern)
  {
    int offset = address % this->pattern_len;
    auto rot_pattern = bingo_rotate(pattern, -offset);
    uint64_t key = build_key(pc, address);
    Super::insert(key, {rot_pattern});
    Super::set_mru(key);
  }

  std::vector<std::vector<bool>> find_patterns(uint64_t pc, uint64_t address)
  {
    uint64_t key = build_key(pc, address);
    uint64_t index = key % this->num_sets;
    uint64_t tag = key / this->num_sets;
    auto& set = this->entries[index];
    uint64_t min_tag_mask = (1ULL << (this->pc_width + this->min_addr_width - this->index_len)) - 1;
    uint64_t max_tag_mask = (1ULL << (this->pc_width + this->max_addr_width - this->index_len)) - 1;
    std::vector<std::vector<bool>> matches;
    this->last_event = BingoEvent::MISS;
    for (int i = 0; i < this->num_ways; i += 1) {
      if (!set[i].valid) continue;
      bool min_match = ((set[i].tag & min_tag_mask) == (tag & min_tag_mask));
      bool max_match = ((set[i].tag & max_tag_mask) == (tag & max_tag_mask));
      if (max_match) {
        this->last_event = BingoEvent::PC_ADDRESS;
        Super::set_mru(set[i].key);
        matches.clear();
        matches.push_back(set[i].data.pattern);
        break;
      }
      if (min_match) {
        this->last_event = BingoEvent::PC_OFFSET;
        matches.push_back(set[i].data.pattern);
      }
    }
    int offset = address % this->pattern_len;
    for (int i = 0; i < (int)matches.size(); i += 1)
      matches[i] = bingo_rotate(matches[i], +offset);
    return matches;
  }

  BingoEvent get_last_event() { return this->last_event; }

  int pattern_len;
  int min_addr_width, max_addr_width, pc_width;

private:
  uint64_t build_key(uint64_t pc, uint64_t address)
  {
    pc &= (1ULL << this->pc_width) - 1;
    address &= (1ULL << this->max_addr_width) - 1;
    uint64_t offset = address & ((1ULL << this->min_addr_width) - 1);
    uint64_t base = (address >> this->min_addr_width);
    uint64_t index_key = bf_hash_index((pc << this->min_addr_width) | offset, this->index_len);
    uint64_t key = (base << (this->pc_width + this->min_addr_width)) | index_key;
    return key;
  }

  BingoEvent last_event = BingoEvent::MISS;
};

struct PrefetchStreamerData {
  std::vector<int> pattern;
};

class PrefetchStreamer : public LRUSetAssociativeCache<PrefetchStreamerData> {
  using Super = LRUSetAssociativeCache<PrefetchStreamerData>;

public:
  PrefetchStreamer(int size, int pattern_len, int debug_level = 0, int num_ways = 16)
      : Super(size, num_ways, debug_level), pattern_len(pattern_len) {}

  void insert_region(uint64_t region_number, const std::vector<int>& pattern)
  {
    uint64_t key = build_key(region_number);
    Super::insert(key, {pattern});
    Super::set_mru(key);
  }

  int issue_prefetches(uint64_t block_address, std::vector<uint64_t>& pref_addr)
  {
    uint64_t region_offset = block_address % this->pattern_len;
    uint64_t region_number = block_address / this->pattern_len;
    uint64_t key = build_key(region_number);
    Entry* entry = Super::find(key);
    if (!entry) return 0;
    Super::set_mru(key);
    int pf_issued = 0;
    std::vector<int>& pattern = entry->data.pattern;
    pattern[region_offset] = 0;
    for (int d = 1; d < this->pattern_len; d += 1) {
      for (int sgn = +1; sgn >= -1; sgn -= 2) {
        int pf_offset = (int)region_offset + sgn * d;
        if (0 <= pf_offset && pf_offset < this->pattern_len && pattern[pf_offset] > 0) {
          uint64_t pf_address =
              ((uint64_t)region_number * this->pattern_len + (uint64_t)pf_offset) << LOG2_BLOCK_SIZE;
          pref_addr.push_back(pf_address);
          pf_issued += 1;
          pattern[pf_offset] = 0;
        }
      }
    }
    Super::erase(key);
    return pf_issued;
  }

private:
  uint64_t build_key(uint64_t region_number)
  {
    return bf_hash_index(region_number, this->index_len);
  }

  int pattern_len;
};

// ── Main Bingo struct ──────────────────────────────────────────────────

struct bingo : public pythia::PrefetcherAdapter {
  using PrefetcherAdapter::PrefetcherAdapter;

  // Knobs with defaults
  uint32_t bingo_region_size = 2048;
  uint32_t bingo_pattern_len = 32;
  uint32_t bingo_pc_width = 16;
  uint32_t bingo_min_addr_width = 0;
  uint32_t bingo_max_addr_width = 5;
  uint32_t bingo_ft_size = 64;
  uint32_t bingo_at_size = 128;
  uint32_t bingo_pht_size = 8192;
  uint32_t bingo_pht_ways = 16;
  uint32_t bingo_pf_streamer_size = 128;
  uint32_t bingo_debug_level = 0;
  float bingo_l1d_thresh = 0.25f;
  float bingo_l2c_thresh = 0.10f;
  float bingo_llc_thresh = 0.05f;
  std::string bingo_pc_address_fill_level = "L2";

  int pc_address_fill_level = P_FILL_L2;
  int pattern_len = 32;

  FilterTable filter_table{64};
  AccumulationTable accumulation_table{128, 32};
  PatternHistoryTable pht{8192, 32, 0, 5, 16, 0, 16};
  PrefetchStreamer pf_streamer{128, 32};

  // Stats
  uint64_t pht_access_cnt = 0;
  uint64_t pht_pc_address_cnt = 0;
  uint64_t pht_pc_offset_cnt = 0;
  uint64_t pht_miss_cnt = 0;
  uint64_t prefetch_cnt[2] = {};
  uint64_t useful_cnt[2] = {};
  uint64_t useless_cnt[2] = {};
  std::unordered_map<int, uint64_t> pref_level_cnt;
  uint64_t region_pref_cnt = 0;
  uint64_t vote_cnt = 0;
  uint64_t voter_sum = 0;
  uint64_t voter_sqr_sum = 0;
  std::unordered_map<uint64_t, BingoEvent> pht_events;
  bool init_done = false;

  void invoke_prefetcher(uint64_t pc, uint64_t address, uint8_t cache_hit, uint8_t type,
                         std::vector<uint64_t>& pref_addr) override;
  void register_fill(uint64_t address) override;
  void dump_stats() override;
  void print_config() override;

  void access(uint64_t block_number, uint64_t pc);
  void eviction(uint64_t block_number);
  int prefetch(uint64_t block_number, std::vector<uint64_t>& pref_addr);
  std::vector<int> find_in_pht(uint64_t pc, uint64_t address);
  void insert_in_pht(const AccumulationTable::Entry& entry);
  std::vector<int> vote(const std::vector<std::vector<bool>>& x);
};

#endif
