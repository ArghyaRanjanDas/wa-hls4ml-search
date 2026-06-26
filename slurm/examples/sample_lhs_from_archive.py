#!/usr/bin/env python3
"""Latin Hypercube Sampling of multi-layer designs from the 45nm nangate archive.

Scans RF=1 reports for the requested layer count, builds a normalised feature
vector per design, then uses LHS to select N representative designs.
Output: a candidates file of   run_name<TAB>stem   lines.

Usage:
    python3 slurm/examples/sample_lhs_from_archive.py \
        --layers 2 --n 5000 \
        [--seed 42] [--dry-run] \
        [--archive /path/to/nangate45] \
        [--out /path/to/candidates.txt]
"""

import argparse
import glob
import json
import math
import os
import re
import sys
from pathlib import Path

ARCHIVE_DEFAULT = "/global/cfs/cdirs/amsc011/shared/wa-hls4ml-catapult/nangate45"
OUT_TEMPLATE    = "/global/cfs/cdirs/amsc011/shared/wa-hls4ml-catapult/gf22fdx/gf22_lhs_{layers}layer_{n}.txt"

_ACT_ENC = {"relu": 0.0, "sigmoid": 0.5, "tanh": 1.0}
_ACT_CLS = {"relu", "sigmoid", "tanh", "HardActivation"}


def _parse_bitwidth(s):
    m = re.search(r"ac_fixed<(\d+)", s or "")
    return int(m.group(1)) if m else None


def _parse_shape(s):
    m = re.search(r"\[(\d+)\]", s or "")
    return int(m.group(1)) if m else None


def _activation_name(layer):
    cls = layer.get("Layer Class", "")
    if cls in ("relu", "sigmoid", "tanh"):
        return cls
    if cls == "HardActivation":
        # quantized sigmoid: integer width == 0; tanh: integer width >= 1
        m = re.search(r"ac_fixed<\d+,(\d+),", layer.get("Output Type", ""))
        if m:
            return "sigmoid" if int(m.group(1)) == 0 else "tanh"
    return "other"


def _norm_size(s):
    return math.log2(max(s, 1)) / math.log2(64)  # sizes in {4,8,16,32,64} → [0.33, 1.0]


def _norm_bw(b):
    return (b - 4) / 10  # bitwidths in {4,6,8,10,12,14} → [0.0, 1.0]


def extract_record(path, n_layers):
    """Return (feature_vector, run_name, stem) or None if invalid / wrong RF."""
    try:
        with open(path) as f:
            report = json.load(f)
    except Exception:
        return None

    layer_summary = report.get("LayerSummary", [])
    dense = [l for l in layer_summary if l.get("Layer Class") == "Dense"]
    if len(dense) != n_layers:
        return None

    rf = int(dense[0].get("Reuse", 1))
    if rf != 1:
        return None

    qofr = report.get("QOFRSummary", {})
    if not qofr or qofr.get("total_area") is None or qofr.get("latency_cycles") is None:
        return None

    bw = _parse_bitwidth(dense[0].get("Weight Type", ""))
    if bw is None:
        return None

    input_sz  = _parse_shape(dense[0].get("Input Shape", ""))
    layer_szs = [_parse_shape(d.get("Output Shape", "")) for d in dense]
    act_layers = [l for l in layer_summary if l.get("Layer Class") in _ACT_CLS]
    acts = [_activation_name(al) for al in act_layers[:n_layers]]

    if input_sz is None or any(s is None for s in layer_szs) or len(acts) < n_layers:
        return None

    # Feature vector: 1 + n_layers sizes (log2-normalised) + bitwidth + n_layers activations
    feat = [_norm_size(input_sz)]
    for sz in layer_szs:
        feat.append(_norm_size(sz))
    feat.append(_norm_bw(bw))
    for a in acts[:n_layers]:
        feat.append(_ACT_ENC.get(a, 0.25))

    parts = Path(path).parts
    run_name = parts[-3]  # .../run_NAME/reports/stem.json
    stem = Path(path).stem
    return feat, run_name, stem


def main():
    p = argparse.ArgumentParser(description=__doc__,
                                formatter_class=argparse.RawDescriptionHelpFormatter)
    p.add_argument("--layers",   type=int, default=2, choices=[2, 3],
                   help="number of dense layers to sample (default: 2)")
    p.add_argument("--n",        type=int, default=5000,
                   help="number of designs to select (default: 5000)")
    p.add_argument("--seed",     type=int, default=42)
    p.add_argument("--dry-run",  action="store_true",
                   help="print coverage stats without writing output file")
    p.add_argument("--archive",  default=ARCHIVE_DEFAULT,
                   help="path to nangate45 archive subdir")
    p.add_argument("--out",      default=None,
                   help="output candidates file (default: derived from --layers/--n)")
    p.add_argument("--exclude",  default=None,
                   help="candidates file from a previous pass; those designs are removed from the pool before sampling")
    args = p.parse_args()

    out_path = args.out or OUT_TEMPLATE.format(layers=args.layers, n=args.n)

    # ── Scan reports ──────────────────────────────────────────────────────────
    layer_dir = os.path.join(args.archive, f"mlp-{args.layers}layer")
    if not os.path.isdir(layer_dir):
        print(f"WARNING: {layer_dir} not found — falling back to flat scan of {args.archive}",
              file=sys.stderr)
        layer_dir = args.archive

    pattern = os.path.join(layer_dir, "*/reports/*.json")
    all_jsons = sorted(glob.glob(pattern))
    print(f"Scanning {len(all_jsons)} report files in {layer_dir} ...")

    records = []
    skipped = 0
    for path in all_jsons:
        rec = extract_record(path, args.layers)
        if rec is None:
            skipped += 1
        else:
            records.append(rec)

    print(f"  Valid RF=1 {args.layers}-layer designs: {len(records)}  ({skipped} skipped/wrong-RF)")

    # ── Exclude previously sampled designs ───────────────────────────────────
    if args.exclude:
        if not os.path.exists(args.exclude):
            print(f"WARNING: --exclude file not found, skipping: {args.exclude}", file=sys.stderr)
            args.exclude = None
    if args.exclude:
        excluded = set()
        with open(args.exclude) as f:
            for line in f:
                line = line.strip()
                if line:
                    run_name, stem = line.split('\t', 1)
                    excluded.add((run_name, stem))
        before = len(records)
        records = [r for r in records if (r[1], r[2]) not in excluded]
        print(f"  Excluded {before - len(records)} designs from {args.exclude}  "
              f"({len(records)} remaining in pool)")

    if not records:
        print("ERROR: no valid designs found", file=sys.stderr)
        sys.exit(1)

    # ── Coverage stats (always printed) ──────────────────────────────────────
    import collections
    bw_counts = collections.Counter()
    sz_counts = collections.Counter()
    act_counts = collections.Counter()
    for feat, run_name, stem in records:
        # Recover discrete values from normalised features
        n = args.layers
        bw = round(feat[n + 1] * 10 + 4)
        bw_counts[bw] += 1
        for i in range(1, n + 1):
            sz = round(2 ** (feat[i] * math.log2(64)))
            sz_counts[sz] += 1
        for i in range(n + 2, n + 2 + n):
            enc = feat[i]
            act = {0.0: "relu", 0.5: "sigmoid", 1.0: "tanh"}.get(enc, "other")
            act_counts[act] += 1
    print(f"  Bitwidths:   {dict(sorted(bw_counts.items()))}")
    print(f"  Layer sizes: {dict(sorted(sz_counts.items()))}")
    print(f"  Activations: {dict(sorted(act_counts.items()))}")

    # ── LHS sampling ─────────────────────────────────────────────────────────
    if args.n >= len(records):
        print(f"  N={args.n} >= pool ({len(records)}) — selecting all designs")
        selected = [(rn, s) for _, rn, s in records]
    else:
        try:
            from scipy.stats.qmc import LatinHypercube
            from scipy.spatial import KDTree
            import numpy as np
        except ImportError:
            print("ERROR: scipy not available (need scipy >= 1.7)", file=sys.stderr)
            sys.exit(1)

        feats = np.array([f for f, _, _ in records])
        tree  = KDTree(feats)

        sampler  = LatinHypercube(d=feats.shape[1], seed=args.seed)
        lhs_pts  = sampler.random(n=args.n)
        _, idxs  = tree.query(lhs_pts)

        seen = set()
        unique_idxs = []
        for i in idxs:
            if i not in seen:
                seen.add(i)
                unique_idxs.append(i)

        selected = [(records[i][1], records[i][2]) for i in unique_idxs]
        print(f"  LHS selected {len(selected)} unique designs "
              f"({args.n - len(selected)} duplicates collapsed)")

    if args.dry_run:
        print(f"\nDry run — would write {len(selected)} entries to {out_path}")
        return

    os.makedirs(os.path.dirname(os.path.abspath(out_path)), exist_ok=True)
    with open(out_path, "w") as f:
        for run_name, stem in selected:
            f.write(f"{run_name}\t{stem}\n")
    print(f"\nWrote {len(selected)} candidates → {out_path}")


if __name__ == "__main__":
    main()
