#ifndef TRACE_PAGE_BUFFER_H
#define TRACE_PAGE_BUFFER_H

#include <atomic>
#include <cstdint>
#include <cstdio>
#include <cstdlib>
#include <iostream>
#include <string>
#include <thread>
#include <unordered_map>

// 64-byte ChampSim instruction record (packed, matching Pin trace layout)
struct __attribute__((packed)) CsInstr {
  uint64_t ip;
  uint8_t  is_branch;
  uint8_t  branch_taken;
  uint8_t  destination_registers[2];
  uint8_t  source_registers[4];
  uint64_t destination_memory[2];
  uint64_t source_memory[4];
};

#define CS_INSTR_SIZE 64
#define PAGE_SHIFT 12

class TracePageBuffer {
public:
  static const size_t RING_SIZE = 3000000;  // 3M page_ids ≈ 24 MB

  TracePageBuffer() : ring_(new std::atomic<uint64_t>[RING_SIZE]) {
    for (size_t i = 0; i < RING_SIZE; i++)
      ring_[i].store(0, std::memory_order_relaxed);
  }

  ~TracePageBuffer() { delete[] ring_; }

  // Start producer thread: decompress trace, extract page_ids into ring buffer.
  void start(const std::string &trace_path) {
    running_ = true;
    producer_ = std::thread(&TracePageBuffer::producerLoop, this, trace_path);
  }

  // Wait for at least `min_pages` page_ids to be buffered ahead of sim_pos.
  bool waitUntilReady(size_t min_pages, int timeout_sec = 30) {
    auto deadline = time(nullptr) + timeout_sec;
    while (time(nullptr) < deadline) {
      if (write_pos_.load(std::memory_order_acquire) >= min_pages)
        return true;
      std::this_thread::sleep_for(std::chrono::milliseconds(100));
    }
    return false;
  }

  // Stop producer and join.
  void stop() {
    running_ = false;
    if (producer_.joinable()) producer_.join();
  }

  // How many page_ids are available ahead of sim_pos.
  size_t aheadOf(size_t sim_pos) const {
    size_t w = write_pos_.load(std::memory_order_acquire);
    return (w > sim_pos) ? (w - sim_pos) : 0;
  }

  // Consume and count up to N page_ids starting from read_pos_.
  // Advances read_pos_ by actual page_ids consumed.
  // Returns map: page_id → access_count.
  std::unordered_map<uint64_t, uint64_t> consume(size_t N) {
    std::unordered_map<uint64_t, uint64_t> counts;
    size_t w = write_pos_.load(std::memory_order_acquire);
    size_t available = (w > read_pos_) ? (w - read_pos_) : 0;
    size_t to_read = (N < available) ? N : available;

    for (size_t i = 0; i < to_read; i++) {
      size_t idx = (read_pos_ + i) % RING_SIZE;
      uint64_t page_id = ring_[idx].load(std::memory_order_acquire);
      if (page_id != 0)
        counts[page_id]++;
    }
    read_pos_ += to_read;
    return counts;
  }

private:
  std::atomic<uint64_t>* ring_;
  std::atomic<size_t> write_pos_{0};
  size_t read_pos_ = 0;
  std::thread producer_;
  std::atomic<bool> running_{false};

  void producerLoop(const std::string &trace_path) {
    // Detect compression
    size_t dot = trace_path.find_last_of('.');
    std::string ext = trace_path.substr(dot + 1);
    std::string decomp = (ext == "xz") ? "xz" : "gzip";
    std::string cmd = decomp + " -dc '" + trace_path + "'";

    FILE *pipe = popen(cmd.c_str(), "r");
    if (!pipe) {
      std::cerr << "[TracePageBuffer] popen failed for " << trace_path << "\n";
      return;
    }

    CsInstr rec;
    size_t local_pos = 0;
    while (running_ && fread(&rec, CS_INSTR_SIZE, 1, pipe) == 1) {
      // Extract page_ids from memory operands
      for (int i = 0; i < 2; i++) {
        if (rec.destination_memory[i] != 0) {
          size_t idx = (local_pos++) % RING_SIZE;
          ring_[idx].store(rec.destination_memory[i] >> PAGE_SHIFT,
                           std::memory_order_release);
        }
      }
      for (int i = 0; i < 4; i++) {
        if (rec.source_memory[i] != 0) {
          size_t idx = (local_pos++) % RING_SIZE;
          ring_[idx].store(rec.source_memory[i] >> PAGE_SHIFT,
                           std::memory_order_release);
        }
      }
      // Update write_pos periodically (every 1000 instructions) to reduce atomic contention
      if (local_pos % 6000 == 0)  // ~1000 instr × ~6 mem refs
        write_pos_.store(local_pos, std::memory_order_release);
    }
    write_pos_.store(local_pos, std::memory_order_release);
    pclose(pipe);
    std::cerr << "[TracePageBuffer] done, total page_ids=" << local_pos << "\n";
  }
};

#endif // TRACE_PAGE_BUFFER_H
