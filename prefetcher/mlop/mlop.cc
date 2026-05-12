#include "mlop.h"

#include <algorithm>
#include <cmath>
#include <iomanip>
#include <iostream>

#include "access_type.h"

void mlop::print_config()
{
  if (!init_done) {
    init_done = true;
    PF_DEGREE = mlop_pref_degree;
    NUM_UPDATES = mlop_num_updates;
    L1D_THRESH = (uint32_t)(mlop_l1d_thresh * NUM_UPDATES);
    L2C_THRESH = (uint32_t)(mlop_l2c_thresh * NUM_UPDATES);
    LLC_THRESH = (uint32_t)(mlop_llc_thresh * NUM_UPDATES);
    debug_level = mlop_debug_level;

    // blocks_in_cache estimated (typical L2C: 512 sets * 8 ways = 4096)
    blocks_in_cache = 4096;
    blocks_in_zone = (uint32_t)(PAGE_SIZE / BLOCK_SIZE);
    amt_size = 32 * blocks_in_cache / blocks_in_zone;
    ORIGIN = blocks_in_zone - 1;
    MAX_OFFSET = (int32_t)blocks_in_zone - 1;
    MIN_OFFSET = -MAX_OFFSET;
    NUM_OFFSETS = 2 * blocks_in_zone - 1;

    access_map_table = new AccessMapTable((int)amt_size, (int)blocks_in_zone,
                                           (int)PF_DEGREE - 1, (int)debug_level);
    pf_offset = std::vector<std::vector<int>>(PF_DEGREE, std::vector<int>());
    pf_level = std::vector<int>(PF_DEGREE, 0);
    offset_scores =
        std::vector<std::vector<int>>(PF_DEGREE, std::vector<int>(NUM_OFFSETS, 0));
  }

  std::cout << "mlop_pref_degree " << mlop_pref_degree << std::endl
            << "mlop_num_updates " << mlop_num_updates << std::endl
            << "mlop_l1d_thresh " << mlop_l1d_thresh << std::endl
            << "mlop_l2c_thresh " << mlop_l2c_thresh << std::endl
            << "mlop_llc_thresh " << mlop_llc_thresh << std::endl
            << "mlop_debug_level " << mlop_debug_level << std::endl
            << "mlop_blocks_in_cache " << blocks_in_cache << std::endl
            << "mlop_blocks_in_zone " << blocks_in_zone << std::endl
            << "mlop_amt_size " << amt_size << std::endl
            << "mlop_PF_DEGREE " << PF_DEGREE << std::endl
            << "mlop_NUM_UPDATES " << NUM_UPDATES << std::endl
            << "mlop_L1D_THRESH " << L1D_THRESH << std::endl
            << "mlop_L2C_THRESH " << L2C_THRESH << std::endl
            << "mlop_LLC_THRESH " << LLC_THRESH << std::endl;
}

void mlop::access(uint64_t block_number)
{
  uint64_t zone_number = block_number / this->blocks_in_zone;
  int zone_offset = (int)(block_number % this->blocks_in_zone);

  AccessMapTable::Entry* entry = this->access_map_table->find_zone(zone_number);
  if (!entry) {
    this->zone_cnt += 1;
    if (this->zone_cnt == 100) {
      this->tracked_zone_number = zone_number;
      this->tracking = true;
      this->zone_life.push_back(std::string(this->blocks_in_zone, 'I'));
    }
    return;
  }

  std::vector<MLOP_State> access_map = entry->data.access_map;
  if (access_map[zone_offset] == MLOP_State::ACCESS) return;

  this->update_cnt += 1;
  const std::deque<int>& queue = entry->data.hist_queue;

  for (int d = 0; d <= (int)queue.size(); d += 1) {
    if (d != 0) {
      int idx = queue[d - 1];
      access_map[idx] = MLOP_State::INIT;
    }
    for (uint32_t i = 0; i < this->blocks_in_zone; i += 1) {
      if (access_map[i] == MLOP_State::ACCESS) {
        int offset = zone_offset - (int)i;
        if (offset >= MIN_OFFSET && offset <= MAX_OFFSET && offset != 0)
          this->offset_scores[d][ORIGIN + offset] += 1;
      }
    }
  }

  if (this->update_cnt == NUM_UPDATES) {
    this->update_cnt = 0;
    this->pf_level = std::vector<int>(PF_DEGREE, 0);
    this->pf_offset = std::vector<std::vector<int>>(PF_DEGREE, std::vector<int>());

    std::vector<int> max_scores(PF_DEGREE, 0);
    for (uint32_t i = 0; i < PF_DEGREE; i += 1)
      max_scores[i] = *std::max_element(this->offset_scores[i].begin(),
                                         this->offset_scores[i].end());

    std::vector<bool> pf_offset_map(NUM_OFFSETS, false);
    for (int d = (int)PF_DEGREE - 1; d >= 0; d -= 1) {
      int fill_level = 0;
      if (max_scores[d] >= (int)L2C_THRESH)
        fill_level = P_FILL_L2;
      else if (max_scores[d] >= (int)LLC_THRESH)
        fill_level = P_FILL_LLC;
      else
        continue;

      std::vector<int> best_offsets;
      for (int i = MIN_OFFSET; i <= MAX_OFFSET; i += 1) {
        int& cur_score = this->offset_scores[d][ORIGIN + i];
        if (cur_score == max_scores[d] && !pf_offset_map[ORIGIN + i])
          best_offsets.push_back(i);
      }

      this->pf_level[d] = fill_level;
      this->pf_offset[d] = best_offsets;

      for (int i = 0; i < (int)best_offsets.size(); i += 1)
        pf_offset_map[ORIGIN + best_offsets[i]] = true;
    }

    this->offset_scores =
        std::vector<std::vector<int>>(PF_DEGREE, std::vector<int>(NUM_OFFSETS, 0));

    // Stats
    this->round_cnt += 1;
    int cur_pf_degree = 0;
    for (const bool& x : pf_offset_map)
      cur_pf_degree += (x ? 1 : 0);
    this->pf_degree_sum += cur_pf_degree;
    this->pf_degree_sqr_sum += bf_square((uint64_t)cur_pf_degree);

    uint64_t max_score_le = max_scores[PF_DEGREE - 1];
    uint64_t max_score_ri = max_scores[0];
    this->max_score_le_sum += max_score_le;
    this->max_score_ri_sum += max_score_ri;
    this->max_score_le_sqr_sum += bf_square(max_score_le);
    this->max_score_ri_sqr_sum += bf_square(max_score_ri);
  }
}

void mlop::prefetch(uint64_t block_number, std::vector<uint64_t>& pref_addr)
{
  uint64_t zone_number = block_number / this->blocks_in_zone;
  int zone_offset = (int)(block_number % this->blocks_in_zone);
  AccessMapTable::Entry* entry = this->access_map_table->find_zone(zone_number);
  if (!entry) return;

  const std::vector<MLOP_State>& access_map = entry->data.access_map;
  const std::vector<int>& prefetch_map = entry->data.prefetch_map;

  for (uint32_t d = 0; d < PF_DEGREE; d += 1) {
    for (int cur_pf_offset : this->pf_offset[d]) {
      int offset_to_prefetch = zone_offset + cur_pf_offset;

      if (!is_inside_zone(offset_to_prefetch)) continue;
      if (access_map[offset_to_prefetch] == MLOP_State::ACCESS) continue;
      if (access_map[offset_to_prefetch] == MLOP_State::PREFTCH &&
          prefetch_map[offset_to_prefetch] <= this->pf_level[d])
        continue;

      uint64_t pf_block_number = (uint64_t)((int64_t)block_number + cur_pf_offset);
      uint64_t pf_addr = pf_block_number << LOG2_BLOCK_SIZE;
      pref_addr.push_back(pf_addr);

      this->mark(pf_block_number, MLOP_State::PREFTCH, this->pf_level[d]);
    }
  }
}

void mlop::mark(uint64_t block_number, MLOP_State state, int fill_level)
{
  this->access_map_table->set_state(block_number, state, fill_level);
}

void mlop::track_zone(uint64_t block_number)
{
  uint64_t zone_number = block_number / this->blocks_in_zone;
  if (this->tracking && zone_number == this->tracked_zone_number) {
    AccessMapTable::Entry* entry = this->access_map_table->find_zone(zone_number);
    if (!entry) {
      this->tracking = false;
      this->zone_life.push_back(std::string(this->blocks_in_zone, 'I'));
      return;
    }
    const auto& access_map = entry->data.access_map;
    const auto& prefetch_map = entry->data.prefetch_map;
    std::string s = mlop_map_to_string(access_map, prefetch_map);
    if (s != this->zone_life.back()) this->zone_life.push_back(s);
  }
}

void mlop::invoke_prefetcher(uint64_t /*pc*/, uint64_t address, uint8_t cache_hit,
                              uint8_t type, std::vector<uint64_t>& pref_addr)
{
  if (static_cast<access_type>(type) != access_type::LOAD) return;

  uint64_t block_number = address >> LOG2_BLOCK_SIZE;

  // Trigger access: cache miss or would be considered a trigger
  if (cache_hit == 0) access(block_number);

  mark(block_number, MLOP_State::ACCESS);
  prefetch(block_number, pref_addr);
  track_zone(block_number);
}

void mlop::register_fill(uint64_t address)
{
  uint64_t evicted_block_number = address >> LOG2_BLOCK_SIZE;
  mark(evicted_block_number, MLOP_State::INIT);
  track_zone(evicted_block_number);
}

void mlop::dump_stats()
{
  if (this->round_cnt == 0) return;

  std::cout << "[MLOP] History of tracked zone:" << std::endl;
  for (auto& x : this->zone_life)
    std::cout << x << std::endl;

  double pf_degree_mean = 1.0 * this->pf_degree_sum / this->round_cnt;
  double pf_degree_sqr_mean = 1.0 * this->pf_degree_sqr_sum / this->round_cnt;
  double pf_degree_sd =
      std::sqrt(std::max(0.0, pf_degree_sqr_mean - bf_square(pf_degree_mean)));
  std::cout << "[MLOP] Prefetch Degree Mean: " << pf_degree_mean << std::endl
            << "[MLOP] Prefetch Degree SD: " << pf_degree_sd << std::endl;

  double max_score_le_mean = 1.0 * this->max_score_le_sum / this->round_cnt;
  double max_score_le_sqr_mean = 1.0 * this->max_score_le_sqr_sum / this->round_cnt;
  double max_score_le_sd =
      std::sqrt(std::max(0.0, max_score_le_sqr_mean - bf_square(max_score_le_mean)));
  std::cout << "[MLOP] Max Score Left Mean (%): "
            << 100.0 * max_score_le_mean / NUM_UPDATES << std::endl
            << "[MLOP] Max Score Left SD (%): "
            << 100.0 * max_score_le_sd / NUM_UPDATES << std::endl;

  double max_score_ri_mean = 1.0 * this->max_score_ri_sum / this->round_cnt;
  double max_score_ri_sqr_mean = 1.0 * this->max_score_ri_sqr_sum / this->round_cnt;
  double max_score_ri_sd =
      std::sqrt(std::max(0.0, max_score_ri_sqr_mean - bf_square(max_score_ri_mean)));
  std::cout << "[MLOP] Max Score Right Mean (%): "
            << 100.0 * max_score_ri_mean / NUM_UPDATES << std::endl
            << "[MLOP] Max Score Right SD (%): "
            << 100.0 * max_score_ri_sd / NUM_UPDATES << std::endl;
}
