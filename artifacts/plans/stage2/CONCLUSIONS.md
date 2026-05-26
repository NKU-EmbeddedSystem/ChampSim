# Stage 2 Conclusions — 602.gcc_s-1850B

**Date:** 2026-05-25 10:15:54 | **Trace:** 602.gcc_s-1850B | **Run:** 20260525-100959 | **Status:** Complete

## B1 Baseline (from Stage 1)

| Prefetcher | IPC | L1D Hit Rate | PF Accuracy | PF Issued |
|------------|-----|-------------|-------------|-----------|
| no | 0.2569 | .8583 | 0 | 0 |
| next_line | 0.4407 | .7561 | .0868 | 2135896 |
| ip_stride | 0.564 | .8157 | .2449 | 769622 |
| spp_dev | 0.5616 | .6002 | .0021 | 3903730 |
| va_ampm_lite | 0.6982 | .8608 | .5935 | 254756 |

**Best B1:** va_ampm_lite — IPC 0.6982

## B2 Oracle Per-PC Hint Dispatch

| Metric | Value |
|--------|-------|
| IPC | 0.7224 |
| L1D Hit Rate | .8584 |
| PF Accuracy | .1918 |
| PF Issued | 996775 |
| Profile PCs | 146 |

## Primary Judgment

- B2 IPC: 0.7224
- Best-B1 IPC: 0.6982
- Gap: 3.4600%
- Verdict: **PASS**

## Auxiliary Checks

See SUMMARY.log for detailed check results.

## Next Stage
- If PASS: proceed to Stage 3 (diagnostic analysis) or Stage 4 (context splitting)
- If FAIL: Stage 3 root-cause analysis required
