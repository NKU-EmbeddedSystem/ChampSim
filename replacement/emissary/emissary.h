#ifndef REPLACEMENT_EMISSARY_H
#define REPLACEMENT_EMISSARY_H

#include <vector>

#include "cache.h"
#include "modules.h"

// EMISSARY P(N) replacement policy
// Maintains two per-set LRU trees: one for P=1 (high-priority I-cache) lines,
// one for P=0 (regular data) lines. Protected capacity is capped at N_MAX ways.
//
// Reference: EMISSARY paper — cost-aware L2 cache replacement
class emissary : public champsim::modules::replacement
{
  long NUM_SET, NUM_WAY, N_MAX;
  uint64_t cycle = 0;

  // Per-set, per-way last-used timestamps for P=1 and P=0 pools
  // Indexed: [set * NUM_WAY + way]
  std::vector<uint64_t> p1_last_used;
  std::vector<uint64_t> p0_last_used;

  // Count of evictions from each pool (for final stats)
  uint64_t total_p1_evictions = 0;
  uint64_t total_p0_evictions = 0;

public:
  explicit emissary(CACHE* cache);
  emissary(CACHE* cache, long sets, long ways, long n_max = 8);

  // void initialize_replacement();
  long find_victim(uint32_t triggering_cpu, uint64_t instr_id, long set, const champsim::cache_block* current_set,
                   champsim::address ip, champsim::address full_addr, access_type type);
  void replacement_cache_fill(uint32_t triggering_cpu, long set, long way, champsim::address full_addr,
                              champsim::address ip, champsim::address victim_addr, access_type type);
  void update_replacement_state(uint32_t triggering_cpu, long set, long way, champsim::address full_addr,
                                champsim::address ip, champsim::address victim_addr, access_type type, bool hit);
  void replacement_final_stats();
};

#endif
