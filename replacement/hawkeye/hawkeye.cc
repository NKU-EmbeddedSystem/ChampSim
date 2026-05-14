#include "hawkeye.h"

#include <algorithm>
#include <cmath>

// Constants definitions if needed
#define bitmask(l) (((l) == 64) ? (unsigned long long)(-1LL) : ((1LL << (l)) - 1LL))
#define bits(x, i, l) (((x) >> (i)) & bitmask(l))

hawkeye::hawkeye(CACHE* cache) : replacement(cache), NUM_SET(cache->NUM_SET), NUM_WAY(cache->NUM_WAY)
{
  // Initialize vectors based on cache size
  rrip.resize(NUM_SET * NUM_WAY, MAXRRIP);
  sample_signature.resize(NUM_SET * NUM_WAY, 0);
  prefetching.resize(NUM_SET * NUM_WAY, false);
  set_timer.resize(NUM_SET, 0);

  // Initialize OPTgen for each set
  optgen_occup_vector.resize(NUM_SET);
  for (int i = 0; i < NUM_SET; i++) {
    // According to original code: init(LLC_WAYS - 2)
    // Ensure strictly positive size if ways are small
    long opt_ways = (NUM_WAY > 2) ? (NUM_WAY - 2) : 1;
    optgen_occup_vector[i].init(opt_ways);
  }

  cache_history_sampler.resize(SAMPLER_SETS);
  for (int i = 0; i < SAMPLER_SETS; i++) {
    cache_history_sampler[i].clear();
  }
}

uint64_t hawkeye::CRC(uint64_t address) const
{
  unsigned long long crcPolynomial = 3988292384ULL;
  unsigned long long result = address;
  for (unsigned int i = 0; i < 32; i++)
    if ((result & 1) == 1) {
      result = (result >> 1) ^ crcPolynomial;
    } else {
      result >>= 1;
    }
  return result;
}

bool hawkeye::is_sampled_set(long set) const
{
  // Logic from original: bits(set, 0, 6) == bits(set, (log2(SETS) - 6), 6)
  // Dynamic calculation of log2(NUM_SET)
  int log2_sets = 0;
  long temp = NUM_SET;
  while (temp >>= 1)
    ++log2_sets;

  if (log2_sets < 6)
    return false; // Safety check

  return bits(set, 0, 6) == bits(set, (log2_sets - 6), 6);
}

void hawkeye::update_cache_history(unsigned int sample_set, unsigned int currentVal)
{
  for (auto& it : cache_history_sampler[sample_set]) {
    if (it.second.lru < currentVal) {
      it.second.lru++;
    }
  }
}

long hawkeye::find_victim(uint32_t triggering_cpu, uint64_t instr_id, long set, const champsim::cache_block* current_set, champsim::address ip,
                          champsim::address full_addr, access_type type)
{
  // Find the line with RRPV of 7 in that set
  for (long i = 0; i < NUM_WAY; i++) {
    if (get_rrip(set, i) == MAXRRIP) {
      return i;
    }
  }

  // If no RRPV of 7, then we find next highest RRPV value (oldest cache-friendly line)
  uint32_t max_rrpv = 0;
  long victim = -1;
  for (long i = 0; i < NUM_WAY; i++) {
    if (get_rrip(set, i) >= max_rrpv) {
      max_rrpv = get_rrip(set, i);
      victim = i;
    }
  }

  // Asserting that victim is not -1
  // Predictor will be trained negatively on evictions
  if (victim != -1 && is_sampled_set(set)) {
    // Accessing flattened arrays
    uint64_t signature = sample_signature[set * NUM_WAY + victim];
    bool is_prefetch = prefetching[set * NUM_WAY + victim];

    if (is_prefetch) {
      predictor_prefetch.decrease(signature);
    } else {
      predictor_demand.decrease(signature);
    }
  }

  return victim;
}

void hawkeye::update_replacement_state(uint32_t triggering_cpu, long set, long way, champsim::address full_addr, champsim::address ip,
                                       champsim::address victim_addr, access_type type, uint8_t hit)
{
  uint64_t paddr_val = full_addr.to<uint64_t>();
  uint64_t pc_val = ip.to<uint64_t>();

  // Mask address (paddr = (paddr >> 6) << 6)
  uint64_t paddr_aligned = (paddr_val >> 6) << 6;

  // Ignore all types that are writebacks (WRITE in ChampSim often includes WBs)
  // Original code: if (type == WRITEBACK) return;
  if (type == access_type::WRITE) {
    return;
  }

  // Flattened index
  long flat_idx = set * NUM_WAY + way;

  if (type == access_type::PREFETCH) {
    if (!hit) {
      prefetching[flat_idx] = true;
    }
  } else {
    prefetching[flat_idx] = false;
  }

  // Only if we are using sampling sets for OPTgen
  if (is_sampled_set(set)) {
    uint64_t currentVal = set_timer[set] % OPTGEN_SIZE;
    uint64_t sample_tag = CRC(paddr_aligned >> 12) % 256;
    uint32_t sample_set = (paddr_aligned >> 6) % SAMPLER_SETS;

    auto& sampler_map = cache_history_sampler[sample_set];

    // If line has been used before, ignoring prefetching (demand access operation)
    if ((type != access_type::PREFETCH) && (sampler_map.find(sample_tag) != sampler_map.end())) {
      unsigned int current_time = set_timer[set];
      if (current_time < sampler_map[sample_tag].previousVal) {
        current_time += TIMER_SIZE;
      }
      uint64_t previousVal = sampler_map[sample_tag].previousVal % OPTGEN_SIZE;
      bool isWrap = (current_time - sampler_map[sample_tag].previousVal) > OPTGEN_SIZE;

      // Train predictor positively for last PC value that was prefetched
      if (!isWrap && optgen_occup_vector[set].is_cache(currentVal, previousVal)) {
        if (sampler_map[sample_tag].prefetching) {
          predictor_prefetch.increase(sampler_map[sample_tag].PCval);
        } else {
          predictor_demand.increase(sampler_map[sample_tag].PCval);
        }
      }
      // Train predictor negatively since OPT did not cache this line
      else {
        if (sampler_map[sample_tag].prefetching) {
          predictor_prefetch.decrease(sampler_map[sample_tag].PCval);
        } else {
          predictor_demand.decrease(sampler_map[sample_tag].PCval);
        }
      }

      optgen_occup_vector[set].set_access(currentVal);
      // Update cache history
      update_cache_history(sample_set, sampler_map[sample_tag].lru);

      // Mark prefetching as false since demand access
      sampler_map[sample_tag].prefetching = false;
    }
    // If line has not been used before, mark as prefetch or demand
    else if (sampler_map.find(sample_tag) == sampler_map.end()) {
      // If sampling, find victim from cache
      if (sampler_map.size() == SAMPLER_HIST) {
        // Replace the element in the cache history (Find LRU == SAMPLER_HIST - 1)
        uint64_t addr_val = 0;
        bool found = false;
        for (auto it = sampler_map.begin(); it != sampler_map.end(); ++it) {
          if ((it->second).lru == (SAMPLER_HIST - 1)) {
            addr_val = it->first;
            found = true;
            break;
          }
        }
        if (found)
          sampler_map.erase(addr_val);
      }

      // Create new entry
      sampler_map[sample_tag].init();
      // If prefetch, mark it as a prefetching or if not, just set the demand access
      if (type == access_type::PREFETCH) {
        sampler_map[sample_tag].set_prefetch();
        optgen_occup_vector[set].set_prefetch(currentVal);
      } else {
        optgen_occup_vector[set].set_access(currentVal);
      }

      // Update cache history
      update_cache_history(sample_set, SAMPLER_HIST - 1);
    }
    // If line is neither of the two above options, then it is a prefetch line
    else {
      uint64_t previousVal = sampler_map[sample_tag].previousVal % OPTGEN_SIZE;
      if (set_timer[set] - sampler_map[sample_tag].previousVal < 5 * NUM_WAY) { // Note: Original used NUM_CORE, using NUM_WAY as proxy or keep define
        if (optgen_occup_vector[set].is_cache(currentVal, previousVal)) {
          if (sampler_map[sample_tag].prefetching) {
            predictor_prefetch.increase(sampler_map[sample_tag].PCval);
          } else {
            predictor_demand.increase(sampler_map[sample_tag].PCval);
          }
        }
      }
      sampler_map[sample_tag].set_prefetch();
      optgen_occup_vector[set].set_prefetch(currentVal);
      // Update cache history
      update_cache_history(sample_set, sampler_map[sample_tag].lru);
    }
    // Update the sample with time and PC
    sampler_map[sample_tag].update(set_timer[set], pc_val);
    sampler_map[sample_tag].lru = 0;
    set_timer[set] = (set_timer[set] + 1) % TIMER_SIZE;
  }

  // Retrieve Hawkeye's prediction for line
  bool prediction = predictor_demand.get_prediction(pc_val);
  if (type == access_type::PREFETCH) {
    prediction = predictor_prefetch.get_prediction(pc_val);
  }

  sample_signature[flat_idx] = pc_val;

  // Fix RRIP counters with correct RRPVs and age accordingly
  if (!prediction) {
    get_rrip(set, way) = MAXRRIP;
  } else {
    get_rrip(set, way) = 0;
    if (!hit) {
      // Verifying RRPV of lines has not saturated
      bool isMaxVal = false;
      for (long i = 0; i < NUM_WAY; i++) {
        if (get_rrip(set, i) == MAXRRIP - 1) {
          isMaxVal = true;
          break;
        }
      }

      // Aging cache-friendly lines that have not saturated
      for (long i = 0; i < NUM_WAY; i++) {
        if (!isMaxVal && get_rrip(set, i) < MAXRRIP - 1) {
          get_rrip(set, i)++;
        }
      }
    }
    get_rrip(set, way) = 0;
  }
}