#!/bin/bash
# ReuseFactor sweep — 3-layer dense NN configs with RF=4, 8, 16
# (input 4-16, layers 4-16, relu/tanh/sigmoid, bitwidth 4/8/12).
# Complements run_dense_3layers_cartesian_rf1.sh (same grid, RF=1).
# Formula: 3 × (3×3)³ × 3 bw = 6561 designs per RF value = 19683 total.
#
# Run from repo root: bash slurm/examples/run_dense_3layers_cartesian_rf_sweep.sh
source $SCRATCH/venv_hls4ml/bin/activate

COMMON_ARGS=(
  --catapult_shell Perlmutter_scripts/catapult_shell.sh
  --flow_tcl      util/catapult_hls4ml_flow.tcl
  --license_config license_servers_perlmutter.json
  --gen_model_config_json config_dense_3layers.json
  --cartesian
  --slurm --slurm-qos express_amsc --slurm-time 00:30:00
  --slurm-parallelism 100 --slurm-mem-per-job 4G
)

echo "=== RF=4, bw=4,8,12, sizes 4-16 (6561 designs) ==="
python iter_manager_catapult.py \
  -o $SCRATCH/catapult_dense_3layers_cartesian_rf4 \
  --flow_config_json config_catapult_flow_rf4.json \
  "${COMMON_ARGS[@]}"

echo "=== RF=8, bw=4,8,12, sizes 4-16 (6561 designs) ==="
python iter_manager_catapult.py \
  -o $SCRATCH/catapult_dense_3layers_cartesian_rf8 \
  --flow_config_json config_catapult_flow_rf8.json \
  "${COMMON_ARGS[@]}"

echo "=== RF=16, bw=4,8,12, sizes 4-16 (6561 designs) ==="
python iter_manager_catapult.py \
  -o $SCRATCH/catapult_dense_3layers_cartesian_rf16 \
  --flow_config_json config_catapult_flow.json \
  "${COMMON_ARGS[@]}"
