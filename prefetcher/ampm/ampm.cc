#include "ampm.h"
#include <algorithm>
#include <cassert>

void ampm::print_config()
{
  std::cout << "ampm_pb_size " << ampm_pb_size << std::endl
            << "ampm_pred_degree " << ampm_pred_degree << std::endl
            << "ampm_pref_degree " << ampm_pref_degree << std::endl
            << "ampm_pref_buffer_size " << ampm_pref_buffer_size << std::endl
            << "ampm_enable_pref_buffer " << ampm_enable_pref_buffer << std::endl
            << "ampm_max_delta " << ampm_max_delta << std::endl;
}

void ampm::invoke_prefetcher(uint64_t /*pc*/, uint64_t address, uint8_t /*cache_hit*/, uint8_t /*type*/,
                              std::vector<uint64_t>& pref_addr)
{
  uint64_t page = address >> LOG2_PAGE_SIZE;
  uint32_t offset = (address >> LOG2_BLOCK_SIZE) & ((1ull << (LOG2_PAGE_SIZE - LOG2_BLOCK_SIZE)) - 1);

  stats.invoke_called++;

  PageEntry* pb_entry = nullptr;
  auto it = std::find_if(page_buffer.begin(), page_buffer.end(),
                         [page](PageEntry* e) { return e->page_id == page; });

  if (it != page_buffer.end()) {
    pb_entry = *it;
    pb_entry->page_id = page;
    pb_entry->bitmap[offset] = true;
    page_buffer.erase(it);
    page_buffer.push_back(pb_entry);
    stats.pb.hit++;
  } else {
    if (page_buffer.size() >= ampm_pb_size) {
      pb_entry = page_buffer.front();
      page_buffer.pop_front();
      delete pb_entry;
      stats.pb.evict++;
    }
    pb_entry = new PageEntry();
    pb_entry->page_id = page;
    pb_entry->bitmap[offset] = true;
    page_buffer.push_back(pb_entry);
    stats.pb.insert++;
  }

  // Check for positive deltas
  std::vector<int32_t> selected_pos;
  for (int32_t delta = static_cast<int32_t>(ampm_max_delta); delta >= 1; --delta) {
    int32_t one_hop = (static_cast<int32_t>(offset) - 1 * delta >= 0) ? (offset - 1 * delta) : -1;
    int32_t two_hop = (static_cast<int32_t>(offset) - 2 * delta >= 0) ? (offset - 2 * delta) : -1;
    if (one_hop >= 0 && two_hop >= 0) {
      if (pb_entry->bitmap[one_hop] && pb_entry->bitmap[two_hop])
        selected_pos.push_back(delta);
    }
  }

  // Check for negative deltas
  std::vector<int32_t> selected_neg;
  for (int32_t delta = static_cast<int32_t>(ampm_max_delta); delta >= 1; --delta) {
    int32_t one_hop = (static_cast<int32_t>(offset) + 1 * delta < 64) ? (offset + 1 * delta) : -1;
    int32_t two_hop = (static_cast<int32_t>(offset) + 2 * delta < 64) ? (offset + 2 * delta) : -1;
    if (one_hop >= 0 && two_hop >= 0) {
      if (pb_entry->bitmap[one_hop] && pb_entry->bitmap[two_hop])
        selected_neg.push_back(delta);
    }
  }

  uint32_t count = 0;
  std::vector<uint64_t> predicted_addrs;

  for (uint32_t i = 0; i < selected_pos.size(); ++i) {
    if (count >= ampm_pred_degree) { stats.pred.degree_reached_pos++; break; }
    int32_t pref_offset = static_cast<int32_t>(offset) + selected_pos[i];
    if (pref_offset >= 0 && pref_offset < 64) {
      uint64_t pf_addr = (page << LOG2_PAGE_SIZE) + (static_cast<uint64_t>(pref_offset) << LOG2_BLOCK_SIZE);
      predicted_addrs.push_back(pf_addr);
      count++;
      assert(static_cast<size_t>(selected_pos[i]) < AMPM_MAX_OFFSETS);
      stats.pred.pos_histogram[selected_pos[i]]++;
    }
  }
  for (uint32_t i = 0; i < selected_neg.size(); ++i) {
    if (count >= ampm_pred_degree) { stats.pred.degree_reached_neg++; break; }
    int32_t pref_offset = static_cast<int32_t>(offset) - selected_neg[i];
    if (pref_offset >= 0 && pref_offset < 64) {
      uint64_t pf_addr = (page << LOG2_PAGE_SIZE) + (static_cast<uint64_t>(pref_offset) << LOG2_BLOCK_SIZE);
      predicted_addrs.push_back(pf_addr);
      count++;
      assert(static_cast<size_t>(selected_neg[i]) < AMPM_MAX_OFFSETS);
      stats.pred.neg_histogram[selected_neg[i]]++;
    }
  }

  stats.pred.total += predicted_addrs.size();

  if (ampm_enable_pref_buffer) {
    buffer_prefetch(predicted_addrs);
    issue_prefetch(pref_addr);
  } else {
    pref_addr = predicted_addrs;
  }
}

void ampm::buffer_prefetch(std::vector<uint64_t> predicted_addrs)
{
  for (size_t i = 0; i < predicted_addrs.size(); ++i) {
    bool found = false;
    for (size_t j = 0; j < pref_buffer.size(); ++j) {
      if (pref_buffer[j] == predicted_addrs[i]) { found = true; stats.pref_buffer.hit++; break; }
    }
    if (!found) {
      if (pref_buffer.size() >= ampm_pref_buffer_size) {
        stats.pref_buffer.dropped += (predicted_addrs.size() - i);
        break;
      } else {
        pref_buffer.push_back(predicted_addrs[i]);
        stats.pref_buffer.insert++;
      }
    }
  }
}

void ampm::issue_prefetch(std::vector<uint64_t>& pref_addr)
{
  uint32_t count = 0;
  while (!pref_buffer.empty() && count < ampm_pref_degree) {
    pref_addr.push_back(pref_buffer.front());
    pref_buffer.pop_front();
    count++;
  }
  stats.pref_buffer.issued += pref_addr.size();
}

void ampm::dump_stats()
{
  std::cout << "ampm.invoke_called " << stats.invoke_called << std::endl
            << "ampm.pb.hit " << stats.pb.hit << std::endl
            << "ampm.pb.evict " << stats.pb.evict << std::endl
            << "ampm.pb.insert " << stats.pb.insert << std::endl
            << "ampm.pred.total " << stats.pred.total << std::endl
            << "ampm.pred.degree_reached_pos " << stats.pred.degree_reached_pos << std::endl
            << "ampm.pred.degree_reached_neg " << stats.pred.degree_reached_neg << std::endl;

  for (uint32_t i = 0; i < AMPM_MAX_OFFSETS; ++i) {
    if (stats.pred.pos_histogram[i])
      std::cout << "ampm.pred.histogram." << i << " " << stats.pred.pos_histogram[i] << std::endl;
  }
  for (uint32_t i = 0; i < AMPM_MAX_OFFSETS; ++i) {
    if (stats.pred.neg_histogram[i])
      std::cout << "ampm.pred.histogram.-" << i << " " << stats.pred.neg_histogram[i] << std::endl;
  }

  std::cout << "ampm.pref_buffer.hit " << stats.pref_buffer.hit << std::endl
            << "ampm.pref_buffer.dropped " << stats.pref_buffer.dropped << std::endl
            << "ampm.pref_buffer.insert " << stats.pref_buffer.insert << std::endl
            << "ampm.pref_buffer.issued " << stats.pref_buffer.issued << std::endl;
}
