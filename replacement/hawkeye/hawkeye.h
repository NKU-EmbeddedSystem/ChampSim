#ifndef REPLACEMENT_HAWKEYE_H
#define REPLACEMENT_HAWKEYE_H

#include <cassert>
#include <cstdint>
#include <map>
#include <memory>
#include <vector>

#include "cache.h"
#include "modules.h"

// --- Original ADDR_INFO from hawkeye_predictor.h ---
struct ADDR_INFO {
  uint64_t addr = 0;
  uint64_t PC;
  unsigned int last_quanta;
  unsigned int lru;
  bool prefetched;

  void init(unsigned int curr_quanta)
  {
    last_quanta = 0;
    PC = 0;
    lru = 0;
    prefetched = false;
  }

  void update(unsigned int curr_quanta, uint64_t pc, bool prediction)
  {
    last_quanta = curr_quanta;
    PC = pc;
  }

  void mark_prefetch() { prefetched = true; }
};

// --- Original CRC helper ---
inline uint64_t CRC(uint64_t address)
{
  static const unsigned long long crcPolynomial = 3988292384ULL;
  unsigned long long result = address;
  for (unsigned int i = 0; i < 32; i++) {
    result = ((result & 1) == 1) ? ((result >> 1) ^ crcPolynomial) : (result >> 1);
  }
  return result;
}

// --- Original Hawkeye Predictor ---
class HAWKEYE_PC_PREDICTOR
{
private:
  std::map<uint64_t, unsigned short> SHCT;
  int max_shct_;
  int shct_size_;

public:
  HAWKEYE_PC_PREDICTOR(int max_shct, int shct_size) : max_shct_(max_shct), shct_size_(shct_size) {}

  bool get_prediction(uint64_t PC)
  {
    uint64_t signature = CRC(PC) % static_cast<uint64_t>(shct_size_);
    if (SHCT.find(signature) != SHCT.end() && SHCT[signature] < ((max_shct_ + 1) / 2)) {
      return false;
    }
    return true;
  }

  void increment(uint64_t PC)
  {
    uint64_t signature = CRC(PC) % static_cast<uint64_t>(shct_size_);
    if (SHCT.find(signature) == SHCT.end()) {
      SHCT[signature] = static_cast<unsigned short>((1 + max_shct_) / 2);
    }
    SHCT[signature] = (SHCT[signature] < max_shct_) ? static_cast<unsigned short>(SHCT[signature] + 1) : static_cast<unsigned short>(max_shct_);
  }

  void decrement(uint64_t PC)
  {
    uint64_t signature = CRC(PC) % static_cast<uint64_t>(shct_size_);
    if (SHCT.find(signature) == SHCT.end()) {
      SHCT[signature] = static_cast<unsigned short>((1 + max_shct_) / 2);
    }
    if (SHCT[signature] != 0) {
      SHCT[signature] = static_cast<unsigned short>(SHCT[signature] - 1);
    }
  }
};

// --- Original OPTgen ---
class OPTgen
{
public:
  std::vector<unsigned int> liveness_history;
  uint64_t num_cache;
  uint64_t num_dont_cache;
  uint64_t access;
  uint64_t CACHE_SIZE;

  void init(uint64_t size)
  {
    num_cache = 0;
    num_dont_cache = 0;
    access = 0;
    CACHE_SIZE = size;
    liveness_history.resize(128, 0);
  }

  uint64_t get_num_opt_hits() { return num_cache; }

  void add_access(uint64_t val)
  {
    access++;
    liveness_history[val] = 0;
  }

  void add_prefetch(uint64_t val) { liveness_history[val] = 0; }

  bool should_cache(uint64_t curr_quanta, uint64_t last_quanta)
  {
    bool is_cache = true;

    unsigned int i = static_cast<unsigned int>(last_quanta);
    while (i != curr_quanta) {
      if (liveness_history[i] >= CACHE_SIZE) {
        is_cache = false;
        break;
      }
      i = (i + 1) % liveness_history.size();
    }

    if (is_cache) {
      i = static_cast<unsigned int>(last_quanta);
      while (i != curr_quanta) {
        liveness_history[i]++;
        i = (i + 1) % liveness_history.size();
      }
      assert(i == curr_quanta);
      num_cache++;
    } else {
      num_dont_cache++;
    }

    return is_cache;
  }
};

// --- Main Replacement Class ---
class hawkeye : public champsim::modules::replacement
{
  using BLOCK = champsim::cache_block;

  long NUM_SET_V;
  long NUM_WAY_V;
  uint32_t NUM_CORE_V;

  int MAXRRIP;
  int TIMER_SIZE;
  int MAX_SHCT;
  int SHCT_SIZE_BITS;
  int SHCT_SIZE;
  int OPTGEN_VECTOR_SIZE;
  int SAMPLED_SET_BITS;
  int SAMPLER_WAYS;
  int SAMPLED_CACHE_SIZE;
  int SAMPLER_SETS;

  // 2D arrays matching original layout
  std::vector<std::vector<uint32_t>> rrpv;
  std::vector<std::vector<uint64_t>> signatures;
  std::vector<std::vector<bool>> prefetched;
  std::vector<uint64_t> perset_mytimer;

  std::vector<OPTgen> optgen;
  std::vector<std::map<uint64_t, ADDR_INFO>> addr_history;

  std::unique_ptr<HAWKEYE_PC_PREDICTOR> demand_predictor;
  std::unique_ptr<HAWKEYE_PC_PREDICTOR> prefetch_predictor;

  bool is_sampled_set(long set);
  void replace_addr_history_element(unsigned int sampler_set);
  void update_addr_history_lru(unsigned int sampler_set, unsigned int curr_lru);

public:
  explicit hawkeye(CACHE* cache);

  long find_victim(uint32_t triggering_cpu, uint64_t instr_id, long set,
                   const champsim::cache_block* current_set, champsim::address ip,
                   champsim::address full_addr, access_type type);

  void replacement_cache_fill(uint32_t triggering_cpu, long set, long way,
                              champsim::address full_addr, champsim::address ip,
                              champsim::address victim_addr, access_type type);

  void update_replacement_state(uint32_t triggering_cpu, long set, long way,
                                 champsim::address full_addr, champsim::address ip,
                                 champsim::address victim_addr, access_type type,
                                 uint8_t hit);
};

#endif
