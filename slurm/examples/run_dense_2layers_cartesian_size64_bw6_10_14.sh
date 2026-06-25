#!/bin/bash
# Cartesian product run — 1647 2-layer dense NN configs with size 64 and bitwidths 6, 10, 14.
# Complements run_dense_2layers_cartesian_size64.sh (same geometry, bw=4,8,12).
#
# Partitioned into three non-overlapping sub-configs:
#   A (675): input=64,   layer1=4-64, layer2=4-64
#   B (540): input=4-32, layer1=64,   layer2=4-64
#   C (432): input=4-32, layer1=4-32, layer2=64
#
# Run from repo root: bash slurm/examples/run_dense_2layers_cartesian_size64_bw6_10_14.sh
source $SCRATCH/venv_hls4ml/bin/activate

COMMON_ARGS=(
  --catapult_shell Perlmutter_scripts/catapult_shell.sh
  --flow_tcl      util/catapult_hls4ml_flow.tcl
  --license_config license_servers_perlmutter.json
  --flow_config_json configs/catapult_flow/config_catapult_flow.json
  --cartesian
  --slurm --slurm-qos express_amsc --slurm-time 06:00:00
  --slurm-parallelism 16 --slurm-mem-per-job 16G
)

OUT=$SCRATCH/catapult_dense_2layers_cartesian_size64_bw6_10_14

echo "=== Sub-run A: input=64, layers 4-64, bw 6/10/14 (675 designs) ==="
python iter_manager_catapult.py -o "$OUT" \
  --gen_model_config_json configs/model_sweeps/config_dense_2layers_size64_bw6_10_14_A.json \
  "${COMMON_ARGS[@]}"

echo "=== Sub-run B: input=4-32, layer1=64, layer2=4-64, bw 6/10/14 (540 designs) ==="
python iter_manager_catapult.py -o "$OUT" \
  --gen_model_config_json configs/model_sweeps/config_dense_2layers_size64_bw6_10_14_B.json \
  "${COMMON_ARGS[@]}"

echo "=== Sub-run C: input=4-32, layer1=4-32, layer2=64, bw 6/10/14 (432 designs) ==="
python iter_manager_catapult.py -o "$OUT" \
  --gen_model_config_json configs/model_sweeps/config_dense_2layers_size64_bw6_10_14_C.json \
  "${COMMON_ARGS[@]}"
