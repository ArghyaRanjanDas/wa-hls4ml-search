#!/bin/bash
# 100-task scale run with REAL models — production design-space sweep.
# express_amsc QoS caps at 32 concurrent nodes (GrpTRES=node=32) so the
# 100 tasks run in ~4 waves of 32. License pool (CatAIhls4ml_c, 105 seats)
# is NOT the bottleneck; the QoS node-cap is.
# Walltime 2h tuned for real models (~20-40 min each).
# Run from repo root: bash slurm/examples/run_scale.sh
source $SCRATCH/venv_hls4ml/bin/activate
python iter_manager_catapult.py \
  -o $SCRATCH/catapult_scale                              $(: output directory) \
  --catapult_shell Perlmutter_scripts/catapult_shell.sh   $(: Apptainer wrapper that launches Catapult) \
  --flow_tcl util/catapult_hls4ml_flow.tcl                $(: TCL script that drives HLS synthesis) \
  --license_config license_servers_perlmutter.json        $(: license server config) \
  --flow_config_json configs/catapult_flow/config_catapult_flow.json            $(: HLS flow parameters) \
  --gen_model_config_json configs/model_sweeps/config_dense_latency_fast.json  $(: real models to synthesize — 20-40 min each) \
  --batch_range 1 --batch_size 200                        $(: run batch 1, 200 tasks) \
  --slurm --slurm-qos express_amsc --slurm-time 02:00:00  $(: SLURM array, express_amsc QoS, 2 hr walltime) \
  --slurm-parallelism 16 --slurm-mem-per-job 16G          $(: 16 syntheses per node, 16G RAM each = 256G per node)
