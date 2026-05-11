#ifndef PROFILER_H
#define PROFILER_H

#ifdef HINT_PROFILING

#include <cstdint>
#include <fstream>
#include <string>
#include <unordered_map>

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
};

class profiler
{
public:
  static profiler& instance();

  void set_output_path(const std::string& path);
  void record_access(uint64_t pc, int repl_policy, int pref_policy, bool hit, uint64_t latency);
  void record_prefetch_issue(uint64_t pc);
  void record_prefetch_hit(uint64_t pc);
  void flush();

private:
  profiler() = default;
  ~profiler();
  std::unordered_map<uint64_t, pc_profile_record> records_;
  std::string output_path_;
  bool flushed_ = false;
};

// Inline convenience macros for instrumenting cache paths
#define PROFILER_RECORD_ACCESS(pc, repl, pref, hit, lat) profiler::instance().record_access(pc, repl, pref, hit, lat)
#define PROFILER_RECORD_PREFETCH_ISSUE(pc) profiler::instance().record_prefetch_issue(pc)
#define PROFILER_RECORD_PREFETCH_HIT(pc) profiler::instance().record_prefetch_hit(pc)

#else

#define PROFILER_RECORD_ACCESS(pc, repl, pref, hit, lat) ((void)0)
#define PROFILER_RECORD_PREFETCH_ISSUE(pc) ((void)0)
#define PROFILER_RECORD_PREFETCH_HIT(pc) ((void)0)

#endif // HINT_PROFILING

#endif // PROFILER_H
