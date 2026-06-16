#include <cstdint>
#include <cstdio>
#include <cstdlib>
#include <iostream>
#include <string>
#include <unordered_map>

class MemoryMapper {
private:
  static const int HUGE_PAGE_SHIFT = 21; // 2MB granularity (fallback)
  static const int PAGE_4K_SHIFT    = 12; // 4KB granularity (area_map mode)
  static const int AREA_COUNT = 3;

  std::unordered_map<uint64_t, int> page_to_area_map;
  std::unordered_map<uint64_t, uint8_t> area_map_4k;
  bool area_map_loaded = false;

public:
  static MemoryMapper &get_instance() {
    static MemoryMapper instance;
    return instance;
  }

  void load_area_map(const std::string &path) {
    FILE *f = fopen(path.c_str(), "rb");
    if (!f) { std::cerr << "[MemoryMapper] ERROR: cannot open " << path << "\n"; return; }
    uint32_t magic = 0, version = 0;
    uint64_t num_entries = 0;
    fread(&magic, 4, 1, f); fread(&version, 4, 1, f); fread(&num_entries, 8, 1, f);
    if (magic != 0x41524541) { std::cerr << "[MemoryMapper] ERROR: bad magic\n"; fclose(f); return; }
    area_map_4k.clear();
    uint64_t page_id; uint8_t area;
    for (uint64_t i = 0; i < num_entries; i++) { fread(&page_id, 8, 1, f); fread(&area, 1, 1, f); area_map_4k[page_id] = area; }
    fclose(f);
    area_map_loaded = true;
    std::cerr << "[MemoryMapper] loaded " << num_entries << " page mappings\n";
  }

  bool has_area_map() const { return area_map_loaded; }

  void set_page_area(uint64_t page_id, uint8_t area) {
    area_map_4k[page_id] = area;
    area_map_loaded = true;
  }

  int get_assigned_area(uint64_t full_addr, bool is_allocated) {
    if (area_map_loaded) {
      uint64_t page_id = full_addr >> PAGE_4K_SHIFT;
      auto it = area_map_4k.find(page_id);
      if (it != area_map_4k.end()) return it->second;
      return 1; // default CXL
    }
    uint64_t huge_page_id = full_addr >> HUGE_PAGE_SHIFT;
    auto it = page_to_area_map.find(huge_page_id);
    if (it != page_to_area_map.end()) return it->second;
    if (is_allocated) {
      int new_area = rand() % AREA_COUNT;
      page_to_area_map[huge_page_id] = new_area;
      return new_area;
    } else {
      return -1;
    }
  }

  const std::unordered_map<uint64_t, uint8_t> &get_area_map_4k() const { return area_map_4k; }
};
