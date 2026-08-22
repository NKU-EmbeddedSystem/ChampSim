#ifndef PREFETCHER_HINT_DISPATCH_H
#define PREFETCHER_HINT_DISPATCH_H

#include "address.h"
#include "cache.h"
#include "hint_table.h"
#include "modules.h"

// Sub-prefetcher includes — the 4 candidate families; each is instantiated
// three times with a fixed low/mid/high prefetch degree baked in at
// construction time (see hint_dispatch.cc).
#include "../dspatch/dspatch.h"
#include "../mlop/mlop.h"
#include "../sandbox/sandbox.h"
#include "../stream/stream.h"

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

// Prefetch policy indices — must match tools/l1d_hint_demo/oracle_gen.py
// Candidate set: 4 families x 3 degree tiers (low/mid/high).
//   sandbox: 1 / 4 / 8    dspatch: 1 / 16 / 64
//   mlop:    1 / 8 / 16   stream:  1 / 4 / 8
enum class PrefetchPolicy : int {
    SANDBOX_D1 = 0,
    SANDBOX_D4 = 1,
    SANDBOX_D8 = 2,
    DSPATCH_D1 = 3,
    DSPATCH_D16 = 4,
    DSPATCH_D64 = 5,
    MLOP_D1 = 6,
    MLOP_D8 = 7,
    MLOP_D16 = 8,
    STREAM_D1 = 9,
    STREAM_D4 = 10,
    STREAM_D8 = 11,
};

class pref_hint_dispatch : public champsim::modules::prefetcher
{
  sandbox sandbox_d1_prefetcher;
  sandbox sandbox_d4_prefetcher;
  sandbox sandbox_d8_prefetcher;
  dspatch dspatch_d1_prefetcher;
  dspatch dspatch_d16_prefetcher;
  dspatch dspatch_d64_prefetcher;
  mlop mlop_d1_prefetcher;
  mlop mlop_d8_prefetcher;
  mlop mlop_d16_prefetcher;
  stream stream_d1_prefetcher;
  stream stream_d4_prefetcher;
  stream stream_d8_prefetcher;

  static constexpr int NUM_PREFETCHERS = 12;

  int last_selected_index = 0;

  // Broadcast-learning support: every demand access trains ALL 12
  // sub-prefetcher instances (each learning via its adapter's
  // invoke_prefetcher), except the PC's filter-marked worst policy which is
  // skipped entirely. Prefetch ISSUE still comes only from the selected
  // instance: non-selected instances are invoked with training_only set,
  // which makes the adapter update state but issue nothing.
  //
  // Instances are visited by direct member reference — never through cached
  // pointers. ChampSim move-constructs modules into their storage
  // (std::tuple intern_) after the constructor body runs, so pointers filled
  // in the constructor would dangle.
  template <typename F>
  void for_each_instance(int skip_idx, F&& f)
  {
    if (skip_idx != 0) f(0, sandbox_d1_prefetcher);
    if (skip_idx != 1) f(1, sandbox_d4_prefetcher);
    if (skip_idx != 2) f(2, sandbox_d8_prefetcher);
    if (skip_idx != 3) f(3, dspatch_d1_prefetcher);
    if (skip_idx != 4) f(4, dspatch_d16_prefetcher);
    if (skip_idx != 5) f(5, dspatch_d64_prefetcher);
    if (skip_idx != 6) f(6, mlop_d1_prefetcher);
    if (skip_idx != 7) f(7, mlop_d8_prefetcher);
    if (skip_idx != 8) f(8, mlop_d16_prefetcher);
    if (skip_idx != 9) f(9, stream_d1_prefetcher);
    if (skip_idx != 10) f(10, stream_d4_prefetcher);
    if (skip_idx != 11) f(11, stream_d8_prefetcher);
  }

  template <typename F>
  void visit_instance(int idx, F&& f)
  {
    switch (idx) {
      case 0: f(sandbox_d1_prefetcher); break;
      case 1: f(sandbox_d4_prefetcher); break;
      case 2: f(sandbox_d8_prefetcher); break;
      case 3: f(dspatch_d1_prefetcher); break;
      case 4: f(dspatch_d16_prefetcher); break;
      case 5: f(dspatch_d64_prefetcher); break;
      case 6: f(mlop_d1_prefetcher); break;
      case 7: f(mlop_d8_prefetcher); break;
      case 8: f(mlop_d16_prefetcher); break;
      case 9: f(stream_d1_prefetcher); break;
      case 10: f(stream_d4_prefetcher); break;
      case 11: f(stream_d8_prefetcher); break;
      default: break;
    }
  }

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
