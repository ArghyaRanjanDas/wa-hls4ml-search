#!/bin/bash
# Profiling run: 3-layer dense, all layers 32 neurons, bw=14, RF=1.
# Single design (input=32, layers=32/32/32, relu, bw=14, RF=1).
# Purpose: measure synthesis wall time before committing to a full size-32 sweep.
#
# Run from repo root: bash slurm/examples/run_dense_3layers_profiling_32.sh
source $SCRATCH/venv_hls4ml/bin/activate

python iter_manager_catapult.py \
  -o $SCRATCH/catapult_dense_3layers_profiling_32 \
  --catapult_shell Perlmutter_scripts/catapult_shell.sh \
  --flow_tcl      util/catapult_hls4ml_flow.tcl \
  --license_config license_servers_perlmutter.json \
  --gen_model_config_json config_dense_3layers_profiling_32.json \
  --flow_config_json config_catapult_flow_rf1.json \
  --cartesian \
  --slurm --slurm-qos express_amsc --slurm-time 01:00:00 \
  --slurm-parallelism 1 --slurm-mem-per-job 16G
