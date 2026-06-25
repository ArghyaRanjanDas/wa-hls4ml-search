#!/bin/bash
# Smoke test: 1-layer dense network synthesised with GF22nm on the login node.
# Runs sequentially — no SLURM, no GNU parallel.  Takes ~10-30 min.
#
# Run from repo root:
#   bash slurm/examples/run_dense_1layer_gf22_test.sh
#
# One design: input=8, output=8, 8-bit weights, relu, RF=1, 5 ns clock.
# Results land in $SCRATCH/catapult_gf22_test/

set -euo pipefail

REPO="$(cd "$(dirname "${BASH_SOURCE[0]}")/../.." && pwd)"
cd "$REPO"

source "${SCRATCH}/venv_hls4ml/bin/activate"

export LM_LICENSE_FILE=$(python3 -c "
import json
with open('license_servers_perlmutter.json') as f:
    cfg = json.load(f)
print(':'.join(f\"{s['port']}@{s['host']}\" for s in cfg['servers']))
")

python iter_manager_catapult.py \
  -o "${SCRATCH}/catapult_gf22_test"              \
  --catapult_shell Perlmutter_scripts/catapult_shell.sh \
  --flow_tcl      util/catapult_hls4ml_flow.tcl   \
  --flow_config_json  configs/catapult_flow/config_catapult_flow_gf22_rf1.json \
  --gen_model_config_json configs/model_sweeps/config_dense_1layer_gf22_test.json \
  --cartesian
