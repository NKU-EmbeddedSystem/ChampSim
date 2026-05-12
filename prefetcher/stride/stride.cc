#include "stride.h"

void stride::print_config()
{
  std::cout << "stride_num_trackers " << stride_num_trackers << std::endl
            << "stride_pref_degree " << stride_pref_degree << std::endl;
}

void stride::invoke_prefetcher(uint64_t pc, uint64_t address, uint8_t /*cache_hit*/, uint8_t /*type*/,
                                std::vector<uint64_t>& pref_addr)
{
  uint64_t cl_addr = address >> LOG2_BLOCK_SIZE;
  stats.tracker.lookup++;

  Tracker* tracker = nullptr;
  auto it = std::find_if(trackers.begin(), trackers.end(),
                         [pc](Tracker* t) { return t->pc == pc; });
  if (it == trackers.end()) {
    if (trackers.size() >= stride_num_trackers) {
      Tracker* victim = trackers.back();
      trackers.pop_back();
      delete victim;
      stats.tracker.evict++;
    }
    tracker = new Tracker();
    tracker->pc = pc;
    tracker->last_cl_addr = cl_addr;
    tracker->last_stride = 0;
    trackers.push_front(tracker);
    stats.tracker.insert++;
    return;
  }

  stats.tracker.hit++;
  int32_t stride_val = 0;
  tracker = (*it);
  if (cl_addr > tracker->last_cl_addr) {
    stride_val = static_cast<int32_t>(cl_addr - tracker->last_cl_addr);
    stats.stride_stats.pos++;
  } else if (cl_addr < tracker->last_cl_addr) {
    stride_val = -static_cast<int32_t>(tracker->last_cl_addr - cl_addr);
    stats.stride_stats.neg++;
  }

  if (stride_val == 0) {
    stats.stride_stats.zero++;
    return;
  }

  if (stride_val == tracker->last_stride) {
    stats.pref.stride_match++;
    uint32_t count = generate_prefetch(address, stride_val, pref_addr);
    stats.pref.generated += count;
  }

  tracker->last_stride = stride_val;
  tracker->last_cl_addr = cl_addr;
  trackers.erase(it);
  trackers.push_front(tracker);
}

uint32_t stride::generate_prefetch(uint64_t address, int32_t stride_val, std::vector<uint64_t>& pref_addr)
{
  uint64_t page = address >> LOG2_PAGE_SIZE;
  uint32_t offset = (address >> LOG2_BLOCK_SIZE) & ((1ull << (LOG2_PAGE_SIZE - LOG2_BLOCK_SIZE)) - 1);
  uint32_t count = 0;

  for (uint32_t deg = 0; deg < stride_pref_degree; ++deg) {
    int32_t pref_offset = static_cast<int32_t>(offset) + stride_val * static_cast<int32_t>(deg);
    if (pref_offset >= 0 && pref_offset < 64) {
      uint64_t addr = (page << LOG2_PAGE_SIZE) + (static_cast<uint64_t>(pref_offset) << LOG2_BLOCK_SIZE);
      pref_addr.push_back(addr);
      count++;
    } else {
      break;
    }
  }
  return count;
}

void stride::dump_stats()
{
  std::cout << "stride_tracker_lookup " << stats.tracker.lookup << std::endl
            << "stride_tracker_evict " << stats.tracker.evict << std::endl
            << "stride_tracker_insert " << stats.tracker.insert << std::endl
            << "stride_tracker_hit " << stats.tracker.hit << std::endl
            << "stride_stride_pos " << stats.stride_stats.pos << std::endl
            << "stride_stride_neg " << stats.stride_stats.neg << std::endl
            << "stride_stride_zero " << stats.stride_stats.zero << std::endl
            << "stride_pref_stride_match " << stats.pref.stride_match << std::endl
            << "stride_pref_generated " << stats.pref.generated << std::endl
            << std::endl;
}
