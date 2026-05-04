#!/bin/bash
# 1-task smoke test. Verifies SLURM submission, license checkout, and
# end-to-end synthesis with one real model in ~10-30 min wall-clock.
# Run from repo root: bash slurm/examples/run_single.sh
source $SCRATCH/venv_hls4ml/bin/activate
python iter_manager_catapult.py \
  -o $SCRATCH/catapult_runs                               $(: output directory) \
  --catapult_shell Perlmutter_scripts/catapult_shell.sh   $(: Apptainer wrapper that launches Catapult) \
  --flow_tcl util/catapult_hls4ml_flow.tcl                $(: TCL script that drives HLS synthesis) \
  --license_config license_servers_perlmutter.json        $(: license server config) \
  --flow_config_json config_catapult_flow.json            $(: HLS flow parameters) \
  --gen_model_config_json config_dense_latency_fast.json  $(: real models to synthesize) \
  --batch_range 1 --batch_size 1                          $(: run batch 1, 1 task) \
  --slurm --slurm-qos express_amsc --slurm-time 00:30:00  $(: SLURM array, express_amsc QoS, 30 min walltime)
