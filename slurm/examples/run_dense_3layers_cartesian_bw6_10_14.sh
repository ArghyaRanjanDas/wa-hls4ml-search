#!/bin/bash
# Cartesian product run — 6561 3-layer dense NN configs with bitwidths 6, 10, 14
# (input 4-16, layers 4-16, relu/tanh/sigmoid independent per layer).
# Complements run_dense_3layers_cartesian_rf1.sh (bw 4,8,12).
# Formula: 3 inputs × (3 sizes × 3 acts)³ × 3 bw = 6561 designs.
#
# Run from repo root: bash slurm/examples/run_dense_3layers_cartesian_bw6_10_14.sh
source $SCRATCH/venv_hls4ml/bin/activate

python iter_manager_catapult.py \
  -o $SCRATCH/catapult_dense_3layers_cartesian_bw6_10_14               $(: output directory) \
  --catapult_shell Perlmutter_scripts/catapult_shell.sh                 $(: Apptainer wrapper that launches Catapult) \
  --flow_tcl      util/catapult_hls4ml_flow.tcl                        $(: TCL script that drives HLS synthesis) \
  --license_config license_servers_perlmutter.json                     $(: license server config) \
  --flow_config_json config_catapult_flow_rf1.json                     $(: HLS flow parameters, RF=1) \
  --gen_model_config_json config_dense_3layers_bw6_10_14.json          $(: 3-layer: sizes 4-16, relu/tanh/sigmoid, 6/10/14-bit) \
  --cartesian                                                           $(: enumerate all 6561 configs, no random sampling) \
  --slurm --slurm-qos express_amsc --slurm-time 00:30:00              $(: SLURM array, express_amsc QoS, 30min max) \
  --slurm-parallelism 64 --slurm-mem-per-job 4G                      $(: 64 syntheses per node, 4G RAM each = 256G per node)
