#!/bin/bash
# 5-task pilot with toy models — fast (~5 min wall-clock total) sanity
# check before scaling up. Uses express_amsc QoS (no double-charge for
# AmSC users; capped at 32 concurrent nodes group-wide).
# Run from repo root: bash slurm/examples/run_pilot.sh
source $SCRATCH/venv_hls4ml/bin/activate
python iter_manager_catapult.py \
  -o $SCRATCH/catapult_pilot \
  --catapult_shell Perlmutter_scripts/catapult_shell.sh \
  --flow_tcl util/catapult_hls4ml_flow.tcl \
  --license_config license_servers_perlmutter.json \
  --flow_config_json config_catapult_flow.json \
  --gen_model_config_json config_dense_latency_fast_toy.json \
  --batch_range 1 --batch_size 5 \
  --slurm --slurm-qos express_amsc --slurm-time 00:30:00
