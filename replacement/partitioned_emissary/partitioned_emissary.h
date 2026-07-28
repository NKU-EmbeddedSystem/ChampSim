#ifndef REPLACEMENT_PARTITIONED_EMISSARY_H
#define REPLACEMENT_PARTITIONED_EMISSARY_H

#include <vector>

#include "cache.h"
#include "modules.h"

// Partitioned heterogeneous replacement:
//   Ways [0, LRU_WAYS-1] → LRU (data partition)
//   Ways [LRU_WAYS, NUM_WAY-1] → EMISSARY P(N) (I-cache priority partition)
//
// Partition selection is driven by CACHE::next_block_partition:
//   false → LRU partition    (for regular data fills)
//   true  → EMISSARY partition (for starvation I-cache fills)
class partitioned_emissary : public champsim::modules::replacement
{
  long NUM_SET, NUM_WAY, LRU_WAYS, N_MAX;
  uint64_t cycle = 0;

  // LRU partition: per-set per-way last-used timestamps
  std::vector<uint64_t> lru_last_used;

  // EMISSARY partition: per-set per-way last-used for P=1 and P=0 pools
  std::vector<uint64_t> p1_last_used;
  std::vector<uint64_t> p0_last_used;

  // Stats
  uint64_t total_lru_evictions = 0;
  uint64_t total_emissary_evictions = 0;
  uint64_t total_p1_evictions = 0;
  uint64_t total_p0_evictions = 0;

  long find_victim_lru(long set, const champsim::cache_block* current_set);
  long find_victim_emissary(long set, const champsim::cache_block* current_set);

public:
  explicit partitioned_emissary(CACHE* cache);
  partitioned_emissary(CACHE* cache, long sets, long ways, long lru_ways, long n_max);

  long find_victim(uint32_t triggering_cpu, uint64_t instr_id, long set, const champsim::cache_block* current_set,
                   champsim::address ip, champsim::address full_addr, access_type type);
  void replacement_cache_fill(uint32_t triggering_cpu, long set, long way, champsim::address full_addr,
                              champsim::address ip, champsim::address victim_addr, access_type type);
  void update_replacement_state(uint32_t triggering_cpu, long set, long way, champsim::address full_addr,
                                champsim::address ip, champsim::address victim_addr, access_type type, bool hit);
  void replacement_final_stats();
};

#endif
