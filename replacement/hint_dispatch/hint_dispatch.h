#ifndef REPLACEMENT_HINT_DISPATCH_H
#define REPLACEMENT_HINT_DISPATCH_H

#include "cache.h"
#include "hint_table.h"
#include "modules.h"

// Sub-policy includes — the 5 existing ChampSim replacement policies
#include "../drrip/drrip.h"
#include "../lru/lru.h"
#include "../random/random.h"
#include "../ship/ship.h"
#include "../srrip/srrip.h"

// hint_dispatch is a standalone replacement module that wraps an ensemble of
// 5 sub-policies and dispatches to the selected one based on a PC-keyed hint
// table lookup. All sub-policies receive update_replacement_state() calls so
// each maintains correct independent state.
//
// The existing replacement_module_model<Rs...> template (cache.h:273-293)
// CANNOT be reused because its fold-expression iterates ALL sub-policies on
// every access. hint_dispatch needs to call exactly ONE sub-policy per access
// based on the runtime hint. A custom dispatch class is required.

class repl_hint_dispatch : public champsim::modules::replacement
{
  // Sub-policy instances — each maintains its own independent state
  lru lru_policy;
  ship ship_policy;
  drrip drrip_policy;
  srrip srrip_policy;
  struct random random_policy;

  static constexpr int NUM_POLICIES = 5;

public:
  explicit repl_hint_dispatch(CACHE* cache);

  long find_victim(uint32_t triggering_cpu, uint64_t instr_id, long set, const champsim::cache_block* current_set,
                   champsim::address ip, champsim::address full_addr, access_type type);

  void update_replacement_state(uint32_t triggering_cpu, long set, long way, champsim::address full_addr,
                                champsim::address ip, champsim::address victim_addr, access_type type, uint8_t hit);

  void replacement_cache_fill(uint32_t triggering_cpu, long set, long way, champsim::address full_addr,
                              champsim::address ip, champsim::address victim_addr, access_type type);

  void replacement_final_stats();
};

#endif
