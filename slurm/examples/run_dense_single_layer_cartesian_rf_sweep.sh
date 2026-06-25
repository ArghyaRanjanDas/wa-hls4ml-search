#!/bin/bash
# ReuseFactor sweep — single-layer dense NN configs with RF=1, 4, 8
# (input 4-64, output 4-64, relu/tanh/sigmoid, bitwidths from configs/model_sweeps/config_dense_single_layer.json).
# Complements run_dense_single_layer_cartesian.sh (same grid, RF=16).
#
# Run from repo root: bash slurm/examples/run_dense_single_layer_cartesian_rf_sweep.sh
source $SCRATCH/venv_hls4ml/bin/activate

COMMON_ARGS=(
  --catapult_shell Perlmutter_scripts/catapult_shell.sh
  --flow_tcl      util/catapult_hls4ml_flow.tcl
  --license_config license_servers_perlmutter.json
  --gen_model_config_json configs/model_sweeps/config_dense_single_layer.json
  --cartesian
  --slurm --slurm-qos express_amsc --slurm-time 00:30:00
  --slurm-parallelism 100 --slurm-mem-per-job 4G
)

echo "=== RF=1 ==="
python iter_manager_catapult.py \
  -o $SCRATCH/catapult_dense_single_layer_cartesian_rf1 \
  --flow_config_json configs/catapult_flow/config_catapult_flow_rf1.json \
  "${COMMON_ARGS[@]}"

echo "=== RF=4 ==="
python iter_manager_catapult.py \
  -o $SCRATCH/catapult_dense_single_layer_cartesian_rf4 \
  --flow_config_json configs/catapult_flow/config_catapult_flow_rf4.json \
  "${COMMON_ARGS[@]}"

echo "=== RF=8 ==="
python iter_manager_catapult.py \
  -o $SCRATCH/catapult_dense_single_layer_cartesian_rf8 \
  --flow_config_json configs/catapult_flow/config_catapult_flow_rf8.json \
  "${COMMON_ARGS[@]}"
