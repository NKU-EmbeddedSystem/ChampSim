#ifndef PREFETCHER_PPF_H
#define PREFETCHER_PPF_H

#include <cstdint>
#include <deque>
#include <iostream>
#include <string>
#include <vector>

#include "modules.h"
#include "pythia_adapter.h"
#include "pythia_compat.h"

// ── SPP/PPF constants (from ppf_dev_helper.h) ────────────────────────

#define PPF_ST_SET 1
#define PPF_ST_WAY 256
#define PPF_ST_TAG_BIT 16
#define PPF_ST_TAG_MASK ((1 << PPF_ST_TAG_BIT) - 1)
#define PPF_SIG_SHIFT 3
#define PPF_SIG_BIT 12
#define PPF_SIG_MASK ((1 << PPF_SIG_BIT) - 1)
#define PPF_SIG_DELTA_BIT 7

#define PPF_PT_SET 512
#define PPF_PT_WAY 4
#define PPF_C_SIG_BIT 4
#define PPF_C_DELTA_BIT 4
#define PPF_C_SIG_MAX ((1 << PPF_C_SIG_BIT) - 1)
#define PPF_C_DELTA_MAX ((1 << PPF_C_DELTA_BIT) - 1)

#define PPF_QUOTIENT_BIT 10
#define PPF_REMAINDER_BIT 6
#define PPF_HASH_BIT (PPF_QUOTIENT_BIT + PPF_REMAINDER_BIT + 1)
#define PPF_FILTER_SET (1 << PPF_QUOTIENT_BIT)

#define PPF_GLOBAL_COUNTER_BIT 10
#define PPF_GLOBAL_COUNTER_MAX ((1 << PPF_GLOBAL_COUNTER_BIT) - 1)
#define PPF_MAX_GHR_ENTRY 8
#define PPF_PAGES_TRACKED 6

#define PPF_PERC_ENTRIES 4096
#define PPF_PERC_FEATURES 9
#define PPF_PERC_COUNTER_MAX 15
#define PPF_POS_UPDT_THRESHOLD 90
#define PPF_NEG_UPDT_THRESHOLD -80

enum PPF_FILTER_REQUEST { SPP_L2C_PREFETCH, SPP_LLC_PREFETCH, L2C_DEMAND, L2C_EVICT, SPP_PERC_REJECT };

inline uint64_t ppf_get_hash(uint64_t key)
{
  key += (key << 12);
  key ^= (key >> 22);
  key += (key << 4);
  key ^= (key >> 9);
  key += (key << 10);
  key ^= (key >> 2);
  key += (key << 7);
  key ^= (key >> 12);
  key = (key >> 3) * 2654435761ULL;
  return key;
}

// ── Helper classes ─────────────────────────────────────────────────────

struct GLOBAL_REGISTER;
struct PERCEPTRON;

struct GLOBAL_REGISTER {
  uint64_t pf_useful = 0, pf_issued = 0, global_accuracy = 0;
  uint8_t valid[PPF_MAX_GHR_ENTRY] = {};
  uint32_t sig[PPF_MAX_GHR_ENTRY] = {};
  uint32_t confidence[PPF_MAX_GHR_ENTRY] = {};
  uint32_t offset[PPF_MAX_GHR_ENTRY] = {};
  int delta[PPF_MAX_GHR_ENTRY] = {};
  uint64_t ip_0 = 0, ip_1 = 0, ip_2 = 0, ip_3 = 0;
  uint64_t page_tracker[PPF_PAGES_TRACKED] = {};

  void update_entry(uint32_t pf_sig, uint32_t pf_confidence, uint32_t pf_offset, int pf_delta);
  uint32_t check_entry(uint32_t page_offset);
};

struct PERCEPTRON {
  int32_t perc_weights[PPF_PERC_ENTRIES][PPF_PERC_FEATURES] = {};
  int32_t PERC_DEPTH[PPF_PERC_FEATURES] = {};

  PERCEPTRON()
  {
    PERC_DEPTH[0] = 2048;
    PERC_DEPTH[1] = 4096;
    PERC_DEPTH[2] = 4096;
    PERC_DEPTH[3] = 4096;
    PERC_DEPTH[4] = 1024;
    PERC_DEPTH[5] = 4096;
    PERC_DEPTH[6] = 1024;
    PERC_DEPTH[7] = 2048;
    PERC_DEPTH[8] = 128;
  }

  void get_perc_index(uint64_t base_addr, uint64_t ip, uint64_t ip_1, uint64_t ip_2,
                      uint64_t ip_3, int32_t cur_delta, uint32_t last_sig, uint32_t curr_sig,
                      uint32_t confidence, uint32_t depth, uint64_t perc_set[PPF_PERC_FEATURES]);
  int32_t perc_predict(uint64_t base_addr, uint64_t ip, uint64_t ip_1, uint64_t ip_2,
                        uint64_t ip_3, int32_t cur_delta, uint32_t last_sig, uint32_t curr_sig,
                        uint32_t confidence, uint32_t depth);
  void perc_update(uint64_t base_addr, uint64_t ip, uint64_t ip_1, uint64_t ip_2, uint64_t ip_3,
                   int32_t cur_delta, uint32_t last_sig, uint32_t curr_sig, uint32_t confidence,
                   uint32_t depth, bool direction, int32_t perc_sum);
};

struct PREFETCH_FILTER {
  GLOBAL_REGISTER* ghr = nullptr;
  PERCEPTRON* perc = nullptr;

  uint64_t remainder_tag[PPF_FILTER_SET] = {};
  uint64_t pc[PPF_FILTER_SET] = {};
  uint64_t pc_1[PPF_FILTER_SET] = {};
  uint64_t pc_2[PPF_FILTER_SET] = {};
  uint64_t pc_3[PPF_FILTER_SET] = {};
  uint64_t address[PPF_FILTER_SET] = {};
  bool valid[PPF_FILTER_SET] = {};
  bool useful[PPF_FILTER_SET] = {};
  int32_t delta[PPF_FILTER_SET] = {};
  int32_t perc_sum[PPF_FILTER_SET] = {};
  uint32_t last_signature[PPF_FILTER_SET] = {};
  uint32_t cur_signature[PPF_FILTER_SET] = {};
  uint32_t confidence[PPF_FILTER_SET] = {};
  uint32_t la_depth[PPF_FILTER_SET] = {};

  // Reject filter (simplified — omit for now, use same array for perc reject)
  bool check(uint64_t pf_addr, uint64_t base_addr, uint64_t ip,
             PPF_FILTER_REQUEST filter_request, int32_t cur_delta, uint32_t last_sig,
             uint32_t cur_sig, uint32_t conf, int32_t sum, uint32_t depth);
};

struct SIGNATURE_TABLE {
  GLOBAL_REGISTER* ghr = nullptr;

  bool valid[PPF_ST_SET][PPF_ST_WAY] = {};
  uint32_t tag[PPF_ST_SET][PPF_ST_WAY] = {};
  uint32_t last_offset[PPF_ST_SET][PPF_ST_WAY] = {};
  uint32_t sig[PPF_ST_SET][PPF_ST_WAY] = {};
  uint32_t lru[PPF_ST_SET][PPF_ST_WAY] = {};

  SIGNATURE_TABLE()
  {
    for (uint32_t set = 0; set < PPF_ST_SET; set++)
      for (uint32_t way = 0; way < PPF_ST_WAY; way++)
        lru[set][way] = way;
  }

  void read_and_update_sig(uint64_t page, uint32_t page_offset, uint32_t& last_sig,
                            uint32_t& curr_sig, int32_t& delta);
};

struct PATTERN_TABLE {
  GLOBAL_REGISTER* ghr = nullptr;
  PERCEPTRON* perc = nullptr;
  PREFETCH_FILTER* filter = nullptr;

  int delta[PPF_PT_SET][PPF_PT_WAY] = {};
  uint32_t c_delta[PPF_PT_SET][PPF_PT_WAY] = {};
  uint32_t c_sig[PPF_PT_SET] = {};

  void update_pattern(uint32_t last_sig, int curr_delta);
  void read_pattern(uint32_t curr_sig, std::vector<int>& prefetch_delta,
                    std::vector<uint32_t>& confidence_q, std::vector<int32_t>& perc_sum_q,
                    uint32_t& lookahead_way, uint32_t& lookahead_conf, uint32_t& pf_q_tail,
                    uint32_t& depth, uint64_t addr, uint64_t base_addr, uint64_t train_addr,
                    uint64_t curr_ip, int32_t train_delta, uint32_t last_sig,
                    uint32_t pq_occupancy, uint32_t pq_SIZE,
                    uint32_t mshr_occupancy, uint32_t mshr_SIZE);
};

// ── Main PPF struct ────────────────────────────────────────────────────

struct ppf : public pythia::PrefetcherAdapter {
  using PrefetcherAdapter::PrefetcherAdapter;

  SIGNATURE_TABLE ST;
  PATTERN_TABLE PT;
  PREFETCH_FILTER FILTER;
  GLOBAL_REGISTER GHR;
  PERCEPTRON PERC;

  int32_t ppf_perc_threshold_hi = -5;
  int32_t ppf_perc_threshold_lo = -15;

  uint32_t access_counter = 0;
  bool init_done = false;

  void invoke_prefetcher(uint64_t pc, uint64_t address, uint8_t cache_hit, uint8_t type,
                         std::vector<uint64_t>& pref_addr) override;
  void register_fill(uint64_t address) override;
  void dump_stats() override;
  void print_config() override;
};

#endif
