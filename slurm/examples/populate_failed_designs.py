#!/usr/bin/env python3
"""Append missing/bad-QoF designs to failed_designs.txt for given archive runs.

Usage:
    python3 slurm/examples/populate_failed_designs.py <run1> [<run2> ...]
        [--archive /path/to/tech-subdir]

Each run's reports/ dir is scanned for JSON files where QOFRSummary is absent
or has null total_area/latency_cycles. Matching stems are appended to
ARCHIVE/failed_designs.txt in the format:  run_name<TAB>stem

Already-present entries are skipped (idempotent).

--archive defaults to the nangate45 subdir; pass the gf22fdx subdir for GF22nm runs.
"""

import json
import os
import glob
import sys

ARCHIVE_BASE = '/global/cfs/cdirs/amsc011/shared/wa-hls4ml-catapult'
DEFAULT_ARCHIVE = os.path.join(ARCHIVE_BASE, 'nangate45')


def bad_report(path):
    try:
        with open(path) as f:
            d = json.load(f)
        q = d.get('QOFRSummary', {})
        return not q or q.get('total_area') is None or q.get('latency_cycles') is None
    except Exception:
        return True


def main():
    args = sys.argv[1:]
    archive = DEFAULT_ARCHIVE
    runs = []
    i = 0
    while i < len(args):
        if args[i] == '--archive' and i + 1 < len(args):
            archive = args[i + 1]
            i += 2
        elif args[i].startswith('--archive='):
            archive = args[i].split('=', 1)[1]
            i += 1
        else:
            runs.append(args[i])
            i += 1

    if not runs:
        print(__doc__)
        sys.exit(1)

    failed_file = os.path.join(archive, 'failed_designs.txt')

    # Load existing entries
    existing = set()
    if os.path.exists(failed_file):
        with open(failed_file) as f:
            for line in f:
                line = line.strip()
                if line:
                    existing.add(line)

    new_entries = []
    for run in runs:
        rdir = os.path.join(archive, run, 'reports')
        if not os.path.isdir(rdir):
            print(f'WARNING: {rdir} not found — skipping', file=sys.stderr)
            continue
        files = sorted(glob.glob(os.path.join(rdir, '*.json')))
        bad = [os.path.splitext(os.path.basename(f))[0] for f in files if bad_report(f)]
        added = 0
        for stem in bad:
            entry = f'{run}\t{stem}'
            if entry not in existing:
                new_entries.append(entry)
                existing.add(entry)
                added += 1
        print(f'{run}: {len(bad)} bad reports, {added} new entries added')

    if new_entries:
        with open(failed_file, 'a') as f:
            for entry in new_entries:
                f.write(entry + '\n')
        print(f'\nAppended {len(new_entries)} entries to {failed_file}')
    else:
        print('\nNothing new to add.')


if __name__ == '__main__':
    main()
