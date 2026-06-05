#!/bin/bash
# ============================================================
# RACE Evaluation — Besu / 1 GB / Staged 10→40→100 TPS
#
# Internal RACE controller implemented in Besu TxPool
# (RaceFlowController.java), activated via -Drace.enabled=true.
# Both variants use identical load (stateBloat.js), isolating
# the effect of RACE ingress throttling.
#
# Variants (2 × 5 reps = 10 runs):
#   baseline : Besu without RACE (-Drace.enabled=false)
#   race     : Besu with RACE enabled (-Drace.enabled=true)
#
# Primary metrics:
#   - RACE: combined_metrics.csv (RPI time-series, mode fractions)
#   - GC:   G1GC log → parse_besu_gc.py (pause times, Full GC count)
#   - Load: Caliper confirmed TPS per stage
#
# Besu binary: besu-source (24.1.1, built with RaceFlowController)
# Heap: 512m (-Xmx512m)
# Output: results/race_besu_eval/<RUN_ID>/
# ============================================================
set -e
cd /home/yeochan.yoon/caliper-stress-test

# ── Binaries ──────────────────────────────────────────────────────────────────
BESU_BIN="/home/yeochan.yoon/besu-source/build/install/besu/bin/besu"
LOG4J_CONFIG="/home/yeochan.yoon/caliper-stress-test/log4j2-console.xml"

# ── Caliper config ────────────────────────────────────────────────────────────
BENCHCONFIG="benchconfig-race-flood.yaml"
NETWORKCONFIG="networkconfig.json"
DEPLOY_BESU="deploy_multi_contracts.py"

# ── Parameters ────────────────────────────────────────────────────────────────
HEAP="1g"
REPLICATIONS=5
METRICS_PORT=9545

# ── Output directory ──────────────────────────────────────────────────────────
RUN_ID=$(date +%Y%m%d_%H%M%S)_race_besu_eval
RESULTS_DIR="/home/yeochan.yoon/caliper-stress-test/results/race_besu_eval/${RUN_ID}"
mkdir -p "${RESULTS_DIR}"

echo "======================================================================"
echo "RACE Besu Evaluation | Clique 1s blocks | Flood 30→150→30 TPS | 1 GB | 5 reps"
echo "Run ID: ${RUN_ID}"
echo "======================================================================"

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

stop_besu() {
    local pid="$1"
    kill "${pid}" 2>/dev/null || true
    local w=0; while kill -0 "${pid}" 2>/dev/null && [ $w -lt 30 ]; do sleep 1; w=$((w+1)); done
    kill -9 "${pid}" 2>/dev/null || true
    pkill -9 -f "hyperledger.besu.Besu" 2>/dev/null || true
    fuser -k 8545/tcp 8546/tcp 30303/tcp ${METRICS_PORT}/tcp 2>/dev/null || true
    sleep 5
}

# run_besu_single VARIANT REP
run_besu_single() {
    local variant="$1"; local rep="$2"
    local label="${variant}_besu_${rep}"
    local run_dir="${RESULTS_DIR}/${label}"; mkdir -p "${run_dir}"
    local data_dir="/home/yeochan.yoon/caliper-stress-test/data_racebesu_${label}_${RUN_ID}"
    local gc_log="${run_dir}/gc_besu.log"
    local race_out_dir="${run_dir}/race_out"

    echo ""; echo "────────────────────────────────────────────────────────────────"
    echo "RUN: ${label} | $(date '+%Y-%m-%d %H:%M:%S')"
    echo "────────────────────────────────────────────────────────────────"

    pkill -9 -f "hyperledger.besu.Besu" 2>/dev/null || true
    fuser -k 8545/tcp 8546/tcp 30303/tcp ${METRICS_PORT}/tcp 2>/dev/null || true
    sleep 5; rm -rf "${data_dir}"; mkdir -p "${data_dir}"

    # Build RACE JVM args
    local race_jvm_opts="-Drace.enabled=false"
    if [ "${variant}" = "race" ]; then
        mkdir -p "${race_out_dir}"
        race_jvm_opts="-Drace.enabled=true \
-Drace.output.path=${race_out_dir} \
-Drace.run.id=${label}_${RUN_ID} \
-Drace.normal.to.pacing.threshold=0.20 \
-Drace.pacing.to.normal.threshold=0.13 \
-Drace.pacing.to.survival.threshold=0.26 \
-Drace.survival.to.pacing.threshold=0.19 \
-Drace.pacing.accept.ratio=0.35 \
-Drace.survival.accept.ratio=0.15 \
-Drace.sample.interval.ms=500 \
-Drace.enable.survival=true \
-Drace.mempool.normalization.size=4096"
    fi

    local java_opts="-Xms${HEAP} -Xmx${HEAP} \
-XX:+UseG1GC -XX:MaxGCPauseMillis=200 -XX:G1HeapWastePercent=5 \
-Xlog:gc*=info:file=${gc_log}:time,uptime,level,tags:filecount=5,filesize=100M \
-Dlog4j.configurationFile=${LOG4J_CONFIG} \
-Dlast.variant=DISABLED \
-Dlass.old.gen.activation.threshold=2.0 \
${race_jvm_opts}"
    export BESU_OPTS="${java_opts}"

    nohup "${BESU_BIN}" --genesis-file="${PWD}/clique_race_genesis.json" \
        --node-private-key-file="/home/yeochan.yoon/banning/clients/besu-lass-raac/benchmark/config/besu-keystore/key" \
        --miner-enabled \
        --miner-coinbase=0xc0A8e4D217eB85b812aeb1226fAb6F588943C2C2 \
        --data-path="${data_dir}" \
        --rpc-http-enabled --rpc-http-port=8545 \
        --rpc-http-host=0.0.0.0 --rpc-http-cors-origins="*" \
        --rpc-ws-enabled --rpc-ws-port=8546 \
        --rpc-ws-max-active-connections=200 \
        --host-allowlist="*" --min-gas-price=0 \
        --tx-pool-layer-max-capacity=67108864 \
        --tx-pool-max-prioritized=16384 \
        --tx-pool-max-future-by-sender=16384 \
        > "${run_dir}/besu_console.log" 2>&1 &
    local pid=$!; echo "  Besu PID: ${pid}"

    sleep 8
    if ! kill -0 ${pid} 2>/dev/null; then
        echo "failed=startup" > "${run_dir}/FAILED"; return 1
    fi
    wait_for_rpc || { stop_besu "${pid}"; echo "failed=rpc_timeout" > "${run_dir}/FAILED"; return 1; }

    python3 "${DEPLOY_BESU}" > "${run_dir}/deploy.log" 2>&1
    grep -q "Contract Address:" "${run_dir}/deploy.log" || {
        stop_besu "${pid}"; echo "failed=deploy" > "${run_dir}/FAILED"; return 1; }
    sleep 3

    echo "  Running Caliper (10→40→100 TPS staged, 120s total)..."
    timeout 600 npx caliper launch manager \
        --caliper-workspace ./ --caliper-benchconfig "${BENCHCONFIG}" \
        --caliper-networkconfig "${NETWORKCONFIG}" \
        > "${run_dir}/caliper_console.log" 2>&1 || true

    cp report.html "${run_dir}/report.html" 2>/dev/null || true
    truncate -s 0 caliper.log 2>/dev/null || true
    stop_besu "${pid}"; rm -rf "${data_dir}"
    unset BESU_OPTS

    # GC summary
    if [ -f "${gc_log}" ]; then
        full_count=$(grep -c "Pause Full" "${gc_log}" 2>/dev/null || echo 0)
        young_count=$(grep -c "Pause Young" "${gc_log}" 2>/dev/null || echo 0)
        echo "  GC: Young=${young_count} Full=${full_count}"
    fi

    # RACE summary
    if [ "${variant}" = "race" ]; then
        local metrics_csv
        metrics_csv=$(find "${race_out_dir}" -name "combined_metrics.csv" 2>/dev/null | head -1)
        if [ -f "${metrics_csv}" ]; then
            normal_samples=$(grep -c ",NORMAL," "${metrics_csv}" 2>/dev/null || echo 0)
            pacing_samples=$(grep -c ",PACING," "${metrics_csv}" 2>/dev/null || echo 0)
            survival_samples=$(grep -c ",SURVIVAL," "${metrics_csv}" 2>/dev/null || echo 0)
            echo "  RACE: NORMAL=${normal_samples} PACING=${pacing_samples} SURVIVAL=${survival_samples}"
            cp "${metrics_csv}" "${run_dir}/combined_metrics.csv" 2>/dev/null || true
        else
            echo "  RACE: no combined_metrics.csv found"
        fi
        find "${race_out_dir}" -name "mode_transitions.log" -exec cp {} "${run_dir}/" \; 2>/dev/null || true
    fi

    grep "| stage" "${run_dir}/caliper_console.log" | sed 's/^/  Caliper: /' || true
    echo "  ✓ ${label} complete"
}

# ── Provenance ────────────────────────────────────────────────────────────────
BESU_COMMIT=$(cd /home/yeochan.yoon/besu-source && git log --oneline -1 2>/dev/null || echo "unknown")
cat > "${RESULTS_DIR}/provenance.txt" <<EOF
RACE Besu Evaluation — besu-source / 1 GB / Clique 1s blocks / Flood 30→150→30 TPS
=====================================================================================
Run ID: ${RUN_ID} | Date: $(date) | Host: $(hostname)
Besu:     ${BESU_BIN} (${BESU_COMMIT})
Genesis:  clique_race_genesis.json (Clique 1s blocks, gasLimit=200M → ~50 TPS capacity)
Heap:     -Xmx1g
TxPool:   LAYERED pool (ESpill disabled), layer-max=64MB, max-prioritized=16384, normalization=4096
Load:     30 TPS 60s → 150 TPS 120s → 30 TPS 60s (stateBloat 200 slots, 3× capacity)
GasPrice: 1 gwei (1e9 wei) — above EIP-1559 baseFee growth throughout flood stage
Variants:
  baseline : RACE disabled (-Drace.enabled=false)
  race     : RACE enabled (-Drace.enabled=true, internal TxPool throttle)
RACE thresholds:
  NormalToPacing=0.20, PacingToNormal=0.13
  PacingToSurvival=0.26, SurvivalToPacing=0.19
  pacingAcceptRatio=0.35, survivalAcceptRatio=0.15
  sampleIntervalMs=500, mempoolNormalizationSize=4096
EOF

# ── Pre-flight ────────────────────────────────────────────────────────────────
pkill -9 -f "hyperledger.besu.Besu" 2>/dev/null || true
fuser -k 8545/tcp 8546/tcp 30303/tcp ${METRICS_PORT}/tcp 2>/dev/null || true
sleep 3

# ── Phase 1: Baseline ─────────────────────────────────────────────────────────
echo ""; echo "=============================="; echo "PHASE 1: ${REPLICATIONS}×BASELINE / BESU"; echo "=============================="
for i in $(seq 1 ${REPLICATIONS}); do
    run_besu_single "baseline" "${i}" || echo "  WARNING: baseline_besu_${i} failed"
    [ "${i}" -lt "${REPLICATIONS}" ] && sleep 30
done

# ── Phase 2: RACE ─────────────────────────────────────────────────────────────
echo ""; echo "=============================="; echo "PHASE 2: ${REPLICATIONS}×RACE / BESU"; echo "=============================="
for i in $(seq 1 ${REPLICATIONS}); do
    run_besu_single "race" "${i}" || echo "  WARNING: race_besu_${i} failed"
    [ "${i}" -lt "${REPLICATIONS}" ] && sleep 30
done

# ── Aggregate GC CSV ──────────────────────────────────────────────────────────
echo ""; echo "Aggregating results..."
python3 scripts/parse_besu_gc.py --results-dir "${RESULTS_DIR}" \
    --out-csv "${RESULTS_DIR}/gc_all.csv" \
    > "${RESULTS_DIR}/gc_summary.md" 2>/dev/null && \
    echo "GC summary → ${RESULTS_DIR}/gc_summary.md"

# ── Summary ───────────────────────────────────────────────────────────────────
python3 scripts/parse_race_results.py --results-dir "${RESULTS_DIR}" \
    > "${RESULTS_DIR}/race_summary.md" 2>/dev/null && \
    echo "RACE summary → ${RESULTS_DIR}/race_summary.md" || true

echo ""; echo "======================================================================"
echo "RACE Besu Evaluation complete. Results: ${RESULTS_DIR}"
echo "======================================================================"
