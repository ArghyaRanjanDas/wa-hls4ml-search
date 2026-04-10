#!/bin/bash
source $SCRATCH/venv_hls4ml/bin/activate
python iter_manager_catapult.py -o $SCRATCH/catapult_runs --catapult_shell Perlmutter_scripts/catapult_shell.sh --flow_tcl util/catapult_hls4ml_flow.tcl --license_config license_servers_perlmutter.json --flow_config_json config_catapult_flow.json --gen_model_config_json config_dense_latency_fast.json --batch_range 1 --batch_size 1 --slurm --slurm-qos debug --slurm-time 00:30:00
