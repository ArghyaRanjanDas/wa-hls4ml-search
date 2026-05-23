#!/bin/bash
# 3-layer cartesian — size=32 extension (113,400 new designs).
# Covers all (input, L1, L2, L3) combinations in {4,8,16,32} that include at
# least one 32, split into 4 non-overlapping groups to avoid re-running
# existing {4,8,16} designs.
#
#   Group inp  — input=32,  layers {4–32}           10,368 designs/RF
#   Group l1   — input {4–16}, L1=32, L2/L3 {4–32}  7,776 designs/RF
#   Group l2   — input {4–16}, L1 {4–16}, L2=32,
#                L3 {4–32}                            5,832 designs/RF
#   Group l3   — input {4–16}, L1/L2 {4–16}, L3=32  4,374 designs/RF
#
# Memory: profiling showed ~5.4 GB/design for 32-neuron → parallelism=50
# gives 50×8G=400 GB/node, within Perlmutter's 512 GB limit.
#
# Run from repo root: bash slurm/examples/run_dense_3layers_sz32_extension.sh
source $SCRATCH/venv_hls4ml/bin/activate

COMMON_ARGS=(
  --catapult_shell Perlmutter_scripts/catapult_shell.sh
  --flow_tcl      util/catapult_hls4ml_flow.tcl
  --license_config license_servers_perlmutter.json
  --cartesian
  --slurm --slurm-qos express_amsc --slurm-time 00:30:00
  --slurm-parallelism 50 --slurm-mem-per-job 8G
)

for GROUP in inp l1 l2 l3; do
    echo "=== Group ${GROUP} ==="
    for RF in 1 4 8 16; do
        if [ "$RF" -eq 16 ]; then
            FLOW_CFG=config_catapult_flow.json
        else
            FLOW_CFG=config_catapult_flow_rf${RF}.json
        fi
        echo "  RF=${RF}"
        python iter_manager_catapult.py \
          -o "$SCRATCH/catapult_dense_3layers_sz32_${GROUP}_rf${RF}" \
          --gen_model_config_json "config_dense_3layers_sz32_${GROUP}.json" \
          --flow_config_json "$FLOW_CFG" \
          "${COMMON_ARGS[@]}"
    done
done
