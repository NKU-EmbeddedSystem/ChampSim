#include "hint_table.h"

#include <atomic>
#include <cstring>
#include <fstream>
#include <iostream>
#include <vector>

// Diagnostics: track how often context dispatch is actually used
namespace {
std::atomic<uint64_t> g_context_lookups{0};
std::atomic<uint64_t> g_context_matches{0};
std::atomic<uint64_t> g_context_fallbacks{0};
std::atomic<uint64_t> g_context_labels_changed{0};  // context gave different pref idx than per-PC
bool g_diag_reported = false;
} // namespace

namespace {
constexpr uint32_t HINT_MAGIC = 0x544E4948;  // "HINT" little-endian
constexpr uint32_t HINT_VERSION = 1;         // v1: per-PC hints only, 16B/entry
constexpr uint32_t HINT_VERSION_2 = 2;       // v2: per-(PC,context) hints, 24B/entry
constexpr std::size_t HINT_ENTRY_SIZE = 16;  // 8B PC + 4x1B fields + 4B reserved
constexpr std::size_t HINT_ENTRY_SIZE_V2 = 24; // v1 + 8B context_key
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

  if (version != HINT_VERSION && version != HINT_VERSION_2) {
    std::cerr << "[hint_table] Error: unsupported hint file version " << version << " (expected " << HINT_VERSION
              << " or " << HINT_VERSION_2 << ")" << std::endl;
    loaded_ = false;
    return false;
  }

  constexpr uint32_t MAX_HINT_ENTRIES = 10'000'000;
  if (num_entries > MAX_HINT_ENTRIES) {
    std::cerr << "[hint_table] Error: excessive entry count " << num_entries
              << " (max " << MAX_HINT_ENTRIES << ")" << std::endl;
    loaded_ = false;
    return false;
  }

  hints_.clear();
  context_hints_.clear();
  hints_.reserve(num_entries);

  const std::size_t entry_size = (version == HINT_VERSION_2) ? HINT_ENTRY_SIZE_V2 : HINT_ENTRY_SIZE;

  for (uint32_t i = 0; i < num_entries; ++i) {
    hint_entry entry{};
    file.read(reinterpret_cast<char*>(&entry), entry_size);

    if (!file.good()) {
      std::cerr << "[hint_table] Error: truncated hint file at entry " << i << std::endl;
      hints_.clear();
      context_hints_.clear();
      loaded_ = false;
      return false;
    }

    if (version == HINT_VERSION_2) {
      context_hints_[entry.pc].push_back(entry);
    } else {
      hints_[entry.pc] = entry;
    }
  }

  loaded_ = true;
  default_entry = {0, default_replacement_idx, default_prefetch_idx, 0, 0};
  std::cout << "[hint_table] Loaded " << num_entries << " hint entries from '" << filepath << "'" << std::endl;
  return true;
}

bool hint_table::load_conservative(const std::string& filepath)
{
  std::ifstream file(filepath, std::ios::binary);
  if (!file.is_open()) {
    std::cerr << "[hint_table] Warning: could not open conservative hint file '" << filepath << "'" << std::endl;
    conservative_loaded_ = false;
    return false;
  }

  uint32_t magic = 0, version = 0, num_entries = 0, reserved = 0;
  file.read(reinterpret_cast<char*>(&magic), sizeof(magic));
  file.read(reinterpret_cast<char*>(&version), sizeof(version));
  file.read(reinterpret_cast<char*>(&num_entries), sizeof(num_entries));
  file.read(reinterpret_cast<char*>(&reserved), sizeof(reserved));

  if (!file.good() || magic != HINT_MAGIC || version != HINT_VERSION || num_entries > 10'000'000) {
    std::cerr << "[hint_table] Error: invalid conservative hint file '" << filepath << "' (v1 per-PC format required)" << std::endl;
    conservative_loaded_ = false;
    return false;
  }

  hints_conservative_.clear();
  hints_conservative_.reserve(num_entries);
  for (uint32_t i = 0; i < num_entries; ++i) {
    hint_entry entry{};
    file.read(reinterpret_cast<char*>(&entry), HINT_ENTRY_SIZE);
    if (!file.good()) {
      std::cerr << "[hint_table] Error: truncated conservative hint file at entry " << i << std::endl;
      hints_conservative_.clear();
      conservative_loaded_ = false;
      return false;
    }
    hints_conservative_[entry.pc] = entry;
  }

  conservative_loaded_ = true;
  std::cout << "[hint_table] Loaded " << num_entries << " conservative hint entries from '" << filepath << "'" << std::endl;
  return true;
}

const hint_entry* hint_table::lookup_conservative(uint64_t pc) const
{
  auto it = hints_conservative_.find(pc);
  return (it != hints_conservative_.end()) ? &it->second : nullptr;
}

void hint_table::record_fill_latency(uint64_t cycles)
{
  constexpr double alpha = 1.0 / 256.0;
  if (ema_count_ == 0) {
    lat_ema_ = static_cast<double>(cycles);
  } else {
    lat_ema_ += alpha * (static_cast<double>(cycles) - lat_ema_);
  }
  ++ema_count_;
  if (conservative_mode_) {
    ++conservative_fills_;
  }

  // Re-evaluate the mode every 1024 demand fills (hysteresis band)
  if ((ema_count_ & 0x3FF) == 0) {
    bool next = conservative_mode_;
    if (!conservative_mode_ && lat_ema_ > thresh_high_) {
      next = true;
    } else if (conservative_mode_ && lat_ema_ < thresh_low_) {
      next = false;
    }
    if (next != conservative_mode_) {
      conservative_mode_ = next;
      ++mode_switches_;
    }

    // Decay per-PC runtime prefetch counters (exponential window)
    for (auto& [pc, st] : pf_rt_stats_) {
      st.issued >>= 1;
      st.useful >>= 1;
    }
  }
}

void hint_table::record_pf_issue(uint64_t pc) { ++pf_rt_stats_[pc].issued; }

void hint_table::record_pf_useful(uint64_t pc) { ++pf_rt_stats_[pc].useful; }

bool hint_table::prefer_conservative(uint64_t pc) const
{
  auto it = pf_rt_stats_.find(pc);
  if (it == pf_rt_stats_.end() || it->second.issued < min_issued_) {
    return false;
  }
  bool gated = static_cast<double>(it->second.useful) < acc_thresh_ * static_cast<double>(it->second.issued);
  if (gated) {
    ++gated_hits_;
  }
  return gated;
}

const hint_entry* hint_table::lookup(uint64_t pc) const
{
  auto it = hints_.find(pc);
  if (it != hints_.end()) {
    return &it->second;
  }
  // Fall back to first context entry for this PC (v2 per-PC default)
  auto cit = context_hints_.find(pc);
  if (cit != context_hints_.end() && !cit->second.empty()) {
    return &cit->second[0];
  }
  return nullptr;
}

const hint_entry* hint_table::lookup_with_context(uint64_t pc, uint64_t context_key) const
{
  g_context_lookups.fetch_add(1, std::memory_order_relaxed);
  // 1. Try context-specific hints first
  auto it = context_hints_.find(pc);
  if (it != context_hints_.end()) {
    for (const auto& entry : it->second) {
      if (entry.context_key == context_key) {
        g_context_matches.fetch_add(1, std::memory_order_relaxed);
        // Check if context entry differs from per-PC fallback
        const hint_entry* fallback = lookup(pc);
        if (fallback && fallback->prefetch_policy_index != entry.prefetch_policy_index) {
          g_context_labels_changed.fetch_add(1, std::memory_order_relaxed);
        }
        return &entry;
      }
    }
  }
  // 2. Fall back to per-PC hint
  g_context_fallbacks.fetch_add(1, std::memory_order_relaxed);
  return lookup(pc);
}

std::size_t hint_table::size() const { return hints_.size() + context_hints_.size(); }

bool hint_table::is_loaded() const { return loaded_; }

void hint_table::print_diagnostics() const
{
  uint64_t lookups = g_context_lookups.load(std::memory_order_relaxed);
  uint64_t matches = g_context_matches.load(std::memory_order_relaxed);
  uint64_t fallbacks = g_context_fallbacks.load(std::memory_order_relaxed);
  uint64_t changed = g_context_labels_changed.load(std::memory_order_relaxed);

  std::cerr << "\n[hint_table] Context Dispatch Diagnostics:\n";
  std::cerr << "  context_hints_ entries: " << context_hints_.size() << "\n";
  std::cerr << "  hints_ entries: " << hints_.size() << "\n";
  std::cerr << "  lookup_with_context calls: " << lookups << "\n";
  std::cerr << "  context exact matches: " << matches
            << " (" << (lookups ? matches * 100.0 / lookups : 0.0) << "%)\n";
  std::cerr << "  fallbacks: " << fallbacks
            << " (" << (lookups ? fallbacks * 100.0 / lookups : 0.0) << "%)\n";
  std::cerr << "  context changed pref idx: " << changed
            << " (" << (matches ? changed * 100.0 / matches : 0.0) << "% of matches)\n";
  if (conservative_loaded_) {
    std::cerr << "[hint_table] Congestion feedback: final fill-latency EMA = " << lat_ema_ << " cycles, thresholds = [" << thresh_low_ << ", "
              << thresh_high_ << "], mode switches = " << mode_switches_ << ", conservative-mode fills = " << conservative_fills_ << " / "
              << ema_count_ << "\n";
    std::cerr << "[hint_table] Accuracy gate: acc_thresh = " << acc_thresh_ << ", min_issued = " << min_issued_ << ", tracked PCs = "
              << pf_rt_stats_.size() << ", gated lookups = " << gated_hits_ << "\n";
  }
}
