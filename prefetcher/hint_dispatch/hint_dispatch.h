#ifndef PREFETCHER_HINT_DISPATCH_H
#define PREFETCHER_HINT_DISPATCH_H

#include "address.h"
#include "cache.h"
#include "hint_table.h"
#include "modules.h"

// Sub-prefetcher includes — the 5 existing ChampSim prefetchers
#include "../ip_stride/ip_stride.h"
#include "../next_line/next_line.h"
#include "../no/no.h"
#include "../spp_dev/spp_dev.h"
#include "../va_ampm_lite/va_ampm_lite.h"

// Context extraction for two-level hint lookup
#include "context_extractors.h"
#include <memory>

#ifndef CONTEXT_FEATURE
#define CONTEXT_FEATURE 0
#endif

enum class ContextFeature {
    NONE = 0,
    PAGE_OFFSET = 1,
    DELTA_SIGNATURE = 2,
    RECENT_PC_HASH = 3,
    COMPOSITE = 4,
};

// Prefetch policy indices — must match policy_registry.py
enum class PrefetchPolicy : int {
    NO = 0,
    NEXT_LINE = 1,
    IP_STRIDE = 2,
    SPP_DEV = 3,
    VA_AMPM_LITE = 4,
};

// hint_dispatch is a standalone prefetcher module that wraps an ensemble of
// 5 sub-prefetchers and dispatches to the selected one based on a PC-keyed
// hint table lookup. Metadata from the selected sub-prefetcher is returned
// verbatim — unselected sub-prefetchers do not participate in the fill pipeline
// for that access.
//
// The hint's prefetch_degree field overrides the sub-prefetcher's default
// aggressiveness. The demand_filter flag suppresses demand-access training
// for the selected sub-prefetcher.

class pref_hint_dispatch : public champsim::modules::prefetcher
{
  no no_prefetcher;
  next_line next_line_prefetcher;
  ip_stride ip_stride_prefetcher;
  spp_dev spp_dev_prefetcher;
  va_ampm_lite va_ampm_lite_prefetcher;

  static constexpr int NUM_PREFETCHERS = 5;

  // Last selected index for cycle_operate() dispatch
  int last_selected_index = 0;

  // Compile-time context feature selection (set via -DCONTEXT_FEATURE=X)
  static constexpr ContextFeature context_feature_ = static_cast<ContextFeature>(CONTEXT_FEATURE);

  // Context extractor for two-level hint lookup (nullptr for baseline NONE)
  std::unique_ptr<ContextExtractor> context_extractor_;

public:
  explicit pref_hint_dispatch(CACHE* cache);

  void prefetcher_initialize();

  uint32_t prefetcher_cache_operate(champsim::address addr, champsim::address ip, uint8_t cache_hit,
                                    bool useful_prefetch, access_type type, uint32_t metadata_in);

  uint32_t prefetcher_cache_fill(champsim::address addr, long set, long way, uint8_t prefetch,
                                 champsim::address evicted_addr, uint32_t metadata_in);

  void prefetcher_cycle_operate();
  void prefetcher_final_stats();
};

#endif
