/**
 * workload_pagecount — count distinct 4KB pages in ChampSim compressed traces.
 *
 * ChampSim trace format: input_instr (64-byte records, gz/xz compressed)
 *   uint64_t ip; uint8_t is_branch, branch_taken;
 *   uint8_t destination_registers[2], source_registers[4];
 *   uint64_t destination_memory[2], source_memory[4];
 *
 * Usage:
 *   workload_pagecount --trace=<path.xz|.gz> --output=<output.jsonl>
 *       [--max_instructions=<N>]
 */

#include <cstdint>
#include <cstdio>
#include <cstdlib>
#include <cstring>
#include <iostream>
#include <string>
#include <unordered_set>

#define PAGE_SIZE 4096
#define PAGE_SHIFT 12
#define INSTR_SIZE 64

struct __attribute__((packed)) ChampSimInstr {
  uint64_t ip;
  uint8_t  is_branch;
  uint8_t  branch_taken;
  uint8_t  destination_registers[2];
  uint8_t  source_registers[4];
  uint64_t destination_memory[2];
  uint64_t source_memory[4];
};

int main(int argc, char *argv[]) {
  std::string trace_path, output_path;
  uint64_t max_instr = 0;
  uint64_t skip_instr = 0;

  for (int i = 1; i < argc; ++i) {
    std::string arg = argv[i];
    if (arg.rfind("--trace=", 0) == 0)           trace_path = arg.substr(8);
    else if (arg.rfind("--output=", 0) == 0)      output_path = arg.substr(9);
    else if (arg.rfind("--skip_instructions=", 0) == 0)
      skip_instr = std::stoull(arg.substr(20));
    else if (arg.rfind("--max_instructions=", 0) == 0)
      max_instr = std::stoull(arg.substr(19));
  }

  if (trace_path.empty() || output_path.empty()) {
    std::cerr << "Usage: workload_pagecount --trace=<path> --output=<path.jsonl> "
                 "[--max_instructions=<N>]\n";
    return 1;
  }

  // Detect compression type
  size_t dot = trace_path.find_last_of('.');
  std::string ext = trace_path.substr(dot + 1);
  std::string decomp_prog;
  if (ext == "xz") decomp_prog = "xz";
  else if (ext == "gz" || ext == "gzip") decomp_prog = "gzip";
  else {
    std::cerr << "Error: unsupported compression '" << ext << "'\n";
    return 1;
  }

  std::string cmd = decomp_prog + " -dc '" + trace_path + "'";
  std::cerr << "[workload_pagecount] " << cmd
            << " max_instr=" << (max_instr > 0 ? std::to_string(max_instr) : "all")
            << "\n";

  FILE *pipe_fp = popen(cmd.c_str(), "r");
  if (!pipe_fp) { std::cerr << "Error: popen failed\n"; return 1; }

  std::unordered_set<uint64_t> pages;
  ChampSimInstr rec;
  uint64_t num_accesses = 0;

  while (fread(&rec, INSTR_SIZE, 1, pipe_fp) == 1) {
    num_accesses++;

    for (int i = 0; i < 2; i++)
      if (rec.destination_memory[i] != 0)
        pages.insert(rec.destination_memory[i] >> PAGE_SHIFT);
    for (int i = 0; i < 4; i++)
      if (rec.source_memory[i] != 0)
        pages.insert(rec.source_memory[i] >> PAGE_SHIFT);

    if (skip_instr > 0 && num_accesses < skip_instr) { num_accesses++; continue; }
    if (num_accesses % 100000000 == 0)
      std::cerr << "  " << (num_accesses / 1000000) << "M accesses, "
                << pages.size() << " distinct pages\n";

    if (max_instr > 0 && num_accesses >= max_instr) break;
  }
  int rc = pclose(pipe_fp);

  uint64_t num_pages = pages.size();

  // Extract benchmark name
  size_t slash = trace_path.find_last_of('/');
  std::string fname = (slash != std::string::npos) ? trace_path.substr(slash + 1) : trace_path;
  size_t dot2 = fname.find(".trace.");
  std::string bmark = (dot2 != std::string::npos) ? fname.substr(0, dot2) : fname;

  double mem_mb = (num_pages * PAGE_SIZE) / (1024.0 * 1024.0);

  FILE *out = fopen(output_path.c_str(), "w");
  if (!out) { std::cerr << "Error: cannot write " << output_path << "\n"; return 1; }
  fprintf(out,
          "{\"benchmark\":\"%s\",\"format\":\"champsim\",\"num_pages\":%lu,"
          "\"mem_mb\":%.1f,\"num_accesses\":%lu,\"max_instr\":%lu,\"rc\":%d}\n",
          bmark.c_str(), num_pages, mem_mb, num_accesses, max_instr, rc);
  fclose(out);

  std::cerr << "[workload_pagecount] Done. " << bmark
            << " pages=" << num_pages << " mem_mb=" << mem_mb
            << " accesses=" << num_accesses << "\n";

  // SIGPIPE (141) is expected when stopping early with --max_instructions
  return (rc == 0 || rc == 141 || rc == 36096) ? 0 : 1;
}
