#include "hawkeye.h"

#include <cassert>
#include <cmath>
#include <memory>

#define bitmask(l) (((l) == 64) ? (unsigned long long)(-1LL) : ((1LL << (l))-1LL))
#define bits(x, i, l) (((x) >> (i)) & bitmask(l))

hawkeye::hawkeye(CACHE* cache)
    : champsim::modules::replacement(cache),
      NUM_SET_V(cache->NUM_SET),
      NUM_WAY_V(cache->NUM_WAY),
      NUM_CORE_V(static_cast<uint32_t>(NUM_CPUS))
{
  const bool single_core = (NUM_CORE_V == 1);

  MAXRRIP = 7;
  TIMER_SIZE = 1024;
  MAX_SHCT = 31;
  SHCT_SIZE_BITS = single_core ? 11 : 14;
  SHCT_SIZE = (1 << SHCT_SIZE_BITS);
  OPTGEN_VECTOR_SIZE = 128;
  SAMPLED_SET_BITS = single_core ? 6 : 8;
  SAMPLER_WAYS = 8;
  SAMPLED_CACHE_SIZE = single_core ? 2800 : (2800 * static_cast<int>(NUM_CORE_V));
  SAMPLER_SETS = SAMPLED_CACHE_SIZE / SAMPLER_WAYS;

  rrpv.resize(NUM_SET_V, std::vector<uint32_t>(NUM_WAY_V, MAXRRIP));
  signatures.resize(NUM_SET_V, std::vector<uint64_t>(NUM_WAY_V, 0));
  prefetched.resize(NUM_SET_V, std::vector<bool>(NUM_WAY_V, false));
  perset_mytimer.resize(NUM_SET_V, 0);
  optgen.resize(NUM_SET_V);

  for (auto& o : optgen) {
    o.init(static_cast<uint64_t>(NUM_WAY_V - 2));
  }

  addr_history.resize(SAMPLER_SETS);
  for (auto& a : addr_history) {
    a.clear();
  }

  demand_predictor = std::make_unique<HAWKEYE_PC_PREDICTOR>(MAX_SHCT, SHCT_SIZE);
  prefetch_predictor = std::make_unique<HAWKEYE_PC_PREDICTOR>(MAX_SHCT, SHCT_SIZE);

  fmt::print(stderr, "[REPL] initialize_replacement: hawkeye\n");
}

bool hawkeye::is_sampled_set(long set)
{
  int log2_sets = static_cast<int>(std::log2(NUM_SET_V));
  return bits(set, 0, static_cast<unsigned long long>(SAMPLED_SET_BITS)) ==
         bits(set, static_cast<unsigned long long>(log2_sets - SAMPLED_SET_BITS), static_cast<unsigned long long>(SAMPLED_SET_BITS));
}

void hawkeye::replace_addr_history_element(unsigned int sampler_set)
{
  uint64_t lru_addr = 0;
  for (auto it = addr_history[sampler_set].begin(); it != addr_history[sampler_set].end(); ++it) {
    if (it->second.lru == (SAMPLER_WAYS - 1)) {
      lru_addr = it->first;
      break;
    }
  }
  addr_history[sampler_set].erase(lru_addr);
}

void hawkeye::update_addr_history_lru(unsigned int sampler_set, unsigned int curr_lru)
{
  for (auto it = addr_history[sampler_set].begin(); it != addr_history[sampler_set].end(); ++it) {
    if (it->second.lru < curr_lru) {
      it->second.lru++;
    }
  }
}

long hawkeye::find_victim(uint32_t cpu, uint64_t instr_id, long set,
                           const champsim::cache_block* current_set,
                           champsim::address ip, champsim::address full_addr,
                           access_type type)
{
  for (long i = 0; i < static_cast<long>(NUM_WAY_V); i++) {
    if (rrpv[set][i] == MAXRRIP) {
      return i;
    }
  }

  uint32_t max_rrip = 0;
  int32_t lru_victim = -1;
  for (long i = 0; i < static_cast<long>(NUM_WAY_V); i++) {
    if (rrpv[set][i] >= max_rrip) {
      max_rrip = rrpv[set][i];
      lru_victim = static_cast<int32_t>(i);
    }
  }

  if (is_sampled_set(set)) {
    if (prefetched[set][lru_victim]) {
      prefetch_predictor->decrement(signatures[set][lru_victim]);
    } else {
      demand_predictor->decrement(signatures[set][lru_victim]);
    }
  }

  return static_cast<long>(lru_victim);
}

void hawkeye::replacement_cache_fill(uint32_t cpu, long set, long way,
                                     champsim::address full_addr,
                                     champsim::address ip,
                                     champsim::address victim_addr,
                                     access_type type)
{
  update_replacement_state(cpu, set, way, full_addr, ip, victim_addr, type, 0);
}

void hawkeye::update_replacement_state(uint32_t cpu, long set, long way,
                                        champsim::address full_addr,
                                        champsim::address ip,
                                        champsim::address victim_addr,
                                        access_type type, uint8_t hit)
{
  uint64_t pc_val = ip.to<uint64_t>();
  uint64_t paddr = full_addr.to<uint64_t>();

  paddr = (paddr >> 6) << 6;

  if (type == access_type::PREFETCH) {
    if (!hit)
      prefetched[set][way] = true;
  } else {
    prefetched[set][way] = false;
  }

  if (type == access_type::WRITE) {
    return;
  }

  if (is_sampled_set(set)) {
    uint64_t curr_quanta = perset_mytimer[set] % OPTGEN_VECTOR_SIZE;
    uint32_t sampler_set = static_cast<uint32_t>((paddr >> 6) % SAMPLER_SETS);
    uint64_t sampler_tag = CRC(paddr >> 12) % 256;

    if ((addr_history[sampler_set].find(sampler_tag) != addr_history[sampler_set].end()) &&
        (type != access_type::PREFETCH))
    {
      unsigned int curr_timer = static_cast<unsigned int>(perset_mytimer[set]);
      if (curr_timer < addr_history[sampler_set][sampler_tag].last_quanta) {
        curr_timer = curr_timer + TIMER_SIZE;
      }
      bool wrap = ((curr_timer - addr_history[sampler_set][sampler_tag].last_quanta) > OPTGEN_VECTOR_SIZE);
      uint64_t last_quanta = addr_history[sampler_set][sampler_tag].last_quanta % OPTGEN_VECTOR_SIZE;

      if (!wrap && optgen[set].should_cache(curr_quanta, last_quanta)) {
        if (addr_history[sampler_set][sampler_tag].prefetched) {
          prefetch_predictor->increment(addr_history[sampler_set][sampler_tag].PC);
        } else {
          demand_predictor->increment(addr_history[sampler_set][sampler_tag].PC);
        }
      } else {
        // Train negatively
        if (addr_history[sampler_set][sampler_tag].prefetched) {
          prefetch_predictor->decrement(addr_history[sampler_set][sampler_tag].PC);
        } else {
          demand_predictor->decrement(addr_history[sampler_set][sampler_tag].PC);
        }
      }

      optgen[set].add_access(curr_quanta);
      update_addr_history_lru(sampler_set, addr_history[sampler_set][sampler_tag].lru);
      addr_history[sampler_set][sampler_tag].prefetched = false;
    }
    else if (addr_history[sampler_set].find(sampler_tag) == addr_history[sampler_set].end())
    {
      if (addr_history[sampler_set].size() == static_cast<size_t>(SAMPLER_WAYS)) {
        replace_addr_history_element(sampler_set);
      }

      addr_history[sampler_set][sampler_tag].init(static_cast<unsigned int>(curr_quanta));

      if (type == access_type::PREFETCH) {
        addr_history[sampler_set][sampler_tag].mark_prefetch();
        optgen[set].add_prefetch(curr_quanta);
      } else {
        optgen[set].add_access(curr_quanta);
      }

      update_addr_history_lru(sampler_set, SAMPLER_WAYS - 1);
    }
    else
    {
      uint64_t last_quanta = addr_history[sampler_set][sampler_tag].last_quanta % OPTGEN_VECTOR_SIZE;
      if (perset_mytimer[set] - addr_history[sampler_set][sampler_tag].last_quanta < 5 * NUM_CORE_V) {
        if (optgen[set].should_cache(curr_quanta, last_quanta)) {
          if (addr_history[sampler_set][sampler_tag].prefetched) {
            prefetch_predictor->increment(addr_history[sampler_set][sampler_tag].PC);
          } else {
            demand_predictor->increment(addr_history[sampler_set][sampler_tag].PC);
          }
        }
      }

      addr_history[sampler_set][sampler_tag].mark_prefetch();
      optgen[set].add_prefetch(curr_quanta);
      update_addr_history_lru(sampler_set, addr_history[sampler_set][sampler_tag].lru);
    }

    bool new_prediction = demand_predictor->get_prediction(pc_val);
    if (type == access_type::PREFETCH) {
      new_prediction = prefetch_predictor->get_prediction(pc_val);
    }

    addr_history[sampler_set][sampler_tag].update(static_cast<unsigned int>(perset_mytimer[set]),
                                                   pc_val, new_prediction);
    addr_history[sampler_set][sampler_tag].lru = 0;
    perset_mytimer[set] = (perset_mytimer[set] + 1) % static_cast<uint64_t>(TIMER_SIZE);
  }

  bool new_prediction = demand_predictor->get_prediction(pc_val);
  if (type == access_type::PREFETCH) {
    new_prediction = prefetch_predictor->get_prediction(pc_val);
  }

  signatures[set][way] = pc_val;

  if (!new_prediction) {
    rrpv[set][way] = MAXRRIP;
  } else {
    rrpv[set][way] = 0;
    if (!hit) {
      bool saturated = false;
      for (long i = 0; i < static_cast<long>(NUM_WAY_V); i++) {
        if (rrpv[set][i] == MAXRRIP - 1) {
          saturated = true;
          break;
        }
      }

      for (long i = 0; i < static_cast<long>(NUM_WAY_V); i++) {
        if (!saturated && rrpv[set][i] < MAXRRIP - 1) {
          rrpv[set][i]++;
        }
      }
    }
    rrpv[set][way] = 0;
  }
}
