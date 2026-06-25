#!/bin/bash
# Re-run a single failed GF22nm design and keep the catapult.log for inspection.
#
# Usage:
#   bash slurm/examples/debug_gf22_failed_design.sh [STEM] [RUN_DIR]
#
# Defaults:
#   STEM    = dense_2l_555
#   RUN_DIR = latest run under $SCRATCH/catapult_gf22_2layer_lhs_rf1/

set -euo pipefail

REPO_DIR="$(cd "$(dirname "${BASH_SOURCE[0]}")/../.." && pwd)"
VENV="${WA_HLS4ML_VENV:-${SCRATCH}/venv_hls4ml/bin/activate}"
source "$VENV"
cd "$REPO_DIR"

STEM="${1:-dense_2l_555}"
RUN_DIR="${2:-$(ls -d $SCRATCH/catapult_gf22_2layer_lhs_rf1/run_*/ 2>/dev/null | sort | tail -1)}"
RUN_DIR="${RUN_DIR%/}"

[[ -n "$RUN_DIR" ]] || { echo "ERROR: no run dir found under \$SCRATCH/catapult_gf22_2layer_lhs_rf1/" >&2; exit 1; }

echo "Stem:    $STEM"
echo "Run dir: $RUN_DIR"

BUILD_DIR="$RUN_DIR/build/$STEM"
DATA_DIR="$RUN_DIR/data/models/$STEM"
CFG="$DATA_DIR/dataflow_config.json"
CATAPULT_LOG="$BUILD_DIR/catapult_native/catapult.log"

[[ -f "$CFG" ]] || { echo "ERROR: dataflow_config.json not found at $CFG" >&2; exit 1; }

# ── Find the 45nm tarball ──────────────────────────────────────────────────────
ARCHIVE_45NM=/global/cfs/cdirs/amsc011/shared/wa-hls4ml-catapult/nangate45
CANDIDATES=/global/cfs/cdirs/amsc011/shared/wa-hls4ml-catapult/gf22fdx/gf22_lhs_2layer_1350.txt

TARBALL=$(python3 - <<PYEOF
import sys
candidates = "$CANDIDATES"
stem       = "$STEM"
archive    = "$ARCHIVE_45NM"
import os

with open(candidates) as f:
    for line in f:
        line = line.strip()
        if not line:
            continue
        run_name, s = line.split('\t', 1)
        if s == stem:
            tb = os.path.join(archive, run_name, 'tarballs', f'{stem}.tar.gz')
            if os.path.exists(tb):
                print(tb)
                sys.exit(0)

print("NOT_FOUND", file=sys.stderr)
sys.exit(1)
PYEOF
)

echo "Tarball: $TARBALL"

# ── Recreate build dir with keras model ───────────────────────────────────────
echo ""
echo "=== Rebuilding keras model ==="
mkdir -p "$BUILD_DIR"

python3 - <<PYEOF
import tarfile, os, sys
sys.path.insert(0, '$REPO_DIR')

tb         = '$TARBALL'
build_dir  = '$BUILD_DIR'
keras_h5   = os.path.join(build_dir, 'keras_model.h5')
model_json = os.path.join(build_dir, 'model.json')

try:
    from qkeras.utils import _add_supported_quantized_objects
    co = {}
    _add_supported_quantized_objects(co)
except Exception:
    co = {}

import tensorflow as tf

with tarfile.open(tb) as t:
    mj = t.extractfile('model.json').read().decode()

with open(model_json, 'w') as f:
    f.write(mj)

model = tf.keras.models.model_from_json(mj, custom_objects=co)
model.save(keras_h5, include_optimizer=False)
print(f'  keras_model.h5 written to {keras_h5}')
PYEOF

# ── Run synthesis ─────────────────────────────────────────────────────────────
echo ""
echo "=== Running synthesis (this will take several minutes) ==="
echo "    Log: $CATAPULT_LOG"
echo "    Tail in another terminal with:"
echo "      tail -f $CATAPULT_LOG"
echo ""

JOB_LINE="${BUILD_DIR}	${REPO_DIR}/Perlmutter_scripts/catapult_shell.sh	${REPO_DIR}/util/catapult_hls4ml_flow.tcl	${CFG}"

LM_LICENSE_FILE=$(python3 -c "
import json
with open('${REPO_DIR}/license_servers_perlmutter.json') as f:
    cfg = json.load(f)
print(':'.join(f\"{s['port']}@{s['host']}\" for s in cfg['servers']))
")
export LM_LICENSE_FILE

# iter_manager derives run_dir as dirname(dirname(build_dir)) = RUN_DIR
# It does NOT delete the build dir on failure, so catapult.log survives
python iter_manager_catapult.py \
    -o "$SCRATCH/catapult_gf22_2layer_lhs_rf1" \
    --run-single-job "$JOB_LINE" && SYNTH_OK=1 || SYNTH_OK=0

echo ""
if [ "$SYNTH_OK" -eq 1 ]; then
    echo "=== Synthesis SUCCEEDED (unexpected for a known-failing design) ==="
else
    echo "=== Synthesis FAILED (expected) — showing last 50 lines of catapult.log ==="
fi

echo ""
echo "────────────────────────────────────────────────────────────"
tail -50 "$CATAPULT_LOG" 2>/dev/null || echo "(catapult.log not found — synthesis may have crashed before Catapult started)"
echo "────────────────────────────────────────────────────────────"
echo ""
echo "Full log: $CATAPULT_LOG"
