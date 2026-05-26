#include "hint_dispatch.h"

#ifdef HINT_PROFILING
#include "profiler.h"
#endif

pref_hint_dispatch::pref_hint_dispatch(CACHE* cache)
    : prefetcher(cache), no_prefetcher(cache), next_line_prefetcher(cache), ip_stride_prefetcher(cache), spp_dev_prefetcher(cache),
      va_ampm_lite_prefetcher(cache)
{
  // Instantiate the context extractor based on the compile-time CONTEXT_FEATURE
  if constexpr (context_feature_ == ContextFeature::PAGE_OFFSET) {
    context_extractor_ = std::make_unique<PageOffsetExtractor>();
  } else if constexpr (context_feature_ == ContextFeature::DELTA_SIGNATURE) {
    context_extractor_ = std::make_unique<DeltaSignatureExtractor>();
  } else if constexpr (context_feature_ == ContextFeature::RECENT_PC_HASH) {
    context_extractor_ = std::make_unique<RecentPCHashExtractor>();
  } else if constexpr (context_feature_ == ContextFeature::COMPOSITE) {
    context_extractor_ = std::make_unique<CompositeExtractor>();
  }
  // NONE: context_extractor_ remains nullptr, skipping two-level lookup entirely
}

void pref_hint_dispatch::prefetcher_initialize()
{
  // Forward initialize to sub-prefetchers that need it (e.g. spp_dev sets up parent pointers)
  spp_dev_prefetcher.prefetcher_initialize();
}

uint32_t pref_hint_dispatch::prefetcher_cache_operate(champsim::address addr, champsim::address ip, uint8_t cache_hit, bool useful_prefetch,
                                                 access_type type, uint32_t metadata_in)
{
  // Two-level hint lookup: compute context key then try context-specific hint
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
  int idx = hint ? hint->prefetch_policy_index : hint_table::instance().get_default_prefetch();

  uint32_t metadata = metadata_in;
  if (hint && hint->prefetch_degree > 0) {
    metadata = hint->prefetch_degree;
  }

  last_selected_index = idx;

#ifdef HINT_PROFILING
  PROFILER_UPDATE_PREFETCH_POLICY(ip.to<uint64_t>(), idx);
#endif

  switch (static_cast<PrefetchPolicy>(idx)) {
    case PrefetchPolicy::NO: return no_prefetcher.prefetcher_cache_operate(addr, ip, cache_hit, useful_prefetch, type, metadata);
    case PrefetchPolicy::NEXT_LINE: return next_line_prefetcher.prefetcher_cache_operate(addr, ip, cache_hit, useful_prefetch, type, metadata);
    case PrefetchPolicy::IP_STRIDE: return ip_stride_prefetcher.prefetcher_cache_operate(addr, ip, cache_hit, useful_prefetch, type, metadata);
    case PrefetchPolicy::SPP_DEV: return spp_dev_prefetcher.prefetcher_cache_operate(addr, ip, cache_hit, useful_prefetch, type, metadata);
    case PrefetchPolicy::VA_AMPM_LITE: return va_ampm_lite_prefetcher.prefetcher_cache_operate(addr, ip, cache_hit, useful_prefetch, type, metadata);
    default: return no_prefetcher.prefetcher_cache_operate(addr, ip, cache_hit, useful_prefetch, type, metadata);
  }
}

uint32_t pref_hint_dispatch::prefetcher_cache_fill(champsim::address addr, long set, long way, uint8_t prefetch,
                                              champsim::address evicted_addr, uint32_t metadata_in)
{
  const hint_entry* hint = hint_table::instance().lookup(addr.to<uint64_t>());

  if (hint && hint->demand_filter && !prefetch) {
    return metadata_in;
  }

  switch (static_cast<PrefetchPolicy>(last_selected_index)) {
    case PrefetchPolicy::NO: return no_prefetcher.prefetcher_cache_fill(addr, set, way, prefetch, evicted_addr, metadata_in);
    case PrefetchPolicy::NEXT_LINE: return next_line_prefetcher.prefetcher_cache_fill(addr, set, way, prefetch, evicted_addr, metadata_in);
    case PrefetchPolicy::IP_STRIDE: return ip_stride_prefetcher.prefetcher_cache_fill(addr, set, way, prefetch, evicted_addr, metadata_in);
    case PrefetchPolicy::SPP_DEV: return spp_dev_prefetcher.prefetcher_cache_fill(addr, set, way, prefetch, evicted_addr, metadata_in);
    case PrefetchPolicy::VA_AMPM_LITE: return va_ampm_lite_prefetcher.prefetcher_cache_fill(addr, set, way, prefetch, evicted_addr, metadata_in);
    default: return metadata_in;
  }
}

void pref_hint_dispatch::prefetcher_cycle_operate()
{
  ip_stride_prefetcher.prefetcher_cycle_operate();
  spp_dev_prefetcher.prefetcher_cycle_operate();
}

void pref_hint_dispatch::prefetcher_final_stats()
{
  spp_dev_prefetcher.prefetcher_final_stats();
  hint_table::instance().print_diagnostics();
}
