#include "hint_dispatch.h"

#ifdef HINT_PROFILING
#include "profiler.h"
#endif

// Degree tiers per family (low/mid/high) — must match PrefetchPolicy indices
// and tools/l1d_hint_demo/gen_configs.py PROFILING_MATRIX.
namespace {
constexpr uint32_t SANDBOX_DEGREES[3] = {1, 4, 8};
constexpr uint32_t DSPATCH_DEGREES[3] = {1, 16, 64};
constexpr uint32_t MLOP_DEGREES[3] = {1, 8, 16};
constexpr uint32_t STREAM_DEGREES[3] = {1, 4, 8};
} // namespace

pref_hint_dispatch::pref_hint_dispatch(CACHE* cache)
    : prefetcher(cache),
      sandbox_d1_prefetcher(cache), sandbox_d4_prefetcher(cache), sandbox_d8_prefetcher(cache),
      dspatch_d1_prefetcher(cache), dspatch_d16_prefetcher(cache), dspatch_d64_prefetcher(cache),
      mlop_d1_prefetcher(cache), mlop_d8_prefetcher(cache), mlop_d16_prefetcher(cache),
      stream_d1_prefetcher(cache), stream_d4_prefetcher(cache), stream_d8_prefetcher(cache)
{
  // Bake the per-instance degree in before prefetcher_initialize() runs:
  //  - stream/dspatch read their knob member directly at operate time;
  //  - sandbox copies sandbox_pref_degree -> pref_degree in its constructor,
  //    so both members are set here;
  //  - mlop derives PF_DEGREE from mlop_pref_degree in print_config(), which
  //    prefetcher_initialize() invokes.
  auto set_sandbox = [](sandbox& p, uint32_t deg) {
    p.sandbox_pref_degree = deg;
    p.pref_degree = deg;
  };
  set_sandbox(sandbox_d1_prefetcher, SANDBOX_DEGREES[0]);
  set_sandbox(sandbox_d4_prefetcher, SANDBOX_DEGREES[1]);
  set_sandbox(sandbox_d8_prefetcher, SANDBOX_DEGREES[2]);
  dspatch_d1_prefetcher.dspatch_pref_degree = DSPATCH_DEGREES[0];
  dspatch_d16_prefetcher.dspatch_pref_degree = DSPATCH_DEGREES[1];
  dspatch_d64_prefetcher.dspatch_pref_degree = DSPATCH_DEGREES[2];
  mlop_d1_prefetcher.mlop_pref_degree = MLOP_DEGREES[0];
  mlop_d8_prefetcher.mlop_pref_degree = MLOP_DEGREES[1];
  mlop_d16_prefetcher.mlop_pref_degree = MLOP_DEGREES[2];
  stream_d1_prefetcher.streamer_pref_degree = STREAM_DEGREES[0];
  stream_d4_prefetcher.streamer_pref_degree = STREAM_DEGREES[1];
  stream_d8_prefetcher.streamer_pref_degree = STREAM_DEGREES[2];

  all_prefetchers[0] = &sandbox_d1_prefetcher;
  all_prefetchers[1] = &sandbox_d4_prefetcher;
  all_prefetchers[2] = &sandbox_d8_prefetcher;
  all_prefetchers[3] = &dspatch_d1_prefetcher;
  all_prefetchers[4] = &dspatch_d16_prefetcher;
  all_prefetchers[5] = &dspatch_d64_prefetcher;
  all_prefetchers[6] = &mlop_d1_prefetcher;
  all_prefetchers[7] = &mlop_d8_prefetcher;
  all_prefetchers[8] = &mlop_d16_prefetcher;
  all_prefetchers[9] = &stream_d1_prefetcher;
  all_prefetchers[10] = &stream_d4_prefetcher;
  all_prefetchers[11] = &stream_d8_prefetcher;

  if constexpr (context_feature_ == ContextFeature::PAGE_OFFSET) {
    context_extractor_ = std::make_unique<PageOffsetExtractor>();
  } else if constexpr (context_feature_ == ContextFeature::DELTA_SIGNATURE) {
    context_extractor_ = std::make_unique<DeltaSignatureExtractor>();
  } else if constexpr (context_feature_ == ContextFeature::RECENT_PC_HASH) {
    context_extractor_ = std::make_unique<RecentPCHashExtractor>();
  } else if constexpr (context_feature_ == ContextFeature::COMPOSITE) {
    context_extractor_ = std::make_unique<CompositeExtractor>();
  }
}

void pref_hint_dispatch::prefetcher_initialize()
{
  sandbox_d1_prefetcher.prefetcher_initialize();
  sandbox_d4_prefetcher.prefetcher_initialize();
  sandbox_d8_prefetcher.prefetcher_initialize();
  dspatch_d1_prefetcher.prefetcher_initialize();
  dspatch_d16_prefetcher.prefetcher_initialize();
  dspatch_d64_prefetcher.prefetcher_initialize();
  mlop_d1_prefetcher.prefetcher_initialize();
  mlop_d8_prefetcher.prefetcher_initialize();
  mlop_d16_prefetcher.prefetcher_initialize();
  stream_d1_prefetcher.prefetcher_initialize();
  stream_d4_prefetcher.prefetcher_initialize();
  stream_d8_prefetcher.prefetcher_initialize();
}

uint32_t pref_hint_dispatch::prefetcher_cache_operate(champsim::address addr, champsim::address ip, uint8_t cache_hit, bool useful_prefetch,
                                                 access_type type, uint32_t metadata_in)
{
  uint64_t context_key = 0;
  if (context_extractor_) {
    context_key = context_extractor_->compute_context(ip.to<uint64_t>(), addr);
    context_extractor_->update_state(ip.to<uint64_t>(), addr);
  }

  const hint_entry* hint = nullptr;
  if (context_key != 0 || context_feature_ != ContextFeature::NONE) {
    hint = hint_table::instance().lookup_with_context(ip.to<uint64_t>(), context_key);
  }
  if (!hint) {
    hint = hint_table::instance().lookup(ip.to<uint64_t>());
  }

  // Congestion feedback: when the memory system is congested (global mode)
  // or this PC's recent prefetch accuracy is too low (per-PC gate), prefer
  // the conservative (bandwidth-taxed) label if one exists.
  bool use_conservative = hint_table::instance().conservative_mode() || hint_table::instance().prefer_conservative(ip.to<uint64_t>());
  if (use_conservative) {
    const hint_entry* conservative_hint = hint_table::instance().lookup_conservative(ip.to<uint64_t>());
    if (conservative_hint) {
      hint = conservative_hint;
    }
  }

  int idx = hint ? hint->prefetch_policy_index : hint_table::instance().get_default_prefetch();

  // Clamp out-of-range indices (e.g. stale hint files from the 15-policy
  // candidate set) to the lowest tier.
  if (idx < 0 || idx >= NUM_PREFETCHERS)
    idx = 0;

  // Broadcast-learning dispatch: every demand access trains ALL
  // sub-prefetcher instances, except the PC's filter-marked worst policy,
  // which is skipped entirely (no learning from this PC). Only the selected
  // instance may ISSUE prefetches; the others are invoked with metadata 0,
  // which the adapter truncates to zero issues after their internal state
  // has been updated.
  int filter_idx = (hint && hint->demand_filter > 0) ? static_cast<int>(hint->demand_filter) - 1 : -1;

  uint32_t metadata = metadata_in;
  if (hint && hint->prefetch_degree > 0) {
    metadata = hint->prefetch_degree;
  }

  last_selected_index = idx;

#ifdef HINT_PROFILING
  PROFILER_UPDATE_PREFETCH_POLICY(ip.to<uint64_t>(), idx);
#endif

  for (int i = 0; i < NUM_PREFETCHERS; ++i) {
    if (i == filter_idx)
      continue; // this PC must not train its worst-AMAT prefetcher
    uint32_t sub_metadata = (i == idx) ? metadata : 0; // only the selected instance issues
    all_prefetchers[i]->prefetcher_cache_operate(addr, ip, cache_hit, useful_prefetch, type, sub_metadata);
  }
  return metadata;
}

uint32_t pref_hint_dispatch::prefetcher_cache_fill(champsim::address addr, long set, long way, uint8_t prefetch,
                                              champsim::address evicted_addr, uint32_t metadata_in)
{
  const hint_entry* hint = hint_table::instance().lookup(addr.to<uint64_t>());

  // Broadcast-learning fill path: demand fills train all non-filtered
  // instances. Prefetch fills are completion feedback and go only to the
  // instance that issued the prefetch.
  int filter_idx = (hint && hint->demand_filter > 0) ? static_cast<int>(hint->demand_filter) - 1 : -1;
  if (prefetch) {
    if (last_selected_index >= 0 && last_selected_index < NUM_PREFETCHERS && last_selected_index != filter_idx)
      all_prefetchers[last_selected_index]->prefetcher_cache_fill(addr, set, way, prefetch, evicted_addr, metadata_in);
  } else {
    for (int i = 0; i < NUM_PREFETCHERS; ++i) {
      if (i == filter_idx)
        continue;
      all_prefetchers[i]->prefetcher_cache_fill(addr, set, way, prefetch, evicted_addr, metadata_in);
    }
  }
  return metadata_in;
}

void pref_hint_dispatch::prefetcher_cycle_operate()
{
  // None of the four candidate families (all Pythia-adapter based) define
  // per-cycle logic; operate/fill callbacks cover their state updates.
}

void pref_hint_dispatch::prefetcher_final_stats()
{
  sandbox_d1_prefetcher.prefetcher_final_stats();
  sandbox_d4_prefetcher.prefetcher_final_stats();
  sandbox_d8_prefetcher.prefetcher_final_stats();
  dspatch_d1_prefetcher.prefetcher_final_stats();
  dspatch_d16_prefetcher.prefetcher_final_stats();
  dspatch_d64_prefetcher.prefetcher_final_stats();
  mlop_d1_prefetcher.prefetcher_final_stats();
  mlop_d8_prefetcher.prefetcher_final_stats();
  mlop_d16_prefetcher.prefetcher_final_stats();
  stream_d1_prefetcher.prefetcher_final_stats();
  stream_d4_prefetcher.prefetcher_final_stats();
  stream_d8_prefetcher.prefetcher_final_stats();
  hint_table::instance().print_diagnostics();
}
