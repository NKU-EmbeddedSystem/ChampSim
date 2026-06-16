/**
 * gen_area_map — generate binary area_map (.amap) from ChampSim compressed traces.
 *
 * Reads ChampSim 64-byte input_instr records via decompression pipe,
 * counts per-page accesses or distinct page order, then assigns top-K
 * pages to area=0 (DRAM) and the rest to area=1 (CXL).
 *
 * Binary area_map format:
 *   uint32_t magic   = 0x41524541  ("AREA")
 *   uint32_t version = 1
 *   uint64_t num_entries
 *   { uint64_t page_id; uint8_t area; } × num_entries   (sorted by page_id)
 *
 * Strategies:
 *   random       — collect all pages, shuffle, top-K → DRAM
 *   sort_heat    — count per-page accesses, sort desc, top-K → DRAM
 *   first_touch  — first K distinct pages in trace order → DRAM
 *
 * Usage:
 *   gen_area_map --trace=<path.xz|.gz> --output=<path.amap>
 *       --placement=<random|sort_heat|first_touch>
 *       [--dram_pages=<K>] [--max_instructions=<N>] [--skip_instructions=<N>]
 *
 * If --dram_pages is omitted, K is derived from the trace itself:
 *   K = floor(distinct_pages / 3), giving DRAM:CXL = 1:2 by page count.
 */

#include <algorithm>
#include <cstdint>
#include <cstdio>
#include <cstdlib>
#include <cstring>
#include <functional>
#include <iostream>
#include <random>
#include <string>
#include <unordered_map>
#include <unordered_set>
#include <vector>

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

static const uint32_t AREA_MAP_MAGIC   = 0x41524541; // "AREA"
static const uint32_t AREA_MAP_VERSION = 1;

static uint64_t resolve_dram_pages(size_t total_pages,
                                   uint64_t requested_dram_pages,
                                   bool has_dram_pages_override,
                                   const char *placement) {
  uint64_t k = has_dram_pages_override
      ? requested_dram_pages
      : static_cast<uint64_t>(total_pages / 3);
  std::cerr << "[" << placement << "] total_pages=" << total_pages
            << " dram_pages=" << k
            << (has_dram_pages_override ? " (override)" : " (auto DRAM:CXL=1:2)")
            << "\n";
  return k;
}

// ---------------------------------------------------------------------------
// Write sorted entries to binary file
// ---------------------------------------------------------------------------
static void write_area_map(const std::string &path,
                           const std::vector<std::pair<uint64_t, uint8_t>> &entries) {
  FILE *f = fopen(path.c_str(), "wb");
  if (!f) { std::cerr << "Error: cannot open " << path << "\n"; exit(1); }
  uint64_t num = entries.size();
  fwrite(&AREA_MAP_MAGIC, 4, 1, f);
  fwrite(&AREA_MAP_VERSION, 4, 1, f);
  fwrite(&num, 8, 1, f);
  for (auto &e : entries) {
    fwrite(&e.first, 8, 1, f);
    fwrite(&e.second, 1, 1, f);
  }
  fclose(f);
}

// ---------------------------------------------------------------------------
// Extract 4KB page IDs from a single instruction record
// ---------------------------------------------------------------------------
// Extract 4KB page IDs from trace VA
static void extract_pages(const ChampSimInstr &rec,
                          std::function<void(uint64_t)> cb) {
  for (int i = 0; i < 2; i++)
    if (rec.destination_memory[i] != 0)
      cb(rec.destination_memory[i] >> PAGE_SHIFT);
  for (int i = 0; i < 4; i++)
    if (rec.source_memory[i] != 0)
      cb(rec.source_memory[i] >> PAGE_SHIFT);
}

// ---------------------------------------------------------------------------
// Read trace via decompression pipe, call fn for each instruction.
// Stops after max_instr instructions (0 = no limit, read full trace).
static void read_trace(const std::string &path,
    const std::function<void(const ChampSimInstr&)> &fn,
    uint64_t max_instr = 0, uint64_t skip_instr = 0) {
  size_t dot = path.find_last_of('.');
  std::string ext = path.substr(dot + 1);
  std::string decomp = (ext == "xz") ? "xz" : "gzip";
  std::string cmd = decomp + " -dc '" + path + "'";

  FILE *p = popen(cmd.c_str(), "r");
  if (!p) { std::cerr << "Error: popen failed\n"; exit(1); }

  ChampSimInstr rec;
  uint64_t count = 0;
  // Skip first skip_instr instructions (e.g. warmup)
  while (count < skip_instr && fread(&rec, INSTR_SIZE, 1, p) == 1) count++;
  if (skip_instr > 0)
    std::cerr << "  Skipped " << count << " warmup instructions\n";
  count = 0;
  while (fread(&rec, INSTR_SIZE, 1, p) == 1) {
    fn(rec);
    count++;
    if (count % 100000000 == 0)
      std::cerr << "  " << (count / 1000000) << "M instructions\n";
    if (max_instr > 0 && count >= max_instr) break;
  }
  pclose(p);
  std::cerr << "  Total: " << count << " instructions"
            << (max_instr > 0 ? " (limited to " + std::to_string(max_instr) + ")" : "")
            << "\n";
}

// ---------------------------------------------------------------------------
// Strategy: first_touch
// ---------------------------------------------------------------------------
static void do_first_touch(const std::string &trace_path, uint64_t K,
                           bool has_dram_pages_override,
                           const std::string &output, uint64_t max_instr = 0, uint64_t skip_instr = 0) {
  std::unordered_set<uint64_t> seen;
  std::vector<uint64_t> ordered_pages;
  read_trace(trace_path, [&](const ChampSimInstr &r) {
    extract_pages(r, [&](uint64_t pid) {
      if (seen.insert(pid).second) {
        ordered_pages.push_back(pid);
      }
    });
  }, max_instr, skip_instr);
  K = resolve_dram_pages(ordered_pages.size(), K, has_dram_pages_override, "first_touch");

  std::vector<std::pair<uint64_t, uint8_t>> entries;
  entries.reserve(ordered_pages.size());
  for (size_t i = 0; i < ordered_pages.size(); ++i)
    entries.push_back({ordered_pages[i], (i < K) ? (uint8_t)0 : (uint8_t)1});
  std::sort(entries.begin(), entries.end(),
    [](auto &a, auto &b) { return a.first < b.first; });
  write_area_map(output, entries);
  std::cerr << "[first_touch] " << entries.size() << " pages → " << output << "\n";
}

// ---------------------------------------------------------------------------
// Strategy: sort_heat
// ---------------------------------------------------------------------------
static void do_sort_heat(const std::string &trace_path, uint64_t K,
                         bool has_dram_pages_override,
                         const std::string &output, uint64_t max_instr = 0, uint64_t skip_instr = 0) {
  std::unordered_map<uint64_t, uint64_t> page_count;
  read_trace(trace_path, [&](const ChampSimInstr &r) {
    extract_pages(r, [&](uint64_t pid) { page_count[pid]++; });
  }, max_instr, skip_instr);
  // Sort by count descending
  std::vector<std::pair<uint64_t, uint64_t>> sorted;
  for (auto &kv : page_count) sorted.push_back(kv);
  std::sort(sorted.begin(), sorted.end(),
    [](auto &a, auto &b) { return a.second > b.second; });
  K = resolve_dram_pages(sorted.size(), K, has_dram_pages_override, "sort_heat");
  // Assign top-K → area 0
  std::vector<std::pair<uint64_t, uint8_t>> entries;
  for (size_t i = 0; i < sorted.size(); ++i)
    entries.push_back({sorted[i].first, (i < K) ? (uint8_t)0 : (uint8_t)1});
  std::sort(entries.begin(), entries.end(),
    [](auto &a, auto &b) { return a.first < b.first; });
  write_area_map(output, entries);
  std::cerr << "[sort_heat] " << entries.size() << " pages → " << output << "\n";
}

// ---------------------------------------------------------------------------
// Strategy: random
// ---------------------------------------------------------------------------
static void do_random(const std::string &trace_path, uint64_t K,
                      bool has_dram_pages_override,
                      const std::string &output, uint64_t max_instr = 0, uint64_t skip_instr = 0) {
  std::vector<uint64_t> page_ids;
  std::unordered_map<uint64_t, bool> seen;
  read_trace(trace_path, [&](const ChampSimInstr &r) {
    extract_pages(r, [&](uint64_t pid) {
      if (!seen[pid]) { seen[pid] = true; page_ids.push_back(pid); }
    });
  }, max_instr, skip_instr);
  K = resolve_dram_pages(page_ids.size(), K, has_dram_pages_override, "random");
  std::mt19937 rng(42);
  std::shuffle(page_ids.begin(), page_ids.end(), rng);
  std::vector<std::pair<uint64_t, uint8_t>> entries;
  for (size_t i = 0; i < page_ids.size(); ++i)
    entries.push_back({page_ids[i], (i < K) ? (uint8_t)0 : (uint8_t)1});
  std::sort(entries.begin(), entries.end(),
    [](auto &a, auto &b) { return a.first < b.first; });
  write_area_map(output, entries);
  std::cerr << "[random] " << entries.size() << " pages → " << output << "\n";
}

// ---------------------------------------------------------------------------
// Main
// ---------------------------------------------------------------------------
int main(int argc, char *argv[]) {
  std::string trace_path, output_path, placement = "sort_heat";
  uint64_t dram_pages = 0;
  bool has_dram_pages_override = false;
  uint64_t max_instr = 0;
  uint64_t skip_instr = 0;

  for (int i = 1; i < argc; ++i) {
    std::string arg = argv[i];
    if (arg.rfind("--trace=", 0) == 0)           trace_path = arg.substr(8);
    else if (arg.rfind("--output=", 0) == 0)      output_path = arg.substr(9);
    else if (arg.rfind("--placement=", 0) == 0)   placement = arg.substr(12);
    else if (arg.rfind("--dram_pages=", 0) == 0) {
      dram_pages = std::stoull(arg.substr(13));
      has_dram_pages_override = true;
    }
    else if (arg.rfind("--skip_instructions=", 0) == 0)
      skip_instr = std::stoull(arg.substr(20));
    else if (arg.rfind("--max_instructions=", 0) == 0)
      max_instr = std::stoull(arg.substr(19));
  }

  if (trace_path.empty() || output_path.empty()) {
    std::cerr << "Usage: gen_area_map --trace=<path.xz|.gz> --output=<path.amap> "
                 "--placement=<random|sort_heat|first_touch> [--dram_pages=<K>] "
                 "[--max_instructions=<N>]\n"
                 "Default: K=floor(distinct_pages/3), DRAM:CXL=1:2.\n";
    return 1;
  }


  std::cerr << "gen_area_map: placement=" << placement
            << " dram_pages=" << (has_dram_pages_override ? std::to_string(dram_pages) : "auto")
            << " max_instr=" << (max_instr > 0 ? std::to_string(max_instr) : "all") << " skip=" << (skip_instr > 0 ? std::to_string(skip_instr) : "none")
            << "\n";

  if (placement == "random")          do_random(trace_path, dram_pages, has_dram_pages_override, output_path, max_instr, skip_instr);
  else if (placement == "sort_heat")  do_sort_heat(trace_path, dram_pages, has_dram_pages_override, output_path, max_instr, skip_instr);
  else if (placement == "first_touch") do_first_touch(trace_path, dram_pages, has_dram_pages_override, output_path, max_instr, skip_instr);
  else { std::cerr << "Unknown placement: " << placement << "\n"; return 1; }

  return 0;
}
