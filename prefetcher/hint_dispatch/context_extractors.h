#pragma once

#include "address.h"
#include <array>
#include <cstdint>

// Use existing page size constants from champsim.h (extern const unsigned LOG2_PAGE_SIZE, PAGE_SIZE)

// Abstract base class for all context extractors.
// Subclasses compute a uint64_t context key from the current memory access
// (PC + address) and maintain internal state across accesses.
class ContextExtractor {
public:
  virtual ~ContextExtractor() = default;

  // Compute the context key from the current access state.
  // Does NOT modify internal state -- call update_state() separately.
  virtual uint64_t compute_context(uint64_t pc, champsim::address addr) = 0;

  // Update internal state with the current access (e.g., update rolling
  // signature, append PC to history). Called after compute_context() so
  // the context reflects history up to but not including this access.
  virtual void update_state(uint64_t pc, champsim::address addr) = 0;

  // Reset all internal state (e.g., between simulation phases).
  virtual void reset() = 0;
};

// ---------------------------------------------------------------------------
// Extractor 1: PageOffsetExtractor
// Combines page number and page offset into a 64-bit context key.
//   bits[63:32] = page_number
//   bits[31:0]  = page_offset
// Deterministic from address alone -- no internal state.
// ---------------------------------------------------------------------------
class PageOffsetExtractor : public ContextExtractor {
public:
  uint64_t compute_context(uint64_t /*pc*/, champsim::address addr) override
  {
    uint64_t raw = addr.to<uint64_t>();
    uint64_t page_number = raw >> LOG2_PAGE_SIZE;
    uint64_t page_offset = raw & (PAGE_SIZE - 1);
    return (page_number << 32) | page_offset;
  }

  void update_state(uint64_t /*pc*/, champsim::address /*addr*/) override
  {
    // No state to update -- deterministic from addr alone.
  }

  void reset() override
  {
    // No state to reset.
  }
};

// ---------------------------------------------------------------------------
// Extractor 2: DeltaSignatureExtractor
// Maintains a rolling per-PC signature: sig = (sig << 7) ^ delta.
// The signature is masked to 12 bits (0xFFF).
//
// Internal state: fixed-size LRU table of 1024 entries keyed by PC. Each entry
// holds {pc, signature, last_offset, lru_counter}. LRU eviction when full.
// ---------------------------------------------------------------------------
class DeltaSignatureExtractor : public ContextExtractor {
private:
  static constexpr int DELTA_TABLE_SIZE = 1024;
  static constexpr int SIG_MASK = 0xFFF;
  static constexpr int SIG_SHIFT = 7;

  struct DeltaEntry {
    uint64_t pc;
    uint64_t signature;
    uint64_t last_offset;
    uint64_t lru_counter;
  };

  std::array<DeltaEntry, DELTA_TABLE_SIZE> delta_table_ = {};
  int table_fill_ = 0;
  uint64_t lru_clock_ = 0;

  // Find the entry index for a given PC, or return -1 if not found.
  int find_entry(uint64_t pc) const
  {
    for (int i = 0; i < table_fill_; i++) {
      if (delta_table_[i].pc == pc) {
        return i;
      }
    }
    return -1;
  }

  // Find the index of the entry with the smallest lru_counter.
  int find_lru_entry() const
  {
    int lru_idx = 0;
    for (int i = 1; i < table_fill_; i++) {
      if (delta_table_[i].lru_counter < delta_table_[lru_idx].lru_counter) {
        lru_idx = i;
      }
    }
    return lru_idx;
  }

public:
  DeltaSignatureExtractor() = default;

  uint64_t compute_context(uint64_t pc, champsim::address /*addr*/) override
  {
    int idx = find_entry(pc);
    if (idx >= 0) {
      return delta_table_[idx].signature & SIG_MASK;
    }
    return 0;
  }

  void update_state(uint64_t pc, champsim::address addr) override
  {
    uint64_t offset = addr.to<uint64_t>() & (PAGE_SIZE - 1);
    int idx = find_entry(pc);

    if (idx >= 0) {
      // Existing entry: compute delta and update rolling signature.
      DeltaEntry& entry = delta_table_[idx];
      int64_t delta = static_cast<int64_t>(offset) - static_cast<int64_t>(entry.last_offset);
      entry.signature = ((entry.signature << SIG_SHIFT) ^ static_cast<uint64_t>(delta)) & SIG_MASK;
      entry.last_offset = offset;
      entry.lru_counter = ++lru_clock_;
    } else if (table_fill_ < DELTA_TABLE_SIZE) {
      // New entry, table not yet full.
      int new_idx = table_fill_++;
      delta_table_[new_idx] = DeltaEntry{pc, 0, offset, ++lru_clock_};
    } else {
      // Table full: evict the LRU entry.
      int lru_idx = find_lru_entry();
      delta_table_[lru_idx] = DeltaEntry{pc, 0, offset, ++lru_clock_};
    }
  }

  void reset() override
  {
    table_fill_ = 0;
    lru_clock_ = 0;
    for (int i = 0; i < DELTA_TABLE_SIZE; i++) {
      delta_table_[i] = DeltaEntry{0, 0, 0, 0};
    }
  }
};

// ---------------------------------------------------------------------------
// Extractor 3: RecentPCHashExtractor
// Tracks the last 8 data-cache-accessing PCs in a circular buffer.
// compute_context() XOR-folds all entries into a 64-bit hash.
// ---------------------------------------------------------------------------
class RecentPCHashExtractor : public ContextExtractor {
private:
  static constexpr int NUM_RECENT_PCS = 8;
  std::array<uint64_t, NUM_RECENT_PCS> recent_pcs_ = {};
  int write_idx_ = 0;

public:
  RecentPCHashExtractor() = default;

  uint64_t compute_context(uint64_t /*pc*/, champsim::address /*addr*/) override
  {
    uint64_t hash = 0;
    for (int i = 0; i < NUM_RECENT_PCS; i++) {
      hash ^= recent_pcs_[i];
    }
    return hash;
  }

  void update_state(uint64_t pc, champsim::address /*addr*/) override
  {
    recent_pcs_[write_idx_ % NUM_RECENT_PCS] = pc;
    write_idx_++;
  }

  void reset() override
  {
    for (int i = 0; i < NUM_RECENT_PCS; i++) {
      recent_pcs_[i] = 0;
    }
    write_idx_ = 0;
  }
};

// ---------------------------------------------------------------------------
// Extractor 4: CompositeExtractor
// Combines DeltaSignatureExtractor and PageOffsetExtractor.
//   bits[63:32] = delta_signature
//   bits[31:0]  = page_offset & 0xFFFF
// Delegates update_state and reset to both sub-extractors.
// ---------------------------------------------------------------------------
class CompositeExtractor : public ContextExtractor {
private:
  DeltaSignatureExtractor delta_sig_extractor_;
  PageOffsetExtractor page_offset_extractor_;

public:
  CompositeExtractor() = default;

  uint64_t compute_context(uint64_t pc, champsim::address addr) override
  {
    uint64_t delta_sig = delta_sig_extractor_.compute_context(pc, addr);
    uint64_t page_off = page_offset_extractor_.compute_context(pc, addr);
    return (delta_sig << 32) | (page_off & 0xFFFF);
  }

  void update_state(uint64_t pc, champsim::address addr) override
  {
    delta_sig_extractor_.update_state(pc, addr);
    page_offset_extractor_.update_state(pc, addr);
  }

  void reset() override
  {
    delta_sig_extractor_.reset();
    page_offset_extractor_.reset();
  }
};
