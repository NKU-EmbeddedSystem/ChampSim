#ifndef HINT_TABLE_H
#define HINT_TABLE_H

#include <cstdint>
#include <string>
#include <unordered_map>

struct hint_entry {
  uint64_t pc;
  uint8_t replacement_policy_index;
  uint8_t prefetch_policy_index;
  uint8_t prefetch_degree;
  uint8_t demand_filter;
};

class hint_table
{
public:
  static hint_table& instance();

  bool load(const std::string& filepath);
  const hint_entry* lookup(uint64_t pc) const;
  std::size_t size() const;
  bool is_loaded() const;

  void set_default_replacement(uint8_t idx) { default_replacement_idx = idx; }
  void set_default_prefetch(uint8_t idx) { default_prefetch_idx = idx; }
  uint8_t get_default_replacement() const { return default_replacement_idx; }
  uint8_t get_default_prefetch() const { return default_prefetch_idx; }

private:
  hint_table() = default;
  std::unordered_map<uint64_t, hint_entry> hints_;
  bool loaded_ = false;
  uint8_t default_replacement_idx = 0;
  uint8_t default_prefetch_idx = 0;
  hint_entry default_entry{0, 0, 0, 0, 0};
};

#endif
