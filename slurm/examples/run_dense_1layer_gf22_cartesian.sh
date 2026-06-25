#!/bin/bash
#SBATCH --job-name=gf22_1layer
#SBATCH --account=amsc011
#SBATCH --qos=shared
#SBATCH --nodes=1
#SBATCH --ntasks=1
#SBATCH --cpus-per-task=2
#SBATCH --mem=8G
#SBATCH --constraint=cpu
#SBATCH --time=2-00:00:00
#SBATCH --output=logs/%x_%j.out
#SBATCH --error=logs/%x_%j.err
#
# GF22nm cartesian sweep — all 1,800 unique single-layer dense NN configs
# (input 4-64, output 4-64, relu/tanh/sigmoid, bitwidth 4-14 even), 4 RF values.
#
# Mirrors run_dense_single_layer_cartesian_rf_sweep.sh + run_dense_single_layer_cartesian_bw14.sh
# but targets GF22FDX (5 ns clock, startup = gf22nm-lib/libsetup.tcl).
#
# Submit from repo root:
#   sbatch slurm/examples/run_dense_1layer_gf22_cartesian.sh
#
# 8 SLURM array jobs (2 model configs × 4 RF):
#   catapult_gf22_1layer_rf{1,4,8,16}        — bw=4,6,8,10,12  (375 designs each)
#   catapult_gf22_1layer_bw14_rf{1,4,8,16}   — bw=14           ( 75 designs each)
# Total: 1,800 GF22nm synthesis jobs.
#
# After each RF group completes, archive with:
#   bash slurm/examples/archive_run.sh $SCRATCH/catapult_gf22_1layer_rf<N>/run_*/

set -euo pipefail

REPO_DIR="${SLURM_SUBMIT_DIR:-$(cd "$(dirname "${BASH_SOURCE[0]}")/../.." && pwd)}"
cd "$REPO_DIR"

source "${SCRATCH}/venv_hls4ml/bin/activate"

COMMON=(
  --catapult_shell Perlmutter_scripts/catapult_shell.sh
  --flow_tcl      util/catapult_hls4ml_flow.tcl
  --license_config license_servers_perlmutter.json
  --cartesian
  --slurm --slurm-qos express_amsc --slurm-time 00:30:00
  --slurm-parallelism 100 --slurm-mem-per-job 4G
)

# ── bw=4,6,8,10,12 × 4 RF ────────────────────────────────────────────────────
for rf in rf1 rf4 rf8 rf16; do
  echo "=== bw=4-12  RF=${rf} ==="
  python iter_manager_catapult.py \
    -o "${SCRATCH}/catapult_gf22_1layer_${rf}" \
    --flow_config_json "config_catapult_flow_gf22_${rf}.json" \
    --gen_model_config_json config_dense_single_layer.json \
    "${COMMON[@]}"
done

# ── bw=14 × 4 RF ─────────────────────────────────────────────────────────────
for rf in rf1 rf4 rf8 rf16; do
  echo "=== bw=14  RF=${rf} ==="
  python iter_manager_catapult.py \
    -o "${SCRATCH}/catapult_gf22_1layer_bw14_${rf}" \
    --flow_config_json "config_catapult_flow_gf22_${rf}.json" \
    --gen_model_config_json config_dense_single_layer_bw14.json \
    "${COMMON[@]}"
done

echo ""
echo "All 8 SLURM jobs submitted."
echo "Archive each run after completion:"
echo "  bash slurm/examples/archive_run.sh \$SCRATCH/catapult_gf22_1layer_rf1/run_*/"
