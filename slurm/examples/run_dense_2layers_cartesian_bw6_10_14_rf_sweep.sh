#!/bin/bash
# Step 1 — RF sweep for bitwidths 6, 10, 14 on the 2-layer 4-32 grid.
# Completes the RF×bitwidth coverage: RF=1,4,8 were already done for bw=4,8,12;
# this adds bw=6,10,14 for the same RF values.
# 1728 designs per RF value = 5184 new designs total.
#
# Run from repo root: bash slurm/examples/run_dense_2layers_cartesian_bw6_10_14_rf_sweep.sh
source $SCRATCH/venv_hls4ml/bin/activate

COMMON_ARGS=(
  --catapult_shell Perlmutter_scripts/catapult_shell.sh
  --flow_tcl      util/catapult_hls4ml_flow.tcl
  --license_config license_servers_perlmutter.json
  --gen_model_config_json configs/model_sweeps/config_dense_2layers_bw6_10_14.json
  --cartesian
  --slurm --slurm-qos express_amsc --slurm-time 06:00:00
  --slurm-parallelism 16 --slurm-mem-per-job 16G
)

echo "=== RF=1, bw=6,10,14, sizes 4-32 (1728 designs) ==="
python iter_manager_catapult.py \
  -o $SCRATCH/catapult_dense_2layers_cartesian_bw6_10_14_rf1 \
  --flow_config_json configs/catapult_flow/config_catapult_flow_rf1.json \
  "${COMMON_ARGS[@]}"

echo "=== RF=4, bw=6,10,14, sizes 4-32 (1728 designs) ==="
python iter_manager_catapult.py \
  -o $SCRATCH/catapult_dense_2layers_cartesian_bw6_10_14_rf4 \
  --flow_config_json configs/catapult_flow/config_catapult_flow_rf4.json \
  "${COMMON_ARGS[@]}"

echo "=== RF=8, bw=6,10,14, sizes 4-32 (1728 designs) ==="
python iter_manager_catapult.py \
  -o $SCRATCH/catapult_dense_2layers_cartesian_bw6_10_14_rf8 \
  --flow_config_json configs/catapult_flow/config_catapult_flow_rf8.json \
  "${COMMON_ARGS[@]}"
