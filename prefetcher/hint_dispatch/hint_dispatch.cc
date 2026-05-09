#include "hint_dispatch.h"

pref_hint_dispatch::pref_hint_dispatch(CACHE* cache)
    : prefetcher(cache), no_prefetcher(cache), next_line_prefetcher(cache), ip_stride_prefetcher(cache), spp_dev_prefetcher(cache),
      va_ampm_lite_prefetcher(cache)
{
}

uint32_t pref_hint_dispatch::prefetcher_cache_operate(champsim::address addr, champsim::address ip, uint8_t cache_hit, bool useful_prefetch,
                                                 access_type type, uint32_t metadata_in)
{
  const hint_entry* hint = hint_table::instance().lookup(ip.to<uint64_t>());
  int idx = hint ? hint->prefetch_policy_index : hint_table::instance().get_default_prefetch();

  uint32_t metadata = metadata_in;
  if (hint && hint->prefetch_degree > 0) {
    metadata = hint->prefetch_degree;
  }

  last_selected_index = idx;

  switch (idx) {
    case 0: return no_prefetcher.prefetcher_cache_operate(addr, ip, cache_hit, useful_prefetch, type, metadata);
    case 1: return next_line_prefetcher.prefetcher_cache_operate(addr, ip, cache_hit, useful_prefetch, type, metadata);
    case 2: return ip_stride_prefetcher.prefetcher_cache_operate(addr, ip, cache_hit, useful_prefetch, type, metadata);
    case 3: return spp_dev_prefetcher.prefetcher_cache_operate(addr, ip, cache_hit, useful_prefetch, type, metadata);
    case 4: return va_ampm_lite_prefetcher.prefetcher_cache_operate(addr, ip, cache_hit, useful_prefetch, type, metadata);
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

  switch (last_selected_index) {
    case 0: return no_prefetcher.prefetcher_cache_fill(addr, set, way, prefetch, evicted_addr, metadata_in);
    case 1: return next_line_prefetcher.prefetcher_cache_fill(addr, set, way, prefetch, evicted_addr, metadata_in);
    case 2: return ip_stride_prefetcher.prefetcher_cache_fill(addr, set, way, prefetch, evicted_addr, metadata_in);
    case 3: return spp_dev_prefetcher.prefetcher_cache_fill(addr, set, way, prefetch, evicted_addr, metadata_in);
    case 4: return va_ampm_lite_prefetcher.prefetcher_cache_fill(addr, set, way, prefetch, evicted_addr, metadata_in);
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
}
