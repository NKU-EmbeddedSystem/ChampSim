#ifndef REPLACEMENT_SET_DUELING_H
#define REPLACEMENT_SET_DUELING_H

#include <algorithm>
#include <array>
#include <cstddef>
#include <memory>
#include <random>
#include <vector>

#include "cache.h"
#include "modules.h"
#include "msl/fwcounter.h"

// ============================================================
// WARNING: INCLUDE ORDER DEPENDENCY
// This header is a template. Sub-policy complete types (lru,
// srrip, ship, etc.) MUST be #include'd BEFORE this header
// at the point of template instantiation.
// The explicit instantiation .cc file handles this ordering.
// ============================================================

namespace set_dueling_detail {

// Lightweight adapter: wraps a single policy R as a
// CACHE::replacement_module_concept.  Avoids the
// multi-policy fold-expression machinery in
// CACHE::replacement_module_model<Rs...> (cache.h:427-528).
template <typename R>
struct single_policy_adapter final : CACHE::replacement_module_concept {
    R intern_;
    explicit single_policy_adapter(CACHE* cache) : intern_(cache) {}

    void bind(CACHE* c) final { intern_.bind(c); }

    void impl_initialize_replacement() final {
        if constexpr (champsim::modules::replacement::has_initialize<R>)
            intern_.initialize_replacement();
    }
    long impl_find_victim(uint32_t triggering_cpu, uint64_t instr_id, long set,
                          const CACHE::BLOCK* current_set, champsim::address ip,
                          champsim::address full_addr, access_type type) final {
        if constexpr (champsim::modules::replacement::has_find_victim<R, uint32_t, uint64_t, long, const CACHE::BLOCK*, champsim::address, champsim::address, access_type>)
            return intern_.find_victim(triggering_cpu, instr_id, set,
                                       current_set, ip, full_addr, type);
        return 0;
    }
    void impl_update_replacement_state(uint32_t triggering_cpu, long set, long way,
                                       champsim::address full_addr, champsim::address ip,
                                       champsim::address victim_addr, access_type type,
                                       bool hit) final {
        if constexpr (champsim::modules::replacement::has_update_state<R, uint32_t, long, long, champsim::address, champsim::address, champsim::address, access_type, bool>)
            intern_.update_replacement_state(triggering_cpu, set, way, full_addr,
                                             ip, victim_addr, type, hit);
    }
    void impl_replacement_cache_fill(uint32_t triggering_cpu, long set, long way,
                                     champsim::address full_addr, champsim::address ip,
                                     champsim::address victim_addr, access_type type) final {
        if constexpr (champsim::modules::replacement::has_cache_fill<R, uint32_t, long, long, champsim::address, champsim::address, champsim::address, access_type>)
            intern_.replacement_cache_fill(triggering_cpu, set, way, full_addr,
                                           ip, victim_addr, type);
        else
            impl_update_replacement_state(triggering_cpu, set, way, full_addr, ip,
                                          victim_addr, type, false);
    }
    void impl_replacement_final_stats() final {
        if constexpr (champsim::modules::replacement::has_final_stats<R>)
            intern_.replacement_final_stats();
    }
};

}  // namespace set_dueling_detail

template <typename... Ps>
struct set_dueling : public champsim::modules::replacement {
    static constexpr std::size_t NUM_POLICIES = sizeof...(Ps);
    static constexpr std::size_t SDM_SIZE = 32;
    static constexpr unsigned PSEL_WIDTH = 10;

    long NUM_SET, NUM_WAY;

    // Randomly sampled leader set indices (sorted at construction for
    // O(log N) binary_search lookup).  Layout:
    //   [cpu 0: policy 0 * SDM_SIZE | policy 1 * SDM_SIZE | ... |
    //    cpu 1: policy 0 * SDM_SIZE | ...]
    std::vector<std::size_t> rand_sets;

    // PSEL counters: PSEL[cpu][policy_idx]
    //   N=2: single PSEL[cpu][0] used for relative preference (DRRIP compat)
    //   N>2: PSEL[cpu][i] = absolute performance counter for policy i
    using psel_counter = champsim::msl::fwcounter<PSEL_WIDTH>;
    std::vector<std::array<psel_counter, NUM_POLICIES>> PSEL;

    // Sub-policy storage
    std::array<std::unique_ptr<CACHE::replacement_module_concept>, NUM_POLICIES> sub_policies;

    explicit set_dueling(CACHE* cache);

    long find_victim(uint32_t triggering_cpu, uint64_t instr_id, long set,
                     const champsim::cache_block* current_set, champsim::address ip,
                     champsim::address full_addr, access_type type);
    void update_replacement_state(uint32_t triggering_cpu, long set, long way,
                                   champsim::address full_addr, champsim::address ip,
                                   champsim::address victim_addr, access_type type,
                                   uint8_t hit);
    void replacement_cache_fill(uint32_t triggering_cpu, long set, long way,
                                 champsim::address full_addr, champsim::address ip,
                                 champsim::address victim_addr, access_type type);
    void initialize_replacement();
    void replacement_final_stats();

private:
    int get_leader_index(uint32_t cpu, long set) const;
    std::size_t get_best_policy_index(uint32_t cpu) const;
};

// ========== Template member function definitions ==========

template <typename... Ps>
set_dueling<Ps...>::set_dueling(CACHE* cache)
    : replacement(cache), NUM_SET(cache->NUM_SET), NUM_WAY(cache->NUM_WAY)
{
    std::size_t idx = 0;
    ((sub_policies[idx++] = std::make_unique<set_dueling_detail::single_policy_adapter<Ps>>(cache)), ...);

    std::size_t TOTAL_SDM_SETS = NUM_CPUS * NUM_POLICIES * SDM_SIZE;
    rand_sets.reserve(TOTAL_SDM_SETS);
    std::generate_n(std::back_inserter(rand_sets), TOTAL_SDM_SETS,
                    [this]() { return std::knuth_b{1}() % static_cast<std::size_t>(NUM_SET); });
    std::sort(std::begin(rand_sets), std::end(rand_sets));

    PSEL.resize(NUM_CPUS);
}

template <typename... Ps>
long set_dueling<Ps...>::find_victim(uint32_t triggering_cpu, uint64_t instr_id,
                                      long set, const champsim::cache_block* current_set,
                                      champsim::address ip, champsim::address full_addr,
                                      access_type type)
{
    auto leader_idx = get_leader_index(triggering_cpu, set);
    if (leader_idx < 0) {
        auto best_idx = get_best_policy_index(triggering_cpu);
        return sub_policies[best_idx]->impl_find_victim(
            triggering_cpu, instr_id, set, current_set, ip, full_addr, type);
    } else {
        return sub_policies[leader_idx]->impl_find_victim(
            triggering_cpu, instr_id, set, current_set, ip, full_addr, type);
    }
}

template <typename... Ps>
void set_dueling<Ps...>::update_replacement_state(
    uint32_t triggering_cpu, long set, long way, champsim::address full_addr,
    champsim::address ip, champsim::address victim_addr, access_type type,
    uint8_t hit)
{
    // On a miss in try_hit(), the CACHE passes way_idx = NUM_WAY (= set_end iterator),
    // which is out of bounds.  Clamp to a safe sentinel for miss events (the way
    // is not meaningful for misses — find_victim already chose the victim).
    if (!hit && way >= NUM_WAY)
        way = 0;
    // Do not update replacement state for writebacks (matching DRRIP)
    if (access_type{type} == access_type::WRITE) {
        for (auto& sp : sub_policies)
            sp->impl_update_replacement_state(triggering_cpu, set, way,
                                               full_addr, ip, victim_addr, type, hit);
        return;
    }

    auto leader_idx = get_leader_index(triggering_cpu, set);

    if (hit) {
        if (leader_idx >= 0) {
            sub_policies[leader_idx]->impl_update_replacement_state(
                triggering_cpu, set, way, full_addr, ip, victim_addr, type, hit);
        } else {
            for (auto& sp : sub_policies)
                sp->impl_update_replacement_state(triggering_cpu, set, way,
                                                   full_addr, ip, victim_addr, type, hit);
        }
    } else {
        for (auto& sp : sub_policies)
            sp->impl_update_replacement_state(triggering_cpu, set, way,
                                               full_addr, ip, victim_addr, type, hit);

        if (leader_idx >= 0) {
            if constexpr (NUM_POLICIES == 2) {
                // DRRIP: miss on leader pushes PSEL toward the OTHER policy
                if (leader_idx == 0)
                    PSEL[triggering_cpu][0]++;  // miss on policy 0: shift toward policy 1
                else
                    PSEL[triggering_cpu][0]--;  // miss on policy 1: shift toward policy 0
            } else {
                PSEL[triggering_cpu][leader_idx]--;
            }
        }
    }
}

template <typename... Ps>
void set_dueling<Ps...>::replacement_cache_fill(
    uint32_t triggering_cpu, long set, long way, champsim::address full_addr,
    champsim::address ip, champsim::address victim_addr, access_type type)
{
    auto leader_idx = get_leader_index(triggering_cpu, set);
    if (leader_idx >= 0) {
        sub_policies[leader_idx]->impl_replacement_cache_fill(
            triggering_cpu, set, way, full_addr, ip, victim_addr, type);
    } else {
        auto best_idx = get_best_policy_index(triggering_cpu);
        sub_policies[best_idx]->impl_replacement_cache_fill(
            triggering_cpu, set, way, full_addr, ip, victim_addr, type);
    }
}

template <typename... Ps>
void set_dueling<Ps...>::initialize_replacement()
{
    for (auto& sp : sub_policies)
        sp->impl_initialize_replacement();
}

template <typename... Ps>
void set_dueling<Ps...>::replacement_final_stats()
{
    for (auto& sp : sub_policies)
        sp->impl_replacement_final_stats();
}

template <typename... Ps>
int set_dueling<Ps...>::get_leader_index(uint32_t cpu, long set) const
{
    auto begin = std::next(std::begin(rand_sets), cpu * NUM_POLICIES * SDM_SIZE);
    auto end   = std::next(begin, NUM_POLICIES * SDM_SIZE);

    auto it = std::lower_bound(begin, end, set);
    if (it == end || *it != static_cast<std::size_t>(set))
        return -1;

    auto offset = static_cast<std::size_t>(std::distance(begin, it));
    return static_cast<int>(offset / SDM_SIZE);
}

template <typename... Ps>
std::size_t set_dueling<Ps...>::get_best_policy_index(uint32_t cpu) const
{
    if constexpr (NUM_POLICIES == 2) {
        return PSEL[cpu][0].value() > (PSEL[cpu][0].maximum / 2) ? 1 : 0;
    } else {
        auto& cnts = PSEL[cpu];
        return static_cast<std::size_t>(
            std::distance(std::begin(cnts),
                          std::max_element(std::begin(cnts), std::end(cnts))));
    }
}

#endif  // REPLACEMENT_SET_DUELING_H
