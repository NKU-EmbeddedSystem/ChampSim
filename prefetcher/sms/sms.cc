#include "sms.h"
#include <algorithm>
#include <cassert>
#include <cstring>
#include <iomanip>

void sms::print_config()
{
  if (!initialized) {
    pht_sets = sms_pht_size / sms_pht_assoc;
    pht.resize(pht_sets);
    initialized = true;
  }
  std::cout << "sms_at_size " << sms_at_size << std::endl
            << "sms_ft_size " << sms_ft_size << std::endl
            << "sms_pht_size " << sms_pht_size << std::endl
            << "sms_pht_assoc " << sms_pht_assoc << std::endl
            << "sms_pref_degree " << sms_pref_degree << std::endl
            << "sms_region_size " << sms_region_size << std::endl
            << "sms_region_size_log " << sms_region_size_log << std::endl
            << "sms_enable_pref_buffer " << sms_enable_pref_buffer << std::endl
            << "sms_pref_buffer_size " << sms_pref_buffer_size << std::endl;
}

void sms::invoke_prefetcher(uint64_t pc, uint64_t address, uint8_t /*cache_hit*/, uint8_t /*type*/,
                             std::vector<uint64_t>& pref_addr)
{
  uint64_t page = address >> sms_region_size_log;
  uint32_t offset = (address >> LOG2_BLOCK_SIZE) & ((1ull << (sms_region_size_log - LOG2_BLOCK_SIZE)) - 1);

  auto at_index = search_acc_table(page);
  stats.at.lookup++;
  if (at_index != acc_table.end()) {
    stats.at.hit++;
    (*at_index)->pattern[offset] = 1;
    update_age_acc_table(at_index);
  } else {
    auto ft_index = search_filter_table(page);
    stats.ft.lookup++;
    if (ft_index != filter_table.end()) {
      stats.ft.hit++;
      insert_acc_table(*ft_index, offset);
      evict_filter_table(ft_index);
    } else {
      insert_filter_table(pc, page, offset);
      generate_prefetch(pc, address, page, offset, pref_addr);
      if (sms_enable_pref_buffer) {
        buffer_prefetch(pref_addr);
        pref_addr.clear();
      }
    }
  }
  if (sms_enable_pref_buffer)
    issue_prefetch(pref_addr);
}

// ── Filter Table ─────────────────────────────────────────────────────
std::deque<sms::FTEntry*>::iterator sms::search_filter_table(uint64_t page)
{
  return std::find_if(filter_table.begin(), filter_table.end(),
                      [page](FTEntry* e) { return e->page == page; });
}
void sms::insert_filter_table(uint64_t pc, uint64_t page, uint32_t offset)
{
  stats.ft.insert++;
  if (filter_table.size() >= sms_ft_size)
    evict_filter_table(search_victim_filter_table());
  auto* e = new FTEntry(); e->page = page; e->pc = pc; e->trigger_offset = offset;
  filter_table.push_back(e);
}
std::deque<sms::FTEntry*>::iterator sms::search_victim_filter_table() { return filter_table.begin(); }
void sms::evict_filter_table(std::deque<sms::FTEntry*>::iterator v) { stats.ft.evict++; delete *v; filter_table.erase(v); }

// ── Accumulation Table ───────────────────────────────────────────────
std::deque<sms::ATEntry*>::iterator sms::search_acc_table(uint64_t page)
{
  return std::find_if(acc_table.begin(), acc_table.end(),
                      [page](ATEntry* e) { return e->page == page; });
}
void sms::insert_acc_table(FTEntry* ftentry, uint32_t offset)
{
  stats.at.insert++;
  if (acc_table.size() >= sms_at_size)
    evict_acc_table(search_victim_acc_table());
  auto* e = new ATEntry();
  e->pc = ftentry->pc; e->page = ftentry->page; e->trigger_offset = ftentry->trigger_offset;
  e->pattern[ftentry->trigger_offset] = 1;
  e->pattern[offset] = 1;
  e->age = 0;
  for (auto* a : acc_table) a->age++;
  acc_table.push_back(e);
}
std::deque<sms::ATEntry*>::iterator sms::search_victim_acc_table()
{
  uint32_t max_age = 0;
  std::deque<ATEntry*>::iterator victim = acc_table.begin();
  for (auto it = acc_table.begin(); it != acc_table.end(); ++it)
    if ((*it)->age >= max_age) { max_age = (*it)->age; victim = it; }
  return victim;
}
void sms::evict_acc_table(std::deque<sms::ATEntry*>::iterator v)
{
  stats.at.evict++;
  insert_pht_table(*v);
  delete *v;
  acc_table.erase(v);
}
void sms::update_age_acc_table(std::deque<sms::ATEntry*>::iterator current)
{
  for (auto* a : acc_table) a->age++;
  (*current)->age = 0;
}

// ── Pattern History Table ────────────────────────────────────────────
void sms::insert_pht_table(ATEntry* atentry)
{
  stats.pht.lookup++;
  uint64_t signature = create_signature(atentry->pc, atentry->trigger_offset);
  int32_t set = -1;
  auto pht_index = search_pht(signature, &set);
  if (pht_index != pht[set].end()) {
    stats.pht.hit++;
    (*pht_index)->pattern = atentry->pattern;
    update_age_pht(set, pht_index);
  } else {
    if (pht[set].size() >= sms_pht_assoc)
      evict_pht(set, search_victim_pht(set));
    stats.pht.insert++;
    auto* e = new PHTEntry(); e->signature = signature; e->pattern = atentry->pattern; e->age = 0;
    for (auto* p : pht[set]) p->age++;
    pht[set].push_back(e);
  }
}
std::deque<sms::PHTEntry*>::iterator sms::search_pht(uint64_t signature, int32_t* set)
{
  *set = signature % pht_sets;
  return std::find_if(pht[*set].begin(), pht[*set].end(),
                      [signature](PHTEntry* e) { return e->signature == signature; });
}
std::deque<sms::PHTEntry*>::iterator sms::search_victim_pht(int32_t set)
{
  uint32_t max_age = 0;
  std::deque<PHTEntry*>::iterator victim = pht[set].begin();
  for (auto it = pht[set].begin(); it != pht[set].end(); ++it)
    if ((*it)->age >= max_age) { max_age = (*it)->age; victim = it; }
  return victim;
}
void sms::update_age_pht(int32_t set, std::deque<sms::PHTEntry*>::iterator current)
{
  for (auto* p : pht[set]) p->age++;
  (*current)->age = 0;
}
void sms::evict_pht(int32_t set, std::deque<sms::PHTEntry*>::iterator v) { stats.pht.evict++; delete *v; pht[set].erase(v); }

uint64_t sms::create_signature(uint64_t pc, uint32_t offset)
{
  return (pc << (sms_region_size_log - LOG2_BLOCK_SIZE)) + offset;
}

int sms::generate_prefetch(uint64_t pc, uint64_t /*address*/, uint64_t page, uint32_t offset,
                            std::vector<uint64_t>& pref_addr)
{
  stats.gen.called++;
  uint64_t signature = create_signature(pc, offset);
  int32_t set = -1;
  auto pht_index = search_pht(signature, &set);
  if (pht_index == pht[set].end()) { stats.gen.pht_miss++; return 0; }
  PHTEntry* e = *pht_index;
  for (uint32_t i = 0; i < SMS_BITMAP_MAX; ++i) {
    if (e->pattern[i] && offset != i) {
      uint64_t addr = (page << sms_region_size_log) + (static_cast<uint64_t>(i) << LOG2_BLOCK_SIZE);
      pref_addr.push_back(addr);
    }
  }
  update_age_pht(set, pht_index);
  stats.gen.pref_generated += pref_addr.size();
  return static_cast<int>(pref_addr.size());
}

void sms::buffer_prefetch(std::vector<uint64_t> paddr)
{
  uint32_t count = 0;
  for (auto addr : paddr) {
    if (pref_buffer.size() >= sms_pref_buffer_size) break;
    pref_buffer.push_back(addr); count++;
  }
  stats.pref_buf.buffered += count;
  stats.pref_buf.spilled += (paddr.size() - count);
}

void sms::issue_prefetch(std::vector<uint64_t>& pref_addr)
{
  uint32_t count = 0;
  while (!pref_buffer.empty() && count < sms_pref_degree) {
    pref_addr.push_back(pref_buffer.front());
    pref_buffer.pop_front(); count++;
  }
  stats.pref_buf.issued += pref_addr.size();
}

void sms::dump_stats()
{
  std::cout << "sms.ft.lookup " << stats.ft.lookup << std::endl
            << "sms.ft.hit " << stats.ft.hit << std::endl
            << "sms.ft.insert " << stats.ft.insert << std::endl
            << "sms.ft.evict " << stats.ft.evict << std::endl
            << "sms.at.lookup " << stats.at.lookup << std::endl
            << "sms.at.hit " << stats.at.hit << std::endl
            << "sms.at.insert " << stats.at.insert << std::endl
            << "sms.at.evict " << stats.at.evict << std::endl
            << "sms.pht.lookup " << stats.pht.lookup << std::endl
            << "sms.pht.hit " << stats.pht.hit << std::endl
            << "sms.pht.insert " << stats.pht.insert << std::endl
            << "sms.pht.evict " << stats.pht.evict << std::endl
            << "sms.generate_prefetch.called " << stats.gen.called << std::endl
            << "sms.generate_prefetch.pht_miss " << stats.gen.pht_miss << std::endl
            << "sms.generate_prefetch.pref_generated " << stats.gen.pref_generated << std::endl
            << "sms.pref_buffer.buffered " << stats.pref_buf.buffered << std::endl
            << "sms.pref_buffer.spilled " << stats.pref_buf.spilled << std::endl
            << "sms.pref_buffer.issued " << stats.pref_buf.issued << std::endl;
}
