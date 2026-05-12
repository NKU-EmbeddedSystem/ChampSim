#ifndef PYTHIA_ADAPTER_H
#define PYTHIA_ADAPTER_H

#include <cstdint>
#include <vector>
#include <string>
#include <fstream>

#include "address.h"
#include "modules.h"

namespace pythia
{

// Legacy Pythia prefetcher interface — ported from older ChampSim API.
// Wraps the new champsim::modules::prefetcher to expose the classic
// invoke_prefetcher / register_fill / dump_stats interface.
struct PrefetcherAdapter : public champsim::modules::prefetcher {
  using prefetcher::prefetcher;

  // ── Subclass implements these (old Pythia API) ────────────────────
  virtual void invoke_prefetcher(uint64_t pc, uint64_t address, uint8_t cache_hit, uint8_t type,
                                 std::vector<uint64_t>& pref_addr) = 0;
  virtual void register_fill(uint64_t address) {}
  virtual void dump_stats() {}
  virtual void print_config() {}
  virtual ~PrefetcherAdapter() = default;

  // ── Called by new ChampSim ────────────────────────────────────────
  uint32_t prefetcher_cache_operate(champsim::address addr, champsim::address ip, uint8_t cache_hit,
                                    bool /*useful_prefetch*/, access_type type, uint32_t metadata_in)  {
    std::vector<uint64_t> pf_addrs;
    invoke_prefetcher(ip.to<uint64_t>(), addr.to<uint64_t>(), cache_hit, static_cast<uint8_t>(type), pf_addrs);
    for (auto pa : pf_addrs) {
      prefetch_line(champsim::address{pa}, true, metadata_in);
    }
    return metadata_in;
  }

  uint32_t prefetcher_cache_fill(champsim::address addr, long /*set*/, long /*way*/, uint8_t /*prefetch*/,
                                 champsim::address /*evicted_addr*/, uint32_t metadata_in)  {
    register_fill(addr.to<uint64_t>());
    return metadata_in;
  }

  void prefetcher_final_stats()
  {
    dump_stats();
  }

  void prefetcher_initialize()
  {
    print_config();
  }
};

} // namespace pythia

#endif
