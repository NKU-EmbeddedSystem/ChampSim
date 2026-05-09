#include "hint_table.h"

#include <cstring>
#include <fstream>
#include <iostream>
#include <vector>

namespace {
constexpr uint32_t HINT_MAGIC = 0x544E4948; // "HINT" little-endian
constexpr uint32_t HINT_VERSION = 1;
constexpr std::size_t HINT_ENTRY_SIZE = 16; // 8B PC + 4x1B fields + 4B reserved
} // namespace

hint_table& hint_table::instance()
{
  static hint_table table;
  return table;
}

bool hint_table::load(const std::string& filepath)
{
  std::ifstream file(filepath, std::ios::binary);
  if (!file.is_open()) {
    std::cerr << "[hint_table] Warning: could not open hint file '" << filepath << "', using defaults." << std::endl;
    loaded_ = false;
    return false;
  }

  uint32_t magic = 0;
  uint32_t version = 0;
  uint32_t num_entries = 0;
  uint32_t reserved = 0;

  file.read(reinterpret_cast<char*>(&magic), sizeof(magic));
  file.read(reinterpret_cast<char*>(&version), sizeof(version));
  file.read(reinterpret_cast<char*>(&num_entries), sizeof(num_entries));
  file.read(reinterpret_cast<char*>(&reserved), sizeof(reserved));

  if (!file.good() || magic != HINT_MAGIC) {
    std::cerr << "[hint_table] Error: invalid hint file magic (expected 0x" << std::hex << HINT_MAGIC << ", got 0x" << magic
              << std::dec << ")" << std::endl;
    loaded_ = false;
    return false;
  }

  if (version != HINT_VERSION) {
    std::cerr << "[hint_table] Error: unsupported hint file version " << version << " (expected " << HINT_VERSION << ")"
              << std::endl;
    loaded_ = false;
    return false;
  }

  hints_.clear();
  hints_.reserve(num_entries);

  for (uint32_t i = 0; i < num_entries; ++i) {
    hint_entry entry{};
    file.read(reinterpret_cast<char*>(&entry.pc), sizeof(entry.pc));
    file.read(reinterpret_cast<char*>(&entry.replacement_policy_index), sizeof(entry.replacement_policy_index));
    file.read(reinterpret_cast<char*>(&entry.prefetch_policy_index), sizeof(entry.prefetch_policy_index));
    file.read(reinterpret_cast<char*>(&entry.prefetch_degree), sizeof(entry.prefetch_degree));
    file.read(reinterpret_cast<char*>(&entry.demand_filter), sizeof(entry.demand_filter));

    if (!file.good()) {
      std::cerr << "[hint_table] Error: truncated hint file at entry " << i << std::endl;
      hints_.clear();
      loaded_ = false;
      return false;
    }

    hints_[entry.pc] = entry;
  }

  loaded_ = true;
  default_entry = {0, default_replacement_idx, default_prefetch_idx, 0, 0};
  std::cout << "[hint_table] Loaded " << num_entries << " hint entries from '" << filepath << "'" << std::endl;
  return true;
}

const hint_entry* hint_table::lookup(uint64_t pc) const
{
  auto it = hints_.find(pc);
  if (it != hints_.end()) {
    return &it->second;
  }
  return nullptr;
}

std::size_t hint_table::size() const { return hints_.size(); }

bool hint_table::is_loaded() const { return loaded_; }
