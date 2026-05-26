#include "hint_dispatch.h"

repl_hint_dispatch::repl_hint_dispatch(CACHE* cache)
    : replacement(cache), lru_policy(cache), ship_policy(cache), drrip_policy(cache), srrip_policy(cache), random_policy(cache)
{
}

long repl_hint_dispatch::find_victim(uint32_t triggering_cpu, uint64_t instr_id, long set, const champsim::cache_block* current_set,
                                champsim::address ip, champsim::address full_addr, access_type type)
{
  const hint_entry* hint = hint_table::instance().lookup(ip.to<uint64_t>());
  int idx = hint ? hint->replacement_policy_index : hint_table::instance().get_default_replacement();

  switch (static_cast<ReplacementPolicy>(idx)) {
    case ReplacementPolicy::LRU: return lru_policy.find_victim(triggering_cpu, instr_id, set, current_set, ip, full_addr, type);
    case ReplacementPolicy::SHIP: return ship_policy.find_victim(triggering_cpu, instr_id, set, current_set, ip, full_addr, type);
    case ReplacementPolicy::DRRIP: return drrip_policy.find_victim(triggering_cpu, instr_id, set, current_set, ip, full_addr, type);
    case ReplacementPolicy::SRRIP: return srrip_policy.find_victim(triggering_cpu, instr_id, set, current_set, ip, full_addr, type);
    case ReplacementPolicy::RANDOM: return random_policy.find_victim(triggering_cpu, instr_id, set, current_set,
                                             ip.to<uint64_t>(), full_addr.to<uint64_t>(), type);
    default: return lru_policy.find_victim(triggering_cpu, instr_id, set, current_set, ip, full_addr, type);
  }
}

void repl_hint_dispatch::update_replacement_state(uint32_t triggering_cpu, long set, long way, champsim::address full_addr,
                                             champsim::address ip, champsim::address victim_addr, access_type type, uint8_t hit)
{
  if (!hit)
    return;
  lru_policy.update_replacement_state(triggering_cpu, set, way, full_addr, ip, victim_addr, type, hit);
  ship_policy.update_replacement_state(triggering_cpu, set, way, full_addr, ip, victim_addr, type, hit);
  drrip_policy.update_replacement_state(triggering_cpu, set, way, full_addr, ip, victim_addr, type, hit);
  srrip_policy.update_replacement_state(triggering_cpu, set, way, full_addr, ip, victim_addr, type, hit);
}

void repl_hint_dispatch::replacement_cache_fill(uint32_t triggering_cpu, long set, long way, champsim::address full_addr,
                                           champsim::address ip, champsim::address victim_addr, access_type type)
{
  lru_policy.replacement_cache_fill(triggering_cpu, set, way, full_addr, ip, victim_addr, type);
}

void repl_hint_dispatch::replacement_final_stats()
{
}
