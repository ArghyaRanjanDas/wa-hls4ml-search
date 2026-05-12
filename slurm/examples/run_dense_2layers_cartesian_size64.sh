#!/bin/bash
# Cartesian product run — 1647 new 2-layer dense NN configs that include size 64
# (the 1728 designs with sizes 4-32 were already run in run_dense_2layers_cartesian.sh).
#
# Partitioned into three non-overlapping sub-configs to avoid re-running existing designs:
#   A (675): input=64,   layer1=4-64, layer2=4-64
#   B (540): input=4-32, layer1=64,   layer2=4-64
#   C (432): input=4-32, layer1=4-32, layer2=64
#
# All three share the same output root; results land in separate run_* subdirs.
#
# Run from repo root: bash slurm/examples/run_dense_2layers_cartesian_size64.sh
source $SCRATCH/venv_hls4ml/bin/activate

COMMON_ARGS=(
  --catapult_shell Perlmutter_scripts/catapult_shell.sh
  --flow_tcl      util/catapult_hls4ml_flow.tcl
  --license_config license_servers_perlmutter.json
  --flow_config_json config_catapult_flow.json
  --cartesian
  --slurm --slurm-qos express_amsc --slurm-time 06:00:00
  --slurm-parallelism 16 --slurm-mem-per-job 16G
)

OUT=$SCRATCH/catapult_dense_2layers_cartesian_size64

echo "=== Sub-run A: input=64, layers 4-64 (675 designs) ==="
python iter_manager_catapult.py -o "$OUT" \
  --gen_model_config_json config_dense_2layers_size64_A.json \
  "${COMMON_ARGS[@]}"

echo "=== Sub-run B: input=4-32, layer1=64, layer2=4-64 (540 designs) ==="
python iter_manager_catapult.py -o "$OUT" \
  --gen_model_config_json config_dense_2layers_size64_B.json \
  "${COMMON_ARGS[@]}"

echo "=== Sub-run C: input=4-32, layer1=4-32, layer2=64 (432 designs) ==="
python iter_manager_catapult.py -o "$OUT" \
  --gen_model_config_json config_dense_2layers_size64_C.json \
  "${COMMON_ARGS[@]}"
