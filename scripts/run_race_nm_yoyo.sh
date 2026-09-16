#!/bin/bash
# ============================================================
# RACE Yo-Yo Adversarial Evaluation — Nethermind / 512 MB
#
# Attacker alternates short 150 TPS bursts (enough to drive RACE into
# SURVIVAL, per the 2026-09-16 flood-eval finding that H_t saturates
# and stays pinned) with near-idle 5 TPS "legitimate traffic" windows,
# then repeats. RACE variant only — no baseline (there's nothing to
# throttle without RACE, so a baseline run has no adversarial content).
#
# Primary metrics:
#   - RACE: RPI/mode time-series (combined_metrics.csv) — does the
#     controller return to NORMAL/PACING promptly once the attacker
#     stops, or does it keep rejecting the 5 TPS "legitimate" traffic
#     for a while (self-censorship persistence)?
#   - Does a second attack burst re-enter SURVIVAL faster than the
#     first (i.e. does H_t never fully recover between bursts)?
#
# NM binary: /home/yeochan.yoon/nethermind-race-built/nethermind.dll
# Output: results/race_nm_yoyo/<RUN_ID>/
# ============================================================
set -e
cd /home/yeochan.yoon/caliper-stress-test

# ── Binaries ──────────────────────────────────────────────────────────────────
NM_DLL="/home/yeochan.yoon/nethermind-race-built/nethermind.dll"
DOTNET_BIN="/home/yeochan.yoon/.dotnet/dotnet"
GC_PARSER="/home/yeochan.yoon/caliper-stress-test/gc-collector/publish/NettraceGcParser.dll"
DT_BIN="${HOME}/.dotnet/tools/dotnet-trace"
NM_CFG="/home/yeochan.yoon/caliper-stress-test/nethermind-caliper-config/caliper_race_aura_cfg.json"

# ── Caliper config ────────────────────────────────────────────────────────────
BENCHCONFIG="benchconfig-race-yoyo.yaml"
NETWORKCONFIG="networkconfig_race_nm.json"
DEPLOY_NM="deploy_multi_contracts_nm.js"

# ── Parameters ────────────────────────────────────────────────────────────────
HEAP_NM=512000000
REPLICATIONS="${REPLICATIONS:-3}"
RACE_OUTPUT_ROOT="/home/yeochan.yoon/caliper-stress-test/results/race_nm_eval_race"

export DOTNET_ROOT="/home/yeochan.yoon/.dotnet"
export PATH="${DOTNET_ROOT}:${PATH}:${HOME}/.dotnet/tools"

# ── Output directory ──────────────────────────────────────────────────────────
RUN_ID=$(date +%Y%m%d_%H%M%S)_race_nm_yoyo
RESULTS_DIR="/home/yeochan.yoon/caliper-stress-test/results/race_nm_yoyo/${RUN_ID}"
mkdir -p "${RESULTS_DIR}"

echo "======================================================================"
echo "RACE Yo-Yo Adversarial Eval | NM | AuRa 1s blocks | 512 MB | ${REPLICATIONS:-3} reps"
echo "Run ID: ${RUN_ID}"
echo "======================================================================"

# Verify NM binary
if [ ! -f "${NM_DLL}" ]; then
    echo "ERROR: NM RACE binary not found at ${NM_DLL}"
    echo "Build with: dotnet publish .../Nethermind.Runner.csproj -c Release -o nethermind-race-built /p:NuGetAudit=false"
    exit 1
fi

# ── Helpers ───────────────────────────────────────────────────────────────────
wait_for_rpc() {
    local port="${1:-8545}"
    local max=120; local c=0
    echo -n "  Waiting for RPC"
    while [ $c -lt $max ]; do
        curl -s --max-time 2 -X POST -H "Content-Type: application/json" \
            --data '{"jsonrpc":"2.0","method":"eth_blockNumber","params":[],"id":1}' \
            http://localhost:${port} > /dev/null 2>&1 && echo " READY" && return 0
        echo -n "."; sleep 1; c=$((c+1))
    done
    echo " TIMEOUT"; return 1
}

stop_nm() {
    local pid="$1"
    kill "${pid}" 2>/dev/null || true
    local w=0; while kill -0 "${pid}" 2>/dev/null && [ $w -lt 30 ]; do sleep 1; w=$((w+1)); done
    kill -9 "${pid}" 2>/dev/null || true
    pkill -9 -f "nethermind.dll" 2>/dev/null || true
    fuser -k 8545/tcp 8546/tcp 2>/dev/null || true
    sleep 5
}

# run_nm_single VARIANT REP
run_nm_single() {
    local variant="$1"; local rep="$2"
    local label="${variant}_nm_${rep}"
    local run_dir="${RESULTS_DIR}/${label}"; mkdir -p "${run_dir}"
    local data_dir="/home/yeochan.yoon/caliper-stress-test/data_race_${label}_${RUN_ID}"
    local nettrace="${run_dir}/gc_trace.nettrace"
    local race_run_id="${label}_${RUN_ID}"
    local race_out_dir="${run_dir}/race_out"

    echo ""; echo "────────────────────────────────────────────────────────────────"
    echo "RUN: ${label} | $(date '+%Y-%m-%d %H:%M:%S')"
    echo "────────────────────────────────────────────────────────────────"

    pkill -9 -f "nethermind.dll" 2>/dev/null || true
    pkill -9 -f "caliper launch" 2>/dev/null || true
    fuser -k 8545/tcp 8546/tcp 2>/dev/null || true
    sleep 5; rm -rf "${data_dir}"; mkdir -p "${data_dir}"

    export NETHERMIND_LAST_MODE="DISABLED"
    export DOTNET_GCHeapHardLimit="${HEAP_NM}"
    export COMPlus_GCHeapHardLimit="${HEAP_NM}"
    export DOTNET_EnableDiagnostics=1
    unset DOTNET_GCHighMemPercent COMPlus_GCHighMemPercent 2>/dev/null || true

    # Build NM arguments
    local nm_extra_args=""
    if [ "${variant}" = "race" ]; then
        mkdir -p "${race_out_dir}"
        nm_extra_args="--Race.Enabled true \
            --Race.OutputRootPath ${race_out_dir} \
            --Race.RunId ${race_run_id} \
            --Race.HeapNormalizationBytes 512000000 \
            --Race.NormalToPacingThreshold 0.20 \
            --Race.PacingToNormalThreshold 0.13 \
            --Race.PacingToSurvivalThreshold 0.26 \
            --Race.SurvivalToPacingThreshold 0.19 \
            --Race.SampleIntervalMs 500 \
            --Race.EnableSurvival true"
    else
        nm_extra_args="--Race.Enabled false"
    fi

    # Update AuRa genesis timestamp to ~60s ago so step counter starts near 0
    python3 -c "
import json, time
spec_path = '$(pwd)/nethermind-caliper-config/caliper_race_aura.json'
with open(spec_path) as f: s = json.load(f)
s['genesis']['timestamp'] = hex(int(time.time()) - 60)
with open(spec_path,'w') as f: json.dump(s, f, indent=4)
"

    nohup "${DOTNET_BIN}" "${NM_DLL}" --config "${NM_CFG}" \
        --Init.BaseDbPath "${data_dir}" \
        --Blocks.MinGasPrice 0 \
        --TxPool.Size 4096 \
        ${nm_extra_args} \
        > "${run_dir}/nm_console.log" 2>&1 &
    local pid=$!; echo "  NM PID: ${pid}"

    sleep 8
    if ! kill -0 ${pid} 2>/dev/null; then
        echo "failed=startup" > "${run_dir}/FAILED"
        unset NETHERMIND_LAST_MODE DOTNET_GCHeapHardLimit COMPlus_GCHeapHardLimit
        return 1
    fi
    wait_for_rpc || {
        stop_nm "${pid}"; echo "failed=rpc_timeout" > "${run_dir}/FAILED"
        unset NETHERMIND_LAST_MODE DOTNET_GCHeapHardLimit COMPlus_GCHeapHardLimit
        return 1; }

    node "${DEPLOY_NM}" 30 "${NETWORKCONFIG}" > "${run_dir}/deploy.log" 2>&1
    grep -q "Contract Address:" "${run_dir}/deploy.log" || {
        stop_nm "${pid}"; echo "failed=deploy" > "${run_dir}/FAILED"
        unset NETHERMIND_LAST_MODE DOTNET_GCHeapHardLimit COMPlus_GCHeapHardLimit
        return 1; }
    # deploy_multi_contracts_nm.js unconditionally resets transactionPollingTimeout/
    # transactionBlockTimeout to short defaults (90/200) on every deploy -- undoing
    # this dedicated config's long-timeout fix (see networkconfig_race_nm.json) right
    # before the actual caliper run. Patch them back rather than touching the shared script.
    python3 -c "
import json
p = '${NETWORKCONFIG}'
d = json.load(open(p))
d['ethereum']['transactionPollingTimeout'] = 280
d['ethereum']['transactionBlockTimeout'] = 2000
d['ethereum']['txWallClockTimeout'] = 300
json.dump(d, open(p, 'w'), indent=2)
"
    sleep 5

    # dotnet-trace GC collection
    local dt_pid=""
    [ -f "${DT_BIN}" ] && {
        "${DT_BIN}" collect --process-id "${pid}" \
            --providers "Microsoft-Windows-DotNETRuntime:0x1:5" \
            --output "${nettrace}" > "${run_dir}/dotnet_trace.log" 2>&1 &
        dt_pid=$!; echo "  dotnet-trace PID: ${dt_pid}"; }

    # warmup(30s) + on1(60s) + off1(90s) + on2(60s) + off2(90s) = 330s + margin
    echo "  Running Caliper (Yo-Yo: 10->150->5->150->5 TPS, 330s total)..."
    # 900s already had some margin, but bumped further for the same reason as
    # the Besu script: txWallClockTimeout is now 300s, so pending txs from the
    # flood stage can legitimately take up to 300s each to resolve to Fail.
    timeout 1200 npx caliper launch manager \
        --caliper-workspace ./ --caliper-benchconfig "${BENCHCONFIG}" \
        --caliper-networkconfig "${NETWORKCONFIG}" \
        > "${run_dir}/caliper_console.log" 2>&1 || true

    # `timeout N` does not reliably propagate its kill signal down through
    # timeout -> npm exec -> node manager -> node worker; orphaned caliper
    # worker processes survive and contaminate the next rep's RPC port.
    pkill -9 -f "caliper launch" 2>/dev/null || true

    [ -n "${dt_pid}" ] && kill -INT "${dt_pid}" 2>/dev/null || true
    sleep 5; [ -n "${dt_pid}" ] && kill "${dt_pid}" 2>/dev/null || true

    cp caliper.log "${run_dir}/caliper.log" 2>/dev/null || true
    cp report.html "${run_dir}/report.html" 2>/dev/null || true
    stop_nm "${pid}"; rm -rf "${data_dir}"
    unset NETHERMIND_LAST_MODE DOTNET_GCHeapHardLimit COMPlus_GCHeapHardLimit \
          DOTNET_GCHighMemPercent COMPlus_GCHighMemPercent 2>/dev/null || true

    # Parse GC nettrace
    [ -f "${nettrace}" ] && [ -f "${GC_PARSER}" ] && {
        "${DOTNET_BIN}" "${GC_PARSER}" "${nettrace}" 2>/dev/null | tee "${run_dir}/gc_summary.txt" | sed 's/^/    /'
        "${DOTNET_BIN}" "${GC_PARSER}" "${nettrace}" --csv 2>/dev/null | \
            awk -v v="${variant}" -v r="${rep}" \
            'NR==1{print "variant,run,client,"$0} NR>1{print v","r",nm,"$0}' \
            > "${run_dir}/gc_events.csv"; }

    # Quick RACE summary
    if [ "${variant}" = "race" ]; then
        local metrics_csv="${race_out_dir}/${race_run_id}/combined_metrics.csv"
        [ -f "${metrics_csv}" ] && {
            normal_samples=$(grep -c ",NORMAL," "${metrics_csv}" 2>/dev/null || echo 0)
            pacing_samples=$(grep -c ",PACING," "${metrics_csv}" 2>/dev/null || echo 0)
            survival_samples=$(grep -c ",SURVIVAL," "${metrics_csv}" 2>/dev/null || echo 0)
            echo "  RACE: NORMAL=${normal_samples} PACING=${pacing_samples} SURVIVAL=${survival_samples}"
        }
        # Copy metrics to run dir for easy access
        find "${race_out_dir}" -name "combined_metrics.csv" -exec cp {} "${run_dir}/" \; 2>/dev/null || true
        find "${race_out_dir}" -name "mode_transitions.log" -exec cp {} "${run_dir}/" \; 2>/dev/null || true
    fi

    grep "| stage" "${run_dir}/caliper_console.log" | sed 's/^/  Caliper: /' || \
        grep "| stage\|Send Rate\|succ" "${run_dir}/caliper_console.log" | tail -5 | sed 's/^/  Caliper: /' || true
    echo "  ✓ ${label} complete"
}

# ── Provenance ────────────────────────────────────────────────────────────────
cat > "${RESULTS_DIR}/provenance.txt" <<EOF
RACE Evaluation — Nethermind / 512 MB / Flood 30→150→30 TPS
=============================================================
Run ID: ${RUN_ID} | Date: $(date) | Host: $(hostname)
NM Binary: ${NM_DLL}
Config:  ${NM_CFG}
Heap:    DOTNET_GCHeapHardLimit=512000000
TxPool:  Size=4096
Load:    30 TPS 60s → 150 TPS 120s → 30 TPS 60s (stateBloat 200 slots, AuRa 1s blocks)
Variants:
  baseline : RACE disabled
  race     : RACE enabled (NormalToPacing=0.20, PacingToSurvival=0.26, EnableSurvival=true)
RACE thresholds:
  NormalToPacing=0.20, PacingToNormal=0.13
  PacingToSurvival=0.26, SurvivalToPacing=0.19
  SampleIntervalMs=500
EOF

# ── Pre-flight ────────────────────────────────────────────────────────────────
pkill -9 -f "nethermind.dll" 2>/dev/null || true
fuser -k 8545/tcp 8546/tcp 2>/dev/null || true
sleep 3

# ── Phase 1: RACE only (no baseline — this is an adversarial-pattern study of
#    RACE's own controller behavior, not a baseline-vs-RACE GC comparison) ────
echo ""; echo "=============================="; echo "PHASE 1: ${REPLICATIONS}×RACE (Yo-Yo pattern) / NM"; echo "=============================="
for i in $(seq 1 ${REPLICATIONS}); do
    run_nm_single "race" "${i}" || echo "  WARNING: race_nm_${i} failed"
    [ "${i}" -lt "${REPLICATIONS}" ] && sleep 30
done

# ── Aggregate GC CSV ──────────────────────────────────────────────────────────
echo ""; echo "Aggregating GC events..."
GC_ALL="${RESULTS_DIR}/gc_all.csv"
header_written=false
for gc_csv in "${RESULTS_DIR}"/*/gc_events.csv; do
    [ -f "${gc_csv}" ] || continue
    if ! ${header_written}; then
        head -1 "${gc_csv}" > "${GC_ALL}"
        header_written=true
    fi
    tail -n +2 "${gc_csv}" >> "${GC_ALL}"
done
[ -f "${GC_ALL}" ] && echo "  GC events: ${GC_ALL}" || echo "  No GC CSV found"

# ── Summary table ─────────────────────────────────────────────────────────────
echo ""; echo "Generating summary..."
python3 scripts/parse_race_results.py --results-dir "${RESULTS_DIR}" \
    > "${RESULTS_DIR}/race_summary.md" 2>/dev/null && \
    echo "RACE summary → ${RESULTS_DIR}/race_summary.md" || \
    echo "  (parse_race_results.py not found — skipping summary)"

# ── Visualization ─────────────────────────────────────────────────────────────
mkdir -p "${RESULTS_DIR}/figures"
python3 scripts/plot_race_rpi.py \
    --results-dir "${RESULTS_DIR}" \
    --out-prefix "${RESULTS_DIR}/figures/race" 2>/dev/null || true

echo ""; echo "======================================================================"
echo "RACE NM Evaluation complete. Results: ${RESULTS_DIR}"
echo "======================================================================"
