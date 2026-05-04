#!/bin/bash
# 100-task scale run with TOY models — license-stress test, fast iteration.
# Use this to validate the full pipeline without long synthesis times.
# Run from repo root: bash slurm/examples/run_scale_toy.sh
source $SCRATCH/venv_hls4ml/bin/activate
python iter_manager_catapult.py \
  -o $SCRATCH/catapult_scale_toy                              $(: output directory) \
  --catapult_shell Perlmutter_scripts/catapult_shell.sh       $(: Apptainer wrapper that launches Catapult) \
  --flow_tcl util/catapult_hls4ml_flow.tcl                    $(: TCL script that drives HLS synthesis) \
  --license_config license_servers_perlmutter.json            $(: license server config) \
  --flow_config_json config_catapult_flow.json                $(: HLS flow parameters) \
  --gen_model_config_json config_dense_latency_fast_toy.json  $(: toy models — fast, minimal resources) \
  --batch_range 1 --batch_size 100                            $(: run batch 1, 100 tasks) \
  --slurm --slurm-qos express_amsc --slurm-time 00:30:00      $(: SLURM array, express_amsc QoS, 30 min walltime)
