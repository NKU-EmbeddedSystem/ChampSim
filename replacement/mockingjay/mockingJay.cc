#include "mockingJay.h"
#include <cmath>
#include <cstdlib>

mockingJay::mockingJay(CACHE* cache) : champsim::modules::replacement(cache), NUM_SET(cache->NUM_SET), NUM_WAY(cache->NUM_WAY)
{
  LOG2_LLC_SET = static_cast<uint32_t>(std::log2(NUM_SET));
  LOG2_LLC_SIZE = LOG2_LLC_SET + static_cast<uint32_t>(std::log2(NUM_WAY)) + 6;  // +6 = LOG2_BLOCK_SIZE
  LOG2_SAMPLED_SETS = LOG2_LLC_SIZE - 16;

  // Constants matching original
  INF_RD = NUM_WAY * HISTORY - 1;
  INF_ETR = (NUM_WAY * HISTORY / GRANULARITY) - 1;
  MAX_RD = INF_RD - 22;

  SAMPLED_CACHE_TAG_BITS = 31 - LOG2_LLC_SIZE;
  PC_SIGNATURE_BITS = LOG2_LLC_SIZE - 10;

  FLEXMIN_PENALTY = 2.0 - std::log2(NUM_CPUS) / 4.0;

  // Allocate data structures
  etr.resize(NUM_SET, std::vector<int>(NUM_WAY, 0));
  etr_clock.resize(NUM_SET, 0);
  current_timestamp.resize(NUM_SET, 0);

  initialize_replacement();
}

void mockingJay::initialize_replacement()
{
  fmt::print(stderr, "[REPL] initialize_replacement: mockingJay\n");
  for (uint32_t i = 0; i < NUM_SET; i++) {
    etr_clock[i] = GRANULARITY;
    current_timestamp[i] = 0;
  }
  for (uint32_t s = 0; s < NUM_SET; s++) {
    if (is_sampled_set(static_cast<int>(s))) {
      int modifier = 1 << LOG2_LLC_SET;
      int limit = 1 << LOG2_SAMPLED_CACHE_SETS;
      for (int i = 0; i < limit; i++) {
        sampled_cache[s + modifier * i].resize(SAMPLED_CACHE_WAYS);
      }
    }
  }
}

bool mockingJay::is_sampled_set(int set)
{
  int mask_length = static_cast<int>(LOG2_LLC_SET) - static_cast<int>(LOG2_SAMPLED_SETS);
  int mask = (1 << mask_length) - 1;
  return (set & mask) == ((set >> (static_cast<int>(LOG2_LLC_SET) - mask_length)) & mask);
}

uint64_t mockingJay::CRC_HASH(uint64_t _blockAddress)
{
  static const unsigned long long crcPolynomial = 3988292384ULL;
  unsigned long long _returnVal = _blockAddress;
  for (unsigned int i = 0; i < 3; i++)
    _returnVal = ((_returnVal & 1) == 1) ? ((_returnVal >> 1) ^ crcPolynomial) : (_returnVal >> 1);
  return _returnVal;
}

uint64_t mockingJay::get_pc_signature(uint64_t pc, bool hit, bool prefetch, uint32_t core)
{
  if (NUM_CPUS == 1) {
    pc = pc << 1;
    if (hit) {
      pc = pc | 1;
    }
    pc = pc << 1;
    if (prefetch) {
      pc = pc | 1;
    }
    pc = CRC_HASH(pc);
    pc = (pc << (64 - PC_SIGNATURE_BITS)) >> (64 - PC_SIGNATURE_BITS);
  } else {
    pc = pc << 1;
    if (prefetch) {
      pc = pc | 1;
    }
    pc = pc << 2;
    pc = pc | core;
    pc = CRC_HASH(pc);
    pc = (pc << (64 - PC_SIGNATURE_BITS)) >> (64 - PC_SIGNATURE_BITS);
  }
  return pc;
}

uint32_t mockingJay::get_sampled_cache_index(uint64_t full_addr)
{
  full_addr = full_addr >> 6;  // LOG2_BLOCK_SIZE
  full_addr = (full_addr << (64 - (LOG2_SAMPLED_CACHE_SETS + LOG2_LLC_SET))) >> (64 - (LOG2_SAMPLED_CACHE_SETS + LOG2_LLC_SET));
  return static_cast<uint32_t>(full_addr);
}

uint64_t mockingJay::get_sampled_cache_tag(uint64_t x)
{
  x >>= LOG2_LLC_SET + 6 + LOG2_SAMPLED_CACHE_SETS;  // +6 = LOG2_BLOCK_SIZE
  x = (x << (64 - SAMPLED_CACHE_TAG_BITS)) >> (64 - SAMPLED_CACHE_TAG_BITS);
  return x;
}

int mockingJay::search_sampled_cache(uint64_t blockAddress, uint32_t set)
{
  if (sampled_cache.find(set) == sampled_cache.end())
    return -1;
  auto& ways = sampled_cache[set];
  for (int way = 0; way < SAMPLED_CACHE_WAYS; way++) {
    if (ways[way].valid && (ways[way].tag == blockAddress)) {
      return way;
    }
  }
  return -1;
}

void mockingJay::detrain(uint32_t set, int way)
{
  if (sampled_cache.find(set) == sampled_cache.end())
    return;
  auto& temp = sampled_cache[set][way];
  if (!temp.valid) {
    return;
  }
  if (rdp.count(temp.signature)) {
    rdp[temp.signature] = std::min(rdp[temp.signature] + 1, INF_RD);
  } else {
    rdp[temp.signature] = INF_RD;
  }
  sampled_cache[set][way].valid = false;
}

int mockingJay::temporal_difference(int init, int sample)
{
  if (sample > init) {
    int diff = sample - init;
    double d = diff * TEMP_DIFFERENCE;
    diff = std::min(1, (int)d);
    return std::min(init + diff, INF_RD);
  } else if (sample < init) {
    int diff = init - sample;
    double d = diff * TEMP_DIFFERENCE;
    diff = std::min(1, (int)d);
    return std::max(init - diff, 0);
  } else {
    return init;
  }
}

int mockingJay::increment_timestamp(int input)
{
  input++;
  input = input % (1 << TIMESTAMP_BITS);
  return input;
}

int mockingJay::time_elapsed(int global, int local)
{
  if (global >= local) {
    return global - local;
  }
  global = global + (1 << TIMESTAMP_BITS);
  return global - local;
}

// --- Core Interface ---

long mockingJay::find_victim(uint32_t cpu, uint64_t instr_id, long set, const BLOCK* current_set, champsim::address ip,
                              champsim::address full_addr, access_type type)
{
  uint64_t pc_val = ip.to<uint64_t>();
  uint64_t addr_val = full_addr.to<uint64_t>();

  // Invalid block check
  for (int way = 0; way < static_cast<int>(NUM_WAY); way++) {
    if (current_set[way].valid == false) {
      return way;
    }
  }

  // Mockingjay eviction policy
  int max_etr = 0;
  int victim_way = 0;
  for (int way = 0; way < static_cast<int>(NUM_WAY); way++) {
    if (std::abs(etr[set][way]) > max_etr ||
        (std::abs(etr[set][way]) == max_etr && etr[set][way] < 0)) {
      max_etr = std::abs(etr[set][way]);
      victim_way = way;
    }
  }

  uint64_t pc_sig = get_pc_signature(pc_val, false, type == access_type::PREFETCH, cpu);
  if (type != access_type::WRITE && rdp.count(pc_sig) &&
      (rdp[pc_sig] > MAX_RD || rdp[pc_sig] / GRANULARITY > max_etr)) {
    return static_cast<long>(NUM_WAY);  // bypass
  }

  return victim_way;
}

void mockingJay::replacement_cache_fill(uint32_t cpu, long set, long way, champsim::address full_addr, champsim::address ip,
                                        champsim::address victim_addr, access_type type)
{
  update_replacement_state(cpu, set, way, full_addr, ip, victim_addr, type, 0);
}

void mockingJay::update_replacement_state(uint32_t cpu, long set, long way, champsim::address full_addr,
                                           champsim::address ip, champsim::address victim_addr,
                                           access_type type, uint8_t hit)
{
  uint64_t pc_val = ip.to<uint64_t>();
  uint64_t addr_val = full_addr.to<uint64_t>();

  if (type == access_type::WRITE) {
    if (!hit) {
      if (way < static_cast<long>(NUM_WAY)) {
        etr[set][way] = -INF_ETR;
      }
    }
    return;
  }

  pc_val = get_pc_signature(pc_val, hit != 0, type == access_type::PREFETCH, cpu);

  if (is_sampled_set(static_cast<int>(set))) {
    uint32_t sampled_cache_index = get_sampled_cache_index(addr_val);
    uint64_t sampled_cache_tag = get_sampled_cache_tag(addr_val);
    int sampled_cache_way = search_sampled_cache(sampled_cache_tag, sampled_cache_index);

    if (sampled_cache_way > -1) {
      auto& line = sampled_cache[sampled_cache_index][sampled_cache_way];
      uint64_t last_signature = line.signature;
      uint64_t last_timestamp = static_cast<uint64_t>(line.timestamp);
      int sample = time_elapsed(current_timestamp[set], static_cast<int>(last_timestamp));

      if (sample <= INF_RD) {
        if (type == access_type::PREFETCH) {
          sample = static_cast<int>(sample * FLEXMIN_PENALTY);
        }
        if (rdp.count(last_signature)) {
          int init = rdp[last_signature];
          rdp[last_signature] = temporal_difference(init, sample);
        } else {
          rdp[last_signature] = sample;
        }
        sampled_cache[sampled_cache_index][sampled_cache_way].valid = false;
      }
    }

    // Find LRU entry in sampled cache
    int lru_way = -1;
    int lru_rd = -1;
    auto& slist = sampled_cache[sampled_cache_index];
    for (int w = 0; w < SAMPLED_CACHE_WAYS; w++) {
      if (slist[w].valid == false) {
        lru_way = w;
        lru_rd = INF_RD + 1;
        continue;
      }
      uint64_t lst = static_cast<uint64_t>(slist[w].timestamp);
      int sample = time_elapsed(current_timestamp[set], static_cast<int>(lst));
      if (sample > INF_RD) {
        lru_way = w;
        lru_rd = INF_RD + 1;
        detrain(sampled_cache_index, w);
      } else if (sample > lru_rd) {
        lru_way = w;
        lru_rd = sample;
      }
    }
    detrain(sampled_cache_index, lru_way);

    // Insert new entry
    for (int w = 0; w < SAMPLED_CACHE_WAYS; w++) {
      if (slist[w].valid == false) {
        slist[w].valid = true;
        slist[w].signature = pc_val;
        slist[w].tag = sampled_cache_tag;
        slist[w].timestamp = current_timestamp[set];
        break;
      }
    }

    current_timestamp[set] = increment_timestamp(current_timestamp[set]);
  }

  // ETR aging
  if (etr_clock[set] == GRANULARITY) {
    for (int w = 0; w < static_cast<int>(NUM_WAY); w++) {
      if (static_cast<long>(w) != way && std::abs(etr[set][w]) < INF_ETR) {
        etr[set][w]--;
      }
    }
    etr_clock[set] = 0;
  }
  etr_clock[set]++;

  // ETR assignment
  if (way < static_cast<long>(NUM_WAY)) {
    if (!rdp.count(pc_val)) {
      if (NUM_CPUS == 1) {
        etr[set][way] = 0;
      } else {
        etr[set][way] = INF_ETR;
      }
    } else {
      if (rdp[pc_val] > MAX_RD) {
        etr[set][way] = INF_ETR;
      } else {
        etr[set][way] = rdp[pc_val] / GRANULARITY;
      }
    }
  }
}
