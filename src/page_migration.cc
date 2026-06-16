#include "page_migration.h"
#include "trace_page_buffer.h"
#include <algorithm>
#include <cmath>
#include <iostream>
#include <set>
#include <vector>

// ─────────────────────────────────────────────────────────────────────────────
// Public interface
// ─────────────────────────────────────────────────────────────────────────────

void PageMigrationEngine::init(MigrationMode mode, uint64_t dram_pages,
                               const std::unordered_map<uint64_t, uint8_t> &initial_map) {
  mode_ = mode;
  dram_pages_ = dram_pages;
  page_area_ = initial_map;
  access_count_ = 0;
  interval_start_ = 0;
  migrate_count_ = 0;
  total_migrations_ = 0;
  total_pages_moved_ = 0;
  avg_dram_heat_post_ = 0.0;
  avg_cxl_heat_post_ = 0.0;
  heat_counts_.clear();
  forward_heat_.clear();
  last_interval_heat_.clear();

  const char *mode_str = "none";
  switch (mode) {
    case MigrationMode::FORWARD:       mode_str = "forward"; break;
    case MigrationMode::BACKWARD:      mode_str = "backward"; break;
    case MigrationMode::FORWARD_LAZY:  mode_str = "forward_lazy"; break;
    case MigrationMode::BACKWARD_LAZY: mode_str = "backward_lazy"; break;
    default: break;
  }
  std::cerr << "[migration] mode=" << mode_str
            << " dram_pages=" << dram_pages_
            << " initial_map_entries=" << initial_map.size() << "\n";
}

void PageMigrationEngine::recordAccess(uint64_t page_id) {
  access_count_++;
  if (mode_ == MigrationMode::BACKWARD || mode_ == MigrationMode::BACKWARD_LAZY)
    heat_counts_[page_id]++;
}

void PageMigrationEngine::maybeMigrate(uint64_t /*current_cycle*/) {
  if (mode_ == MigrationMode::NONE) return;
  if (access_count_ - interval_start_ < MIGRATION_INTERVAL) return;

  total_migrations_++;

  switch (mode_) {
    case MigrationMode::BACKWARD:      doBackwardMigration();      break;
    case MigrationMode::FORWARD:       doForwardMigration();       break;
    case MigrationMode::BACKWARD_LAZY: doBackwardLazyMigration();  break;
    case MigrationMode::FORWARD_LAZY:  doForwardLazyMigration();   break;
    default: break;
  }

  interval_start_ = access_count_;
  migrate_count_++;
}

void PageMigrationEngine::forceMigrate(uint64_t /*current_cycle*/) {
  if (mode_ == MigrationMode::NONE) return;
  total_migrations_++;
  switch (mode_) {
    case MigrationMode::BACKWARD:      doBackwardMigration();      break;
    case MigrationMode::FORWARD:       doForwardMigration();       break;
    case MigrationMode::BACKWARD_LAZY: doBackwardLazyMigration();  break;
    case MigrationMode::FORWARD_LAZY:  doForwardLazyMigration();   break;
    default: break;
  }
  migrate_count_++;
}

uint8_t PageMigrationEngine::getArea(uint64_t page_id) const {
  auto it = page_area_.find(page_id);
  if (it != page_area_.end()) return it->second;
  return 1; // default: CXL
}

// ─────────────────────────────────────────────────────────────────────────────
// Shared helpers
// ─────────────────────────────────────────────────────────────────────────────

std::vector<std::pair<uint64_t, uint64_t>>
PageMigrationEngine::buildSorted(const std::unordered_map<uint64_t, uint64_t> &heat_map) {
  std::vector<std::pair<uint64_t, uint64_t>> sorted;
  for (auto &kv : heat_map) sorted.push_back(kv);
  std::sort(sorted.begin(), sorted.end(),
            [](const auto &a, const auto &b) { return a.second > b.second; });
  return sorted;
}

uint64_t PageMigrationEngine::backfillFromOldDram(
    const std::unordered_map<uint64_t, uint64_t> &new_dram_pages,
    uint64_t slots) {
  if (slots == 0) return 0;

  // Collect old DRAM pages not already in new_dram, with their previous heat
  std::vector<std::pair<uint64_t, uint64_t>> candidates;
  for (auto &kv : page_area_) {
    if (kv.second != 0) continue;                  // not in DRAM
    if (new_dram_pages.count(kv.first) > 0) continue;  // already placed

    uint64_t heat = 0;
    auto hit = last_interval_heat_.find(kv.first);
    if (hit != last_interval_heat_.end())
      heat = hit->second;
    candidates.push_back({kv.first, heat});
  }

  // Sort by previous heat descending
  std::sort(candidates.begin(), candidates.end(),
            [](const auto &a, const auto &b) { return a.second > b.second; });

  // Backfill up to `slots`
  uint64_t filled = 0;
  for (size_t i = 0; i < candidates.size() && filled < slots; i++) {
    page_area_[candidates[i].first] = 0;
    filled++;
  }

  return filled;
}

uint64_t PageMigrationEngine::applyDramAssignment(
    const std::unordered_map<uint64_t, uint64_t> &new_dram_set,
    const std::unordered_map<uint64_t, uint64_t> &heat_map,
    double &dram_heat_sum_out, uint64_t &dram_count_out,
    double &cxl_heat_sum_out, uint64_t &cxl_count_out) {

  uint64_t pages_moved = 0;
  dram_heat_sum_out = 0.0; dram_count_out = 0;
  cxl_heat_sum_out = 0.0;  cxl_count_out = 0;

  // Collect all pages that have a current area
  std::set<uint64_t> all_pages;
  for (auto &kv : page_area_) all_pages.insert(kv.first);
  for (auto &kv : new_dram_set) all_pages.insert(kv.first);

  for (uint64_t pid : all_pages) {
    uint8_t old_area = 1;
    auto it = page_area_.find(pid);
    if (it != page_area_.end()) old_area = it->second;

    uint8_t new_area = (new_dram_set.count(pid) > 0) ? 0 : 1;

    if (old_area != new_area) pages_moved++;

    page_area_[pid] = new_area;

    // Accumulate heat from the heat_map (0 if not present = cold)
    double h = 0.0;
    auto hit = heat_map.find(pid);
    if (hit != heat_map.end()) h = static_cast<double>(hit->second);

    if (new_area == 0) {
      dram_heat_sum_out += h;
      dram_count_out++;
    } else {
      cxl_heat_sum_out += h;
      cxl_count_out++;
    }
  }

  return pages_moved;
}

void PageMigrationEngine::logAndUpdateStats(const char *mode_label,
                                            uint64_t pages_moved,
                                            double dram_heat_sum, uint64_t dram_count,
                                            double cxl_heat_sum, uint64_t cxl_count) {
  // Update running averages
  if (dram_count > 0) {
    double this_dram_avg = dram_heat_sum / dram_count;
    avg_dram_heat_post_ = (avg_dram_heat_post_ * (total_migrations_ - 1) + this_dram_avg)
                          / total_migrations_;
  }
  if (cxl_count > 0) {
    double this_cxl_avg = cxl_heat_sum / cxl_count;
    avg_cxl_heat_post_ = (avg_cxl_heat_post_ * (total_migrations_ - 1) + this_cxl_avg)
                         / total_migrations_;
  }

  total_pages_moved_ += pages_moved;

  std::cerr << "[migration] " << mode_label << " #" << total_migrations_
            << " pages_moved=" << pages_moved
            << " dram_avg_heat=" << (dram_count > 0 ? dram_heat_sum / dram_count : 0.0)
            << " cxl_avg_heat=" << (cxl_count > 0 ? cxl_heat_sum / cxl_count : 0.0)
            << " dram_pages=" << dram_count
            << " cxl_pages=" << cxl_count
            << "\n";
}

// ─────────────────────────────────────────────────────────────────────────────
// Full-replacement migration: top-K every interval
// ─────────────────────────────────────────────────────────────────────────────

void PageMigrationEngine::doBackwardMigration() {
  if (heat_counts_.empty()) return;

  auto sorted = buildSorted(heat_counts_);
  size_t N = sorted.size();
  uint64_t K = dram_pages_;

  std::unordered_map<uint64_t, uint64_t> new_dram_set;
  size_t assign_count = (N < K) ? N : K;
  for (size_t i = 0; i < assign_count; i++) {
    new_dram_set[sorted[i].first] = sorted[i].second;
  }

  // Shortfall handling: if sorted has fewer than K pages,
  // backfill from old DRAM pages by last_interval_heat_
  if (assign_count < K) {
    uint64_t slots = K - assign_count;
    backfillFromOldDram(new_dram_set, slots);
  }

  double dram_heat_sum, cxl_heat_sum;
  uint64_t dram_count, cxl_count;
  uint64_t pages_moved = applyDramAssignment(new_dram_set, heat_counts_,
                                             dram_heat_sum, dram_count,
                                             cxl_heat_sum, cxl_count);

  logAndUpdateStats("backward", pages_moved,
                    dram_heat_sum, dram_count,
                    cxl_heat_sum, cxl_count);

  last_interval_heat_ = std::move(heat_counts_);
  heat_counts_.clear();
}

void PageMigrationEngine::doForwardMigration() {

  size_t ahead = page_buffer_->aheadOf(0);
  auto future_heat = page_buffer_->consume(1000000);

  auto sorted = buildSorted(future_heat);
  size_t N = sorted.size();
  uint64_t K = dram_pages_;

  std::unordered_map<uint64_t, uint64_t> new_dram_set;
  size_t assign_count = (N < K) ? N : K;
  for (size_t i = 0; i < assign_count; i++) {
    new_dram_set[sorted[i].first] = sorted[i].second;
  }

  if (assign_count < K) {
    uint64_t slots = K - assign_count;
    backfillFromOldDram(new_dram_set, slots);
  }

  double dram_heat_sum, cxl_heat_sum;
  uint64_t dram_count, cxl_count;
  uint64_t pages_moved = applyDramAssignment(new_dram_set, future_heat,
                                             dram_heat_sum, dram_count,
                                             cxl_heat_sum, cxl_count);

  logAndUpdateStats("forward", pages_moved,
                    dram_heat_sum, dram_count,
                    cxl_heat_sum, cxl_count);

  last_interval_heat_ = std::move(future_heat);
}

// ─────────────────────────────────────────────────────────────────────────────
// Lazy / incremental migration: promote/demote with hysteresis
// ─────────────────────────────────────────────────────────────────────────────

void PageMigrationEngine::doBackwardLazyMigration() {
  if (heat_counts_.empty()) {
    last_interval_heat_ = std::move(heat_counts_);
    heat_counts_.clear();
    return;
  }

  uint64_t K = dram_pages_;

  // ── Compute DRAM heat statistics for thresholds ──
  std::vector<uint64_t> dram_heats;
  for (auto &kv : page_area_) {
    if (kv.second == 0) {
      auto hit = heat_counts_.find(kv.first);
      dram_heats.push_back(hit != heat_counts_.end() ? hit->second : 0);
    }
  }
  if (dram_heats.empty()) dram_heats.push_back(0);

  std::sort(dram_heats.begin(), dram_heats.end());
  uint64_t dram_median_heat = dram_heats[dram_heats.size() / 2];
  size_t p20_idx = dram_heats.size() / 5;
  if (p20_idx >= dram_heats.size()) p20_idx = 0;
  uint64_t demote_threshold = dram_heats[p20_idx];

  // Budget: at most 10% of K pages promoted/demoted per interval
  uint64_t budget = std::max(uint64_t(1), K / 10);

  // ── Demote candidates (DRAM → CXL): coldest DRAM pages ──
  std::vector<std::pair<uint64_t, uint64_t>> demote_candidates;
  for (auto &kv : page_area_) {
    if (kv.second != 0) continue;
    uint64_t h = 0;
    auto hit = heat_counts_.find(kv.first);
    if (hit != heat_counts_.end()) h = hit->second;
    if (h <= demote_threshold && h < dram_median_heat) {
      demote_candidates.push_back({kv.first, h});
    }
  }
  std::sort(demote_candidates.begin(), demote_candidates.end(),
            [](const auto &a, const auto &b) { return a.second < b.second; });

  // ── Promote candidates (CXL → DRAM): pages hotter than DRAM median ──
  std::vector<std::pair<uint64_t, uint64_t>> promote_candidates;
  for (auto &kv : heat_counts_) {
    uint8_t area = 1;
    auto it = page_area_.find(kv.first);
    if (it != page_area_.end()) area = it->second;
    if (area == 0) continue;
    if (kv.second > dram_median_heat) {
      promote_candidates.push_back({kv.first, kv.second});
    }
  }
  std::sort(promote_candidates.begin(), promote_candidates.end(),
            [](const auto &a, const auto &b) { return a.second > b.second; });

  // ── Execute demotes ──
  uint64_t demote_count = 0;
  uint64_t demote_budget = std::min(budget, (uint64_t)demote_candidates.size());
  for (size_t i = 0; i < demote_budget; i++) {
    page_area_[demote_candidates[i].first] = 1;
    demote_count++;
  }

  // ── Compute available DRAM slots after demotion ──
  uint64_t dram_after_demote = 0;
  for (auto &kv : page_area_) {
    if (kv.second == 0) dram_after_demote++;
  }
  uint64_t free_slots = (dram_after_demote < K) ? (K - dram_after_demote) : 0;

  // ── Execute promotes ──
  uint64_t promote_count = 0;
  uint64_t promote_budget = std::min(budget, (uint64_t)promote_candidates.size());
  promote_budget = std::min(promote_budget, free_slots + demote_count);
  for (size_t i = 0; i < promote_budget; i++) {
    page_area_[promote_candidates[i].first] = 0;
    promote_count++;
  }

  // ── Enforce K capacity ──
  uint64_t dram_after_promote = 0;
  for (auto &kv : page_area_) {
    if (kv.second == 0) dram_after_promote++;
  }
  if (dram_after_promote > K) {
    std::vector<std::pair<uint64_t, uint64_t>> all_dram;
    for (auto &kv : page_area_) {
      if (kv.second == 0) {
        uint64_t h = 0;
        auto hit = heat_counts_.find(kv.first);
        if (hit != heat_counts_.end()) h = hit->second;
        all_dram.push_back({kv.first, h});
      }
    }
    std::sort(all_dram.begin(), all_dram.end(),
              [](const auto &a, const auto &b) { return a.second < b.second; });
    uint64_t excess = dram_after_promote - K;
    for (size_t i = 0; i < excess && i < all_dram.size(); i++) {
      page_area_[all_dram[i].first] = 1;
    }
  }

  // ── Stats ──
  uint64_t total_moved = demote_count + promote_count;
  uint64_t final_dram = 0, final_cxl = 0;
  double final_dram_heat = 0, final_cxl_heat = 0;
  for (auto &kv : page_area_) {
    uint64_t h = 0;
    auto hit = heat_counts_.find(kv.first);
    if (hit != heat_counts_.end()) h = hit->second;
    if (kv.second == 0) { final_dram++; final_dram_heat += h; }
    else                { final_cxl++;  final_cxl_heat  += h; }
  }

  logAndUpdateStats("backward_lazy", total_moved,
                    final_dram_heat, final_dram,
                    final_cxl_heat, final_cxl);

  last_interval_heat_ = std::move(heat_counts_);
  heat_counts_.clear();
}

void PageMigrationEngine::doForwardLazyMigration() {
  if (!page_buffer_) return;

  // Peek the next 1M page_ids from the trace (future lookahead)
  auto future_heat = page_buffer_->consume(1000000);
  if (future_heat.empty()) {
    last_interval_heat_ = std::move(future_heat);
    return;
  }

  uint64_t K = dram_pages_;

  // ── Compute DRAM heat statistics using future_heat ──
  std::vector<uint64_t> dram_heats;
  for (auto &kv : page_area_) {
    if (kv.second == 0) {
      auto hit = future_heat.find(kv.first);
      dram_heats.push_back(hit != future_heat.end() ? hit->second : 0);
    }
  }
  if (dram_heats.empty()) dram_heats.push_back(0);

  std::sort(dram_heats.begin(), dram_heats.end());
  uint64_t dram_median_heat = dram_heats[dram_heats.size() / 2];
  size_t p20_idx = dram_heats.size() / 5;
  if (p20_idx >= dram_heats.size()) p20_idx = 0;
  uint64_t demote_threshold = dram_heats[p20_idx];

  uint64_t budget = std::max(uint64_t(1), K / 10);

  // ── Demote candidates ──
  std::vector<std::pair<uint64_t, uint64_t>> demote_candidates;
  for (auto &kv : page_area_) {
    if (kv.second != 0) continue;
    uint64_t h = 0;
    auto hit = future_heat.find(kv.first);
    if (hit != future_heat.end()) h = hit->second;
    if (h <= demote_threshold && h < dram_median_heat) {
      demote_candidates.push_back({kv.first, h});
    }
  }
  std::sort(demote_candidates.begin(), demote_candidates.end(),
            [](const auto &a, const auto &b) { return a.second < b.second; });

  // ── Promote candidates ──
  std::vector<std::pair<uint64_t, uint64_t>> promote_candidates;
  for (auto &kv : future_heat) {
    uint8_t area = 1;
    auto it = page_area_.find(kv.first);
    if (it != page_area_.end()) area = it->second;
    if (area == 0) continue;
    if (kv.second > dram_median_heat) {
      promote_candidates.push_back({kv.first, kv.second});
    }
  }
  std::sort(promote_candidates.begin(), promote_candidates.end(),
            [](const auto &a, const auto &b) { return a.second > b.second; });

  // ── Execute demotes ──
  uint64_t demote_count = 0;
  uint64_t demote_budget = std::min(budget, (uint64_t)demote_candidates.size());
  for (size_t i = 0; i < demote_budget; i++) {
    page_area_[demote_candidates[i].first] = 1;
    demote_count++;
  }

  // ── Count DRAM pages after demotion ──
  uint64_t dram_after_demote = 0;
  for (auto &kv : page_area_) {
    if (kv.second == 0) dram_after_demote++;
  }
  uint64_t free_slots = (dram_after_demote < K) ? (K - dram_after_demote) : 0;

  // ── Execute promotes ──
  uint64_t promote_count = 0;
  uint64_t promote_budget = std::min(budget, (uint64_t)promote_candidates.size());
  promote_budget = std::min(promote_budget, free_slots + demote_count);
  for (size_t i = 0; i < promote_budget; i++) {
    page_area_[promote_candidates[i].first] = 0;
    promote_count++;
  }

  // ── Enforce K capacity ──
  uint64_t dram_after_promote = 0;
  for (auto &kv : page_area_) {
    if (kv.second == 0) dram_after_promote++;
  }
  if (dram_after_promote > K) {
    std::vector<std::pair<uint64_t, uint64_t>> all_dram;
    for (auto &kv : page_area_) {
      if (kv.second == 0) {
        uint64_t h = 0;
        auto hit = future_heat.find(kv.first);
        if (hit != future_heat.end()) h = hit->second;
        all_dram.push_back({kv.first, h});
      }
    }
    std::sort(all_dram.begin(), all_dram.end(),
              [](const auto &a, const auto &b) { return a.second < b.second; });
    uint64_t excess = dram_after_promote - K;
    for (size_t i = 0; i < excess && i < all_dram.size(); i++) {
      page_area_[all_dram[i].first] = 1;
    }
  }

  // ── Stats ──
  uint64_t total_moved = demote_count + promote_count;
  uint64_t final_dram = 0, final_cxl = 0;
  double final_dram_heat = 0, final_cxl_heat = 0;
  for (auto &kv : page_area_) {
    uint64_t h = 0;
    auto hit = future_heat.find(kv.first);
    if (hit != future_heat.end()) h = hit->second;
    if (kv.second == 0) { final_dram++; final_dram_heat += h; }
    else                { final_cxl++;  final_cxl_heat  += h; }
  }

  logAndUpdateStats("forward_lazy", total_moved,
                    final_dram_heat, final_dram,
                    final_cxl_heat, final_cxl);

  last_interval_heat_ = std::move(future_heat);
}
