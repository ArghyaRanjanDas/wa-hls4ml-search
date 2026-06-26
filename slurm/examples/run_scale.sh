#!/bin/bash
# 100-task scale run with REAL models — production design-space sweep.
# express_amsc QoS caps at 32 concurrent nodes (GrpTRES=node=32) so the
# 100 tasks run in ~4 waves of 32. License pool (CatAIhls4ml_c, 105 seats)
# is NOT the bottleneck; the QoS node-cap is.
# Walltime 2h tuned for real models (~20-40 min each).
# Run from repo root: bash slurm/examples/run_scale.sh
source $SCRATCH/venv_hls4ml/bin/activate
python iter_manager_catapult.py \
  -o $SCRATCH/catapult_scale \
  --catapult_shell Perlmutter_scripts/catapult_shell.sh \
  --flow_tcl util/catapult_hls4ml_flow.tcl \
  --license_config license_servers_perlmutter.json \
  --flow_config_json config_catapult_flow.json \
  --gen_model_config_json config_dense_latency_fast.json \
  --batch_range 1 --batch_size 100 \
  --slurm --slurm-qos express_amsc --slurm-time 02:00:00
