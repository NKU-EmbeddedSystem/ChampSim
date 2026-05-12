#ifndef PREFETCHER_MLOP_H
#define PREFETCHER_MLOP_H

#include <cstdint>
#include <deque>
#include <sstream>
#include <string>
#include <vector>

#include "modules.h"
#include "pythia_adapter.h"
#include "pythia_compat.h"
#include "bakshalipour_fw.h"

enum class MLOP_State { INIT = 0, ACCESS = 1, PREFTCH = 2 };

inline char getStateChar(MLOP_State state)
{
  char sc[] = {'I', 'A', 'P'};
  return sc[(int)state];
}

inline std::string mlop_map_to_string(const std::vector<MLOP_State>& access_map,
                                       const std::vector<int>& prefetch_map)
{
  std::ostringstream oss;
  for (unsigned i = 0; i < access_map.size(); i += 1) {
    if (access_map[i] == MLOP_State::PREFTCH)
      oss << prefetch_map[i];
    else
      oss << getStateChar(access_map[i]);
  }
  return oss.str();
}

struct AccessMapData {
  std::vector<MLOP_State> access_map;
  std::vector<int> prefetch_map;
  std::deque<int> hist_queue;
};

class AccessMapTable : public LRUSetAssociativeCache<AccessMapData> {
  using Super = LRUSetAssociativeCache<AccessMapData>;

public:
  AccessMapTable(int size, int blocks_in_zone, int queue_size, int debug_level = 0,
                 int num_ways = 16)
      : Super(size, num_ways, debug_level), blocks_in_zone(blocks_in_zone),
        queue_size(queue_size)
  {
  }

  void set_state(uint64_t block_number, MLOP_State new_state, int new_fill_level = 0)
  {
    uint64_t zone_number = block_number / this->blocks_in_zone;
    int zone_offset = (int)(block_number % this->blocks_in_zone);
    uint64_t key = build_key(zone_number);
    Entry* entry = Super::find(key);
    if (!entry) {
      if (new_state == MLOP_State::INIT) return;
      Super::insert(
          key, {std::vector<MLOP_State>((unsigned)blocks_in_zone, MLOP_State::INIT),
                std::vector<int>(blocks_in_zone, 0)});
      entry = Super::find(key);
    }

    auto& access_map = entry->data.access_map;
    auto& prefetch_map = entry->data.prefetch_map;
    auto& hist_queue = entry->data.hist_queue;

    if (new_state == MLOP_State::ACCESS) {
      Super::set_mru(key);
      hist_queue.push_front(zone_offset);
      if ((int)hist_queue.size() > this->queue_size) hist_queue.pop_back();
    }

    access_map[zone_offset] = new_state;
    prefetch_map[zone_offset] = new_fill_level;

    if (new_state == MLOP_State::INIT) {
      bool all_init = true;
      for (unsigned i = 0; i < this->blocks_in_zone; i += 1)
        if (access_map[i] != MLOP_State::INIT) {
          all_init = false;
          break;
        }
      if (all_init) Super::erase(key);
    }
  }

  Entry* find_zone(uint64_t zone_number)
  {
    uint64_t key = build_key(zone_number);
    return Super::find(key);
  }

private:
  uint64_t build_key(uint64_t zone_number)
  {
    return bf_hash_index(zone_number, this->index_len);
  }

  unsigned blocks_in_zone;
  unsigned queue_size;
};

struct mlop : public pythia::PrefetcherAdapter {
  using PrefetcherAdapter::PrefetcherAdapter;

  // Knobs with defaults
  uint32_t mlop_pref_degree = 4;
  uint32_t mlop_num_updates = 100;
  float mlop_l1d_thresh = 0.25f;
  float mlop_l2c_thresh = 0.10f;
  float mlop_llc_thresh = 0.05f;
  uint32_t mlop_debug_level = 0;

  // Derived
  uint32_t PF_DEGREE = 4;
  uint32_t NUM_UPDATES = 100;
  uint32_t L1D_THRESH = 25;
  uint32_t L2C_THRESH = 10;
  uint32_t LLC_THRESH = 5;
  uint32_t blocks_in_zone = 64;
  uint32_t blocks_in_cache = 4096;
  uint32_t amt_size = 2048;
  uint32_t ORIGIN = 63;
  int32_t MAX_OFFSET = 63;
  int32_t MIN_OFFSET = -63;
  uint32_t NUM_OFFSETS = 127;

  AccessMapTable* access_map_table = nullptr;

  std::vector<std::vector<int>> pf_offset;
  std::vector<std::vector<int>> offset_scores;
  std::vector<int> pf_level;
  uint32_t update_cnt = 0;
  uint32_t debug_level = 0;

  // Stats
  uint64_t round_cnt = 0;
  uint64_t pf_degree_sum = 0, pf_degree_sqr_sum = 0;
  uint64_t max_score_le_sum = 0, max_score_le_sqr_sum = 0;
  uint64_t max_score_ri_sum = 0, max_score_ri_sqr_sum = 0;

  uint64_t zone_cnt = 0;
  bool tracking = false;
  uint64_t tracked_zone_number = 0;
  std::vector<std::string> zone_life;
  bool init_done = false;

  void invoke_prefetcher(uint64_t pc, uint64_t address, uint8_t cache_hit, uint8_t type,
                         std::vector<uint64_t>& pref_addr) override;
  void register_fill(uint64_t address) override;
  void dump_stats() override;
  void print_config() override;

  void access(uint64_t block_number);
  void prefetch(uint64_t block_number, std::vector<uint64_t>& pref_addr);
  void mark(uint64_t block_number, MLOP_State state, int fill_level = 0);
  void track_zone(uint64_t block_number);

private:
  bool is_inside_zone(int zone_offset)
  {
    return (0 <= zone_offset && zone_offset < (int)this->blocks_in_zone);
  }
};

#endif
