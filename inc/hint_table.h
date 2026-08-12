#ifndef HINT_TABLE_H
#define HINT_TABLE_H

#include <cstdint>
#include <string>
#include <unordered_map>
#include <vector>

struct hint_entry {
  uint64_t pc;
  uint8_t replacement_policy_index;
  uint8_t prefetch_policy_index;
  uint8_t prefetch_degree;
  uint8_t demand_filter;
  uint64_t context_key = 0;  // optional context for two-level lookup (v2 format)
};

class hint_table
{
public:
  static hint_table& instance();

  bool load(const std::string& filepath);
  bool load_conservative(const std::string& filepath);
  const hint_entry* lookup(uint64_t pc) const;
  const hint_entry* lookup_conservative(uint64_t pc) const;
  const hint_entry* lookup_with_context(uint64_t pc, uint64_t context_key) const;
  std::size_t size() const;
  bool is_loaded() const;
  bool conservative_loaded() const { return conservative_loaded_; }

  // Runtime congestion feedback (scheme C): CACHE reports demand fill
  // latencies; an EMA with hysteresis drives conservative_mode(), which
  // hint_dispatch consults to pick between the aggressive and
  // conservative hint tables.
  void record_fill_latency(uint64_t cycles);
  bool conservative_mode() const { return conservative_mode_; }
  void set_congestion_thresholds(double high, double low)
  {
    thresh_high_ = high;
    thresh_low_ = low;
  }

  // Runtime per-PC prefetch accuracy gating (scheme C v2): CACHE reports
  // prefetch issues/useful-hits attributed to the issuing PC; counters are
  // decayed periodically. prefer_conservative(pc) is true when the PC has
  // issued enough prefetches (volume floor) with accuracy below the threshold.
  void record_pf_issue(uint64_t pc);
  void record_pf_useful(uint64_t pc);
  bool prefer_conservative(uint64_t pc) const;
  void set_accuracy_gate(double acc_thresh, uint32_t min_issued)
  {
    acc_thresh_ = acc_thresh;
    min_issued_ = min_issued;
  }

  void set_default_replacement(uint8_t idx) { default_replacement_idx = idx; }
  void set_default_prefetch(uint8_t idx) { default_prefetch_idx = idx; }
  uint8_t get_default_replacement() const { return default_replacement_idx; }
  uint8_t get_default_prefetch() const { return default_prefetch_idx; }

  // Diagnostics: print context dispatch statistics
  void print_diagnostics() const;

private:
  hint_table() = default;
  std::unordered_map<uint64_t, hint_entry> hints_;
  std::unordered_map<uint64_t, hint_entry> hints_conservative_;
  std::unordered_map<uint64_t, std::vector<hint_entry>> context_hints_;
  bool loaded_ = false;
  bool conservative_loaded_ = false;
  uint8_t default_replacement_idx = 0;
  uint8_t default_prefetch_idx = 0;
  hint_entry default_entry{0, 0, 0, 0, 0};

  // congestion feedback state
  double lat_ema_ = 0.0;
  uint64_t ema_count_ = 0;
  double thresh_high_ = 500.0; // L1D cycles; enter conservative mode above
  double thresh_low_ = 350.0;  // L1D cycles; leave conservative mode below
  bool conservative_mode_ = false;
  uint64_t mode_switches_ = 0;
  uint64_t conservative_fills_ = 0;

  // per-PC runtime prefetch accuracy (scheme C v2)
  struct pf_pc_stats {
    uint32_t issued = 0;
    uint32_t useful = 0;
  };
  std::unordered_map<uint64_t, pf_pc_stats> pf_rt_stats_;
  double acc_thresh_ = 0.03;    // accuracy below this -> prefer conservative
  uint32_t min_issued_ = 64;    // volume floor: ignore low-activity PCs
  uint64_t gated_lookups_ = 0;  // diagnostics: lookups that switched to conservative
  mutable uint64_t gated_hits_ = 0;
};

#endif
