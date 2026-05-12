#include "power7.h"

const char* power7::cfg_str(Config c) {
  switch(c) { case Default:return"Default";case Off:return"Off";
    case Shallowest:return"Shallowest";case S_Shallowest:return"S_Shallowest";
    case Shallow:return"Shallow";case S_Shallow:return"S_Shallow";
    case Medium:return"Medium";case S_Medium:return"S_Medium";
    case Deep:return"Deep";case S_Deep:return"S_Deep";
    case Deeper:return"Deeper";case S_Deeper:return"S_Deeper";
    case Deepest:return"Deepest";case S_Deepest:return"S_Deepest";
    default:return"UNK"; }
}
const char* power7::mode_str(Mode m) {
  switch(m) { case Explore:return"Explore";case Exploit:return"Exploit";default:return"UNK"; }
}

void power7::print_config() {
  std::cout << "streamer_num_trackers " << streamer_num_trackers << std::endl
            << "stride_num_trackers " << stride_num_trackers << std::endl
            << "power7_explore_epoch " << power7_explore_epoch << std::endl
            << "power7_exploit_epoch " << power7_exploit_epoch << std::endl
            << "power7_default_streamer_degree " << power7_default_streamer_degree << std::endl;
}

void power7::set_params() {
  stats.streamer_degree = get_streamer_degree(config);
  stats.stride_degree = get_stride_degree(config);
}

uint32_t power7::get_streamer_degree(Config c) {
  switch(c) { case Default:return power7_default_streamer_degree;case Off:return 0;
    case Shallowest:case S_Shallowest:return 2;case Shallow:case S_Shallow:return 3;
    case Medium:case S_Medium:return 4;case Deep:case S_Deep:return 5;
    case Deeper:case S_Deeper:return 6;case Deepest:case S_Deepest:return 7;
    default:return power7_default_streamer_degree; }
}
uint32_t power7::get_stride_degree(Config c) {
  switch(c) { case S_Shallowest:case S_Shallow:case S_Medium:case S_Deep:
    case S_Deeper:case S_Deepest:return 4;default:return 0; }
}

void power7::invoke_prefetcher(uint64_t pc, uint64_t address, uint8_t cache_hit, uint8_t type,
                                std::vector<uint64_t>& pref_addr) {
  access_counter++;
  stats.called++;

  // State machine: Explorer/Exploit with config cycling
  if (mode == Exploit) {
    if (access_counter >= power7_exploit_epoch) {
      mode = Explore; config = Default; set_params();
      access_counter = 0; cycle_stamp = 0;
      stats.mode_s.exploit_to_explore++;
    } else { stats.mode_s.exploit++; }
  } else {
    if (access_counter >= power7_explore_epoch) {
      if (config == S_Deepest) {
        mode = Exploit; config = get_winner_config(); set_params();
        stats.mode_s.explore_to_exploit++;
      } else {
        mode = Explore; config = static_cast<Config>(static_cast<int>(config)+1); set_params();
      }
      access_counter = 0; cycle_stamp = 0;
    } else { stats.mode_s.explore++; }
  }

  stats.config_hist[config][mode]++;

  // Invoke stream + stride sub-prefetchers
  uint32_t pre_size = static_cast<uint32_t>(pref_addr.size());
  invoke_stream(pc, address, pref_addr);
  uint32_t stream_count = static_cast<uint32_t>(pref_addr.size()) - pre_size;
  invoke_stride(address, pref_addr);
  uint32_t stride_count = static_cast<uint32_t>(pref_addr.size()) - pre_size - stream_count;

  stats.pred.streamer += stream_count;
  stats.pred.stride += stride_count;
  stats.pred.total += (stream_count + stride_count);
}

// ── Embedded stride logic ────────────────────────────────────────────
void power7::invoke_stride(uint64_t address, std::vector<uint64_t>& pref_addr) {
  if (stats.stride_degree == 0) return;
  uint64_t cl_addr = address >> LOG2_BLOCK_SIZE;

  StrideTracker* t = nullptr;
  auto it = std::find_if(stride_trackers.begin(), stride_trackers.end(),
                         [cl_addr](StrideTracker* x){ return x->pc == cl_addr; });
  if (it == stride_trackers.end()) {
    if (stride_trackers.size() >= stride_num_trackers)
      { delete stride_trackers.back(); stride_trackers.pop_back(); }
    t = new StrideTracker(); t->pc = cl_addr; t->last_cl_addr = cl_addr; t->last_stride = 0;
    stride_trackers.push_front(t);
    return;
  }
  t = *it;
  int64_t stride_val = static_cast<int64_t>(cl_addr) - static_cast<int64_t>(t->last_cl_addr);
  if (stride_val == 0 || stride_val != t->last_stride) {
    t->last_stride = stride_val; t->last_cl_addr = cl_addr;
    stride_trackers.erase(it); stride_trackers.push_front(t);
    return;
  }
  // Confirmed stride — generate prefetches
  uint64_t page = address >> LOG2_PAGE_SIZE;
  uint32_t off = (address >> LOG2_BLOCK_SIZE) & 63;
  for (uint32_t i = 0; i < stats.stride_degree; ++i) {
    int64_t po = static_cast<int64_t>(off) + stride_val * static_cast<int64_t>(i+1);
    if (po >= 0 && po < 64)
      pref_addr.push_back((page << LOG2_PAGE_SIZE) | (static_cast<uint64_t>(po) << LOG2_BLOCK_SIZE));
    else break;
  }
  t->last_stride = stride_val; t->last_cl_addr = cl_addr;
  stride_trackers.erase(it); stride_trackers.push_front(t);
}

// ── Embedded stream logic ────────────────────────────────────────────
void power7::invoke_stream(uint64_t /*pc*/, uint64_t address, std::vector<uint64_t>& pref_addr) {
  if (stats.streamer_degree == 0) return;
  uint64_t page = address >> LOG2_PAGE_SIZE;
  uint32_t offset = (address >> LOG2_BLOCK_SIZE) & 63;

  auto it = std::find_if(stream_trackers.begin(), stream_trackers.end(),
                         [page](StreamTracker* x){ return x->page == page; });
  StreamTracker* t = nullptr;
  if (it == stream_trackers.end()) {
    if (stream_trackers.size() >= streamer_num_trackers)
      { delete stream_trackers.back(); stream_trackers.pop_back(); }
    t = new StreamTracker(page, offset);
    stream_trackers.push_front(t);
    return;
  }
  t = *it;
  if (offset == t->last_offset) return;

  int32_t dir = offset > t->last_offset ? +1 : -1;
  bool match = (dir == t->last_dir); t->conf = match ? 1 : 0;
  t->last_offset = offset; t->last_dir = dir;
  stream_trackers.erase(it); stream_trackers.push_front(t);

  if (match) {
    int32_t po = static_cast<int32_t>(offset);
    for (uint32_t i = 0; i < stats.streamer_degree; ++i) {
      po = (dir == +1) ? po+1 : po-1;
      if (po >= 0 && po < 64)
        pref_addr.push_back((page << LOG2_PAGE_SIZE) | (static_cast<uint64_t>(po) << LOG2_BLOCK_SIZE));
      else break;
    }
  }
}

power7::Config power7::get_winner_config() {
  uint64_t min_cyc = UINT64_MAX; Config best = Default;
  for (int i = 0; i < NumConfigs; ++i) { Config c=static_cast<Config>(i); if(get_streamer_degree(c)+get_stride_degree(c)>0){best=c;break;} }
  return best;
}

void power7::dump_stats() {
  std::cout << "power7.called " << stats.called << std::endl
            << "power7.mode.explore " << stats.mode_s.explore << std::endl
            << "power7.mode.exploit " << stats.mode_s.exploit << std::endl
            << "power7.mode.explore_to_exploit " << stats.mode_s.explore_to_exploit << std::endl
            << "power7.mode.exploit_to_explore " << stats.mode_s.exploit_to_explore << std::endl;
  for (int c = 0; c < NumConfigs; ++c)
    for (int m = 0; m < NumModes; ++m)
      if (stats.config_hist[c][m])
        std::cout << "power7.config." << cfg_str(static_cast<Config>(c)) << "."
                  << mode_str(static_cast<Mode>(m)) << " " << stats.config_hist[c][m] << std::endl;
  std::cout << "power7.pred.total " << stats.pred.total << std::endl
            << "power7.pred.streamer " << stats.pred.streamer << std::endl
            << "power7.pred.stride " << stats.pred.stride << std::endl;
}
