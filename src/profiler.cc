#ifdef HINT_PROFILING

#include "profiler.h"

#include <iostream>

namespace {
std::string prefetch_policy_name(int idx) {
    switch (idx) {
        case 0: return "no";
        case 1: return "next_line";
        case 2: return "ip_stride";
        case 3: return "spp_dev";
        case 4: return "va_ampm_lite";
        default: return "unknown";
    }
}

std::string replacement_policy_name(int idx) {
    switch (idx) {
        case 0: return "lru";
        case 1: return "ship";
        case 2: return "drrip";
        case 3: return "srrip";
        case 4: return "random";
        default: return "unknown";
    }
}
} // namespace

#ifdef HINT_CONTEXT_PROFILING
namespace {
const char* context_extractor_name(int idx) {
    switch (idx) {
        case 0: return "page_offset";
        case 1: return "delta_signature";
        case 2: return "recent_pc_hash";
        case 3: return "composite";
        default: return "unknown";
    }
}
} // namespace
#endif

profiler& profiler::instance()
{
  static profiler p;
  return p;
}

void profiler::set_output_path(const std::string& path) { output_path_ = path; }

void profiler::record_access(uint64_t pc, int repl_policy, int pref_policy, bool hit, uint64_t latency, bool is_demand)
{
  auto& rec = records_[pc];
  if (rec.access_count == 0) {
    rec.pc = pc;
  }

  // Only count demand accesses (LOAD/RFO) for AMAT calculation
  // Prefetch requests should not affect AMAT comparison across prefetchers
  if (is_demand) {
    rec.access_count++;
    if (hit) {
      rec.hit_count++;
    } else {
      rec.miss_count++;
    }
    rec.total_latency += latency;
  }

  rec.active_replacement_policy = repl_policy;
  // Only update prefetch policy if explicitly set (not -1 sentinel value)
  if (pref_policy >= 0) {
    rec.active_prefetch_policy = pref_policy;
  }

#ifdef HINT_CONTEXT_PROFILING
  // If context keys were recorded before this access, update per-context stats
  // Only for demand accesses to ensure fair AMAT comparison
  if (ctx_keys_valid_ && is_demand) {
    for (int e = 0; e < pc_profile_record::NUM_CONTEXT_EXTRACTORS; e++) {
      auto& cs = rec.context_stats[e][latest_ctx_keys_[e]];
      cs.access_count++;
      if (hit) cs.hit_count++; else cs.miss_count++;
      cs.total_latency += latency;
    }
    ctx_keys_valid_ = false;  // consume the keys
  }
#endif

  if (records_.size() <= 3 && is_demand) {
    std::cerr << "[profiler] record_access: pc=0x" << std::hex << pc << std::dec
              << " hit=" << hit << " total=" << records_.size() << std::endl;
  }
}

void profiler::update_prefetch_policy(uint64_t pc, int pref_policy)
{
  auto it = records_.find(pc);
  if (it != records_.end()) {
    it->second.active_prefetch_policy = pref_policy;
  }
}

void profiler::record_prefetch_issue(uint64_t pc)
{
  auto& rec = records_[pc];
  rec.pc = pc;
  rec.prefetch_issued++;
}

void profiler::record_prefetch_hit(uint64_t pc)
{
  auto& rec = records_[pc];
  rec.pc = pc;
  rec.prefetch_hit++;
}

#ifdef HINT_CONTEXT_PROFILING
void profiler::record_context_keys(uint64_t pc, champsim::address addr)
{
  // Compute context keys from all 4 extractors
  // Extractor 0: PageOffset (deterministic from addr alone)
  latest_ctx_keys_[0] = ctx_page_off_.compute_context(pc, addr);
  // Extractor 1: DeltaSignature (uses PC for per-PC state lookup)
  latest_ctx_keys_[1] = ctx_delta_sig_.compute_context(pc, addr);
  // Extractor 2: RecentPCHash (uses PC history for XOR-fold)
  latest_ctx_keys_[2] = ctx_recent_pc_.compute_context(pc, addr);
  // Extractor 3: Composite = (delta_sig << 32) | (page_off & 0xFFFF)
  latest_ctx_keys_[3] = (latest_ctx_keys_[1] << 32) | (latest_ctx_keys_[0] & 0xFFFF);

  // Update state for all extractors (page_offset has no state, others do)
  ctx_page_off_.update_state(pc, addr);
  ctx_delta_sig_.update_state(pc, addr);
  ctx_recent_pc_.update_state(pc, addr);

  ctx_keys_valid_ = true;
}
#endif

void profiler::flush()
{
  if (flushed_)
    return;
  flushed_ = true;

  // Write JSON lines to stdout when no output path is set.
  // Use std::cout directly — redirecting an ofstream's rdbuf to
  // std::cout.rdbuf() leaves is_open() == false on the ofstream.
  std::ostream* out;
  std::ofstream fout;
  if (output_path_.empty()) {
    out = &std::cout;
  } else {
    fout.open(output_path_);
    if (!fout.is_open()) {
      std::cerr << "[profiler] Warning: could not open output file '" << output_path_ << "'" << std::endl;
      return;
    }
    out = &fout;
  }

  for (const auto& [pc, rec] : records_) {
    double hit_ratio = rec.access_count > 0 ? static_cast<double>(rec.hit_count) / rec.access_count : 0.0;
    double pref_accuracy = rec.prefetch_issued > 0 ? static_cast<double>(rec.prefetch_hit) / rec.prefetch_issued : 0.0;

    double avg_amat = rec.access_count > 0 ? static_cast<double>(rec.total_latency) / rec.access_count : 0.0;

    (*out) << "{"
        << "\"pc\": \"0x" << std::hex << rec.pc << std::dec << "\", "
        << "\"access_count\": " << rec.access_count << ", "
        << "\"hit_count\": " << rec.hit_count << ", "
        << "\"miss_count\": " << rec.miss_count << ", "
        << "\"hit_ratio\": " << hit_ratio << ", "
        << "\"prefetch_issued\": " << rec.prefetch_issued << ", "
        << "\"prefetch_hit\": " << rec.prefetch_hit << ", "
        << "\"prefetch_accuracy\": " << pref_accuracy << ", "
        << "\"total_latency\": " << rec.total_latency << ", "
        << "\"avg_amat\": " << avg_amat << ", "
        << "\"active_replacement_policy\": \"" << replacement_policy_name(rec.active_replacement_policy) << "\", "
        << "\"active_prefetch_policy\": \"" << prefetch_policy_name(rec.active_prefetch_policy) << "\"}"
        << std::endl;
  }

  std::cerr << "[profiler] Flushed " << records_.size() << " PC profile records" << std::endl;

#ifdef HINT_CONTEXT_PROFILING
  // Output per-(PC, extractor, context_key) statistics
  uint64_t context_records = 0;
  for (const auto& [pc, rec] : records_) {
    for (int e = 0; e < pc_profile_record::NUM_CONTEXT_EXTRACTORS; e++) {
      for (const auto& [ctx_key, cs] : rec.context_stats[e]) {
        if (cs.access_count == 0) continue;
        double ctx_hit_ratio = static_cast<double>(cs.hit_count) / cs.access_count;
        double ctx_avg_amat = static_cast<double>(cs.total_latency) / cs.access_count;

        (*out) << "{"
            << "\"pc\": \"0x" << std::hex << rec.pc << std::dec << "\", "
            << "\"context_extractor\": \"" << context_extractor_name(e) << "\", "
            << "\"context_key\": " << ctx_key << ", "
            << "\"access_count\": " << cs.access_count << ", "
            << "\"hit_count\": " << cs.hit_count << ", "
            << "\"miss_count\": " << cs.miss_count << ", "
            << "\"hit_ratio\": " << ctx_hit_ratio << ", "
            << "\"total_latency\": " << cs.total_latency << ", "
            << "\"avg_amat\": " << ctx_avg_amat << "}"
            << std::endl;
        context_records++;
      }
    }
  }
  std::cerr << "[profiler] Flushed " << context_records << " context profile records" << std::endl;
#endif
}

profiler::~profiler() { flush(); }

#endif // HINT_PROFILING
