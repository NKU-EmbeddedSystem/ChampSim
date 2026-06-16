# Task 3.0 Conclusions — Working Set Size Survey

**Date:** 2026-06-16 15:29:59 | **Input:** ChampSim traces (12 unique workloads) | **Run:** 20260616-152936 | **Status:** Complete

## Results

| Benchmark | WSS Pages | WSS (MB) | DRAM Pages (K) | DRAM (MB) |
|-----------|-----------|----------|---------------------|-----------|
| h264ref_178B | 1,282 | 5.0 | 427 | 1.7 |
| perlbench_53B | 2,160 | 8.4 | 720 | 2.8 |
| sphinx3_883B | 3,861 | 15.1 | 1,287 | 5.0 |
| astar_163B | 5,031 | 19.7 | 1,677 | 6.6 |
| cactusADM_734B | 7,244 | 28.3 | 2,414 | 9.4 |
| libquantum_964B | 8,196 | 32.0 | 2,732 | 10.7 |
| zeusmp_100B | 9,180 | 35.9 | 3,060 | 12.0 |
| soplex_66B | 11,831 | 46.2 | 3,943 | 15.4 |
| omnetpp_4B | 15,996 | 62.5 | 5,332 | 20.8 |
| xalancbmk_99B | 19,203 | 75.0 | 6,401 | 25.0 |
| mcf_46B | 50,357 | 196.7 | 16,785 | 65.6 |
| milc_360B | 88,935 | 347.4 | 29,645 | 115.8 |

- 12 valid benchmarks
- DRAM pages range: 427 – 29,645

## Filter

- Decision: RETAINED (12/12 valid)

## Best Single Workload

- **Smallest WSS:** h264ref_178B (1,282 pages)

## Checks

- [PASS] All 12/12 traces found
- [PASS] All WSS > 0
- See SUMMARY.log for full details

## Next Stage

- Stage 3.1: Generate area_map files (random / sort_heat / first_touch)
- DRAM:CXL=1:2 is derived directly by the area_map generator from each trace's distinct pages
- This stage's pages.jsonl is retained as an informational WSS survey, not as a required K input
