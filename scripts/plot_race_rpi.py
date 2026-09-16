#!/usr/bin/env python3
"""
RACE visualization: RPI time-series with NORMAL/PACING/SURVIVAL mode bands.

Usage:
  python3 scripts/plot_race_rpi.py \
    --results-dir results/race_nm_eval/<RUN_ID>/ \
    --out-prefix figures/race

Produces:
  figures/race_rpi_time_series.pdf   — per-rep RPI overlaid with mode shading
  figures/race_mode_summary.pdf      — stacked bar: fraction of time in each mode
"""
import argparse
import sys
from pathlib import Path

import numpy as np

try:
    import matplotlib
    matplotlib.use('Agg')
    import matplotlib.pyplot as plt
    import matplotlib.patches as mpatches
    import matplotlib.ticker as mticker
except ImportError:
    print('matplotlib not found: pip install matplotlib', file=sys.stderr)
    sys.exit(1)

try:
    import pandas as pd
except ImportError:
    print('pandas not found: pip install pandas', file=sys.stderr)
    sys.exit(1)

MODE_COLORS = {
    'NORMAL':   '#2166ac',
    'PACING':   '#f1a340',
    'SURVIVAL': '#d73027',
}
STAGE_COLORS = ['#eff3ff', '#bdd7e7', '#6baed6']
STAGE_LABELS = ['Stage 1 (10 TPS, 30s)', 'Stage 2 (40 TPS, 30s)', 'Stage 3 (100 TPS, 60s)']
STAGE_BOUNDARIES = [0, 30, 60, 120]  # seconds from run start


def load_combined_metrics(path: Path):
    if not path.exists():
        return None
    df = pd.read_csv(path)
    if 'timestamp' not in df.columns:
        return None
    df['timestamp'] = pd.to_datetime(df['timestamp'], utc=True, errors='coerce')
    df = df.dropna(subset=['timestamp']).sort_values('timestamp')
    t0 = df['timestamp'].iloc[0]
    df['elapsed_s'] = (df['timestamp'] - t0).dt.total_seconds()
    return df


def find_race_dirs(results_dir: Path):
    race_dirs = []
    for run_dir in sorted(results_dir.iterdir()):
        if not run_dir.is_dir():
            continue
        for race_run in sorted(run_dir.glob('race_out/run_*/combined_metrics.csv')):
            race_dirs.append((run_dir.name, race_run))
        for race_run in sorted(run_dir.glob('combined_metrics.csv')):
            race_dirs.append((run_dir.name, race_run))
    return race_dirs


def plot_rpi_timeseries(results_dir: Path, out_prefix: Path):
    race_dirs = find_race_dirs(results_dir)
    if not race_dirs:
        print('No combined_metrics.csv found.', file=sys.stderr)
        return

    n = len(race_dirs)
    ncols = min(n, 3)
    nrows = (n + ncols - 1) // ncols
    fig, axes = plt.subplots(nrows, ncols, figsize=(5 * ncols, 3.5 * nrows), squeeze=False)

    for idx, (run_name, metrics_path) in enumerate(race_dirs):
        ax = axes[idx // ncols][idx % ncols]
        df = load_combined_metrics(metrics_path)
        if df is None or df.empty:
            ax.set_visible(False)
            continue

        # Stage background shading
        for si, (t_start, t_end) in enumerate(zip(STAGE_BOUNDARIES[:-1], STAGE_BOUNDARIES[1:])):
            ax.axvspan(t_start, t_end, color=STAGE_COLORS[si], alpha=0.4, zorder=0)

        # Mode transition shading
        if 'current_mode' in df.columns:
            prev_mode = df['current_mode'].iloc[0]
            t_start_mode = df['elapsed_s'].iloc[0]
            for _, row in df.iterrows():
                if row['current_mode'] != prev_mode:
                    ax.axvspan(t_start_mode, row['elapsed_s'],
                               color=MODE_COLORS.get(prev_mode, '#888888'), alpha=0.15, zorder=1)
                    t_start_mode = row['elapsed_s']
                    prev_mode = row['current_mode']
            ax.axvspan(t_start_mode, df['elapsed_s'].iloc[-1],
                       color=MODE_COLORS.get(prev_mode, '#888888'), alpha=0.15, zorder=1)

        # RPI line
        if 'RPI' in df.columns:
            ax.plot(df['elapsed_s'], df['RPI'], color='black', linewidth=1.0, zorder=3, label='RPI')
            ax.axhline(0.60, color='#f1a340', linestyle='--', linewidth=0.8,
                       label='NormalToPacing=0.60', zorder=2)
            ax.axhline(0.85, color='#d73027', linestyle=':', linewidth=0.8,
                       label='PacingToSurvival=0.85', zorder=2)

        ax.set_ylim(0, 1.05)
        ax.set_xlabel('Elapsed (s)', fontsize=9)
        ax.set_ylabel('RPI', fontsize=9)
        ax.set_title(run_name, fontsize=9)
        ax.grid(True, alpha=0.25)

        if idx == 0:
            ax.legend(fontsize=7, loc='upper left')

    # Hide unused subplots
    for idx in range(n, nrows * ncols):
        axes[idx // ncols][idx % ncols].set_visible(False)

    # Legend for mode colors
    mode_patches = [mpatches.Patch(color=c, alpha=0.5, label=m)
                    for m, c in MODE_COLORS.items()]
    stage_patches = [mpatches.Patch(color=STAGE_COLORS[i], alpha=0.5, label=STAGE_LABELS[i])
                     for i in range(3)]
    fig.legend(handles=mode_patches + stage_patches,
               loc='lower center', ncol=3, fontsize=8, bbox_to_anchor=(0.5, -0.02))

    fig.suptitle('RACE: RPI Time-Series with Mode Transitions\n(NM, 1 GB, 10→40→100 TPS staged)',
                 fontsize=11, y=1.01)
    fig.tight_layout()
    out = out_prefix.parent / (out_prefix.name + '_rpi_time_series.pdf')
    out.parent.mkdir(parents=True, exist_ok=True)
    fig.savefig(out, bbox_inches='tight')
    plt.close(fig)
    print(f'RPI time-series: {out}')


def plot_mode_summary(results_dir: Path, out_prefix: Path):
    race_dirs = find_race_dirs(results_dir)
    if not race_dirs:
        return

    data = []
    for run_name, metrics_path in race_dirs:
        df = load_combined_metrics(metrics_path)
        if df is None or df.empty or 'current_mode' not in df.columns:
            continue
        variant = 'race' if 'race' in run_name else 'baseline'
        total = len(df)
        for mode in ('NORMAL', 'PACING', 'SURVIVAL'):
            frac = (df['current_mode'] == mode).sum() / total if total > 0 else 0
            data.append(dict(run=run_name, variant=variant, mode=mode, fraction=frac))

    if not data:
        return

    df_mode = pd.DataFrame(data)
    runs = df_mode['run'].unique()
    bottoms = np.zeros(len(runs))

    fig, ax = plt.subplots(figsize=(max(4, len(runs) * 0.9), 4))
    for mode, color in MODE_COLORS.items():
        fracs = [df_mode[(df_mode['run'] == r) & (df_mode['mode'] == mode)]['fraction'].sum()
                 for r in runs]
        ax.bar(range(len(runs)), fracs, bottom=bottoms, color=color, label=mode, alpha=0.85)
        bottoms += np.array(fracs)

    ax.set_xticks(range(len(runs)))
    ax.set_xticklabels(runs, rotation=45, ha='right', fontsize=8)
    ax.set_ylabel('Fraction of samples', fontsize=10)
    ax.set_title('RACE: Time Fraction per Flow Control Mode', fontsize=10)
    ax.set_ylim(0, 1)
    ax.legend(fontsize=9, loc='upper right')
    ax.grid(True, axis='y', alpha=0.3)
    fig.tight_layout()

    out = out_prefix.parent / (out_prefix.name + '_mode_summary.pdf')
    out.parent.mkdir(parents=True, exist_ok=True)
    fig.savefig(out, bbox_inches='tight')
    plt.close(fig)
    print(f'Mode summary: {out}')


def main():
    ap = argparse.ArgumentParser()
    ap.add_argument('--results-dir', required=True)
    ap.add_argument('--out-prefix', default='figures/race')
    args = ap.parse_args()

    results_dir = Path(args.results_dir)
    out_prefix = Path(args.out_prefix)

    plot_rpi_timeseries(results_dir, out_prefix)
    plot_mode_summary(results_dir, out_prefix)


if __name__ == '__main__':
    main()
