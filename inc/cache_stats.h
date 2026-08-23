#ifndef CACHE_STATS_H
#define CACHE_STATS_H

#include <cstdint>
#include <string>
#include <type_traits>
#include <utility>

#include "channel.h"
#include "event_counter.h"

struct cache_stats {
  std::string name;
  // prefetch stats
  uint64_t pf_requested = 0;
  uint64_t pf_issued = 0;
  uint64_t pf_useful = 0;
  uint64_t pf_useful_hit = 0;  // demand hit on a filled prefetch line
  uint64_t pf_useful_late = 0; // demand merged with an in-flight prefetch (MSHR)
  uint64_t pf_useless = 0;
  uint64_t pf_fill = 0;
  // Diagnostic sinks for issued prefetches that are neither useful nor
  // useless: absorbed into an in-flight prefetch MSHR, absorbed into a
  // demand MSHR, or hit a resident line without ever missing.
  uint64_t pf_absorbed_pf_mshr = 0;
  uint64_t pf_absorbed_dem_mshr = 0;
  uint64_t pf_hit_resident = 0;
  uint64_t pf_mshr_full_drop = 0;    // dropped: MSHR full (never touches DRAM)
  uint64_t pf_downstream_reject = 0; // dropped: lower-level queue full
  uint64_t pf_try_hit_entered = 0;   // prefetch packets reaching tag check
  uint64_t pf_miss_entered = 0;      // prefetch packets entering handle_miss
  uint64_t pf_mshr_alloc = 0;        // prefetch MSHRs successfully allocated

  champsim::stats::event_counter<std::pair<access_type, std::remove_cv_t<decltype(NUM_CPUS)>>> hits = {};
  champsim::stats::event_counter<std::pair<access_type, std::remove_cv_t<decltype(NUM_CPUS)>>> misses = {};
  champsim::stats::event_counter<std::pair<access_type, std::remove_cv_t<decltype(NUM_CPUS)>>> mshr_merge = {};
  champsim::stats::event_counter<std::pair<access_type, std::remove_cv_t<decltype(NUM_CPUS)>>> mshr_return = {};

  long total_miss_latency_cycles{};
};

cache_stats operator-(cache_stats lhs, cache_stats rhs);

#endif
