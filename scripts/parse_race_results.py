#!/usr/bin/env python3
"""
RACE Results Parser
Parses a race_nm_eval or race_besu_eval results directory and outputs a
Markdown summary with:
  - Per-run GC stats table (NM: gc_events.csv; Besu: gc_besu.log)
  - Variant comparison: baseline vs RACE (GC reduction, mode fractions)
  - Per-stage Caliper TPS from caliper_console.log

Usage:
  python3 parse_race_results.py --results-dir results/race_nm_eval/<RUN_ID>
  python3 parse_race_results.py --results-dir results/race_besu_eval/<RUN_ID>
"""

import argparse
import csv
import glob
import json
import os
import re
import sys
from collections import defaultdict
from statistics import median, mean, stdev

# ── GC parsers ────────────────────────────────────────────────────────────────

def parse_nm_gc(gc_csv):
    """Parse gc_events.csv from NettraceGcParser. Returns list of pause_ms floats."""
    pauses = []
    try:
        with open(gc_csv) as f:
            reader = csv.DictReader(f)
            for row in reader:
                for key in ('pause_ms', 'PauseMs', 'duration_ms', 'DurationMs'):
                    if key in row:
                        try:
                            pauses.append(float(row[key]))
                        except ValueError:
                            pass
                        break
    except Exception:
        pass
    return pauses


_PAUSE_RE = re.compile(
    r'\[gc\s+\]\s+GC\(\d+\)\s+Pause\s+(Young|Mixed|Full|Remark|Cleanup)'
    r'[^\d]*?([\d]+\.[\d]+)ms'
)

def parse_besu_gc(gc_log):
    """Parse Besu G1GC log. Returns (all_pauses, full_pauses) lists of ms floats."""
    all_pauses, full_pauses = [], []
    try:
        with open(gc_log) as f:
            for line in f:
                m = _PAUSE_RE.search(line)
                if m:
                    gc_type, ms_str = m.group(1), m.group(2)
                    ms = float(ms_str)
                    all_pauses.append(ms)
                    if gc_type == 'Full':
                        full_pauses.append(ms)
    except Exception:
        pass
    return all_pauses, full_pauses


# ── RACE metrics parsers ──────────────────────────────────────────────────────

def parse_combined_metrics(csv_path):
    """Parse NM combined_metrics.csv. Returns mode counts dict."""
    counts = {'NORMAL': 0, 'PACING': 0, 'SURVIVAL': 0}
    rpis = []
    try:
        with open(csv_path) as f:
            reader = csv.DictReader(f)
            mode_col = None
            rpi_col = None
            for row in reader:
                if mode_col is None:
                    for c in row:
                        if 'mode' in c.lower() and 'prev' not in c.lower():
                            mode_col = c
                        if c.lower() in ('rpi', 'normalized_rpi', 'rpi_value'):
                            rpi_col = c
                mode = row.get(mode_col, '').strip().upper()
                if mode in counts:
                    counts[mode] += 1
                if rpi_col:
                    try:
                        rpis.append(float(row[rpi_col]))
                    except ValueError:
                        pass
    except Exception:
        pass
    return counts, rpis


def parse_besu_rpi_jsonl(jsonl_dir):
    """Parse race_besu_rpi.jsonl files from a run's race_logs dir."""
    counts = {'NORMAL': 0, 'PACING': 0, 'SURVIVAL': 0}
    rpis = []
    for f in glob.glob(os.path.join(jsonl_dir, '*.jsonl')):
        try:
            with open(f) as fh:
                for line in fh:
                    try:
                        obj = json.loads(line)
                        mode = obj.get('mode', 'NORMAL').upper()
                        if mode in counts:
                            counts[mode] += 1
                        rpi = obj.get('rpi')
                        if rpi is not None:
                            rpis.append(float(rpi))
                    except (json.JSONDecodeError, ValueError):
                        pass
        except Exception:
            pass
    return counts, rpis


# ── Caliper TPS parser ────────────────────────────────────────────────────────

_STAGE_RE = re.compile(r'\|\s*(stage\w*)\s*\|.*?(\d+\.?\d*)\s*TPS', re.IGNORECASE)

def parse_caliper_tps(caliper_log):
    """Extract per-stage confirmed TPS from caliper_console.log."""
    stages = {}
    try:
        with open(caliper_log) as f:
            for line in f:
                m = _STAGE_RE.search(line)
                if m:
                    stages[m.group(1)] = float(m.group(2))
    except Exception:
        pass
    return stages


# ── Run discovery ─────────────────────────────────────────────────────────────

def discover_runs(results_dir):
    """Detect client type and collect run metadata."""
    runs = []
    for entry in sorted(os.listdir(results_dir)):
        d = os.path.join(results_dir, entry)
        if not os.path.isdir(d):
            continue
        m = re.match(r'^(baseline|race)_(nm|besu)_(\d+)$', entry)
        if not m:
            continue
        variant, client, rep = m.group(1), m.group(2), int(m.group(3))
        run = {
            'label': entry, 'variant': variant, 'client': client, 'rep': rep,
            'dir': d,
            'failed': os.path.exists(os.path.join(d, 'FAILED')),
        }
        runs.append(run)
    return runs


def collect_run_stats(run):
    d = run['dir']
    client = run['client']
    stats = {}

    # GC
    if client == 'nm':
        gc_csv = os.path.join(d, 'gc_events.csv')
        pauses = parse_nm_gc(gc_csv)
        full_pauses = [p for p in pauses if p > 500]  # rough full GC threshold
        stats['gc_pauses'] = pauses
        stats['full_gc_count'] = len(full_pauses)
    else:
        gc_log = os.path.join(d, 'gc_besu.log')
        pauses, full_pauses = parse_besu_gc(gc_log)
        stats['gc_pauses'] = pauses
        stats['full_gc_count'] = len(full_pauses)

    if stats['gc_pauses']:
        stats['gc_mean_ms'] = mean(stats['gc_pauses'])
        stats['gc_median_ms'] = median(stats['gc_pauses'])
        stats['gc_p99_ms'] = sorted(stats['gc_pauses'])[int(len(stats['gc_pauses']) * 0.99)]
        stats['gc_total_s'] = sum(stats['gc_pauses']) / 1000.0
        stats['gc_count'] = len(stats['gc_pauses'])
    else:
        stats.update({'gc_mean_ms': 0, 'gc_median_ms': 0, 'gc_p99_ms': 0,
                      'gc_total_s': 0, 'gc_count': 0})

    # RACE metrics
    mode_counts = {'NORMAL': 0, 'PACING': 0, 'SURVIVAL': 0}
    rpis = []
    if run['variant'] == 'race':
        if client == 'nm':
            cm = os.path.join(d, 'combined_metrics.csv')
            if os.path.exists(cm):
                mode_counts, rpis = parse_combined_metrics(cm)
        else:
            cm = os.path.join(d, 'combined_metrics.csv')
            race_logs = os.path.join(d, 'race_logs')
            if os.path.exists(cm):
                mode_counts, rpis = parse_combined_metrics(cm)
            elif os.path.isdir(race_logs):
                mode_counts, rpis = parse_besu_rpi_jsonl(race_logs)
    stats['mode_counts'] = mode_counts
    stats['rpi_mean'] = mean(rpis) if rpis else 0.0

    # Caliper TPS
    stats['stages'] = parse_caliper_tps(os.path.join(d, 'caliper_console.log'))

    return stats


# ── Markdown output ───────────────────────────────────────────────────────────

def fmt(v, precision=1):
    if isinstance(v, float):
        return f'{v:.{precision}f}'
    return str(v)


def print_run_table(runs, all_stats):
    print('## Per-run GC Summary\n')
    print('| Label | GC Count | Full GCs | Mean (ms) | P99 (ms) | Total GC (s) |')
    print('|-------|----------|----------|-----------|----------|--------------|')
    for run in runs:
        s = all_stats[run['label']]
        status = ' ❌' if run['failed'] else ''
        print(f"| {run['label']}{status} | {s['gc_count']} | {s['full_gc_count']} | "
              f"{fmt(s['gc_mean_ms'])} | {fmt(s['gc_p99_ms'])} | {fmt(s['gc_total_s'], 2)} |")
    print()


def print_variant_comparison(runs, all_stats):
    print('## Baseline vs RACE Comparison\n')
    clients = sorted(set(r['client'] for r in runs))
    for client in clients:
        print(f'### {client.upper()}\n')
        for variant in ('baseline', 'race'):
            variant_runs = [r for r in runs if r['variant'] == variant and r['client'] == client
                            and not r['failed']]
            if not variant_runs:
                continue
            gc_totals = [all_stats[r['label']]['gc_total_s'] for r in variant_runs]
            full_gcs = [all_stats[r['label']]['full_gc_count'] for r in variant_runs]
            means_ms = [all_stats[r['label']]['gc_mean_ms'] for r in variant_runs]
            n = len(variant_runs)
            print(f'**{variant}** (n={n})')
            print(f'- Total GC time: mean={mean(gc_totals):.2f}s, '
                  f'std={stdev(gc_totals):.2f}s' if n > 1 else
                  f'- Total GC time: {gc_totals[0]:.2f}s')
            print(f'- Full GC count: mean={mean(full_gcs):.1f}')
            print(f'- Mean pause:    {mean(means_ms):.1f} ms')
            print()

        # Reduction
        b_runs = [r for r in runs if r['variant'] == 'baseline' and r['client'] == client
                  and not r['failed']]
        r_runs = [r for r in runs if r['variant'] == 'race' and r['client'] == client
                  and not r['failed']]
        if b_runs and r_runs:
            b_total = mean([all_stats[r['label']]['gc_total_s'] for r in b_runs])
            r_total = mean([all_stats[r['label']]['gc_total_s'] for r in r_runs])
            reduction = (b_total - r_total) / b_total * 100 if b_total > 0 else 0
            b_full = mean([all_stats[r['label']]['full_gc_count'] for r in b_runs])
            r_full = mean([all_stats[r['label']]['full_gc_count'] for r in r_runs])
            full_red = (b_full - r_full) / b_full * 100 if b_full > 0 else 0
            print(f'**RACE reduction**: Total GC time −{reduction:.1f}%, Full GC count −{full_red:.1f}%\n')


def print_mode_table(runs, all_stats):
    race_runs = [r for r in runs if r['variant'] == 'race' and not r['failed']]
    if not race_runs:
        return
    print('## RACE Mode Fractions\n')
    print('| Label | NORMAL | PACING | SURVIVAL | RPI_mean |')
    print('|-------|--------|--------|----------|----------|')
    for run in race_runs:
        s = all_stats[run['label']]
        mc = s['mode_counts']
        total = sum(mc.values()) or 1
        n_pct = mc['NORMAL'] / total * 100
        p_pct = mc['PACING'] / total * 100
        sv_pct = mc['SURVIVAL'] / total * 100
        print(f"| {run['label']} | {n_pct:.0f}% | {p_pct:.0f}% | {sv_pct:.0f}% | "
              f"{s['rpi_mean']:.3f} |")
    print()


def print_tps_table(runs, all_stats):
    sample = next((r for r in runs if all_stats[r['label']]['stages']), None)
    if not sample:
        return
    stage_keys = sorted(all_stats[sample['label']]['stages'].keys())
    if not stage_keys:
        return
    print('## Per-Stage Caliper TPS\n')
    header = '| Label | ' + ' | '.join(stage_keys) + ' |'
    sep = '|-------|' + '--------|' * len(stage_keys)
    print(header); print(sep)
    for run in runs:
        s = all_stats[run['label']]
        cells = [fmt(s['stages'].get(k, 0)) for k in stage_keys]
        print(f"| {run['label']} | {' | '.join(cells)} |")
    print()


# ── Main ──────────────────────────────────────────────────────────────────────

def main():
    ap = argparse.ArgumentParser()
    ap.add_argument('--results-dir', required=True)
    args = ap.parse_args()

    runs = discover_runs(args.results_dir)
    if not runs:
        print(f'No runs found in {args.results_dir}', file=sys.stderr)
        sys.exit(0)

    all_stats = {}
    for run in runs:
        all_stats[run['label']] = collect_run_stats(run)

    run_id = os.path.basename(args.results_dir)
    print(f'# RACE Evaluation Results\n')
    print(f'**Run ID**: `{run_id}`  ')
    print(f'**Runs found**: {len(runs)} ({sum(1 for r in runs if r["failed"])} failed)\n')

    print_run_table(runs, all_stats)
    print_variant_comparison(runs, all_stats)
    print_mode_table(runs, all_stats)
    print_tps_table(runs, all_stats)


if __name__ == '__main__':
    main()
