#include "bingo.h"

#include <algorithm>
#include <cmath>
#include <iomanip>
#include <iostream>

#include "access_type.h"

void bingo::print_config()
{
  if (!init_done) {
    init_done = true;
    pattern_len = bingo_pattern_len;

    if (!bingo_pc_address_fill_level.compare("L1"))
      pc_address_fill_level = P_FILL_L1;
    else if (!bingo_pc_address_fill_level.compare("L2"))
      pc_address_fill_level = P_FILL_L2;
    else if (!bingo_pc_address_fill_level.compare("LLC"))
      pc_address_fill_level = P_FILL_LLC;

    filter_table = FilterTable(bingo_ft_size, bingo_debug_level);
    accumulation_table =
        AccumulationTable(bingo_at_size, bingo_pattern_len, bingo_debug_level);
    pht = PatternHistoryTable(bingo_pht_size, bingo_pattern_len, bingo_min_addr_width,
                               bingo_max_addr_width, bingo_pc_width, bingo_debug_level,
                               bingo_pht_ways);
    pf_streamer = PrefetchStreamer(bingo_pf_streamer_size, bingo_pattern_len, bingo_debug_level);
  }

  std::cout << "bingo_region_size " << bingo_region_size << std::endl
            << "bingo_pattern_len " << bingo_pattern_len << std::endl
            << "bingo_pc_width " << bingo_pc_width << std::endl
            << "bingo_min_addr_width " << bingo_min_addr_width << std::endl
            << "bingo_max_addr_width " << bingo_max_addr_width << std::endl
            << "bingo_ft_size " << bingo_ft_size << std::endl
            << "bingo_at_size " << bingo_at_size << std::endl
            << "bingo_pht_size " << bingo_pht_size << std::endl
            << "bingo_pht_ways " << bingo_pht_ways << std::endl
            << "bingo_pf_streamer_size " << bingo_pf_streamer_size << std::endl
            << "bingo_debug_level " << bingo_debug_level << std::endl
            << "bingo_l1d_thresh " << bingo_l1d_thresh << std::endl
            << "bingo_l2c_thresh " << bingo_l2c_thresh << std::endl
            << "bingo_llc_thresh " << bingo_llc_thresh << std::endl
            << "bingo_pc_address_fill_level " << bingo_pc_address_fill_level << std::endl;
}

void bingo::access(uint64_t block_number, uint64_t pc)
{
  uint64_t region_number = block_number / this->pattern_len;
  int region_offset = (int)(block_number % this->pattern_len);

  bool success = this->accumulation_table.set_pattern(region_number, region_offset);
  if (success)
    return;

  FilterTable::Entry* entry = this->filter_table.find_by_region(region_number);
  if (!entry) {
    this->filter_table.insert_region(region_number, pc, region_offset);
    std::vector<int> pattern = this->find_in_pht(pc, block_number);
    if (pattern.empty())
      return;
    this->pf_streamer.insert_region(region_number, pattern);
    return;
  }

  if (entry->data.offset != region_offset) {
    uint64_t at_region_number =
        bf_hash_index(entry->key, this->filter_table.get_index_len());
    AccumulationTable::Entry victim =
        this->accumulation_table.insert_entry(at_region_number, entry->data.pc,
                                               entry->data.offset);
    this->accumulation_table.set_pattern(region_number, region_offset);
    this->filter_table.erase_region(region_number);
    if (victim.valid)
      this->insert_in_pht(victim);
  }
}

void bingo::eviction(uint64_t block_number)
{
  uint64_t region_number = block_number / this->pattern_len;
  this->filter_table.erase_region(region_number);
  AccumulationTable::Entry* entry = this->accumulation_table.erase_region(region_number);
  if (entry)
    this->insert_in_pht(*entry);
}

int bingo::prefetch(uint64_t block_number, std::vector<uint64_t>& pref_addr)
{
  return this->pf_streamer.issue_prefetches(block_number, pref_addr);
}

std::vector<int> bingo::find_in_pht(uint64_t pc, uint64_t address)
{
  std::vector<std::vector<bool>> matches = this->pht.find_patterns(pc, address);
  this->pht_access_cnt += 1;
  BingoEvent pht_last_event = this->pht.get_last_event();
  uint64_t region_number = address / this->pattern_len;
  if (pht_last_event != BingoEvent::MISS)
    this->pht_events[region_number] = pht_last_event;

  std::vector<int> pattern;
  if (pht_last_event == BingoEvent::PC_ADDRESS) {
    this->pht_pc_address_cnt += 1;
    pattern.resize(this->pattern_len, 0);
    for (int i = 0; i < this->pattern_len; i += 1)
      if (matches[0][i])
        pattern[i] = pc_address_fill_level;
  } else if (pht_last_event == BingoEvent::PC_OFFSET) {
    this->pht_pc_offset_cnt += 1;
    pattern = this->vote(matches);
  } else if (pht_last_event == BingoEvent::MISS) {
    this->pht_miss_cnt += 1;
  }

  if (pht_last_event != BingoEvent::MISS) {
    this->region_pref_cnt += 1;
    for (int i = 0; i < (int)pattern.size(); i += 1)
      if (pattern[i] != 0)
        this->pref_level_cnt[pattern[i]] += 1;
  }
  return pattern;
}

void bingo::insert_in_pht(const AccumulationTable::Entry& entry)
{
  uint64_t pc = entry.data.pc;
  uint64_t region_number =
      bf_hash_index(entry.key, this->accumulation_table.get_index_len());
  uint64_t address = region_number * this->pattern_len + entry.data.offset;
  const std::vector<bool>& pattern = entry.data.pattern;
  this->pht.insert_pattern(pc, address, pattern);
}

std::vector<int> bingo::vote(const std::vector<std::vector<bool>>& x)
{
  int n = (int)x.size();
  if (n == 0)
    return std::vector<int>();

  this->vote_cnt += 1;
  this->voter_sum += n;
  this->voter_sqr_sum += bf_square((uint64_t)n);

  bool pf_flag = false;
  std::vector<int> res(this->pattern_len, 0);
  for (int i = 0; i < this->pattern_len; i += 1) {
    int cnt = 0;
    for (int j = 0; j < n; j += 1)
      if (x[j][i])
        cnt += 1;
    double p = 1.0 * cnt / n;
    if (p >= bingo_l1d_thresh)
      res[i] = P_FILL_L1;
    else if (p >= bingo_l2c_thresh)
      res[i] = P_FILL_L2;
    else if (p >= bingo_llc_thresh)
      res[i] = P_FILL_LLC;
    else
      res[i] = 0;
    if (res[i] != 0)
      pf_flag = true;
  }
  if (!pf_flag)
    return std::vector<int>();
  return res;
}

void bingo::invoke_prefetcher(uint64_t pc, uint64_t addr, uint8_t cache_hit, uint8_t type,
                               std::vector<uint64_t>& pref_addr)
{
  if (type != static_cast<uint8_t>(access_type::LOAD))
    return;

  uint64_t block_number = addr >> LOG2_BLOCK_SIZE;

  access(block_number, pc);
  prefetch(block_number, pref_addr);
}

void bingo::register_fill(uint64_t addr)
{
  uint64_t evicted_block_number = addr >> LOG2_BLOCK_SIZE;
  eviction(evicted_block_number);
}

void bingo::dump_stats()
{
  std::cout << "[Bingo] PHT Access: " << this->pht_access_cnt << std::endl
            << "[Bingo] PHT Hit PC+Addr: " << this->pht_pc_address_cnt << std::endl
            << "[Bingo] PHT Hit PC+Offs: " << this->pht_pc_offset_cnt << std::endl
            << "[Bingo] PHT Miss: " << this->pht_miss_cnt << std::endl
            << std::endl
            << "[Bingo] Prefetch PC+Addr: " << this->prefetch_cnt[0] << std::endl
            << "[Bingo] Prefetch PC+Offs: " << this->prefetch_cnt[1] << std::endl
            << std::endl
            << "[Bingo] Useful PC+Addr: " << this->useful_cnt[0] << std::endl
            << "[Bingo] Useful PC+Offs: " << this->useful_cnt[1] << std::endl
            << std::endl
            << "[Bingo] Useless PC+Addr: " << this->useless_cnt[0] << std::endl
            << "[Bingo] Useless PC+Offs: " << this->useless_cnt[1] << std::endl
            << std::endl;

  double l1_pref_per_region =
      this->region_pref_cnt ? 1.0 * this->pref_level_cnt[P_FILL_L1] / this->region_pref_cnt : 0;
  double l2_pref_per_region =
      this->region_pref_cnt ? 1.0 * this->pref_level_cnt[P_FILL_L2] / this->region_pref_cnt : 0;
  double l3_pref_per_region =
      this->region_pref_cnt ? 1.0 * this->pref_level_cnt[P_FILL_LLC] / this->region_pref_cnt : 0;
  double no_pref_per_region = (double)this->pattern_len -
                              (l1_pref_per_region + l2_pref_per_region + l3_pref_per_region);

  std::cout << "[Bingo] L1 Prefetch per Region: " << l1_pref_per_region << std::endl
            << "[Bingo] L2 Prefetch per Region: " << l2_pref_per_region << std::endl
            << "[Bingo] L3 Prefetch per Region: " << l3_pref_per_region << std::endl
            << "[Bingo] No Prefetch per Region: " << no_pref_per_region << std::endl
            << std::endl;

  double voter_mean = this->vote_cnt ? 1.0 * this->voter_sum / this->vote_cnt : 0;
  double voter_sqr_mean =
      this->vote_cnt ? 1.0 * this->voter_sqr_sum / this->vote_cnt : 0;
  double voter_sd = std::sqrt(std::max(0.0, voter_sqr_mean - bf_square(voter_mean)));
  std::cout << "[Bingo] Number of Voters Mean: " << voter_mean << std::endl
            << "[Bingo] Number of Voters SD: " << voter_sd << std::endl;
}
