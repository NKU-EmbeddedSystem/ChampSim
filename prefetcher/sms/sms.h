#ifndef PREFETCHER_SMS_H
#define PREFETCHER_SMS_H

#include <bitset>
#include <cstdint>
#include <deque>
#include <vector>

#include "modules.h"
#include "pythia_adapter.h"
#include "pythia_compat.h"

#define SMS_BITMAP_MAX 64

struct sms : public pythia::PrefetcherAdapter {
  using PrefetcherAdapter::PrefetcherAdapter;

  // ── Internal types ────────────────────────────────────────────────
  struct FTEntry {
    uint64_t page = 0xdeadbeef, pc = 0xdeadbeef;
    uint32_t trigger_offset = 0;
  };
  struct ATEntry {
    uint64_t page = 0xdeadbeef, pc = 0xdeadbeef;
    uint32_t trigger_offset = 0;
    std::bitset<64> pattern;
    uint32_t age = 0;
  };
  struct PHTEntry {
    uint64_t signature = 0xdeadbeef;
    std::bitset<64> pattern;
    uint32_t age = 0;
  };

  // ── Stats ─────────────────────────────────────────────────────────
  struct {
    struct { uint64_t lookup=0,hit=0,insert=0,evict=0; } ft, at, pht;
    struct { uint64_t called=0,pht_miss=0,pref_generated=0; } gen;
    struct { uint64_t spilled=0,buffered=0,issued=0; } pref_buf;
  } stats;

  // ── Config knobs ──────────────────────────────────────────────────
  uint32_t sms_at_size = 32;
  uint32_t sms_ft_size = 64;
  uint32_t sms_pht_size = 16384;
  uint32_t sms_pht_assoc = 16;
  uint32_t sms_pref_degree = 4;
  uint32_t sms_region_size = 2048;
  uint32_t sms_region_size_log = 11;
  bool sms_enable_pref_buffer = true;
  uint32_t sms_pref_buffer_size = 256;

  // ── State ─────────────────────────────────────────────────────────
  std::deque<FTEntry*> filter_table;
  std::deque<ATEntry*> acc_table;
  std::vector<std::deque<PHTEntry*>> pht;
  uint32_t pht_sets = 0;
  std::deque<uint64_t> pref_buffer;
  bool initialized = false;

  // ── Overrides ─────────────────────────────────────────────────────
  void invoke_prefetcher(uint64_t pc, uint64_t address, uint8_t cache_hit, uint8_t type,
                         std::vector<uint64_t>& pref_addr) override;
  void dump_stats() override;
  void print_config() override;

  // ── Helpers ───────────────────────────────────────────────────────
  std::deque<FTEntry*>::iterator  search_filter_table(uint64_t page);
  std::deque<FTEntry*>::iterator  search_victim_filter_table();
  void evict_filter_table(std::deque<FTEntry*>::iterator victim);
  void insert_filter_table(uint64_t pc, uint64_t page, uint32_t offset);
  std::deque<ATEntry*>::iterator  search_acc_table(uint64_t page);
  std::deque<ATEntry*>::iterator  search_victim_acc_table();
  void evict_acc_table(std::deque<ATEntry*>::iterator victim);
  void update_age_acc_table(std::deque<ATEntry*>::iterator current);
  void insert_acc_table(FTEntry* ftentry, uint32_t offset);
  std::deque<PHTEntry*>::iterator search_pht(uint64_t signature, int32_t* set);
  std::deque<PHTEntry*>::iterator search_victim_pht(int32_t set);
  void evict_pht(int32_t set, std::deque<PHTEntry*>::iterator victim);
  void update_age_pht(int32_t set, std::deque<PHTEntry*>::iterator current);
  void insert_pht_table(ATEntry* atentry);
  uint64_t create_signature(uint64_t pc, uint32_t offset);
  int generate_prefetch(uint64_t pc, uint64_t address, uint64_t page, uint32_t offset,
                        std::vector<uint64_t>& pref_addr);
  void buffer_prefetch(std::vector<uint64_t> paddr);
  void issue_prefetch(std::vector<uint64_t>& pref_addr);
};

#endif
