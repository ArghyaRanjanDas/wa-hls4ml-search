#!/bin/bash
# Two-shot tech comparison: same 1-layer design (input=8, output=8, 8-bit, relu, RF=1)
# synthesised back-to-back with nangate-45nm and GF22nm.  No SLURM needed.
#
# Run from repo root:
#   bash slurm/examples/run_dense_1layer_tech_compare.sh
#
# Results:
#   $SCRATCH/catapult_45nm_test/   — nangate-45nm_beh
#   $SCRATCH/catapult_gf22_test/   — GF22FDX (5 ns)

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

run_synth() {
    local label="$1" flow_cfg="$2" outdir="$3"
    echo ""
    echo "=== ${label} ==="
    echo "    flow:   ${flow_cfg}"
    echo "    output: ${outdir}"
    python iter_manager_catapult.py \
        -o "${outdir}"                                      \
        --catapult_shell Perlmutter_scripts/catapult_shell.sh \
        --flow_tcl      util/catapult_hls4ml_flow.tcl       \
        --flow_config_json  "${flow_cfg}"                   \
        --gen_model_config_json configs/model_sweeps/config_dense_1layer_gf22_test.json \
        --cartesian
    echo "=== ${label} done ==="
}

run_synth "nangate-45nm" "configs/catapult_flow/config_catapult_flow_rf1.json"      "${SCRATCH}/catapult_45nm_test"
run_synth "GF22nm"       "configs/catapult_flow/config_catapult_flow_gf22_rf1.json" "${SCRATCH}/catapult_gf22_test"

echo ""
echo "Both syntheses complete."
echo "  45nm : ${SCRATCH}/catapult_45nm_test"
echo "  GF22 : ${SCRATCH}/catapult_gf22_test"
