# Stage 3 Conclusions — 602.gcc_s-1850B

**Date:** 2026-05-26 08:16:49 | **Trace:** 602.gcc_s-1850B | **Run:** 20260526-074345 | **Status:** Complete

## B1 Baseline (from Stage 1)

| Prefetcher | IPC | L1D Hit Rate | PF Accuracy | PF Issued |
|------------|-----|-------------|-------------|-----------|
| no | 0.2569 | .8583 | 0 | 0 |
| next_line | 0.4407 | .7561 | .0868 | 2135896 |
| ip_stride | 0.564 | .8157 | .2449 | 769622 |
| spp_dev | 0.5616 | .6002 | .0021 | 3903730 |
| va_ampm_lite | 0.6982 | .8608 | .5935 | 254756 |

**Best B1:** va_ampm_lite — IPC 0.6982

## B2 Oracle Per-PC (from Stage 2)

| Metric | Value |
|--------|-------|
| IPC | 0.7224 |

## B3 Oracle Per-PC × Context

| Extractor | IPC | L1D Hit Rate | PF Accuracy | PF Issued |
|-----------|-----|-------------|-------------|-----------|
| page_offset | 0.5093 | .7970 | .1914 | 1000630 |
| delta_signature | 0.7204 | .8576 | .1949 | 1017660 |
| recent_pc_hash | 0.7066 | .8617 | .1969 | 906769 |
| composite | 0.5728 | .7961 | .1634 | 1021473 |

**Best B3:** delta_signature — IPC 0.7204

## Primary Judgment

- B3 (best) IPC: 0.7204
- B2 IPC: 0.7224
- Gap vs B2: -.2700%
- Gap vs B1-best: 3.1700%
- Verdict: **FAIL**

## Analysis

See SUMMARY.log for detailed auxiliary checks.

## Next Stage
- If PASS: context splitting provides value, proceed to production evaluation
- If FAIL: per-PC granularity is sufficient, context splitting not needed for this trace
