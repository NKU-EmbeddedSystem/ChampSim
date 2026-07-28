#include "emissary.h"

#include <algorithm>
#include <cassert>
#include <cstdint>

#include "access_type.h"
#include "fmt/core.h"

emissary::emissary(CACHE* cache) : emissary(cache, cache->NUM_SET, cache->NUM_WAY, 8) {}

emissary::emissary(CACHE* cache, long sets, long ways, long n_max)
    : replacement(cache), NUM_SET(sets), NUM_WAY(ways), N_MAX(n_max),
      p1_last_used(static_cast<std::size_t>(sets * ways), 0),
      p0_last_used(static_cast<std::size_t>(sets * ways), 0)
{
}

long emissary::find_victim(uint32_t triggering_cpu, uint64_t instr_id, long set, const champsim::cache_block* current_set,
                           champsim::address ip, champsim::address full_addr, access_type type)
{
  // Count P=1 lines in this set
  long p1_count = 0;
  for (long w = 0; w < NUM_WAY; ++w) {
    if (current_set[w].valid && current_set[w].priority)
      ++p1_count;
  }

  auto p1_begin = std::next(std::begin(p1_last_used), set * NUM_WAY);
  auto p0_begin = std::next(std::begin(p0_last_used), set * NUM_WAY);

  if (p1_count <= N_MAX) {
    // P=1 pool not full — evict from P=0 pool
    long victim = -1;
    uint64_t min_cycle = UINT64_MAX;
    for (long w = 0; w < NUM_WAY; ++w) {
      if (!current_set[w].valid || !current_set[w].priority) {
        // Candidate: invalid or P=0
        uint64_t last = current_set[w].valid ? *std::next(p0_begin, w) : 0;
        if (!current_set[w].valid || last < min_cycle) {
          min_cycle = last;
          victim = w;
        }
      }
    }
    // Prefer invalid way
    for (long w = 0; w < NUM_WAY; ++w) {
      if (!current_set[w].valid) {
        return w;
      }
    }
    assert(victim >= 0);
    ++total_p0_evictions;
    return victim;
  } else {
    // P=1 pool overflow — evict from P=1 pool
    long victim = -1;
    uint64_t min_cycle = UINT64_MAX;
    for (long w = 0; w < NUM_WAY; ++w) {
      if (current_set[w].valid && current_set[w].priority) {
        uint64_t last = *std::next(p1_begin, w);
        if (last < min_cycle) {
          min_cycle = last;
          victim = w;
        }
      }
    }
    assert(victim >= 0);
    ++total_p1_evictions;
    return victim;
  }
}

void emissary::replacement_cache_fill(uint32_t triggering_cpu, long set, long way, champsim::address full_addr,
                                      champsim::address ip, champsim::address victim_addr, access_type type)
{
  // New block inserted — mark it in the appropriate pool
  const auto idx = static_cast<std::size_t>(set * NUM_WAY + way);
  if (p1_last_used[idx] > 0 || p0_last_used[idx] > 0) {
    // Block already has history (shouldn't happen for a fresh fill, but be safe)
  }
  p1_last_used[idx] = ++cycle;
  p0_last_used[idx] = ++cycle;
}

void emissary::update_replacement_state(uint32_t triggering_cpu, long set, long way, champsim::address full_addr,
                                        champsim::address ip, champsim::address victim_addr, access_type type, bool hit)
{
  // On hit, update the last-used timestamp in the appropriate pool
  if (!hit)
    return;

  const auto idx = static_cast<std::size_t>(set * NUM_WAY + way);
  bool is_p1 = intern_->block[idx].priority;
  if (is_p1) {
    p1_last_used[idx] = ++cycle;
  } else {
    p0_last_used[idx] = ++cycle;
  }
}

void emissary::replacement_final_stats()
{
  fmt::print("\nEMISSARY P(N) replacement stats (N={}):\n", N_MAX);
  fmt::print("  P=1 evictions: {}\n", total_p1_evictions);
  fmt::print("  P=0 evictions: {}\n", total_p0_evictions);
  if (total_p1_evictions + total_p0_evictions > 0) {
    fmt::print("  P=1 eviction ratio: {:.1f}%\n",
               100.0 * total_p1_evictions / (total_p1_evictions + total_p0_evictions));
  }
}
