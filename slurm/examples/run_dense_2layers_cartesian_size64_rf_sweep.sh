#!/bin/bash
# Step 2a — RF sweep for size-64 extension, bitwidths 4, 8, 12.
# The size-64 designs currently only exist at RF=16; this adds RF=1, 4, 8.
# Each RF value runs 3 non-overlapping sub-configs (A/B/C) = 1647 designs per RF.
# Total: 3 × 1647 = 4941 new designs.
#
# Run from repo root: bash slurm/examples/run_dense_2layers_cartesian_size64_rf_sweep.sh
source $SCRATCH/venv_hls4ml/bin/activate

COMMON_ARGS=(
  --catapult_shell Perlmutter_scripts/catapult_shell.sh
  --flow_tcl      util/catapult_hls4ml_flow.tcl
  --license_config license_servers_perlmutter.json
  --cartesian
  --slurm --slurm-qos express_amsc --slurm-time 06:00:00
  --slurm-parallelism 16 --slurm-mem-per-job 16G
)

for RF in 1 4 8; do
  echo "=== RF=${RF}, bw=4,8,12, size-64 extension (1647 designs) ==="
  OUT=$SCRATCH/catapult_dense_2layers_cartesian_size64_rf${RF}

  echo "--- Sub-run A: input=64, layers 4-64 (675 designs) ---"
  python iter_manager_catapult.py -o "$OUT" \
    --flow_config_json config_catapult_flow_rf${RF}.json \
    --gen_model_config_json config_dense_2layers_size64_A.json \
    "${COMMON_ARGS[@]}"

  echo "--- Sub-run B: input=4-32, layer1=64, layer2=4-64 (540 designs) ---"
  python iter_manager_catapult.py -o "$OUT" \
    --flow_config_json config_catapult_flow_rf${RF}.json \
    --gen_model_config_json config_dense_2layers_size64_B.json \
    "${COMMON_ARGS[@]}"

  echo "--- Sub-run C: input=4-32, layer1=4-32, layer2=64 (432 designs) ---"
  python iter_manager_catapult.py -o "$OUT" \
    --flow_config_json config_catapult_flow_rf${RF}.json \
    --gen_model_config_json config_dense_2layers_size64_C.json \
    "${COMMON_ARGS[@]}"
done
