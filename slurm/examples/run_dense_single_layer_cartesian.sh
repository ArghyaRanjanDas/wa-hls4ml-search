#!/bin/bash
# Full Cartesian product run — all 375 unique single-layer dense NN configs
# (input 4-64, output 4-64, relu/tanh/sigmoid, bitwidth 4-12 even).
# No random sampling.
#
# Run from repo root: bash slurm/examples/run_dense_single_layer_cartesian.sh
source $SCRATCH/venv_hls4ml/bin/activate

python iter_manager_catapult.py \
  -o $SCRATCH/catapult_dense_single_layer_cartesian               $(: output directory) \
  --catapult_shell Perlmutter_scripts/catapult_shell.sh           $(: Apptainer wrapper that launches Catapult) \
  --flow_tcl util/catapult_hls4ml_flow.tcl                        $(: TCL script that drives HLS synthesis) \
  --license_config license_servers_perlmutter.json                $(: license server config) \
  --flow_config_json configs/catapult_flow/config_catapult_flow.json                    $(: HLS flow parameters) \
  --gen_model_config_json configs/model_sweeps/config_dense_single_layer.json          $(: single-layer: in/out 4-64, relu/tanh/sigmoid, 4-12-bit) \
  --cartesian                                                     $(: enumerate all 375 unique configs, no random sampling) \
  --slurm --slurm-qos express_amsc --slurm-time 06:00:00          $(: SLURM array, express_amsc QoS, 6hr max) \
  --slurm-parallelism 16 --slurm-mem-per-job 16G                  $(: 16 syntheses per node, 16G RAM each = 256G per node)
