#!/bin/bash
# BramFactor smoke test — one medium model (2 layers, 64 neurons, relu, 8-bit).
# Runs synthesis directly (no SLURM) to avoid queue wait.
# After completion, check BramFactor made it into the generated project:
#   grep -r BramFactor $SCRATCH/catapult_runs_bramtest/
#
# Run from repo root: bash slurm/examples/run_bram_test_medium.sh
source $SCRATCH/venv_hls4ml/bin/activate

python iter_manager_catapult.py \
  -o $SCRATCH/catapult_runs_bramtest                        $(: output directory) \
  --catapult_shell Perlmutter_scripts/catapult_shell.sh     $(: Apptainer wrapper that launches Catapult) \
  --flow_tcl util/catapult_hls4ml_flow.tcl                  $(: TCL script that drives HLS synthesis) \
  --license_config license_servers_perlmutter.json          $(: license server config) \
  --flow_config_json configs/catapult_flow/config_catapult_flow.json              $(: HLS flow parameters, includes BramFactor=0) \
  --gen_model_config_json configs/model_sweeps/config_bram_test_medium.json           $(: fixed model: 2 dense layers, 64 neurons, relu, 8-bit) \
  --batch_range 1 --batch_size 1                            $(: single model, no SLURM)
