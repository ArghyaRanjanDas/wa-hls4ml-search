#!/bin/bash
# Single-layer dense NN — bw=14 only, RF sweep (RF=1,4,8,16).
# Covers the 75-design gap per RF value (5 inputs × 5 outputs × 3 acts × 1 bw = 75 designs each).
# Complements run_dense_single_layer_cartesian.sh (RF=16) and
# run_dense_single_layer_cartesian_rf_sweep.sh (RF=1,4,8), all of which used bw=4,6,8,10,12.
#
# Run from repo root: bash slurm/examples/run_dense_single_layer_cartesian_bw14.sh
source $SCRATCH/venv_hls4ml/bin/activate

COMMON_ARGS=(
  --catapult_shell Perlmutter_scripts/catapult_shell.sh
  --flow_tcl      util/catapult_hls4ml_flow.tcl
  --license_config license_servers_perlmutter.json
  --gen_model_config_json config_dense_single_layer_bw14.json
  --cartesian
  --slurm --slurm-qos express_amsc --slurm-time 00:30:00
  --slurm-parallelism 100 --slurm-mem-per-job 4G
)

echo "=== RF=1 ==="
python iter_manager_catapult.py \
  -o $SCRATCH/catapult_dense_single_layer_cartesian_bw14_rf1 \
  --flow_config_json config_catapult_flow_rf1.json \
  "${COMMON_ARGS[@]}"

echo "=== RF=4 ==="
python iter_manager_catapult.py \
  -o $SCRATCH/catapult_dense_single_layer_cartesian_bw14_rf4 \
  --flow_config_json config_catapult_flow_rf4.json \
  "${COMMON_ARGS[@]}"

echo "=== RF=8 ==="
python iter_manager_catapult.py \
  -o $SCRATCH/catapult_dense_single_layer_cartesian_bw14_rf8 \
  --flow_config_json config_catapult_flow_rf8.json \
  "${COMMON_ARGS[@]}"

echo "=== RF=16 ==="
python iter_manager_catapult.py \
  -o $SCRATCH/catapult_dense_single_layer_cartesian_bw14_rf16 \
  --flow_config_json config_catapult_flow.json \
  "${COMMON_ARGS[@]}"
