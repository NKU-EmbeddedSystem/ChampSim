#include "dspatch.h"

#include <algorithm>
#include <cassert>
#include <iostream>

void dspatch::print_config()
{
  if (!init_done) {
    init_done = true;
    spt.resize(dspatch_num_spt_entries);
    for (uint32_t i = 0; i < dspatch_num_spt_entries; ++i)
      spt[i] = new DSPatch_SPTEntry();
  }

  std::cout << "dspatch_log2_region_size " << dspatch_log2_region_size << std::endl
            << "dspatch_num_cachelines_in_region " << dspatch_num_cachelines_in_region << std::endl
            << "dspatch_pb_size " << dspatch_pb_size << std::endl
            << "dspatch_num_spt_entries " << dspatch_num_spt_entries << std::endl
            << "dspatch_compression_granularity " << dspatch_compression_granularity << std::endl
            << "dspatch_pred_throttle_bw_thr " << dspatch_pred_throttle_bw_thr << std::endl
            << "dspatch_bitmap_selection_policy " << dspatch_bitmap_selection_policy << std::endl
            << "dspatch_sig_type " << dspatch_sig_type << std::endl
            << "dspatch_sig_hash_type " << dspatch_sig_hash_type << std::endl
            << "dspatch_or_count_max " << dspatch_or_count_max << std::endl
            << "dspatch_measure_covP_max " << dspatch_measure_covP_max << std::endl
            << "dspatch_measure_accP_max " << dspatch_measure_accP_max << std::endl
            << "dspatch_acc_thr " << dspatch_acc_thr << std::endl
            << "dspatch_cov_thr " << dspatch_cov_thr << std::endl
            << "dspatch_enable_pref_buffer " << dspatch_enable_pref_buffer << std::endl
            << "dspatch_pref_buffer_size " << dspatch_pref_buffer_size << std::endl
            << "dspatch_pref_degree " << dspatch_pref_degree << std::endl;
}

void dspatch::invoke_prefetcher(uint64_t pc, uint64_t address, uint8_t /*cache_hit*/,
                                 uint8_t /*type*/, std::vector<uint64_t>& pref_addr)
{
  uint64_t page = address >> dspatch_log2_region_size;
  uint32_t offset = (address >> LOG2_BLOCK_SIZE) &
                    ((1ULL << (dspatch_log2_region_size - LOG2_BLOCK_SIZE)) - 1);

  DSPatch_PBEntry* pbentry = search_pb(page);
  stats.pb.lookup++;
  if (pbentry) {
    pbentry->bmp_real[offset] = true;
    stats.pb.hit++;
  } else {
    if (page_buffer.size() >= dspatch_pb_size) {
      pbentry = page_buffer.front();
      page_buffer.pop_front();
      add_to_spt(pbentry);
      delete pbentry;
      stats.pb.evict++;
    }
    pbentry = new DSPatch_PBEntry();
    pbentry->page = page;
    pbentry->trigger_pc = pc;
    pbentry->trigger_offset = offset;
    pbentry->bmp_real[offset] = true;
    page_buffer.push_back(pbentry);
    stats.pb.insert++;

    generate_prefetch(pc, page, offset, address, pref_addr);
    if (dspatch_enable_pref_buffer) {
      buffer_prefetch(pref_addr);
      pref_addr.clear();
    }
  }

  if (dspatch_enable_pref_buffer)
    issue_prefetch(pref_addr);
}

void dspatch::generate_prefetch(uint64_t pc, uint64_t page, uint32_t offset, uint64_t /*address*/,
                                 std::vector<uint64_t>& pref_addr)
{
  DSPatchBitmap bmp_pred;
  uint64_t signature = create_signature(pc, page, offset);
  uint32_t spt_index = get_spt_index(signature);

  DSPatch_SPTEntry* sptentry = spt[spt_index];
  DSPatch_pref_candidate candidate = select_bitmap(sptentry, bmp_pred);
  stats.gen_pref.called++;
  stats.gen_pref.selection_dist[candidate]++;

  uint32_t ncl = dspatch_num_cachelines_in_region;
  uint32_t gran = dspatch_compression_granularity;

  bmp_pred = dspatch_decompress(bmp_pred, gran, ncl);
  bmp_pred = dspatch_rotate_left(bmp_pred, offset, ncl);

  if (bw_bucket >= dspatch_pred_throttle_bw_thr && candidate == ACCP) {
    bmp_pred.reset();
    stats.gen_pref.reset++;
  }

  for (uint32_t index = 0; index < ncl; ++index) {
    if (bmp_pred[index] && index != offset) {
      uint64_t addr = (page << dspatch_log2_region_size) + (index << LOG2_BLOCK_SIZE);
      pref_addr.push_back(addr);
    }
  }
  stats.gen_pref.total += pref_addr.size();
}

DSPatch_pref_candidate dspatch::select_bitmap(DSPatch_SPTEntry* sptentry,
                                               DSPatchBitmap& bmp_selected)
{
  switch (dspatch_bitmap_selection_policy) {
    case 1:
      bmp_selected = sptentry->bmp_cov;
      return COVP;
    case 2:
      bmp_selected = sptentry->bmp_acc;
      return ACCP;
    case 3:
      return dyn_selection(sptentry, bmp_selected);
    default:
      return NONE;
  }
}

DSPatch_PBEntry* dspatch::search_pb(uint64_t page)
{
  auto it = std::find_if(page_buffer.begin(), page_buffer.end(),
                          [page](DSPatch_PBEntry* e) { return e->page == page; });
  return it != page_buffer.end() ? *it : nullptr;
}

void dspatch::buffer_prefetch(const std::vector<uint64_t>& paddr)
{
  uint32_t count = 0;
  for (uint32_t i = 0; i < paddr.size(); ++i) {
    if (pref_buffer.size() >= dspatch_pref_buffer_size) break;
    pref_buffer.push_back(paddr[i]);
    count++;
  }
  stats.pref_buffer_s.buffered += count;
  stats.pref_buffer_s.spilled += (paddr.size() - count);
}

void dspatch::issue_prefetch(std::vector<uint64_t>& pref_addr)
{
  uint32_t count = 0;
  while (!pref_buffer.empty() && count < dspatch_pref_degree) {
    pref_addr.push_back(pref_buffer.front());
    pref_buffer.pop_front();
    count++;
  }
  stats.pref_buffer_s.issued += pref_addr.size();
}

uint64_t dspatch::create_signature(uint64_t pc, uint64_t /*page*/, uint32_t /*offset*/)
{
  if (dspatch_sig_type == 1) return pc;
  return pc;
}

uint32_t dspatch::get_spt_index(uint64_t signature)
{
  uint32_t folded = folded_xor(signature, 2);
  uint32_t hashed = dspatch_get_hash(folded, dspatch_sig_hash_type);
  return hashed % dspatch_num_spt_entries;
}

void dspatch::add_to_spt(DSPatch_PBEntry* pbentry)
{
  stats.spt.called++;
  DSPatchBitmap bmp_real = pbentry->bmp_real;
  uint64_t trigger_pc = pbentry->trigger_pc;
  uint32_t trigger_offset = pbentry->trigger_offset;

  uint64_t signature = create_signature(trigger_pc, 0xdeadbeef, trigger_offset);
  uint32_t spt_index = get_spt_index(signature);
  DSPatch_SPTEntry* sptentry = spt[spt_index];

  uint32_t ncl = dspatch_num_cachelines_in_region;
  uint32_t gran = dspatch_compression_granularity;

  bmp_real = dspatch_rotate_right(bmp_real, trigger_offset, ncl);
  DSPatchBitmap bmp_cov = dspatch_decompress(sptentry->bmp_cov, gran, ncl);
  DSPatchBitmap bmp_acc = dspatch_decompress(sptentry->bmp_acc, gran, ncl);

  uint32_t pop_bmp_real = dspatch_popcount(bmp_real, ncl);
  uint32_t pop_bmp_cov = dspatch_popcount(bmp_cov, ncl);
  uint32_t pop_bmp_acc = dspatch_popcount(bmp_acc, ncl);
  uint32_t same_bmp_cov = dspatch_count_same(bmp_cov, bmp_real, ncl);
  uint32_t same_bmp_acc = dspatch_count_same(bmp_acc, bmp_real, ncl);

  uint32_t cov_bmp_cov = pop_bmp_real ? 100 * same_bmp_cov / pop_bmp_real : 0;
  uint32_t acc_bmp_cov = pop_bmp_cov ? 100 * same_bmp_cov / pop_bmp_cov : 0;
  uint32_t cov_bmp_acc = pop_bmp_real ? 100 * same_bmp_acc / pop_bmp_real : 0;
  uint32_t acc_bmp_acc = pop_bmp_acc ? 100 * same_bmp_acc / pop_bmp_acc : 0;

  if (dspatch_count_diff(bmp_real, bmp_cov, ncl) != 0) {
    sptentry->or_count.incr(dspatch_or_count_max);
    stats.spt.or_count_incr++;
  }
  if ((int)acc_bmp_cov < (int)dspatch_acc_thr || (int)cov_bmp_cov < (int)dspatch_cov_thr) {
    sptentry->measure_covP.incr(dspatch_measure_covP_max);
    stats.spt.measure_covP_incr++;
  }

  if (sptentry->measure_covP.value() == dspatch_measure_covP_max) {
    if (bw_bucket == 3 || cov_bmp_cov < 50) {
      sptentry->bmp_cov = dspatch_compress(bmp_real, gran, ncl);
      sptentry->or_count.reset();
      stats.spt.bmp_cov_reset++;
    }
  } else {
    sptentry->bmp_cov = dspatch_compress(dspatch_bitwise_or(bmp_cov, bmp_real), gran, ncl);
    stats.spt.bmp_cov_update++;
  }

  if ((int)acc_bmp_acc < 50) {
    sptentry->measure_accP.incr();
    stats.spt.measure_accP_incr++;
  } else {
    sptentry->measure_accP.decr();
    stats.spt.measure_accP_decr++;
  }

  sptentry->bmp_acc =
      dspatch_bitwise_and(bmp_real, dspatch_decompress(sptentry->bmp_cov, gran, ncl));
  sptentry->bmp_acc = dspatch_compress(sptentry->bmp_acc, gran, ncl);
  stats.spt.bmp_acc_update++;
}

DSPatch_pref_candidate dspatch::dyn_selection(DSPatch_SPTEntry* sptentry,
                                               DSPatchBitmap& bmp_selected)
{
  stats.dyn_selection.called++;

  if (bw_bucket == 3) {
    if (sptentry->measure_accP.value() == dspatch_measure_accP_max) {
      bmp_selected.reset();
      stats.dyn_selection.none++;
      return NONE;
    } else {
      bmp_selected = sptentry->bmp_acc;
      stats.dyn_selection.accp_reason1++;
      return ACCP;
    }
  } else if (bw_bucket == 2) {
    if (sptentry->measure_covP.value() == dspatch_measure_covP_max) {
      bmp_selected = sptentry->bmp_acc;
      stats.dyn_selection.accp_reason2++;
      return ACCP;
    } else {
      bmp_selected = sptentry->bmp_cov;
      stats.dyn_selection.covp_reason1++;
      return COVP;
    }
  } else {
    bmp_selected = sptentry->bmp_cov;
    stats.dyn_selection.covp_reason2++;
    return COVP;
  }
}

void dspatch::dump_stats()
{
  std::cout << "dspatch.pb.lookup " << stats.pb.lookup << std::endl
            << "dspatch.pb.hit " << stats.pb.hit << std::endl
            << "dspatch.pb.evict " << stats.pb.evict << std::endl
            << "dspatch.pb.insert " << stats.pb.insert << std::endl
            << std::endl
            << "dspatch.gen_pref.called " << stats.gen_pref.called << std::endl
            << "dspatch.gen_pref.reset " << stats.gen_pref.reset << std::endl
            << "dspatch.gen_pref.total " << stats.gen_pref.total << std::endl
            << std::endl
            << "dspatch.dyn_selection.called " << stats.dyn_selection.called << std::endl
            << "dspatch.dyn_selection.none " << stats.dyn_selection.none << std::endl
            << "dspatch.dyn_selection.accp_reason1 " << stats.dyn_selection.accp_reason1
            << std::endl
            << "dspatch.dyn_selection.accp_reason2 " << stats.dyn_selection.accp_reason2
            << std::endl
            << "dspatch.dyn_selection.covp_reason1 " << stats.dyn_selection.covp_reason1
            << std::endl
            << "dspatch.dyn_selection.covp_reason2 " << stats.dyn_selection.covp_reason2
            << std::endl
            << std::endl
            << "dspatch.spt.called " << stats.spt.called << std::endl
            << "dspatch.spt.or_count_incr " << stats.spt.or_count_incr << std::endl
            << "dspatch.spt.measure_covP_incr " << stats.spt.measure_covP_incr << std::endl
            << "dspatch.spt.bmp_cov_reset " << stats.spt.bmp_cov_reset << std::endl
            << "dspatch.spt.bmp_cov_update " << stats.spt.bmp_cov_update << std::endl
            << "dspatch.spt.measure_accP_incr " << stats.spt.measure_accP_incr << std::endl
            << "dspatch.spt.measure_accP_decr " << stats.spt.measure_accP_decr << std::endl
            << "dspatch.spt.bmp_acc_update " << stats.spt.bmp_acc_update << std::endl
            << std::endl
            << "dspatch.pref_buffer.spilled " << stats.pref_buffer_s.spilled << std::endl
            << "dspatch.pref_buffer.buffered " << stats.pref_buffer_s.buffered << std::endl
            << "dspatch.pref_buffer.issued " << stats.pref_buffer_s.issued << std::endl
            << std::endl
            << "dspatch.bw.called " << stats.bw.called << std::endl
            << "dspatch.bw.bw_histogram ";
  for (uint32_t i = 0; i < DSPATCH_MAX_BW_LEVEL; ++i)
    std::cout << stats.bw.bw_histogram[i] << ",";
  std::cout << std::endl;
}
