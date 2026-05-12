#include "ppf.h"

#include <algorithm>
#include <cstring>
#include <iostream>

// ── GLOBAL_REGISTER ────────────────────────────────────────────────────

void GLOBAL_REGISTER::update_entry(uint32_t pf_sig, uint32_t pf_confidence,
                                    uint32_t pf_offset, int pf_delta)
{
  uint32_t min_conf = 100, victim_way = PPF_MAX_GHR_ENTRY;

  for (uint32_t i = 0; i < PPF_MAX_GHR_ENTRY; i++) {
    if (valid[i] && (offset[i] == pf_offset)) {
      sig[i] = pf_sig;
      confidence[i] = pf_confidence;
      delta[i] = pf_delta;
      return;
    }
    if (confidence[i] < min_conf) {
      min_conf = confidence[i];
      victim_way = i;
    }
  }

  if (victim_way >= PPF_MAX_GHR_ENTRY) return;

  valid[victim_way] = 1;
  sig[victim_way] = pf_sig;
  confidence[victim_way] = pf_confidence;
  offset[victim_way] = pf_offset;
  delta[victim_way] = pf_delta;
}

uint32_t GLOBAL_REGISTER::check_entry(uint32_t page_offset)
{
  uint32_t max_conf = 0, max_conf_way = PPF_MAX_GHR_ENTRY;
  for (uint32_t i = 0; i < PPF_MAX_GHR_ENTRY; i++) {
    if ((offset[i] == page_offset) && (max_conf < confidence[i])) {
      max_conf = confidence[i];
      max_conf_way = i;
    }
  }
  return max_conf_way;
}

// ── PERCEPTRON ─────────────────────────────────────────────────────────

void PERCEPTRON::get_perc_index(uint64_t base_addr, uint64_t ip, uint64_t ip_1, uint64_t ip_2,
                                 uint64_t ip_3, int32_t cur_delta, uint32_t last_sig,
                                 uint32_t curr_sig, uint32_t confidence, uint32_t depth,
                                 uint64_t perc_set[PPF_PERC_FEATURES])
{
  uint64_t cache_line = base_addr >> LOG2_BLOCK_SIZE;
  uint64_t page_addr = base_addr >> LOG2_PAGE_SIZE;

  int sig_delta = (cur_delta < 0) ? (((-1) * cur_delta) + (1 << (PPF_SIG_DELTA_BIT - 1)))
                                   : cur_delta;

  uint64_t pre_hash[PPF_PERC_FEATURES];
  pre_hash[0] = base_addr;
  pre_hash[1] = cache_line;
  pre_hash[2] = page_addr;
  pre_hash[3] = confidence ^ page_addr;
  pre_hash[4] = curr_sig ^ (uint64_t)sig_delta;
  pre_hash[5] = ip_1 ^ (ip_2 >> 1) ^ (ip_3 >> 2);
  pre_hash[6] = ip ^ depth;
  pre_hash[7] = ip ^ (uint64_t)sig_delta;
  pre_hash[8] = confidence;

  for (int i = 0; i < PPF_PERC_FEATURES; i++)
    perc_set[i] = (pre_hash[i]) % (uint64_t)PERC_DEPTH[i];
}

int32_t PERCEPTRON::perc_predict(uint64_t base_addr, uint64_t ip, uint64_t ip_1, uint64_t ip_2,
                                  uint64_t ip_3, int32_t cur_delta, uint32_t last_sig,
                                  uint32_t curr_sig, uint32_t confidence, uint32_t depth)
{
  uint64_t perc_set[PPF_PERC_FEATURES];
  get_perc_index(base_addr, ip, ip_1, ip_2, ip_3, cur_delta, last_sig, curr_sig, confidence,
                 depth, perc_set);

  int32_t sum = 0;
  for (int i = 0; i < PPF_PERC_FEATURES; i++)
    sum += perc_weights[perc_set[i]][i];
  return sum;
}

void PERCEPTRON::perc_update(uint64_t base_addr, uint64_t ip, uint64_t ip_1, uint64_t ip_2,
                              uint64_t ip_3, int32_t cur_delta, uint32_t last_sig,
                              uint32_t curr_sig, uint32_t confidence, uint32_t depth,
                              bool direction, int32_t perc_sum_val)
{
  uint64_t perc_set[PPF_PERC_FEATURES];
  get_perc_index(base_addr, ip, ip_1, ip_2, ip_3, cur_delta, last_sig, curr_sig, confidence,
                 depth, perc_set);

  if (!direction) {
    // Prediction was wrong
    for (int i = 0; i < PPF_PERC_FEATURES; i++) {
      if (perc_sum_val >= 0) {
        // Predicted to prefetch — decrement
        if (perc_weights[perc_set[i]][i] > -1 * (PPF_PERC_COUNTER_MAX + 1))
          perc_weights[perc_set[i]][i]--;
      } else {
        // Predicted to not prefetch — increment
        if (perc_weights[perc_set[i]][i] < PPF_PERC_COUNTER_MAX)
          perc_weights[perc_set[i]][i]++;
      }
    }
  }
  if (direction && perc_sum_val > PPF_NEG_UPDT_THRESHOLD &&
      perc_sum_val < PPF_POS_UPDT_THRESHOLD) {
    // Prediction correct but sum not saturated
    for (int i = 0; i < PPF_PERC_FEATURES; i++) {
      if (perc_sum_val >= 0) {
        if (perc_weights[perc_set[i]][i] < PPF_PERC_COUNTER_MAX)
          perc_weights[perc_set[i]][i]++;
      } else {
        if (perc_weights[perc_set[i]][i] > -1 * (PPF_PERC_COUNTER_MAX + 1))
          perc_weights[perc_set[i]][i]--;
      }
    }
  }
}

// ── PREFETCH_FILTER ────────────────────────────────────────────────────

bool PREFETCH_FILTER::check(uint64_t check_addr, uint64_t base_addr, uint64_t ip,
                             PPF_FILTER_REQUEST filter_request, int32_t cur_delta,
                             uint32_t last_sig, uint32_t cur_sig, uint32_t conf, int32_t sum,
                             uint32_t depth)
{
  uint64_t cache_line = check_addr >> LOG2_BLOCK_SIZE;
  uint64_t hash = ppf_get_hash(cache_line);
  uint64_t quotient = (hash >> PPF_REMAINDER_BIT) & ((1 << PPF_QUOTIENT_BIT) - 1);
  uint64_t remainder = hash & ((1ULL << PPF_REMAINDER_BIT) - 1);

  switch (filter_request) {
    case SPP_PERC_REJECT:
      if ((valid[quotient] || useful[quotient]) && remainder_tag[quotient] == remainder)
        return false;
      return true;

    case SPP_L2C_PREFETCH:
      if ((valid[quotient] || useful[quotient]) && remainder_tag[quotient] == remainder)
        return false;
      valid[quotient] = 1;
      useful[quotient] = 0;
      remainder_tag[quotient] = remainder;
      delta[quotient] = cur_delta;
      pc[quotient] = ip;
      pc_1[quotient] = ghr->ip_1;
      pc_2[quotient] = ghr->ip_2;
      pc_3[quotient] = ghr->ip_3;
      last_signature[quotient] = last_sig;
      cur_signature[quotient] = cur_sig;
      confidence[quotient] = conf;
      address[quotient] = base_addr;
      perc_sum[quotient] = sum;
      la_depth[quotient] = depth;
      return true;

    case SPP_LLC_PREFETCH:
      if ((valid[quotient] || useful[quotient]) && remainder_tag[quotient] == remainder)
        return false;
      return true;

    case L2C_DEMAND:
      if ((remainder_tag[quotient] == remainder) && (useful[quotient] == 0)) {
        useful[quotient] = 1;
        if (valid[quotient]) {
          ghr->pf_useful++;
          if (ghr->pf_useful > PPF_GLOBAL_COUNTER_MAX) {
            ghr->pf_useful >>= 1;
            ghr->pf_issued >>= 1;
          }
        }
        if (valid[quotient]) {
          perc->perc_update(address[quotient], pc[quotient], pc_1[quotient], pc_2[quotient],
                            pc_3[quotient], delta[quotient], last_signature[quotient],
                            cur_signature[quotient], confidence[quotient], la_depth[quotient],
                            true, perc_sum[quotient]);
        }
      }
      return true;

    case L2C_EVICT:
      if (valid[quotient] && !useful[quotient]) {
        if (ghr->pf_useful) ghr->pf_useful--;
        perc->perc_update(address[quotient], pc[quotient], pc_1[quotient], pc_2[quotient],
                          pc_3[quotient], delta[quotient], last_signature[quotient],
                          cur_signature[quotient], confidence[quotient], la_depth[quotient],
                          false, perc_sum[quotient]);
      }
      valid[quotient] = 0;
      useful[quotient] = 0;
      remainder_tag[quotient] = 0;
      return true;

    default:
      return true;
  }
}

// ── SIGNATURE_TABLE ────────────────────────────────────────────────────

void SIGNATURE_TABLE::read_and_update_sig(uint64_t page, uint32_t page_offset,
                                           uint32_t& last_sig, uint32_t& curr_sig,
                                           int32_t& delta)
{
  uint32_t set = ppf_get_hash(page) % PPF_ST_SET;
  uint32_t match = PPF_ST_WAY;
  uint32_t partial_page = page & PPF_ST_TAG_MASK;
  uint8_t ST_hit = 0;
  int sig_delta = 0;

  // Case 1: Hit
  for (match = 0; match < PPF_ST_WAY; match++) {
    if (valid[set][match] && (tag[set][match] == partial_page)) {
      last_sig = sig[set][match];
      delta = (int32_t)page_offset - (int32_t)last_offset[set][match];

      if (delta) {
        sig_delta = (delta < 0) ? (((-1) * delta) + (1 << (PPF_SIG_DELTA_BIT - 1))) : delta;
        sig[set][match] = ((last_sig << PPF_SIG_SHIFT) ^ sig_delta) & PPF_SIG_MASK;
        curr_sig = sig[set][match];
        last_offset[set][match] = page_offset;
      } else {
        last_sig = 0;
      }
      ST_hit = 1;
      break;
    }
  }

  // Case 2: Invalid
  if (match == PPF_ST_WAY) {
    for (match = 0; match < PPF_ST_WAY; match++) {
      if (valid[set][match] == 0) {
        valid[set][match] = 1;
        tag[set][match] = partial_page;
        sig[set][match] = 0;
        curr_sig = sig[set][match];
        last_offset[set][match] = page_offset;
        break;
      }
    }
  }

  // Case 3: Miss
  if (match == PPF_ST_WAY) {
    for (match = 0; match < PPF_ST_WAY; match++) {
      if (lru[set][match] == PPF_ST_WAY - 1) {
        tag[set][match] = partial_page;
        sig[set][match] = 0;
        curr_sig = sig[set][match];
        last_offset[set][match] = page_offset;
        break;
      }
    }
  }

  if (match == PPF_ST_WAY) return;

  // GHR check on ST miss
  if (ST_hit == 0) {
    uint32_t GHR_found = ghr->check_entry(page_offset);
    if (GHR_found < PPF_MAX_GHR_ENTRY) {
      sig_delta = (ghr->delta[GHR_found] < 0)
                      ? (((-1) * ghr->delta[GHR_found]) + (1 << (PPF_SIG_DELTA_BIT - 1)))
                      : ghr->delta[GHR_found];
      sig[set][match] = ((ghr->sig[GHR_found] << PPF_SIG_SHIFT) ^ sig_delta) & PPF_SIG_MASK;
      curr_sig = sig[set][match];
    }
  }

  // Update LRU
  for (uint32_t way = 0; way < PPF_ST_WAY; way++) {
    if (lru[set][way] < lru[set][match]) lru[set][way]++;
  }
  lru[set][match] = 0;
}

// ── PATTERN_TABLE ──────────────────────────────────────────────────────

void PATTERN_TABLE::update_pattern(uint32_t last_sig, int curr_delta)
{
  uint32_t set = ppf_get_hash(last_sig) % PPF_PT_SET;
  uint32_t match = 0;

  // Case 1: Hit
  for (match = 0; match < PPF_PT_WAY; match++) {
    if (delta[set][match] == curr_delta) {
      c_delta[set][match]++;
      c_sig[set]++;
      if (c_sig[set] > PPF_C_SIG_MAX) {
        for (uint32_t way = 0; way < PPF_PT_WAY; way++)
          c_delta[set][way] >>= 1;
        c_sig[set] >>= 1;
      }
      break;
    }
  }

  // Case 2: Miss
  if (match == PPF_PT_WAY) {
    uint32_t victim_way = PPF_PT_WAY;
    uint32_t min_counter = PPF_C_SIG_MAX;

    for (match = 0; match < PPF_PT_WAY; match++) {
      if (c_delta[set][match] < min_counter) {
        victim_way = match;
        min_counter = c_delta[set][match];
      }
    }

    if (victim_way < PPF_PT_WAY) {
      delta[set][victim_way] = curr_delta;
      c_delta[set][victim_way] = 0;
      c_sig[set]++;
      if (c_sig[set] > PPF_C_SIG_MAX) {
        for (uint32_t way = 0; way < PPF_PT_WAY; way++)
          c_delta[set][way] >>= 1;
        c_sig[set] >>= 1;
      }
    }
  }
}

void PATTERN_TABLE::read_pattern(uint32_t curr_sig, std::vector<int>& delta_q,
                                  std::vector<uint32_t>& confidence_q,
                                  std::vector<int32_t>& perc_sum_q, uint32_t& lookahead_way,
                                  uint32_t& lookahead_conf, uint32_t& pf_q_tail, uint32_t& depth,
                                  uint64_t addr, uint64_t base_addr, uint64_t train_addr,
                                  uint64_t curr_ip, int32_t train_delta, uint32_t last_sig,
                                  uint32_t pq_occupancy, uint32_t pq_SIZE,
                                  uint32_t mshr_occupancy, uint32_t mshr_SIZE)
{
  uint32_t set = ppf_get_hash(curr_sig) % PPF_PT_SET;
  uint32_t max_conf = 0;
  bool found_candidate = false;

  if (c_sig[set]) {
    for (uint32_t way = 0; way < PPF_PT_WAY; way++) {
      uint32_t local_conf = (100 * c_delta[set][way]) / c_sig[set];
      uint32_t pf_conf =
          depth ? (ghr->global_accuracy * c_delta[set][way] / c_sig[set] * lookahead_conf / 100)
                : local_conf;

      int32_t perc_sum_val =
          perc->perc_predict(train_addr, curr_ip, ghr->ip_1, ghr->ip_2, ghr->ip_3,
                              train_delta + delta[set][way], last_sig, curr_sig, pf_conf, depth);
      bool do_pf = (perc_sum_val >= -15) ? true : false;  // ppf_perc_threshold_lo
      bool fill_l2 = (perc_sum_val >= -5) ? true : false; // ppf_perc_threshold_hi

      if (fill_l2 && (mshr_occupancy >= mshr_SIZE || pq_occupancy >= pq_SIZE)) continue;

      if (pf_conf && do_pf && pf_q_tail < 100) {
        confidence_q[pf_q_tail] = pf_conf;
        delta_q[pf_q_tail] = delta[set][way];
        perc_sum_q[pf_q_tail] = perc_sum_val;

        if (pf_conf > max_conf) {
          lookahead_way = way;
          max_conf = pf_conf;
        }
        pf_q_tail++;
        found_candidate = true;
      }

      // Record perceptron rejects
      if (pf_conf && pf_q_tail < (pq_SIZE + mshr_SIZE) && !fill_l2) {
        uint64_t pf_addr = (base_addr & ~((uint64_t)BLOCK_SIZE - 1)) +
                           ((uint64_t)delta[set][way] << LOG2_BLOCK_SIZE);
        if ((addr & ~((uint64_t)PAGE_SIZE - 1)) == (pf_addr & ~((uint64_t)PAGE_SIZE - 1))) {
          filter->check(pf_addr, train_addr, curr_ip, SPP_PERC_REJECT,
                        train_delta + delta[set][way], last_sig, curr_sig, pf_conf, perc_sum_val,
                        depth);
        }
      }
    }
    lookahead_conf = max_conf;
    if (found_candidate) depth++;
  }
}

// ── MAIN PPF ───────────────────────────────────────────────────────────

void ppf::print_config()
{
  if (!init_done) {
    init_done = true;
    ST.ghr = &GHR;
    PT.ghr = &GHR;
    PT.perc = &PERC;
    PT.filter = &FILTER;
    FILTER.ghr = &GHR;
    FILTER.perc = &PERC;
  }

  std::cout << "ppf_perc_threshold_hi " << ppf_perc_threshold_hi << std::endl
            << "ppf_perc_threshold_lo " << ppf_perc_threshold_lo << std::endl;
}

void ppf::invoke_prefetcher(uint64_t ip, uint64_t addr, uint8_t /*cache_hit*/, uint8_t /*type*/,
                             std::vector<uint64_t>& pref_addr)
{
  uint64_t page = addr >> LOG2_PAGE_SIZE;
  uint32_t page_offset = (addr >> LOG2_BLOCK_SIZE) & ((PAGE_SIZE / BLOCK_SIZE) - 1);
  uint32_t last_sig = 0, curr_sig = 0;

  GHR.global_accuracy = GHR.pf_issued ? ((100 * GHR.pf_useful) / GHR.pf_issued) : 0;

  for (int i = PPF_PAGES_TRACKED - 1; i > 0; i--)
    GHR.page_tracker[i] = GHR.page_tracker[i - 1];
  GHR.page_tracker[0] = page;

  int distinct_pages = 0;
  for (int i = 0; i < PPF_PAGES_TRACKED; i++) {
    int j;
    for (j = 0; j < i; j++)
      if (GHR.page_tracker[i] == GHR.page_tracker[j]) break;
    if (i == j) distinct_pages++;
  }
  if (distinct_pages == 0) distinct_pages = 1;

  int32_t delta = 0;
  ST.read_and_update_sig(page, page_offset, last_sig, curr_sig, delta);

  FILTER.check(addr, 0, 0, L2C_DEMAND, 0, 0, 0, 0, 0, 0);

  if (last_sig) PT.update_pattern(last_sig, delta);

  // Prefetch generation
  uint64_t base_addr = addr;
  uint64_t curr_ip = ip;
  uint32_t lookahead_conf = 100, pf_q_head = 0, pf_q_tail = 0, depth = 0;

  GHR.ip_3 = GHR.ip_2;
  GHR.ip_2 = GHR.ip_1;
  GHR.ip_1 = GHR.ip_0;
  GHR.ip_0 = ip;

  std::vector<int> delta_q(200, 0);
  std::vector<uint32_t> confidence_q(200, 0);
  std::vector<int32_t> perc_sum_q(200, 0);
  confidence_q[0] = 100;

  // Use fixed PQ/MSHR sizes (L2C typical values)
  const uint32_t PQ_SIZE = 32;
  const uint32_t MSHR_SIZE = 16;

  int prev_delta = 0;
  uint64_t train_addr = addr;
  int32_t train_delta = 0;
  uint8_t num_pf = 0;

  bool do_lookahead = true;
  while (do_lookahead) {
    uint32_t lookahead_way = PPF_PT_WAY;

    train_addr = addr;
    train_delta = prev_delta;

    PT.read_pattern(curr_sig, delta_q, confidence_q, perc_sum_q, lookahead_way, lookahead_conf,
                    pf_q_tail, depth, addr, base_addr, train_addr, curr_ip, train_delta,
                    last_sig, 0, PQ_SIZE, 0, MSHR_SIZE);

    do_lookahead = false;
    for (uint32_t i = pf_q_head; i < pf_q_tail; i++) {
      uint64_t pf_addr =
          (base_addr & ~((uint64_t)BLOCK_SIZE - 1)) + ((uint64_t)delta_q[i] << LOG2_BLOCK_SIZE);
      int32_t perc_sum_val = perc_sum_q[i];

      PPF_FILTER_REQUEST fill_level =
          (perc_sum_val >= ppf_perc_threshold_hi) ? SPP_L2C_PREFETCH : SPP_LLC_PREFETCH;

      if ((addr & ~((uint64_t)PAGE_SIZE - 1)) == (pf_addr & ~((uint64_t)PAGE_SIZE - 1))) {
        if (num_pf < (uint8_t)((PQ_SIZE) / distinct_pages)) {
          if (FILTER.check(pf_addr, train_addr, curr_ip, fill_level,
                           train_delta + delta_q[i], last_sig, curr_sig, confidence_q[i],
                           perc_sum_val, depth - 1)) {
            pref_addr.push_back(pf_addr);
            num_pf++;

            if (fill_level == SPP_L2C_PREFETCH) {
              GHR.pf_issued++;
              if (GHR.pf_issued > PPF_GLOBAL_COUNTER_MAX) {
                GHR.pf_issued >>= 1;
                GHR.pf_useful >>= 1;
              }
            }
          }
        }
      } else {
        // Cross-page boundary: store in GHR for bootstrapping
        GHR.update_entry(curr_sig, confidence_q[i],
                         (pf_addr >> LOG2_BLOCK_SIZE) & 0x3F, delta_q[i]);
      }
      do_lookahead = true;
      pf_q_head++;
    }

    if (lookahead_way < PPF_PT_WAY) {
      uint32_t set = ppf_get_hash(curr_sig) % PPF_PT_SET;
      base_addr += ((uint64_t)PT.delta[set][lookahead_way] << LOG2_BLOCK_SIZE);
      prev_delta += PT.delta[set][lookahead_way];

      int sig_delta =
          (PT.delta[set][lookahead_way] < 0)
              ? (((-1) * PT.delta[set][lookahead_way]) + (1 << (PPF_SIG_DELTA_BIT - 1)))
              : PT.delta[set][lookahead_way];
      curr_sig = ((curr_sig << PPF_SIG_SHIFT) ^ sig_delta) & PPF_SIG_MASK;
    }
  }
}

void ppf::register_fill(uint64_t addr)
{
  FILTER.check(addr, 0, 0, L2C_EVICT, 0, 0, 0, 0, 0, 0);
}

void ppf::dump_stats()
{
  std::cout << "ppf.pf_issued " << GHR.pf_issued << std::endl
            << "ppf.pf_useful " << GHR.pf_useful << std::endl;
}
