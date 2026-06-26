# -*- coding: utf-8 -*-
"""
Design space coverage metrics for the wa-hls4ml Catapult archive.

Computes fill distance and separation distance per axis (linear and log2),
then a normalized L-inf multi-dimensional fill distance across all continuous axes.

Reference bounds: sizes [4,64], bitwidths (even) [4,14], RF [1,16].
"""

import numpy as np

# ── Grids ────────────────────────────────────────────────────────────────────

GRIDS = {
    "1-layer": {
        "sizes":     np.array([4, 8, 16, 32, 64]),
        "bitwidths": np.array([4, 6, 8, 10, 12, 14]),
        "rf":        np.array([1, 4, 8, 16]),
    },
    "2-layer": {
        "sizes":     np.array([4, 8, 16, 32, 64]),
        "bitwidths": np.array([4, 6, 8, 10, 12, 14]),
        "rf":        np.array([1, 4, 8, 16]),
    },
    "3-layer": {
        "sizes":     np.array([4, 8, 16]),
        "bitwidths": np.array([4, 6, 8, 10, 12, 14]),
        "rf":        np.array([1, 4, 8, 16]),
    },
}

# Full-space bounds (reference)
BOUNDS = {
    "sizes":     (4, 64),
    "bitwidths": (4, 14),   # even-integer space: {4,6,8,10,12,14}
    "rf":        (1, 16),
}

# Axes where log2 normalization is used in the multi-dim metric
LOG2_AXES = {"sizes", "rf"}


# ── Core metrics ─────────────────────────────────────────────────────────────

def fill_distance_1d(samples, lo, hi, n_eval=10_000):
    """Max distance from any point in [lo,hi] to its nearest sample."""
    xs = np.linspace(lo, hi, n_eval)
    dists = np.min(np.abs(xs[:, None] - samples[None, :]), axis=1)
    return float(dists.max())


def sep_distance_1d(samples):
    """Min distance between any two distinct sample points."""
    s = np.sort(samples)
    return float(np.min(np.diff(s)))


def metrics_1d(samples, lo, hi):
    """Return (fill_lin, sep_lin, fill_log2, sep_log2) for one axis."""
    fill_lin = fill_distance_1d(samples, lo, hi)
    sep_lin  = sep_distance_1d(samples)
    if lo > 0:
        slog = np.log2(samples)
        fill_log2 = fill_distance_1d(slog, np.log2(lo), np.log2(hi))
        sep_log2  = sep_distance_1d(slog)
    else:
        fill_log2 = sep_log2 = float("nan")
    return fill_lin, sep_lin, fill_log2, sep_log2


# ── Normalized multi-dim fill distance (L-inf) ───────────────────────────────

def normalize(samples, lo, hi, log2=False):
    if log2:
        return (np.log2(samples) - np.log2(lo)) / (np.log2(hi) - np.log2(lo))
    return (samples - lo) / (hi - lo)


def multidim_fill_distance(grids_norm, bounds_norm, n_eval=500):
    """
    L-inf fill distance: for a uniform grid of eval points in the unit hypercube,
    compute max over eval points of min-distance to nearest sample point.

    grids_norm: dict axis -> normalized 1D sample array
    Returns (fill_dist, bottleneck_axis).
    """
    axes = list(grids_norm.keys())
    # Build all combinations of eval points (coarse grid per axis)
    pts = np.meshgrid(*[np.linspace(0, 1, n_eval) for _ in axes], indexing="ij")
    eval_pts = np.stack([p.ravel() for p in pts], axis=1)  # (N, D)

    # Sample grid: cartesian product of normalized samples
    sample_grids = np.meshgrid(*[grids_norm[a] for a in axes], indexing="ij")
    samples = np.stack([g.ravel() for g in sample_grids], axis=1)  # (M, D)

    # L-inf distance from each eval point to nearest sample
    diffs = np.abs(eval_pts[:, None, :] - samples[None, :, :])  # (N, M, D)
    linf_to_samples = diffs.max(axis=2)                          # (N, M)
    min_dist_per_eval = linf_to_samples.min(axis=1)              # (N,)

    worst_idx = int(np.argmax(min_dist_per_eval))
    worst_pt  = eval_pts[worst_idx]
    # Which axis contributes most to that point's distance to nearest sample?
    # Re-compute per-axis contribution for the worst eval point
    diffs_worst = np.abs(worst_pt[None, :] - samples)            # (M, D)
    nearest_idx = np.argmin(diffs_worst.max(axis=1))
    per_axis_gap = np.abs(worst_pt - samples[nearest_idx])
    bottleneck = axes[int(np.argmax(per_axis_gap))]

    return float(min_dist_per_eval.max()), bottleneck


# ── Report ────────────────────────────────────────────────────────────────────

def main():
    print()
    print("=" * 75)
    print(" Design space coverage metrics — wa-hls4ml Catapult archive")
    print("=" * 75)

    # ── Per-axis table ────────────────────────────────────────────────────────
    print()
    print("[ Per-axis fill/separation distances ]")
    print()
    hdr = f"  {'Axis':<20}  {'Topology':<8}  {'Samples':30}  "
    hdr += f"{'Fill(lin)':>9}  {'Sep(lin)':>8}  {'Fill(log2)':>10}  {'Sep(log2)':>9}"
    print(hdr)
    print("  " + "-" * (len(hdr) - 2))

    axes_cfg = [
        ("sizes",     "sizes",     True),
        ("bitwidths", "bitwidths", False),
        ("rf",        "RF",        True),
    ]

    for axis_key, axis_label, do_log in axes_cfg:
        lo, hi = BOUNDS[axis_key]
        seen = {}
        for topo, grids in GRIDS.items():
            s = grids[axis_key]
            key = tuple(s)
            if key in seen:
                seen[key].append(topo)
            else:
                seen[key] = [topo]

        for key, topos in seen.items():
            s = np.array(key)
            fl, sl, flog, slog = metrics_1d(s, lo, hi)
            topo_str = "/".join(t.split("-")[0] for t in topos) + "L"
            samples_str = "{" + ",".join(str(v) for v in s) + "}"
            fl_str   = f"{fl:9.2f}"
            sl_str   = f"{sl:8.2f}"
            flog_str = f"{flog:10.3f}" if do_log else f"{'—':>10}"
            slog_str = f"{slog:9.3f}"  if do_log else f"{'—':>9}"
            # Special note for bitwidths: complete in even-integer space
            note = "  ← complete (even-int space)" if axis_key == "bitwidths" else ""
            print(f"  {axis_label:<20}  {topo_str:<8}  {samples_str:<30}  "
                  f"{fl_str}  {sl_str}  {flog_str}  {slog_str}{note}")

    # ── 3-layer sizes vs [4,16] (intended range) ─────────────────────────────
    print()
    print("  [ 3-layer sizes vs intended range [4,16] only ]")
    s3 = GRIDS["3-layer"]["sizes"]
    fl, sl, flog, slog = metrics_1d(s3, 4, 16)
    print(f"  {'sizes':<20}  {'3L':<8}  {'{4,8,16}':<30}  "
          f"{fl:9.2f}  {sl:8.2f}  {flog:10.3f}  {slog:9.3f}")

    # ── Multi-dimensional L-inf fill distance ─────────────────────────────────
    print()
    print("[ Multi-dimensional L∞ fill distance  (normalized axes → [0,1]) ]")
    print("  Normalization: sizes → log₂, bitwidths → linear, RF → log₂")
    print()

    for topo, grids in GRIDS.items():
        grids_norm = {}
        for axis_key in ("sizes", "bitwidths", "rf"):
            lo, hi = BOUNDS[axis_key]
            log2 = axis_key in LOG2_AXES
            grids_norm[axis_key] = normalize(grids[axis_key], lo, hi, log2=log2)

        fill, bottleneck = multidim_fill_distance(grids_norm, {}, n_eval=100)
        print(f"  {topo:<10}  L∞ fill dist = {fill:.4f}  "
              f"(bottleneck axis: {bottleneck})")

    # Extra: 3-layer with sizes bounded at [4,16]
    grids_norm_3l_narrow = {}
    for axis_key in ("sizes", "bitwidths", "rf"):
        lo = 4 if axis_key != "sizes" else 4
        hi = 16 if axis_key == "sizes" else BOUNDS[axis_key][1]
        log2 = axis_key in LOG2_AXES
        grids_norm_3l_narrow[axis_key] = normalize(
            GRIDS["3-layer"][axis_key], lo, hi, log2=log2)
    fill_narrow, btn_narrow = multidim_fill_distance(grids_norm_3l_narrow, {}, n_eval=100)
    print(f"  {'3-layer':<10}  L∞ fill dist = {fill_narrow:.4f}  "
          f"(bottleneck axis: {btn_narrow})  [sizes bounded at [4,16]]")

    print()
    print("  Interpretation:")
    print("  • Fill dist 0.0 = perfect coverage; 0.5 = worst point is halfway")
    print("    between two samples (or at the edge of an uncovered region).")
    print("  • 1/2-layer bottleneck is RF (gap RF=1→RF=4 in log space = 2×others).")
    print("  • 3-layer bottleneck is sizes (missing [16,64] when ref=[4,64]).")
    print()


if __name__ == "__main__":
    main()
