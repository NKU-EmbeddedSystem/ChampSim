#ifndef PREFETCHER_HINT_DISPATCH_H
#define PREFETCHER_HINT_DISPATCH_H

#include "address.h"
#include "cache.h"
#include "hint_table.h"
#include "modules.h"

// Sub-prefetcher includes
#include "../ampm/ampm.h"
#include "../bingo/bingo.h"
#include "../dspatch/dspatch.h"
#include "../ip_stride/ip_stride.h"
#include "../mlop/mlop.h"
#include "../next_line/next_line.h"
#include "../no/no.h"
#include "../power7/power7.h"
#include "../ppf/ppf.h"
#include "../sandbox/sandbox.h"
#include "../sms/sms.h"
#include "../spp_dev/spp_dev.h"
#include "../stream/stream.h"
#include "../stride/stride.h"
#include "../va_ampm_lite/va_ampm_lite.h"

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
    STRIDE = 5,
    STREAM = 6,
    AMPM = 7,
    SMS = 8,
    BINGO = 9,
    SANDBOX = 10,
    POWER7 = 11,
    DSPATCH = 12,
    MLOP = 13,
    PPF = 14,
};

class pref_hint_dispatch : public champsim::modules::prefetcher
{
  no no_prefetcher;
  next_line next_line_prefetcher;
  ip_stride ip_stride_prefetcher;
  spp_dev spp_dev_prefetcher;
  va_ampm_lite va_ampm_lite_prefetcher;
  stride stride_prefetcher;
  stream stream_prefetcher;
  ampm ampm_prefetcher;
  sms sms_prefetcher;
  bingo bingo_prefetcher;
  sandbox sandbox_prefetcher;
  power7 power7_prefetcher;
  dspatch dspatch_prefetcher;
  mlop mlop_prefetcher;
  ppf ppf_prefetcher;

  static constexpr int NUM_PREFETCHERS = 15;

  int last_selected_index = 0;

  static constexpr ContextFeature context_feature_ = static_cast<ContextFeature>(CONTEXT_FEATURE);
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
