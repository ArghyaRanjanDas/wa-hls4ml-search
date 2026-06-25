#!/bin/bash
# ReuseFactor sweep — 2-layer dense NN configs with RF=1, 4, 8
# (input 4-32, hidden 4-32, output 4-32, relu/tanh/sigmoid, bitwidth 4/8/12).
# Complements run_dense_2layers_cartesian.sh (same grid, RF=16).
# 1728 designs per RF value = 5184 new designs total.
#
# Run from repo root: bash slurm/examples/run_dense_2layers_cartesian_rf_sweep.sh
source $SCRATCH/venv_hls4ml/bin/activate

COMMON_ARGS=(
  --catapult_shell Perlmutter_scripts/catapult_shell.sh
  --flow_tcl      util/catapult_hls4ml_flow.tcl
  --license_config license_servers_perlmutter.json
  --gen_model_config_json configs/model_sweeps/config_dense_2layers.json
  --cartesian
  --slurm --slurm-qos express_amsc --slurm-time 06:00:00
  --slurm-parallelism 16 --slurm-mem-per-job 16G
)

echo "=== RF=1: 1728 designs ==="
python iter_manager_catapult.py \
  -o $SCRATCH/catapult_dense_2layers_cartesian_rf1 \
  --flow_config_json configs/catapult_flow/config_catapult_flow_rf1.json \
  "${COMMON_ARGS[@]}"

echo "=== RF=4: 1728 designs ==="
python iter_manager_catapult.py \
  -o $SCRATCH/catapult_dense_2layers_cartesian_rf4 \
  --flow_config_json configs/catapult_flow/config_catapult_flow_rf4.json \
  "${COMMON_ARGS[@]}"

echo "=== RF=8: 1728 designs ==="
python iter_manager_catapult.py \
  -o $SCRATCH/catapult_dense_2layers_cartesian_rf8 \
  --flow_config_json configs/catapult_flow/config_catapult_flow_rf8.json \
  "${COMMON_ARGS[@]}"
