# Task 3.1 Conclusions — Area Map Generation

**Date:** 2026-06-16 20:11:39 | **Input:** ChampSim traces (12 unique workloads) | **Run:** 20260616-195704 | **Status:** Complete

## Results

| Benchmark_Strategy | File Size (bytes) | Status |
|--------|---------|---------|
| astar_random | 51,856 | PASS |
| astar_sort_heat | 51,856 | PASS |
| astar_first_touch | 51,856 | PASS |
| cactusADM_random | 615,283 | PASS |
| cactusADM_sort_heat | 615,283 | PASS |
| cactusADM_first_touch | 615,283 | PASS |
| h264ref_random | 21,769 | PASS |
| h264ref_sort_heat | 21,769 | PASS |
| h264ref_first_touch | 21,769 | PASS |
| libquantum_random | 73,780 | PASS |
| libquantum_sort_heat | 73,780 | PASS |
| libquantum_first_touch | 73,780 | PASS |
| mcf_random | 2,576,059 | PASS |
| mcf_sort_heat | 2,576,059 | PASS |
| mcf_first_touch | 2,576,059 | PASS |
| milc_random | 865,033 | PASS |
| milc_sort_heat | 865,033 | PASS |
| milc_first_touch | 865,033 | PASS |
| omnetpp_random | 178,675 | PASS |
| omnetpp_sort_heat | 178,675 | PASS |
| omnetpp_first_touch | 178,675 | PASS |
| perlbench_random | 30,220 | PASS |
| perlbench_sort_heat | 30,220 | PASS |
| perlbench_first_touch | 30,220 | PASS |
| soplex_random | 110,680 | PASS |
| soplex_sort_heat | 110,680 | PASS |
| soplex_first_touch | 110,680 | PASS |
| sphinx3_random | 40,948 | PASS |
| sphinx3_sort_heat | 40,948 | PASS |
| sphinx3_first_touch | 40,948 | PASS |
| xalancbmk_random | 230,425 | PASS |
| xalancbmk_sort_heat | 230,425 | PASS |
| xalancbmk_first_touch | 230,425 | PASS |
| zeusmp_random | 393,082 | PASS |
| zeusmp_sort_heat | 393,082 | PASS |
| zeusmp_first_touch | 393,082 | PASS |

- 36 area_map files generated

## Checks

- [PASS] All 36/36 tasks succeeded
- [PASS] Magic bytes correct (0 failures)
- [PASS] DRAM:CXL 1:2 ratio correct (0 failures)
- [PASS] Zero failures

## Next Stage

- Stage 3.2: Full sweep — 7 placement×migration configs × 4 replacement policies
- Use area_maps from this stage as --area_map inputs
- DRAM:CXL placement ratio is fixed at 1:2 by distinct 4KB pages
