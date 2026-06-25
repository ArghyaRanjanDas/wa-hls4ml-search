#!/bin/bash
# Full Cartesian product run — all 2,880 unique 2-layer dense NN configs
# (input 4-32, hidden 4-32, output 4-32, independent activations per layer,
# relu/tanh/sigmoid, bitwidth 4-12 even). No random sampling.
#
# Run from repo root: bash slurm/examples/run_dense_2layers_cartesian.sh
source $SCRATCH/venv_hls4ml/bin/activate

python iter_manager_catapult.py \
  -o $SCRATCH/catapult_dense_2layers_cartesian                   $(: output directory) \
  --catapult_shell Perlmutter_scripts/catapult_shell.sh          $(: Apptainer wrapper that launches Catapult) \
  --flow_tcl util/catapult_hls4ml_flow.tcl                       $(: TCL script that drives HLS synthesis) \
  --license_config license_servers_perlmutter.json               $(: license server config) \
  --flow_config_json configs/catapult_flow/config_catapult_flow.json                   $(: HLS flow parameters) \
  --gen_model_config_json configs/model_sweeps/config_dense_2layers.json              $(: 2-layer: in/hidden/out 4-32, relu/tanh/sigmoid, 4-12-bit) \
  --cartesian                                                     $(: enumerate all 2880 unique configs, no random sampling) \
  --slurm --slurm-qos express_amsc --slurm-time 06:00:00         $(: SLURM array, express_amsc QoS, 6hr max) \
  --slurm-parallelism 16 --slurm-mem-per-job 16G                 $(: 16 syntheses per node, 16G RAM each = 256G per node)
