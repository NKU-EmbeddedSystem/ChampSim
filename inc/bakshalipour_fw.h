#ifndef BAKSHALIPOUR_FW_H
#define BAKSHALIPOUR_FW_H

#include <cstdint>
#include <cstdlib>
#include <sstream>
#include <string>
#include <unordered_map>
#include <vector>

// Pythia fill-level constants (not in ChampSim core)
#define P_FILL_L1 1
#define P_FILL_L2 2
#define P_FILL_LLC 4

inline uint64_t bf_hash_index(uint64_t key, int index_len)
{
  if (index_len == 0)
    return 0;
  uint64_t mask = (1ULL << index_len) - 1;
  uint64_t low = key & mask;
  key >>= index_len;
  key ^= low;
  return key & mask;
}

template <class T> inline T bf_square(T x) { return x * x; }

template <class T> class SetAssociativeCache {
public:
  class Entry {
  public:
    uint64_t key = 0, index = 0, tag = 0;
    bool valid = false;
    T data{};
  };

  SetAssociativeCache(int size, int num_ways, int debug_level = 0)
      : size(size), num_ways(num_ways), num_sets(size / num_ways),
        entries(num_sets, std::vector<Entry>(num_ways)), cams(num_sets), debug_level(debug_level)
  {
    for (int i = 0; i < num_sets; i += 1)
      for (int j = 0; j < num_ways; j += 1)
        entries[i][j].valid = false;
    for (int max_index = num_sets - 1; max_index > 0; max_index >>= 1)
      this->index_len += 1;
  }

  Entry* erase(uint64_t key)
  {
    Entry* entry = this->find(key);
    uint64_t index = key % this->num_sets;
    uint64_t tag = key / this->num_sets;
    auto& cam = cams[index];
    cam.erase(tag);
    if (entry)
      entry->valid = false;
    return entry;
  }

  Entry insert(uint64_t key, const T& data)
  {
    Entry* entry = this->find(key);
    if (entry != nullptr) {
      Entry old_entry = *entry;
      entry->data = data;
      return old_entry;
    }
    uint64_t index = key % this->num_sets;
    uint64_t tag = key / this->num_sets;
    std::vector<Entry>& set = this->entries[index];
    int victim_way = -1;
    for (int i = 0; i < this->num_ways; i += 1)
      if (!set[i].valid) {
        victim_way = i;
        break;
      }
    if (victim_way == -1)
      victim_way = this->select_victim(index);
    Entry& victim = set[victim_way];
    Entry old_entry = victim;
    victim = {key, index, tag, true, data};
    auto& cam = cams[index];
    if (old_entry.valid)
      cam.erase(old_entry.tag);
    cam[tag] = victim_way;
    return old_entry;
  }

  Entry* find(uint64_t key)
  {
    uint64_t index = key % this->num_sets;
    uint64_t tag = key / this->num_sets;
    auto& cam = cams[index];
    if (cam.find(tag) == cam.end())
      return nullptr;
    int way = cam[tag];
    Entry& entry = this->entries[index][way];
    return &entry;
  }

  int get_index_len() { return this->index_len; }
  void set_debug_level(int ld) { this->debug_level = ld; }

protected:
  virtual int select_victim(uint64_t /*index*/) { return rand() % this->num_ways; }

  int size = 0, num_ways = 0, num_sets = 0;
  int index_len = 0;
  std::vector<std::vector<Entry>> entries;
  std::vector<std::unordered_map<uint64_t, int>> cams;
  int debug_level = 0;
};

template <class T> class LRUSetAssociativeCache : public SetAssociativeCache<T> {
public:
  using Super = SetAssociativeCache<T>;

  LRUSetAssociativeCache(int size, int num_ways, int debug_level = 0)
      : Super(size, num_ways, debug_level), lru(this->num_sets, std::vector<uint64_t>(num_ways))
  {
  }

  void set_mru(uint64_t key) { *this->get_lru(key) = this->t++; }

protected:
  int select_victim(uint64_t index) override
  {
    std::vector<uint64_t>& lru_set = this->lru[index];
    return (int)(std::min_element(lru_set.begin(), lru_set.end()) - lru_set.begin());
  }

  uint64_t* get_lru(uint64_t key)
  {
    uint64_t index = key % this->num_sets;
    uint64_t tag = key / this->num_sets;
    int way = this->cams[index][tag];
    return &this->lru[index][way];
  }

  std::vector<std::vector<uint64_t>> lru;
  uint64_t t = 1;
};

#endif
