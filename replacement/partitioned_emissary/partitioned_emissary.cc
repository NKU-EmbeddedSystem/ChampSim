#include "partitioned_emissary.h"

#include <algorithm>
#include <cassert>
#include <cstdint>

#include "fmt/core.h"

partitioned_emissary::partitioned_emissary(CACHE* cache)
    : partitioned_emissary(cache, cache->NUM_SET, cache->NUM_WAY, cache->NUM_WAY / 2, 8) {}

partitioned_emissary::partitioned_emissary(CACHE* cache, long sets, long ways, long lru_ways, long n_max)
    : replacement(cache), NUM_SET(sets), NUM_WAY(ways), LRU_WAYS(lru_ways), N_MAX(n_max),
      lru_last_used(static_cast<std::size_t>(sets * ways), 0),
      p1_last_used(static_cast<std::size_t>(sets * ways), 0),
      p0_last_used(static_cast<std::size_t>(sets * ways), 0)
{
}

// ── LRU partition victim selection ──
long partitioned_emissary::find_victim_lru(long set, const champsim::cache_block* current_set)
{
  long victim = -1;
  uint64_t min_cycle = UINT64_MAX;

  for (long w = 0; w < LRU_WAYS; ++w) {
    if (!current_set[w].valid)
      return w; // prefer invalid
    uint64_t last = lru_last_used[static_cast<std::size_t>(set * NUM_WAY + w)];
    if (last < min_cycle) {
      min_cycle = last;
      victim = w;
    }
  }
  assert(victim >= 0);
  return victim;
}

// ── EMISSARY partition victim selection ──
long partitioned_emissary::find_victim_emissary(long set, const champsim::cache_block* current_set)
{
  // Count P=1 lines in the EMISSARY partition
  long p1_count = 0;
  for (long w = LRU_WAYS; w < NUM_WAY; ++w) {
    if (current_set[w].valid && current_set[w].priority)
      ++p1_count;
  }

  // First look for any invalid way in the partition
  for (long w = LRU_WAYS; w < NUM_WAY; ++w) {
    if (!current_set[w].valid)
      return w;
  }

  auto p1_begin = std::next(std::begin(p1_last_used), set * NUM_WAY);
  auto p0_begin = std::next(std::begin(p0_last_used), set * NUM_WAY);

  if (p1_count <= N_MAX) {
    // P=1 pool not full — evict from P=0
    long victim = -1;
    uint64_t min_cycle = UINT64_MAX;
    for (long w = LRU_WAYS; w < NUM_WAY; ++w) {
      if (!current_set[w].priority) {
        uint64_t last = *std::next(p0_begin, w);
        if (last < min_cycle) {
          min_cycle = last;
          victim = w;
        }
      }
    }
    assert(victim >= 0);
    ++total_p0_evictions;
    return victim;
  } else {
    // P=1 pool overflow — evict from P=1
    long victim = -1;
    uint64_t min_cycle = UINT64_MAX;
    for (long w = LRU_WAYS; w < NUM_WAY; ++w) {
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

// ── Main victim selection: reads next_block_partition from cache ──
long partitioned_emissary::find_victim(uint32_t triggering_cpu, uint64_t instr_id, long set,
                                       const champsim::cache_block* current_set, champsim::address ip,
                                       champsim::address full_addr, access_type type)
{
  bool to_emissary = intern_->next_block_partition;

  if (to_emissary) {
    ++total_emissary_evictions;
    return find_victim_emissary(set, current_set);
  } else {
    ++total_lru_evictions;
    return find_victim_lru(set, current_set);
  }
}

// ── Fill: update appropriate partition state ──
void partitioned_emissary::replacement_cache_fill(uint32_t triggering_cpu, long set, long way,
                                                   champsim::address full_addr, champsim::address ip,
                                                   champsim::address victim_addr, access_type type)
{
  const auto idx = static_cast<std::size_t>(set * NUM_WAY + way);
  uint64_t ts = ++cycle;

  if (way < LRU_WAYS) {
    lru_last_used[idx] = ts;
    p1_last_used[idx] = ts;
    p0_last_used[idx] = ts;
  } else {
    // EMISSARY partition — the block's priority determines initial pool
    lru_last_used[idx] = ts;
    p1_last_used[idx] = ts;
    p0_last_used[idx] = ts;
  }
}

// ── Hit update: update the partition that owns this way ──
void partitioned_emissary::update_replacement_state(uint32_t triggering_cpu, long set, long way,
                                                     champsim::address full_addr, champsim::address ip,
                                                     champsim::address victim_addr, access_type type, bool hit)
{
  if (!hit)
    return;

  const auto idx = static_cast<std::size_t>(set * NUM_WAY + way);
  uint64_t ts = ++cycle;

  if (way < LRU_WAYS) {
    // LRU partition
    lru_last_used[idx] = ts;
  } else {
    // EMISSARY partition — check block priority
    bool is_p1 = intern_->block[idx].priority;
    if (is_p1) {
      p1_last_used[idx] = ts;
    } else {
      p0_last_used[idx] = ts;
    }
  }
}

// ── Final stats ──
void partitioned_emissary::replacement_final_stats()
{
  fmt::print("\nPartitioned EMISSARY replacement stats (LRU ways={}, EMISSARY ways={}, N={}):\n",
             LRU_WAYS, NUM_WAY - LRU_WAYS, N_MAX);
  fmt::print("  LRU partition evictions:     {}\n", total_lru_evictions);
  fmt::print("  EMISSARY partition evictions: {}\n", total_emissary_evictions);
  fmt::print("    P=1 evictions: {}\n", total_p1_evictions);
  fmt::print("    P=0 evictions: {}\n", total_p0_evictions);
  if (total_p1_evictions + total_p0_evictions > 0) {
    fmt::print("    P=1 eviction ratio: {:.1f}%\n",
               100.0 * static_cast<double>(total_p1_evictions) /
                   static_cast<double>(total_p1_evictions + total_p0_evictions));
  }
}
