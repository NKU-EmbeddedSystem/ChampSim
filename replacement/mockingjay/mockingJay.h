#ifndef MOCKINGJAY_H
#define MOCKINGJAY_H

#include <algorithm>
#include <cmath>
#include <cstdint>
#include <map>
#include <unordered_map>
#include <vector>

#include "cache.h"
#include "modules.h"

class mockingJay : public champsim::modules::replacement
{
public:
  using BLOCK = champsim::cache_block;

  // ====================================================================
  // 1. Constants & Parameters
  // ====================================================================
  uint32_t NUM_SET;
  uint32_t NUM_WAY;
  uint32_t NUM_CPUS_VAL;

  uint32_t LOG2_LLC_SET;
  uint32_t LOG2_LLC_SIZE;
  uint32_t LOG2_SAMPLED_SETS;

  const int HISTORY = 8;
  const int GRANULARITY = 8;
  int INF_RD;
  int INF_ETR;
  int MAX_RD;

  const int SAMPLED_CACHE_WAYS = 5;
  const int LOG2_SAMPLED_CACHE_SETS = 4;
  int SAMPLED_CACHE_TAG_BITS;
  int PC_SIGNATURE_BITS;
  const int TIMESTAMP_BITS = 8;

  const double TEMP_DIFFERENCE = 1.0 / 16.0;
  double FLEXMIN_PENALTY;

  // ====================================================================
  // 2. Data Structures
  // ====================================================================
  struct SampledCacheLine {
    bool valid = false;
    uint64_t tag = 0;
    uint64_t signature = 0;
    int timestamp = 0;
  };

  std::vector<std::vector<int>> etr;
  std::vector<int> etr_clock;
  std::unordered_map<uint64_t, int> rdp;
  std::vector<int> current_timestamp;
  std::unordered_map<uint32_t, std::vector<SampledCacheLine>> sampled_cache;

  // ====================================================================
  // 3. Constructor
  // ====================================================================
  explicit mockingJay(CACHE* cache);

  // ====================================================================
  // 4. Function Declarations (仅声明，无代码)
  // ====================================================================
  void initialize_replacement();

  long find_victim(uint32_t cpu, uint64_t instr_id, long set, const BLOCK* current_set, champsim::address ip, champsim::address full_addr, access_type type);

  void replacement_cache_fill(uint32_t cpu, long set, long way, champsim::address full_addr, champsim::address ip, champsim::address victim_addr,
                              access_type type);

  void update_replacement_state(uint32_t cpu, long set, long way, champsim::address full_addr, champsim::address ip, champsim::address victim_addr,
                                access_type type, uint8_t hit);

  // 内部辅助函数声明
  bool is_sampled_set(int set);
  void initialize_sampled_sets();
  uint64_t CRC_HASH(uint64_t _blockAddress);
  uint64_t get_pc_signature(uint64_t pc, bool hit, bool prefetch, uint32_t core);
  uint32_t get_sampled_cache_index(uint64_t full_addr);
  uint64_t get_sampled_cache_tag(uint64_t x);
  int search_sampled_cache(uint64_t blockAddress, uint32_t set);
  void detrain(uint32_t set, int way);
  int temporal_difference(int init, int sample);
  int increment_timestamp(int input);
  int time_elapsed(int global, int local);
};

#endif
