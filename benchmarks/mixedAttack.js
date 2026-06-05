'use strict';

/**
 * Mixed Attack Workload — RAAC Baseline
 * 90% "normal" txs: StateBloater.bloat(startIdx, 1)  — 1 SSTORE, low gas
 * 10% "attack" txs: StateBloater.bloat(startIdx, 200) — 200 SSTOREs, ~4 M gas
 *
 * No AI filtering. All txs reach the node.
 * Used as the baseline for RAAC evaluation.
 */

const { WorkloadModuleBase } = require('@hyperledger/caliper-core');
const fs = require('fs');
const path = require('path');

const ATTACK_RATIO = 0.30;   // 30% attack transactions
const NORMAL_SLOTS = 1;       // normal: 1 SSTORE
const ATTACK_SLOTS = 200;     // attack: 200 SSTOREs (~4M gas, within 8M gasLimit)

class MixedAttackWorkload extends WorkloadModuleBase {
    constructor() {
        super();
        this.txIndex = 0;
        this.contractId = null;
        this.normalCount = 0;
        this.attackCount = 0;
        this.logPath = null;
        this.logStream = null;
    }

    async initializeWorkloadModule(workerIndex, totalWorkers, numberProtocols, adapterConfig, blockchainConfig) {
        await super.initializeWorkloadModule(workerIndex, totalWorkers, numberProtocols, adapterConfig, blockchainConfig);

        const args = this.roundArguments || {};
        const numContracts = args.numContracts || 30;
        const prefix = args.contractPrefix || 'SB';
        this.contractId = `${prefix}${workerIndex % numContracts}`;

        // Optional sidecar log path: roundArguments.logDir or RAAC_LOG_DIR env var
        const logDir = args.logDir || process.env.RAAC_LOG_DIR || null;
        if (logDir) {
            const logFile = path.join(logDir, `worker${workerIndex}_baseline.jsonl`);
            this.logStream = fs.createWriteStream(logFile, { flags: 'a' });
        }

        console.log(`[MixedAttack/baseline] Worker ${workerIndex} → contract ${this.contractId}`);
    }

    async submitTransaction() {
        this.txIndex++;
        const isAttack = Math.random() < ATTACK_RATIO;
        const slots = isAttack ? ATTACK_SLOTS : NORMAL_SLOTS;

        const startIdx = (this.workerIndex * 10_000_000) + (this.txIndex * ATTACK_SLOTS);

        if (isAttack) this.attackCount++;
        else this.normalCount++;

        if (this.logStream) {
            this.logStream.write(JSON.stringify({
                worker: this.workerIndex, txIndex: this.txIndex,
                type: isAttack ? 'attack' : 'normal', slots,
                raac_mode: 'baseline', submitted: true,
            }) + '\n');
        }

        const request = {
            contract: this.contractId,
            verb: 'bloat',
            args: [startIdx, slots],
            readOnly: false,
        };

        await this.sutAdapter.sendRequests(request);
    }

    async cleanupWorkloadModule() {
        if (this.logStream) this.logStream.end();
        console.log(`[MixedAttack/baseline] Worker ${this.workerIndex} done: normal=${this.normalCount} attack=${this.attackCount}`);
    }
}

function createWorkloadModule() {
    return new MixedAttackWorkload();
}

module.exports.createWorkloadModule = createWorkloadModule;
