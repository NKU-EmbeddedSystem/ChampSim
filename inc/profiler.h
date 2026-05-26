#ifndef PROFILER_H
#define PROFILER_H

#ifdef HINT_PROFILING

#include <cstdint>
#include <fstream>
#include <string>
#include <unordered_map>

#ifdef HINT_CONTEXT_PROFILING
#include "address.h"
#include "../prefetcher/hint_dispatch/context_extractors.h"
#include <memory>
#endif

struct pc_profile_record {
  uint64_t pc;
  uint64_t access_count = 0;
  uint64_t hit_count = 0;
  uint64_t miss_count = 0;
  uint64_t prefetch_issued = 0;
  uint64_t prefetch_hit = 0;
  uint64_t total_latency = 0;            // accumulated access latency
  double avg_amat = 0.0;                 // total_latency / access_count
  int active_replacement_policy = -1;
  int active_prefetch_policy = -1;

#ifdef HINT_CONTEXT_PROFILING
  // Per-extractor, per-context_key statistics
  // context_stats[e][context_key] = {access_count, hit_count, miss_count, total_latency}
  struct context_stat {
    uint64_t access_count = 0;
    uint64_t hit_count = 0;
    uint64_t miss_count = 0;
    uint64_t total_latency = 0;
  };
  // 4 extractor dimensions: 0=page_offset, 1=delta_signature, 2=recent_pc_hash, 3=composite
  static constexpr int NUM_CONTEXT_EXTRACTORS = 4;
  std::unordered_map<uint64_t, context_stat> context_stats[NUM_CONTEXT_EXTRACTORS];
#endif
};

class profiler
{
public:
  static profiler& instance();

  void set_output_path(const std::string& path);
  void record_access(uint64_t pc, int repl_policy, int pref_policy, bool hit, uint64_t latency, bool is_demand);
  void update_prefetch_policy(uint64_t pc, int pref_policy);
  void record_prefetch_issue(uint64_t pc);
  void record_prefetch_hit(uint64_t pc);
  void flush();

#ifdef HINT_CONTEXT_PROFILING
  // Compute all 4 context keys for the given access, update extractor state,
  // and store the keys for the next record_access() call to use.
  void record_context_keys(uint64_t pc, champsim::address addr);
#endif

private:
  profiler() = default;
  ~profiler();
  std::unordered_map<uint64_t, pc_profile_record> records_;
  std::string output_path_;
  bool flushed_ = false;

#ifdef HINT_CONTEXT_PROFILING
  // Context extractor instances (one of each type)
  PageOffsetExtractor ctx_page_off_;
  DeltaSignatureExtractor ctx_delta_sig_;
  RecentPCHashExtractor ctx_recent_pc_;
  // Composite = delta_sig + page_off, no separate instance needed

  // Latest computed context keys, consumed by the next record_access()
  uint64_t latest_ctx_keys_[pc_profile_record::NUM_CONTEXT_EXTRACTORS] = {};
  bool ctx_keys_valid_ = false;
#endif
};

// Inline convenience macros for instrumenting cache paths
#define PROFILER_RECORD_ACCESS(pc, repl, pref, hit, lat, demand) profiler::instance().record_access(pc, repl, pref, hit, lat, demand)
#define PROFILER_UPDATE_PREFETCH_POLICY(pc, policy) profiler::instance().update_prefetch_policy(pc, policy)
#define PROFILER_RECORD_PREFETCH_ISSUE(pc) profiler::instance().record_prefetch_issue(pc)
#define PROFILER_RECORD_PREFETCH_HIT(pc) profiler::instance().record_prefetch_hit(pc)

#ifdef HINT_CONTEXT_PROFILING
#define PROFILER_RECORD_CONTEXT_KEYS(pc, addr) profiler::instance().record_context_keys(pc, addr)
#else
#define PROFILER_RECORD_CONTEXT_KEYS(pc, addr) ((void)0)
#endif

#else

#define PROFILER_RECORD_ACCESS(pc, repl, pref, hit, lat, demand) ((void)0)
#define PROFILER_UPDATE_PREFETCH_POLICY(pc, policy) ((void)0)
#define PROFILER_RECORD_PREFETCH_ISSUE(pc) ((void)0)
#define PROFILER_RECORD_PREFETCH_HIT(pc) ((void)0)
#define PROFILER_RECORD_CONTEXT_KEYS(pc, addr) ((void)0)

#endif // HINT_PROFILING

#endif // PROFILER_H
