
## Per-Run GC Summary

| Run | Total GC Time (ms) | Full GC Events | Young GC Count | Mixed GC Count | Mean Pause (ms) | p95 Pause (ms) | Max Pause (ms) |
|-----|--------------------|----------------|----------------|----------------|-----------------|----------------|----------------|
| baseline_besu_1 | 3781 | 0 | 674 | 0 | 5.6 | 9.3 | 24.6 |
| baseline_besu_2 | 3651 | 0 | 677 | 0 | 5.4 | 8.6 | 16.1 |
| baseline_besu_3 | 3864 | 0 | 686 | 0 | 5.6 | 9.8 | 23.9 |
| baseline_besu_4 | 3659 | 0 | 672 | 0 | 5.4 | 8.7 | 26.1 |
| baseline_besu_5 | 3867 | 0 | 707 | 0 | 5.5 | 9.6 | 29.2 |
| race_besu_1 | 541 | 0 | 93 | 0 | 5.8 | 10.0 | 17.4 |
| race_besu_2 | 852 | 0 | 154 | 0 | 5.5 | 9.4 | 13.6 |
| race_besu_3 | 882 | 0 | 158 | 0 | 5.6 | 8.5 | 15.5 |
| race_besu_4 | 887 | 0 | 161 | 0 | 5.5 | 8.4 | 17.9 |
| race_besu_5 | 846 | 0 | 154 | 0 | 5.5 | 8.4 | 14.1 |

## Aggregate GC Statistics (mean ± sd across reps)

| Variant | Reps | Total GC Time/run (ms) | Full GCs/run | Mean Pause (ms) | p95 Pause (ms) | p99 Pause (ms) | Max Pause (ms) |
|---------|------|------------------------|--------------|-----------------|----------------|----------------|----------------|
| baseline_besu | 5 | 3764.5 ± 94.4 | 0.0 ± 0.0 | 5.5 ± 0.1 | 9.2 ± 0.5 | 13.4 ± 1.0 | 24.0 ± 4.4 |
| race_besu | 5 | 801.7 ± 131.1 | 0.0 ± 0.0 | 5.6 ± 0.1 | 9.0 ± 0.7 | 12.9 ± 2.2 | 15.7 ± 1.7 |

### Total GC Time and Full GC Events per Run

| Run | Total GC Time (ms) | Total Full GC Events |
|-----|-------------------|----------------------|
| baseline_besu_1 | 3781 | 0 |
| baseline_besu_2 | 3651 | 0 |
| baseline_besu_3 | 3864 | 0 |
| baseline_besu_4 | 3659 | 0 |
| baseline_besu_5 | 3867 | 0 |
| race_besu_1 | 541 | 0 |
| race_besu_2 | 852 | 0 |
| race_besu_3 | 882 | 0 |
| race_besu_4 | 887 | 0 |
| race_besu_5 | 846 | 0 |
