#!/bin/bash
# Step 3 — 3-layer dense cartesian sweep, RF=1.
# Same design space as run_dense_3layers_cartesian.sh but with RF=1.
# Generates 6561 build directories then fails at SLURM submission if budget
# is insufficient — use the part scripts to submit in budget-sized chunks.
#
# Run from repo root: bash slurm/examples/run_dense_3layers_cartesian_rf1.sh
source $SCRATCH/venv_hls4ml/bin/activate

python iter_manager_catapult.py \
  -o $SCRATCH/catapult_dense_3layers_cartesian_rf1                      \
  --catapult_shell Perlmutter_scripts/catapult_shell.sh                 \
  --flow_tcl      util/catapult_hls4ml_flow.tcl                        \
  --license_config license_servers_perlmutter.json                     \
  --flow_config_json config_catapult_flow_rf1.json                     \
  --gen_model_config_json config_dense_3layers.json                    \
  --cartesian                                                           \
  --slurm --slurm-qos express_amsc --slurm-time 06:00:00              \
  --slurm-parallelism 16 --slurm-mem-per-job 16G
