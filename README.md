# RACE: Runtime-Aware Feedback Control for Admission Throttling in Managed Blockchain Clients

Replication package for the RACE evaluation (Hyperledger Besu + Nethermind).

## Structure
- `configs/` — Caliper benchmark configurations (flood, Yo-Yo attack, equal-throughput ablation, fee-aware ablation)
- `benchmarks/` — Workload JavaScript files (StateBloater-based, single-sender and 2-worker fee-tiered variants)
- `scripts/` — Run and analysis scripts
- `results/` — GC event, RPI-controller telemetry, and per-transaction admission-decision CSVs (raw GC trace files and console logs are excluded; only the small derived CSVs needed to reproduce the paper's tables/figures are kept)
- `src/` — Smart contract source (`StateBloater.sol`)

## Required harness patch: Caliper Ethereum connector nonce-reset

`@hyperledger/caliper-ethereum`'s connector resets its local nonce counter (`context.localNonce = null`, forcing a fresh on-chain nonce fetch) only for a fixed whitelist of pool-rejection error strings. RACE's own ingress throttling rejects submissions with messages that were **not** in that whitelist (Besu: a generic `"Internal error"`; Nethermind: `"RacePacingRejected, RACE action=..."`). Without adding both strings to the connector's reset condition, a single-sender workload (`workers: 1`, used throughout this evaluation) permanently wedges on a nonce gap the first time RACE's throttle actually engages, silently corrupting every subsequent measurement in the run. Add both patterns to the reset condition in `ethereum-connector.js` (search for the existing `FeeTooLowToCompete` / `nonce too low` check) before running any script here. This is the single most important prerequisite for reproducing the numbers in this repository — an earlier version of this replication package (data collected 2026-04-27/28) predates this fix and has been superseded; see the results directories below, all collected 2026-09-16 after the fix.

## Datasets

| Directory | Paper section | Description |
|---|---|---|
| `results/race_besu_eval/20260916_082748_race_besu_eval/` | §VIII-B (GC Stabilisation, Besu) | 5×baseline + 5×RACE, 30→150→30 TPS flood, 1 GB heap |
| `results/race_nm_eval/20260916_091132_race_nm_eval/` | §VIII-C (Nethermind Portability) | 5×baseline reps (RACE disabled; no controller telemetry by construction) |
| `results/race_nm_eval/20260916_115414_race_nm_eval/` | §VIII-C | 5×RACE reps, same flood workload, 512 MB heap |
| `results/race_nm_yoyo/20260916_133911_race_nm_yoyo/` | §XI (Adversarial Evaluation: the Yo-Yo attack) | 3 reps, alternating 150 TPS attack bursts / 5 TPS idle windows |
| `results/race_nm_matched_rate/20260916_134551_race_nm_matched_rate/` | §X-C (Volume vs. Selectivity ablation) | 5×baseline reps with offered rate fixed at RACE's own measured effective admission rate (19 TPS) instead of 150 TPS |
| `results/race_besu_feetest/20260916_141629_race_besu_feetest/` | §XII (Fee-Aware Admission) | 3×fee\_agnostic + 3×fee\_aware reps, 2-worker spam/legit fee-tiered workload |

## Scripts

Each `run_race_*.sh` in `scripts/` reproduces one dataset above; see the header comment in each for exact parameters. `parse_race_results.py` and `plot_race_rpi.py` aggregate/plot controller telemetry; `parse_besu_gc.py` / `parse_nettrace_gc.py` parse the respective platforms' GC logs.
