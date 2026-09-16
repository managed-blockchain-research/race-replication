
## Per-Run GC Summary

| Run | Total GC Time (ms) | Full GC Events | Young GC Count | Mixed GC Count | Mean Pause (ms) | p95 Pause (ms) | Max Pause (ms) |
|-----|--------------------|----------------|----------------|----------------|-----------------|----------------|----------------|
| fee_agnostic_besu_1 | 745 | 0 | 124 | 0 | 6.0 | 9.8 | 18.5 |
| fee_agnostic_besu_2 | 756 | 0 | 127 | 0 | 6.0 | 9.7 | 16.6 |
| fee_agnostic_besu_3 | 693 | 0 | 124 | 0 | 5.6 | 9.8 | 14.8 |
| fee_aware_besu_1 | 734 | 0 | 128 | 0 | 5.7 | 8.7 | 17.5 |
| fee_aware_besu_2 | 690 | 0 | 125 | 0 | 5.5 | 8.4 | 14.8 |
| fee_aware_besu_3 | 703 | 0 | 125 | 0 | 5.6 | 8.4 | 14.0 |

## Aggregate GC Statistics (mean ± sd across reps)

| Variant | Reps | Total GC Time/run (ms) | Full GCs/run | Mean Pause (ms) | p95 Pause (ms) | p99 Pause (ms) | Max Pause (ms) |
|---------|------|------------------------|--------------|-----------------|----------------|----------------|----------------|
| fee_agnostic_besu | 3 | 731.4 ± 27.7 | 0.0 ± 0.0 | 5.9 ± 0.2 | 9.8 ± 0.0 | 12.9 ± 1.1 | 16.6 ± 1.5 |
| fee_aware_besu | 3 | 709.3 ± 18.5 | 0.0 ± 0.0 | 5.6 ± 0.1 | 8.5 ± 0.2 | 14.2 ± 1.0 | 15.4 ± 1.5 |

### Total GC Time and Full GC Events per Run

| Run | Total GC Time (ms) | Total Full GC Events |
|-----|-------------------|----------------------|
| fee_agnostic_besu_1 | 745 | 0 |
| fee_agnostic_besu_2 | 756 | 0 |
| fee_agnostic_besu_3 | 693 | 0 |
| fee_aware_besu_1 | 734 | 0 |
| fee_aware_besu_2 | 690 | 0 |
| fee_aware_besu_3 | 703 | 0 |
