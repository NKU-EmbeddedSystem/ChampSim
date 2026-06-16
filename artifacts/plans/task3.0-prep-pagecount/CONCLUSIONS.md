# Task 3.0 Conclusions — Working Set Size Survey

**Date:** 2026-06-15 16:01:11 | **Input:** ChampSim traces (12 unique workloads) | **Run:** 20260615-160018 | **Status:** Complete

## Results

| Benchmark | WSS Pages | WSS (MB) | DRAM Pages (K) | DRAM (MB) |
|-----------|-----------|----------|---------------------|-----------|
| h264ref_178B | 1,282 | 5.0 | 427 | 1.7 |
| perlbench_53B | 2,309 | 9.0 | 769 | 3.0 |
| sphinx3_883B | 3,865 | 15.1 | 1,288 | 5.0 |
| astar_163B | 5,061 | 19.8 | 1,687 | 6.6 |
| libquantum_964B | 8,196 | 32.0 | 2,732 | 10.7 |
| cactusADM_734B | 10,666 | 41.7 | 3,555 | 13.9 |
| soplex_66B | 11,870 | 46.4 | 3,956 | 15.5 |
| zeusmp_100B | 13,111 | 51.2 | 4,370 | 17.1 |
| omnetpp_4B | 16,154 | 63.1 | 5,384 | 21.0 |
| xalancbmk_99B | 19,866 | 77.6 | 6,622 | 25.9 |
| mcf_46B | 64,191 | 250.7 | 21,397 | 83.6 |
| milc_360B | 93,475 | 365.1 | 31,158 | 121.7 |

- 12 valid benchmarks
- DRAM pages range: 427 – 31,158

## Filter

- Decision: RETAINED (12/12 valid)

## Best Single Workload

- **Smallest WSS:** h264ref_178B (1,282 pages)

## Checks

- [PASS] All 12/12 traces found
- [PASS] All WSS > 0
- See SUMMARY.log for full details

## Next Stage

- Stage 3.1: Generate area_map files (sort_heat / first_touch) using per-benchmark K values
- K = min(WSS / 3, 262144) from this stage's pages.jsonl
