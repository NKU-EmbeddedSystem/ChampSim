#ifndef PAGE_MIGRATION_H
#define PAGE_MIGRATION_H

#include <cstdint>
#include <string>
#include <unordered_map>
#include <vector>

// Forward declaration
class TracePageBuffer;

#define MIGRATION_INTERVAL 1000000  // trigger migration every 1M data-memory accesses

enum class MigrationMode { NONE, FORWARD, BACKWARD, FORWARD_LAZY, BACKWARD_LAZY };

class PageMigrationEngine {
public:
  PageMigrationEngine() : mode_(MigrationMode::NONE), dram_pages_(0),
                          access_count_(0), interval_start_(0) {}

  // Configure: set migration mode + DRAM capacity + initial area_map
  void init(MigrationMode mode, uint64_t dram_pages,
            const std::unordered_map<uint64_t, uint8_t> &initial_map);

  // Set the trace page buffer (required for FORWARD / FORWARD_LAZY modes)
  void setPageBuffer(TracePageBuffer *buf) { page_buffer_ = buf; }

  // Called on every data-memory reference to track heat during ROI and align
  // forward lookahead during warmup.
  void recordAccess(uint64_t page_id, bool in_roi = true);

  // Trigger migration check. Should be called periodically.
  void maybeMigrate(uint64_t current_cycle);

  // Force migration immediately — bypasses interval check (for main-loop trigger)
  void forceMigrate(uint64_t current_cycle);

  // Get current area for a page (looks up area_map, falls back to area 1 = CXL)
  uint8_t getArea(uint64_t page_id) const;

  // Check if migration is enabled
  bool isActive() const { return mode_ != MigrationMode::NONE; }
  bool usesForwardLookahead() const {
    return mode_ == MigrationMode::FORWARD || mode_ == MigrationMode::FORWARD_LAZY;
  }

  // Stats
  uint64_t getMigrateCount() const { return migrate_count_; }
  uint64_t getTotalMigrations() const { return total_migrations_; }
  uint64_t getTotalPagesMoved() const { return total_pages_moved_; }
  double getAvgDramHeatAfter() const { return avg_dram_heat_post_; }
  double getAvgCxlHeatAfter() const { return avg_cxl_heat_post_; }

private:
  MigrationMode mode_;
  uint64_t dram_pages_;
  uint64_t access_count_;
  uint64_t interval_start_;

  // Current page→area mapping
  std::unordered_map<uint64_t, uint8_t> page_area_;

  // Backward mode: accumulated access counts in current interval
  std::unordered_map<uint64_t, uint64_t> heat_counts_;

  // Forward mode: trace page buffer for lookahead
  TracePageBuffer *page_buffer_ = nullptr;

  // Forward mode: predicted future access counts (from nextAccess hints)
  std::unordered_map<uint64_t, uint64_t> forward_heat_;

  // Previous interval's heat map (for shortfall backfill)
  std::unordered_map<uint64_t, uint64_t> last_interval_heat_;

  // Migration statistics
  uint64_t migrate_count_ = 0;

  // Detailed per-migration stats
  uint64_t total_migrations_ = 0;
  uint64_t total_pages_moved_ = 0;
  double avg_dram_heat_post_ = 0.0;
  double avg_cxl_heat_post_ = 0.0;

  // ── Full-replacement migration (top-K every interval) ──
  void doBackwardMigration();
  void doForwardMigration();

  // ── Lazy / incremental migration (promote/demote with thresholds) ──
  void doBackwardLazyMigration();
  void doForwardLazyMigration();

  // ── Shared helpers ──
  // Build sorted (page_id, heat) list from a heat map, descending
  static std::vector<std::pair<uint64_t, uint64_t>>
  buildSorted(const std::unordered_map<uint64_t, uint64_t> &heat_map);

  // Shortfall backfill: given the set of pages already assigned to DRAM,
  // pick up to `slots` additional pages from old DRAM pages (by their
  // last_interval_heat_) that are NOT already in new_dram.
  uint64_t backfillFromOldDram(
      std::unordered_map<uint64_t, uint64_t> &new_dram_pages,
      uint64_t slots);

  // Apply the new dram assignment: dram_set → area 0, everything else → area 1
  uint64_t applyDramAssignment(
      const std::unordered_map<uint64_t, uint64_t> &new_dram_set,
      const std::unordered_map<uint64_t, uint64_t> &heat_map,
      double &dram_heat_sum_out, uint64_t &dram_count_out,
      double &cxl_heat_sum_out, uint64_t &cxl_count_out);

  // Log migration result and update running stats
  void logAndUpdateStats(const char *mode_label,
                         uint64_t pages_moved,
                         double dram_heat_sum, uint64_t dram_count,
                         double cxl_heat_sum, uint64_t cxl_count);

  // Resolve DRAM capacity. Explicit --dram_pages wins; otherwise use the
  // initial area_map's DRAM count, or one third of the currently known pages.
  uint64_t effectiveDramPages(uint64_t candidate_pages) const;

  // Update both the migration engine's current map and the live mapper used by
  // packet area assignment.
  void setPageArea(uint64_t page_id, uint8_t area);
};

#endif // PAGE_MIGRATION_H
