#ifdef HINT_PROFILING

#include "profiler.h"

#include <iostream>

profiler& profiler::instance()
{
  static profiler p;
  return p;
}

void profiler::set_output_path(const std::string& path) { output_path_ = path; }

void profiler::record_access(uint64_t pc, int repl_policy, int pref_policy, bool hit, uint64_t latency)
{
  auto& rec = records_[pc];
  rec.pc = pc;
  rec.access_count++;
  if (hit) {
    rec.hit_count++;
  } else {
    rec.miss_count++;
  }
  rec.active_replacement_policy = repl_policy;
  rec.active_prefetch_policy = pref_policy;
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

void profiler::flush()
{
  if (flushed_)
    return;
  flushed_ = true;

  std::ofstream out;
  if (output_path_.empty()) {
    out.basic_ios::rdbuf(std::cout.rdbuf());
  } else {
    out.open(output_path_);
  }

  if (!out.is_open()) {
    std::cerr << "[profiler] Warning: could not open output file '" << output_path_ << "'" << std::endl;
    return;
  }

  for (const auto& [pc, rec] : records_) {
    double hit_ratio = rec.access_count > 0 ? static_cast<double>(rec.hit_count) / rec.access_count : 0.0;
    double pref_accuracy = rec.prefetch_issued > 0 ? static_cast<double>(rec.prefetch_hit) / rec.prefetch_issued : 0.0;

    out << "{"
        << "\"pc\": \"0x" << std::hex << rec.pc << std::dec << "\", "
        << "\"access_count\": " << rec.access_count << ", "
        << "\"hit_count\": " << rec.hit_count << ", "
        << "\"miss_count\": " << rec.miss_count << ", "
        << "\"hit_ratio\": " << hit_ratio << ", "
        << "\"prefetch_issued\": " << rec.prefetch_issued << ", "
        << "\"prefetch_hit\": " << rec.prefetch_hit << ", "
        << "\"prefetch_accuracy\": " << pref_accuracy << ", "
        << "\"active_replacement_policy\": " << rec.active_replacement_policy << ", "
        << "\"active_prefetch_policy\": " << rec.active_prefetch_policy << "}"
        << std::endl;
  }

  std::cerr << "[profiler] Flushed " << records_.size() << " PC profile records" << std::endl;
}

profiler::~profiler() { flush(); }

#endif // HINT_PROFILING
