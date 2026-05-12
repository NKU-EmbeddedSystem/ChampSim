#ifndef PREFETCHER_POWER7_H
#define PREFETCHER_POWER7_H

#include <cstdint>
#include <deque>
#include <vector>

#include "modules.h"
#include "pythia_adapter.h"
#include "pythia_compat.h"

struct power7 : public pythia::PrefetcherAdapter {
  using PrefetcherAdapter::PrefetcherAdapter;

  enum Config { Default=0,Off,Shallowest,S_Shallowest,Shallow,S_Shallow,
                Medium,S_Medium,Deep,S_Deep,Deeper,S_Deeper,Deepest,S_Deepest,NumConfigs };
  enum Mode { Explore=0,Exploit,NumModes };

  // Stride tracker
  struct StrideTracker { uint64_t pc=0,last_cl_addr=0; int64_t last_stride=0; };

  // Stream tracker
  struct StreamTracker { uint64_t page=0; uint32_t last_offset=0; int32_t last_dir=0; uint8_t conf=0;
    StreamTracker(uint64_t p,uint32_t o):page(p),last_offset(o){} };

  Config config = Default;
  Mode mode = Exploit;
  uint64_t access_counter = 0;
  uint64_t cycle_stamp = 0;

  uint32_t streamer_num_trackers = 64;
  uint32_t stride_num_trackers = 64;
  uint32_t power7_explore_epoch = 5000;
  uint32_t power7_exploit_epoch = 50000;
  uint32_t power7_default_streamer_degree = 5;

  std::deque<StrideTracker*> stride_trackers;
  std::deque<StreamTracker*> stream_trackers;

  struct {
    uint64_t called=0, streamer_degree=0, stride_degree=0;
    struct { uint64_t explore=0,exploit=0,explore_to_exploit=0,exploit_to_explore=0; } mode_s;
    uint64_t config_hist[NumConfigs][NumModes] = {};
    struct { uint64_t total=0,streamer=0,stride=0; } pred;
  } stats;

  void invoke_prefetcher(uint64_t pc, uint64_t address, uint8_t cache_hit, uint8_t type,
                         std::vector<uint64_t>& pref_addr) override;
  void dump_stats() override;
  void print_config() override;

private:
  void set_params();
  uint32_t get_streamer_degree(Config c);
  uint32_t get_stride_degree(Config c);
  Config get_winner_config();
  void invoke_stride(uint64_t address, std::vector<uint64_t>& pref_addr);
  void invoke_stream(uint64_t pc, uint64_t address, std::vector<uint64_t>& pref_addr);
  const char* cfg_str(Config c);
  const char* mode_str(Mode m);
};

#endif
