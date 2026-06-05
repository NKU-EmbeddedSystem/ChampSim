#include <cstdint>
#include <cstdlib>
#include <unordered_map>

class MemoryMapper {
private:
  static const int HUGE_PAGE_SHIFT = 21; // 2MB granularity
  static const int AREA_COUNT = 3;       // e.g., 0: Local DRAM, 1: NUMA, 2: CXL
  std::unordered_map<uint64_t, int> page_to_area_map;

public:
  static MemoryMapper &get_instance() {
    static MemoryMapper instance;
    return instance;
  }

  int get_assigned_area(uint64_t full_addr, bool is_allocated) {
    uint64_t huge_page_id = full_addr >> HUGE_PAGE_SHIFT;

    auto it = page_to_area_map.find(huge_page_id);
    if (it != page_to_area_map.end()) {
      return it->second;
    }

    if (is_allocated) {
      // 这里可以替换为更复杂的策略（比如 70% 概率 Local，30% 概率 CXL）
      int new_area = rand() % AREA_COUNT;
      page_to_area_map[huge_page_id] = new_area;
      return new_area;
    } else {
      return -1;
    }
  }
};