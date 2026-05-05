#!/bin/bash
# 200-task scale run — dense NNs with 1-3 layers, 16-256 neurons, up to 8-bit quantization.
# Run from repo root: bash slurm/examples/run_dense_1to3layers.sh
source $SCRATCH/venv_hls4ml/bin/activate
python iter_manager_catapult.py \
  -o $SCRATCH/catapult_dense_1to3layers                        $(: output directory) \
  --catapult_shell Perlmutter_scripts/catapult_shell.sh        $(: Apptainer wrapper that launches Catapult) \
  --flow_tcl util/catapult_hls4ml_flow.tcl                     $(: TCL script that drives HLS synthesis) \
  --license_config license_servers_perlmutter.json             $(: license server config) \
  --flow_config_json config_catapult_flow.json                 $(: HLS flow parameters) \
  --gen_model_config_json config_dense_1to3layers.json         $(: 1-3 layer dense NNs, 16-256 neurons, 8-bit max) \
  --batch_range 1 --batch_size 1000                            $(: run batch 1, 1000 tasks) \
  --slurm --slurm-qos express_amsc --slurm-time 02:00:00       $(: SLURM array, express_amsc QoS, 2 hr walltime) \
  --slurm-parallelism 16 --slurm-mem-per-job 16G               $(: 16 syntheses per node, 16G RAM each = 256G per node)
