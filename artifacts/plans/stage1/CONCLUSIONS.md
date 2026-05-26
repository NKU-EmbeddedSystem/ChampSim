# Stage 1 Conclusions — 602.gcc_s-1850B

**Date:** 2026-05-24 04:28:48 | **Trace:** 602.gcc_s-1850B | **Run:** 20260524-042106 | **Status:** Complete

## Results

| Prefetcher | IPC | L1D Hit Rate | PF Accuracy | PF Issued |
|------------|-----|-------------|-------------|-----------|
| no | 0.2569 | .8583 | 0 | 0 |
| next_line | 0.4407 | .7561 | .0868 | 2135896 |
| ip_stride | 0.564 | .8157 | .2449 | 769622 |
| spp_dev | 0.5616 | .6002 | .0021 | 3903730 |
| va_ampm_lite | 0.6982 | .8608 | .5935 | 254756 |

## Trace Filter
- Best/Worst ratio: 2.7177
- Decision: RETAINED

## Best Single Policy
- **va_ampm_lite** — IPC 0.6982

## Checks
- [PASS] IPC sanity (0.1–4.0)
- See SUMMARY.log for full details

## Next Stage
- Stage 2: Oracle Per-PC Hint Dispatch
- Hypothesis: B2 IPC > 0.6982 (Best B1 = va_ampm_lite)
