#include "sandbox.h"
#include <algorithm>
#include <cassert>
#include <cmath>
#include <cstdlib>

void sandbox::print_config()
{
  if (!initialized) {
    pref_degree = sandbox_pref_degree;
    init_evaluated_offsets();
    init_non_evaluated_offsets();
    reset_eval();
    initialized = true;
  }
  std::cout << "sandbox_pref_degree " << sandbox_pref_degree << std::endl
            << "sandbox_enable_stream_detect " << sandbox_enable_stream_detect << std::endl
            << "sandbox_stream_detect_length " << sandbox_stream_detect_length << std::endl
            << "sandbox_num_access_in_phase " << sandbox_num_access_in_phase << std::endl
            << "sandbox_num_cycle_offsets " << sandbox_num_cycle_offsets << std::endl
            << "sandbox_bloom_filter_size " << sandbox_bloom_filter_size << std::endl
            << "sandbox_seed " << sandbox_seed << std::endl;
}

void sandbox::init_evaluated_offsets()
{
  for (int32_t i = 1; i <= 8; ++i) evaluated_offsets.push_back(new Score(i));
  for (int32_t i = -8; i <= -1; ++i) evaluated_offsets.push_back(new Score(i));
}

void sandbox::init_non_evaluated_offsets()
{
  for (int32_t i = 9; i <= 16; ++i) non_evaluated_offsets.push_back(i);
  for (int32_t i = -16; i <= -9; ++i) non_evaluated_offsets.push_back(i);
}

void sandbox::reset_eval()
{
  eval.curr_ptr = 0;
  eval.total_demand = 0;
  eval.filter_hit = 0;
  filter_set.clear();
}

void sandbox::invoke_prefetcher(uint64_t /*pc*/, uint64_t address, uint8_t /*cache_hit*/, uint8_t /*type*/,
                                 std::vector<uint64_t>& pref_addr)
{
  uint64_t page = address >> LOG2_PAGE_SIZE;
  uint32_t offset = (address >> LOG2_BLOCK_SIZE) & ((1ull << (LOG2_PAGE_SIZE - LOG2_BLOCK_SIZE)) - 1);

  stats.called++;

  // Step 1: check demand access in filter
  eval.total_demand++;
  stats.step1.filter_lookup++;
  bool lookup = filter_lookup(address);
  if (lookup) {
    stats.step1.filter_hit++;
    eval.filter_hit++;
    evaluated_offsets[eval.curr_ptr]->score++;
    if (sandbox_enable_stream_detect) {
      for (uint32_t i = 1; i <= sandbox_stream_detect_length; ++i) {
        int32_t stream_offset = static_cast<int32_t>(offset) - (evaluated_offsets[eval.curr_ptr]->offset * static_cast<int32_t>(i));
        if (stream_offset >= 0 && stream_offset < 64) {
          uint64_t stream_addr = (page << LOG2_PAGE_SIZE) + (static_cast<uint64_t>(stream_offset) << LOG2_BLOCK_SIZE);
          if (filter_lookup(stream_addr)) evaluated_offsets[eval.curr_ptr]->score++;
        }
      }
    }
  }

  // Step 2: generate pseudo prefetch and add to filter
  uint32_t pref_offset = offset + evaluated_offsets[eval.curr_ptr]->offset;
  if (pref_offset < 64) {
    uint64_t pseudo_pref_addr = (page << LOG2_PAGE_SIZE) + (static_cast<uint64_t>(pref_offset) << LOG2_BLOCK_SIZE);
    filter_set.insert(pseudo_pref_addr);
    stats.step2.filter_add++;
  }

  // Step 3: check end of phase / end of round
  if (eval.total_demand == sandbox_num_access_in_phase) {
    stats.step3.end_of_phase++;
    uint32_t next_ptr = eval.curr_ptr + 1;
    if (next_ptr < evaluated_offsets.size()) {
      reset_eval(); eval.curr_ptr = next_ptr;
    } else {
      stats.step3.end_of_round++;
      end_of_round(); reset_eval(); eval.curr_ptr = 0;
    }
  }

  // Step 4: generate actual prefetches based on scores
  std::vector<Score*> pos_offsets, neg_offsets;
  get_offset_list_sorted(pos_offsets, neg_offsets);
  generate_prefetch(pos_offsets, pref_degree, page, offset, pref_addr);
  uint32_t pos_pref = static_cast<uint32_t>(pref_addr.size());
  generate_prefetch(neg_offsets, pref_degree, page, offset, pref_addr);
  uint32_t neg_pref = static_cast<uint32_t>(pref_addr.size()) - pos_pref;
  destroy_offset_list(pos_offsets);
  destroy_offset_list(neg_offsets);

  stats.step4.pref_generated += pref_addr.size();
  stats.step4.pref_generated_pos += pos_pref;
  stats.step4.pref_generated_neg += neg_pref;
}

void sandbox::get_offset_list_sorted(std::vector<Score*>& pos, std::vector<Score*>& neg)
{
  for (auto* s : evaluated_offsets) {
    if (s->offset > 0) pos.push_back(new Score(s->offset, s->score));
    else neg.push_back(new Score(s->offset, s->score));
  }
  std::sort(pos.begin(), pos.end(), [](Score* a, Score* b) { return std::abs(a->offset) < std::abs(b->offset); });
  std::sort(neg.begin(), neg.end(), [](Score* a, Score* b) { return std::abs(a->offset) < std::abs(b->offset); });
}

void sandbox::generate_prefetch(std::vector<Score*> olist, uint32_t pd, uint64_t page,
                                 uint32_t offset, std::vector<uint64_t>& pref_addr)
{
  uint32_t count = 0;
  for (auto* s : olist) {
    for (uint32_t la = 1; la <= sandbox_stream_detect_length + 1; ++la) {
      if (la > 1 && !sandbox_enable_stream_detect) break;
      if (s->score >= la * sandbox_num_access_in_phase) {
        uint64_t addr = generate_address(page, offset, s->offset, la);
        if (addr != 0xdeadbeef) { pref_addr.push_back(addr); count++; record_pref_stats(s->offset, 1); }
      }
    }
    if (count > pd) break;
  }
}

void sandbox::destroy_offset_list(std::vector<Score*> l) { for (auto* s : l) delete s; }

uint64_t sandbox::generate_address(uint64_t page, uint32_t offset, int32_t delta, uint32_t lookahead)
{
  int32_t pf_off = static_cast<int32_t>(offset) + delta * static_cast<int32_t>(lookahead);
  if (pf_off >= 0 && pf_off < 64)
    return (page << LOG2_PAGE_SIZE) + (static_cast<uint64_t>(pf_off) << LOG2_BLOCK_SIZE);
  return 0xdeadbeef;
}

void sandbox::end_of_round()
{
  std::sort(evaluated_offsets.begin(), evaluated_offsets.end(),
            [](Score* a, Score* b) { return a->score > b->score; });
  for (uint32_t c = 0; c < sandbox_num_cycle_offsets; ++c) {
    if (evaluated_offsets.empty()) break;
    Score* s = evaluated_offsets.back(); evaluated_offsets.pop_back();
    non_evaluated_offsets.push_back(s->offset); delete s;
  }
  for (uint32_t c = 0; c < sandbox_num_cycle_offsets; ++c) {
    int32_t off = non_evaluated_offsets.front(); non_evaluated_offsets.pop_front();
    evaluated_offsets.push_back(new Score(off));
  }
}

bool sandbox::filter_lookup(uint64_t address) { return filter_set.count(address) > 0; }

void sandbox::record_pref_stats(int32_t offset, uint32_t pref_count)
{
  uint32_t idx = offset > 0 ? static_cast<uint32_t>(offset) : static_cast<uint32_t>(64 + std::abs(offset));
  if (idx < 128) stats.pref_delta_dist[idx] += pref_count;
}

void sandbox::dump_stats()
{
  std::cout << "sandbox_called " << stats.called << std::endl
            << "sandbox_step1_filter_lookup " << stats.step1.filter_lookup << std::endl
            << "sandbox_step1_filter_hit " << stats.step1.filter_hit << std::endl
            << "sandbox_step2_filter_add " << stats.step2.filter_add << std::endl
            << "sandbox_step3_end_of_phase " << stats.step3.end_of_phase << std::endl
            << "sandbox_step3_end_of_round " << stats.step3.end_of_round << std::endl
            << "sandbox_step4_pref_generated " << stats.step4.pref_generated << std::endl
            << "sandbox_step4_pref_generated_pos " << stats.step4.pref_generated_pos << std::endl
            << "sandbox_step4_pref_generated_neg " << stats.step4.pref_generated_neg << std::endl;
  for (uint32_t i = 0; i < 128; ++i) {
    if (stats.pref_delta_dist[i]) {
      std::cout << "sandbox_offset_";
      if (i >= 64) std::cout << (int32_t)(64 - i);
      else std::cout << i;
      std::cout << " " << stats.pref_delta_dist[i] << std::endl;
    }
  }
}
