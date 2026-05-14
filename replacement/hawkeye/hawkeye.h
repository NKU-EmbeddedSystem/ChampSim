#ifndef REPLACEMENT_HAWKEYE_H
#define REPLACEMENT_HAWKEYE_H

#include <cmath>
#include <cstdint>
#include <map>
#include <vector>

#include "cache.h"
#include "modules.h"

// --- Helper Structs & Classes (Original helper_function.h / optgen.h / hawkeye_predictor.h) ---

// Information for each address
struct HAWKEYE_HISTORY {
  uint64_t PCval;
  uint32_t previousVal;
  uint32_t lru;
  bool prefetching;

  void init()
  {
    PCval = 0;
    previousVal = 0;
    lru = 0;
    prefetching = false;
  }

  void update(unsigned int currentVal, uint64_t PC)
  {
    previousVal = currentVal;
    PCval = PC;
  }

  void set_prefetch() { prefetching = true; }
};

class Hawkeye_Predictor
{
// 2K entries, 5-bit counter per entry
#define MAX_PCMAP 31
#define PCMAP_SIZE 2048
private:
  std::map<uint64_t, int> PC_Map;

  uint64_t CRC(uint64_t address)
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

public:
  Hawkeye_Predictor() {}

  bool get_prediction(uint64_t PC)
  {
    uint64_t result = CRC(PC) % PCMAP_SIZE;
    if (PC_Map.find(result) != PC_Map.end() && PC_Map[result] < ((MAX_PCMAP + 1) / 2)) {
      return false;
    }
    return true;
  }

  void increase(uint64_t PC)
  {
    uint64_t result = CRC(PC) % PCMAP_SIZE;
    if (PC_Map.find(result) == PC_Map.end()) {
      PC_Map[result] = (MAX_PCMAP + 1) / 2;
    }
    if (PC_Map[result] < MAX_PCMAP) {
      PC_Map[result] = PC_Map[result] + 1;
    } else {
      PC_Map[result] = MAX_PCMAP;
    }
  }

  void decrease(uint64_t PC)
  {
    uint64_t result = CRC(PC) % PCMAP_SIZE;
    if (PC_Map.find(result) == PC_Map.end()) {
      PC_Map[result] = (MAX_PCMAP + 1) / 2;
    }
    if (PC_Map[result] != 0) {
      PC_Map[result] = PC_Map[result] - 1;
    }
  }
};

class OPTgen
{
#define OPTGEN_SIZE 128
public:
  std::vector<unsigned int> liveness_intervals;
  uint64_t num_cache;
  uint64_t access;
  uint64_t cache_size;

  void init(uint64_t size)
  {
    num_cache = 0;
    access = 0;
    cache_size = size;
    liveness_intervals.resize(OPTGEN_SIZE, 0);
  }

  uint64_t get_optgen_hits() { return num_cache; }

  void set_access(uint64_t val)
  {
    access++;
    liveness_intervals[val] = 0;
  }

  void set_prefetch(uint64_t val) { liveness_intervals[val] = 0; }

  bool is_cache(uint64_t val, uint64_t endVal)
  {
    bool cache = true;
    unsigned int count = endVal;
    while (count != val) {
      if (liveness_intervals[count] >= cache_size) {
        cache = false;
        break;
      }
      count = (count + 1) % liveness_intervals.size();
    }

    if (cache) {
      count = endVal;
      while (count != val) {
        liveness_intervals[count]++;
        count = (count + 1) % liveness_intervals.size();
      }
      num_cache++;
    }
    return cache;
  }
};

// --- Main Replacement Class ---

class hawkeye : public champsim::modules::replacement
{
private:
  // Constants
  static constexpr int MAXRRIP = 7;
  static constexpr int SAMPLER_ENTRIES = 2800;
  static constexpr int SAMPLER_HIST = 8;
  static constexpr int SAMPLER_SETS = SAMPLER_ENTRIES / SAMPLER_HIST;
  static constexpr int TIMER_SIZE = 1024;

  // Cache Geometry
  long NUM_SET;
  long NUM_WAY;

  // Data Structures
  std::vector<uint32_t> rrip; // Flat vector simulating [set][way]
  std::vector<uint64_t> sample_signature;
  std::vector<bool> prefetching;
  std::vector<uint64_t> set_timer;

  std::vector<OPTgen> optgen_occup_vector;
  std::vector<std::map<uint64_t, HAWKEYE_HISTORY>> cache_history_sampler;

  Hawkeye_Predictor predictor_demand;
  Hawkeye_Predictor predictor_prefetch;

  // Helper Functions
  uint64_t CRC(uint64_t address) const;
  bool is_sampled_set(long set) const;
  void update_cache_history(unsigned int sample_set, unsigned int currentVal);

  // Accessor for flattened RRIP
  uint32_t& get_rrip(long set, long way) { return rrip[set * NUM_WAY + way]; }

public:
  explicit hawkeye(CACHE* cache);

  long find_victim(uint32_t triggering_cpu, uint64_t instr_id, long set, const champsim::cache_block* current_set, champsim::address ip,
                   champsim::address full_addr, access_type type);

  void update_replacement_state(uint32_t triggering_cpu, long set, long way, champsim::address full_addr, champsim::address ip, champsim::address victim_addr,
                                access_type type, uint8_t hit);

  // Optional: Print stats at end of simulation
  // void replacement_final_stats() override;
};

#endif