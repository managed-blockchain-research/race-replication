'use strict';

const { WorkloadModuleBase } = require('@hyperledger/caliper-core');

class StateBloaterWorkload extends WorkloadModuleBase {
    constructor() {
        super();
        this.txIndex = 0;
        this.contractId = null;
    }

    async initializeWorkloadModule(workerIndex, totalWorkers, numberProtocols, adapterConfig, blockchainConfig) {
        await super.initializeWorkloadModule(workerIndex, totalWorkers, numberProtocols, adapterConfig, blockchainConfig);
        if (this.roundArguments) {
            this.workerArguments = this.roundArguments;
        }

        const args = this.workerArguments || { slotsPerTx: 50, numContracts: 1, contractPrefix: 'SB' };
        const numContracts = args.numContracts || 1;
        const prefix = args.contractPrefix || 'SB';

        this.numContracts = numContracts;
        this.contractPrefix = prefix;
        this.moduleStartMs = Date.now();
        console.log(`Worker ${workerIndex} → cycling ${numContracts} contracts`);
    }

    async submitTransaction() {
        this.txIndex++;
        const args = this.workerArguments || { slotsPerTx: 50 };
        const slotsPerTx = args.slotsPerTx || 50;
        const slotCycleSize = args.slotCycleSize || 0;
        const contractIndex = (this.txIndex - 1) % this.numContracts;
        const contractId = `${this.contractPrefix}${contractIndex}`;
        // Per-contract cycling: each contract owns slot range [0..slotCycleSize-1]
        // txsForThisContract counts how many times this worker has touched this contract
        // → same slots repeat after slotCycleSize/slotsPerTx rounds → warm re-accesses
        // → LAST-AL grouping keeps trie nodes hot → fewer RocksDB reloads → less CLR GC
        const txsForThisContract = Math.floor((this.txIndex - 1) / this.numContracts);
        const startIdx = slotCycleSize > 0
            ? (txsForThisContract * slotsPerTx) % slotCycleSize
            : (this.workerIndex * 1000000) + (this.txIndex * slotsPerTx);

        // Uniform gasPrice across every tx lets the TxPool's "compete" eviction
        // deadlock: once full, a same-priced newcomer can never legitimately evict an
        // already-pooled entry (tie loses), so the pool locks up permanently under
        // sustained load -- exactly the mempool-filling scenario RACE's flood stage is
        // designed to trigger (30->150->30 TPS, 3x capacity). Bumping the price by
        // elapsed wall-clock ms (+ a small per-worker offset to break ties between
        // workers in the same millisecond) makes newer transactions always outbid
        // older pooled ones, so the pool churns instead of freezing -- same fix as
        // stateBloatVariedFee.js, ported here so RACE's baseline/race arms share
        // identical, tie-lock-free load.
        const BASE_GAS_PRICE = 1000000000;
        const elapsedMs = Date.now() - this.moduleStartMs;
        const gasPrice = BASE_GAS_PRICE + elapsedMs + this.workerIndex;

        const request = {
            contract: contractId,
            verb: 'bloat',
            args: [startIdx, slotsPerTx],
            readOnly: false,
            gasPrice
        };

        await this.sutAdapter.sendRequests(request);
    }
}

function createWorkloadModule() {
    return new StateBloaterWorkload();
}

module.exports.createWorkloadModule = createWorkloadModule;
