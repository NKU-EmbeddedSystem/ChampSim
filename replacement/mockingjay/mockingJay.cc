#include "mockingJay.h"

// ====================================================================
// Constructor
// ====================================================================
mockingJay::mockingJay(CACHE* cache) : champsim::modules::replacement(cache), NUM_SET(cache->NUM_SET), NUM_WAY(cache->NUM_WAY), NUM_CPUS_VAL(NUM_CPUS)
{
  LOG2_LLC_SET = static_cast<uint32_t>(std::log2(NUM_SET));
  LOG2_LLC_SIZE = LOG2_LLC_SET + static_cast<uint32_t>(std::log2(NUM_WAY)) + 6;

  LOG2_SAMPLED_SETS = (LOG2_LLC_SIZE > 16) ? (LOG2_LLC_SIZE - 16) : 0;

  INF_RD = NUM_WAY * HISTORY - 1;
  INF_ETR = (NUM_WAY * HISTORY / GRANULARITY) - 1;
  MAX_RD = INF_RD - 22;

  SAMPLED_CACHE_TAG_BITS = 31 - LOG2_LLC_SIZE;
  if (SAMPLED_CACHE_TAG_BITS < 1)
    SAMPLED_CACHE_TAG_BITS = 10;

  PC_SIGNATURE_BITS = (LOG2_LLC_SIZE > 10) ? (LOG2_LLC_SIZE - 10) : 6;

  FLEXMIN_PENALTY = 2.0 - std::log2(NUM_CPUS_VAL) / 4.0;

  etr.resize(NUM_SET, std::vector<int>(NUM_WAY, 0));
  etr_clock.resize(NUM_SET, GRANULARITY);
  current_timestamp.resize(NUM_SET, 0);

  initialize_sampled_sets();
}

// ====================================================================
// Helper Functions Implementation
// ====================================================================
bool mockingJay::is_sampled_set(int set)
{
  int mask_length = LOG2_LLC_SET - LOG2_SAMPLED_SETS;
  int mask = (1 << mask_length) - 1;
  return (set & mask) == ((set >> (LOG2_LLC_SET - mask_length)) & mask);
}

void mockingJay::initialize_sampled_sets()
{
  for (uint32_t set = 0; set < NUM_SET; set++) {
    if (is_sampled_set(set)) {
      sampled_cache[set].resize(SAMPLED_CACHE_WAYS);
    }
  }
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
  if (NUM_CPUS_VAL == 1) {
    pc = pc << 1;
    if (hit)
      pc = pc | 1;
    pc = pc << 1;
    if (prefetch)
      pc = pc | 1;
    pc = CRC_HASH(pc);
    pc = (pc << (64 - PC_SIGNATURE_BITS)) >> (64 - PC_SIGNATURE_BITS);
  } else {
    pc = pc << 1;
    if (prefetch)
      pc = pc | 1;
    pc = pc << 2;
    pc = pc | core;
    pc = CRC_HASH(pc);
    pc = (pc << (64 - PC_SIGNATURE_BITS)) >> (64 - PC_SIGNATURE_BITS);
  }
  return pc;
}

uint32_t mockingJay::get_sampled_cache_index(uint64_t full_addr)
{
  uint64_t block_addr = full_addr >> 6;
  uint32_t set_idx = static_cast<uint32_t>(block_addr & (NUM_SET - 1));
  return set_idx;
}

uint64_t mockingJay::get_sampled_cache_tag(uint64_t x)
{
  x >>= LOG2_LLC_SET + 6 + LOG2_SAMPLED_CACHE_SETS;
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
  auto& line = sampled_cache[set][way];

  if (!line.valid)
    return;

  if (rdp.count(line.signature)) {
    rdp[line.signature] = std::min(rdp[line.signature] + 1, INF_RD);
  } else {
    rdp[line.signature] = INF_RD;
  }
  line.valid = false;
}

int mockingJay::temporal_difference(int init, int sample)
{
  double diff_val = 0;
  if (sample > init) {
    diff_val = (double)(sample - init) * TEMP_DIFFERENCE;
    int diff = static_cast<int>(std::min(1.0, diff_val));
    return std::min(init + diff, INF_RD);
  } else if (sample < init) {
    diff_val = (double)(init - sample) * TEMP_DIFFERENCE;
    int diff = static_cast<int>(std::min(1.0, diff_val));
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
  if (global >= local)
    return global - local;
  global = global + (1 << TIMESTAMP_BITS);
  return global - local;
}

// ====================================================================
// Core Interface Implementation
// ====================================================================

void mockingJay::initialize_replacement() {}

long mockingJay::find_victim(uint32_t cpu, uint64_t instr_id, long set, const BLOCK* current_set, champsim::address ip, champsim::address full_addr,
                             access_type type)
{
  uint64_t pc_val = ip.to<uint64_t>();
  uint64_t addr_val = full_addr.to<uint64_t>();

  // 1. Invalid check
  for (int way = 0; way < (int)NUM_WAY; way++) {
    if (current_set[way].valid == false) {
      return way;
    }
  }

  // 2. Mockingjay Eviction Policy
  int max_etr_val = 0;
  int victim_way = 0;
  for (int way = 0; way < (int)NUM_WAY; way++) {
    if (std::abs(etr[set][way]) > max_etr_val || (std::abs(etr[set][way]) == max_etr_val && etr[set][way] < 0)) {
      max_etr_val = std::abs(etr[set][way]);
      victim_way = way;
    }
  }

  uint64_t pc_signature = get_pc_signature(pc_val, false, type == access_type::PREFETCH, cpu);

  // 3. Bypass Logic
  if (type != access_type::WRITE && rdp.count(pc_signature) && (rdp[pc_signature] > MAX_RD || rdp[pc_signature] / GRANULARITY > max_etr_val)) {
    // 返回 NUM_WAY 作为 bypass 信号 (配合 update_state 中的检查)
    return NUM_WAY;
  }

  return victim_way;
}

void mockingJay::update_replacement_state(uint32_t cpu, long set, long way, champsim::address full_addr, champsim::address ip, champsim::address victim_addr,
                                          access_type type, uint8_t hit)
{
  // 【关键保护】防止 Bypass 越界
  if (way >= (long)NUM_WAY) {
    return;
  }

  uint64_t pc_val = ip.to<uint64_t>();
  uint64_t addr_val = full_addr.to<uint64_t>();

  if (type == access_type::WRITE) {
    if (!hit) {
      etr[set][way] = -INF_ETR;
    }
    return;
  }

  uint64_t pc_sig = get_pc_signature(pc_val, hit, type == access_type::PREFETCH, cpu);

  if (is_sampled_set(set)) {
    uint32_t sampled_cache_index = (uint32_t)set;
    uint64_t sampled_cache_tag = get_sampled_cache_tag(addr_val);

    if (sampled_cache.find(sampled_cache_index) == sampled_cache.end()) {
      sampled_cache[sampled_cache_index].resize(SAMPLED_CACHE_WAYS);
    }

    int sampled_cache_way = search_sampled_cache(sampled_cache_tag, sampled_cache_index);

    if (sampled_cache_way > -1) {
      auto& line = sampled_cache[sampled_cache_index][sampled_cache_way];
      uint64_t last_signature = line.signature;
      uint64_t last_timestamp = (uint64_t)line.timestamp;
      int sample = time_elapsed(current_timestamp[set], (int)last_timestamp);

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
        line.valid = false;
      }
    }

    int lru_way = -1;
    int lru_rd = -1;
    auto& ways = sampled_cache[sampled_cache_index];

    for (int w = 0; w < SAMPLED_CACHE_WAYS; w++) {
      if (ways[w].valid == false) {
        lru_way = w;
        lru_rd = INF_RD + 1;
        continue;
      }

      uint64_t last_timestamp = (uint64_t)ways[w].timestamp;
      int sample = time_elapsed(current_timestamp[set], (int)last_timestamp);
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

    for (int w = 0; w < SAMPLED_CACHE_WAYS; w++) {
      if (ways[w].valid == false) {
        ways[w].valid = true;
        ways[w].signature = pc_sig;
        ways[w].tag = sampled_cache_tag;
        ways[w].timestamp = current_timestamp[set];
        break;
      }
    }

    current_timestamp[set] = increment_timestamp(current_timestamp[set]);
  }

  if (etr_clock[set] == GRANULARITY) {
    for (int w = 0; w < (int)NUM_WAY; w++) {
      if ((uint32_t)w != way && std::abs(etr[set][w]) < INF_ETR) {
        etr[set][w]--;
      }
    }
    etr_clock[set] = 0;
  }
  etr_clock[set]++;

  if (way < (long)NUM_WAY) {
    if (!rdp.count(pc_sig)) {
      if (NUM_CPUS_VAL == 1) {
        etr[set][way] = 0;
      } else {
        etr[set][way] = INF_ETR;
      }
    } else {
      if (rdp[pc_sig] > MAX_RD) {
        etr[set][way] = INF_ETR;
      } else {
        etr[set][way] = rdp[pc_sig] / GRANULARITY;
      }
    }
  }
}