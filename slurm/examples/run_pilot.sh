#!/bin/bash
# 5-task pilot with toy models — fast (~5 min wall-clock total) sanity
# check before scaling up. Uses express_amsc QoS (no double-charge for
# AmSC users; capped at 32 concurrent nodes group-wide).
# Run from repo root: bash slurm/examples/run_pilot.sh
source $SCRATCH/venv_hls4ml/bin/activate
python iter_manager_catapult.py \
  -o $SCRATCH/catapult_pilot                                  $(: output directory) \
  --catapult_shell Perlmutter_scripts/catapult_shell.sh       $(: Apptainer wrapper that launches Catapult) \
  --flow_tcl util/catapult_hls4ml_flow.tcl                    $(: TCL script that drives HLS synthesis) \
  --license_config license_servers_perlmutter.json            $(: license server config) \
  --flow_config_json configs/catapult_flow/config_catapult_flow.json                $(: HLS flow parameters) \
  --gen_model_config_json configs/model_sweeps/config_dense_latency_fast_toy.json  $(: toy models — fast, minimal resources) \
  --batch_range 1 --batch_size 5                              $(: run batch 1, 5 tasks) \
  --slurm --slurm-qos express_amsc --slurm-time 00:30:00      $(: SLURM array, express_amsc QoS, 30 min walltime)
