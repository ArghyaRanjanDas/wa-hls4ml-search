#!/bin/bash
# 100-task scale run with TOY models — license-stress test, fast iteration.
# Use this to validate the full pipeline without long synthesis times.
# Run from repo root: bash slurm/examples/run_scale_toy.sh
source $SCRATCH/venv_hls4ml/bin/activate
python iter_manager_catapult.py \
  -o $SCRATCH/catapult_scale_toy \
  --catapult_shell Perlmutter_scripts/catapult_shell.sh \
  --flow_tcl util/catapult_hls4ml_flow.tcl \
  --license_config license_servers_perlmutter.json \
  --flow_config_json config_catapult_flow.json \
  --gen_model_config_json config_dense_latency_fast_toy.json \
  --batch_range 1 --batch_size 100 \
  --slurm --slurm-qos express_amsc --slurm-time 00:30:00
