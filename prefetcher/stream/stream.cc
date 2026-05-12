#include "stream.h"
#include <cassert>

void stream::print_config()
{
  std::cout << "stream_num_trackers " << streamer_num_trackers << std::endl
            << "stream_pref_degree " << streamer_pref_degree << std::endl;
}

void stream::invoke_prefetcher(uint64_t /*pc*/, uint64_t address, uint8_t /*cache_hit*/, uint8_t /*type*/,
                                std::vector<uint64_t>& pref_addr)
{
  uint64_t page = address >> LOG2_PAGE_SIZE;
  uint32_t offset = (address >> LOG2_BLOCK_SIZE) & ((1ull << (LOG2_PAGE_SIZE - LOG2_BLOCK_SIZE)) - 1);

  stats.called++;

  auto it = std::find_if(trackers.begin(), trackers.end(),
                         [page](StreamTracker* t) { return t->page == page; });
  StreamTracker* tracker = (it != trackers.end()) ? (*it) : nullptr;

  if (!tracker) {
    stats.tracker.missed++;
    if (trackers.size() >= streamer_num_trackers) {
      tracker = trackers.front();
      trackers.pop_front();
      delete tracker;
      stats.tracker.evict++;
    }
    tracker = new StreamTracker(page, offset);
    trackers.push_back(tracker);
    stats.tracker.insert++;
    return;
  }

  stats.tracker.hit++;
  if (offset == tracker->last_offset) {
    stats.tracker.same_offset++;
    return;
  }

  bool dir_match = false;
  int32_t dir = offset > tracker->last_offset ? +1 : -1;
  if (dir == tracker->last_dir) {
    tracker->conf = 1;
    dir_match = true;
    stats.tracker.dir_match++;
  } else {
    tracker->conf = 0;
    stats.tracker.dir_mismatch++;
  }
  tracker->last_offset = offset;
  tracker->last_dir = dir;
  trackers.erase(it);
  trackers.push_back(tracker);

  if (dir_match) {
    stats.pred.dir_match++;
    int32_t pref_offset = static_cast<int32_t>(offset);
    for (uint32_t i = 0; i < streamer_pref_degree; ++i) {
      pref_offset = (dir == +1) ? (pref_offset + 1) : (pref_offset - 1);
      if (pref_offset >= 0 && pref_offset < 64) {
        uint64_t pf_addr = (page << LOG2_PAGE_SIZE) + (static_cast<uint64_t>(pref_offset) << LOG2_BLOCK_SIZE);
        pref_addr.push_back(pf_addr);
      } else {
        break;
      }
    }
  }
  stats.pred.total += pref_addr.size();
}

void stream::dump_stats()
{
  std::cout << "stream.called " << stats.called << std::endl
            << "stream.tracker.missed " << stats.tracker.missed << std::endl
            << "stream.tracker.evict " << stats.tracker.evict << std::endl
            << "stream.tracker.insert " << stats.tracker.insert << std::endl
            << "stream.tracker.hit " << stats.tracker.hit << std::endl
            << "stream.tracker.same_offset " << stats.tracker.same_offset << std::endl
            << "stream.tracker.dir_match " << stats.tracker.dir_match << std::endl
            << "stream.tracker.dir_mismatch " << stats.tracker.dir_mismatch << std::endl
            << "stream.pred.dir_match " << stats.pred.dir_match << std::endl
            << "stream.pred.total " << stats.pred.total << std::endl;
}
