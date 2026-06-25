#!/bin/bash
# Submit failed-design re-run jobs sequentially — one at a time.
# Each job must complete before the next is submitted.
# Uses run_rerun_from_archive.sh — no --prepare-only.
#
# Usage (submit this script itself as a long-running shared job):
#   REPO=/global/u2/g/gdg/research/projects/genesis/wa-hls4ml-paper/wa-hls4ml-search
#   sbatch --job-name=rerun_seq --account=amsc011 --qos=shared \
#     --ntasks=1 --cpus-per-task=2 --mem=4G --constraint=cpu --time=2-00:00:00 \
#     --output=$SCRATCH/rerun_seq.out --wrap="cd $REPO && bash slurm/examples/submit_reruns.sh"

set -euo pipefail

REPO=/global/u2/g/gdg/research/projects/genesis/wa-hls4ml-paper/wa-hls4ml-search

submit_rerun() {
    local orig_run="$1" flow_cfg="$2" label="$3"
    local keep="${KEEP_SCRATCH:-0}"
    echo "  Starting rerun_${label} ..."
    sbatch --wait \
        --job-name="rerun_${label}" \
        --account=amsc011 \
        --qos=shared \
        --ntasks=1 --cpus-per-task=2 --mem=16G \
        --constraint=cpu \
        --time=2-00:00:00 \
        --output="$SCRATCH/rerun_${label}.out" \
        --error="$SCRATCH/rerun_${label}.err" \
        --wrap="source \$SCRATCH/venv_hls4ml/bin/activate && cd $REPO && \
                ORIG_RUN=${orig_run} \
                FLOW_CFG=${flow_cfg} \
                KEEP_SCRATCH=${keep} \
                bash slurm/examples/run_rerun_from_archive.sh"
    echo "  Done: rerun_${label}"
}

echo "Running re-run jobs sequentially..."

#                                                                             label         failures
#KEEP_SCRATCH=1 submit_rerun run_20260531_093401_e6edde98 configs/catapult_flow/config_catapult_flow_rf1.json     sz64_l1_rf1   # 503
#KEEP_SCRATCH=1 submit_rerun run_20260522_214453_7dd5508f configs/catapult_flow/config_catapult_flow_rf1.json     sz64_l3_rf1   # 459
#KEEP_SCRATCH=1 submit_rerun run_20260527_074357_aff0d65c configs/catapult_flow/config_catapult_flow_rf1.json     sz64_l2_rf1   # 333
#KEEP_SCRATCH=1 submit_rerun run_20260601_090902_4db63227 configs/catapult_flow/config_catapult_flow_rf4.json     sz64_l1_rf4   # 251
#KEEP_SCRATCH=1 submit_rerun run_20260528_121757_f758fd3a configs/catapult_flow/config_catapult_flow_rf4.json     sz64_l2_rf4   # 235
#KEEP_SCRATCH=1 submit_rerun run_20260521_193026_cba4319e configs/catapult_flow/config_catapult_flow.json         sz32_l3_rf16  # 212
#KEEP_SCRATCH=1 submit_rerun run_20260601_091721_d8d2e774 configs/catapult_flow/config_catapult_flow_rf8.json     sz64_l1_rf8   # 186
#KEEP_SCRATCH=1 submit_rerun run_20260530_130622_1329d506 configs/catapult_flow/config_catapult_flow.json         sz64_l2_rf16  # 147
#KEEP_SCRATCH=1 submit_rerun run_20260529_131718_42b83b2b configs/catapult_flow/config_catapult_flow_rf8.json     sz64_l2_rf8   # 136
#KEEP_SCRATCH=1 submit_rerun run_20260602_175454_3852b272 configs/catapult_flow/config_catapult_flow.json         sz64_l1_rf16  # 104
#KEEP_SCRATCH=1 submit_rerun run_20260524_141002_d30e0a91 configs/catapult_flow/config_catapult_flow_rf4.json     sz64_l3_rf4   #  69
#KEEP_SCRATCH=1 submit_rerun run_20260525_095507_5d107c91 configs/catapult_flow/config_catapult_flow_rf8.json     sz64_l3_rf8   #  44
#KEEP_SCRATCH=1 submit_rerun run_20260526_025959_d64af1bb configs/catapult_flow/config_catapult_flow.json         sz64_l3_rf16  #  14
#                                                                                      total: 2,695

# ── inp group — populate failed_designs.txt first (see note below) ────────────
KEEP_SCRATCH=1 submit_rerun run_20260603_083059_83e7d4d3 configs/catapult_flow/config_catapult_flow_rf1.json     sz64_inp_rf1_l1a  # 165
KEEP_SCRATCH=1 submit_rerun run_20260603_083059_aef76e2f configs/catapult_flow/config_catapult_flow_rf4.json     sz64_inp_rf4_l1a  #  99
KEEP_SCRATCH=1 submit_rerun run_20260604_173538_d4da9e4b configs/catapult_flow/config_catapult_flow_rf4.json     sz64_inp_rf4_l1b  #  19
#                                                                                      inp total: 283
#
# Before uncommenting, populate failed_designs.txt:
#   python3 slurm/examples/populate_failed_designs.py \
#     run_20260603_083059_83e7d4d3 run_20260603_083059_aef76e2f run_20260604_173538_d4da9e4b

echo ""
echo "All sequential re-run jobs complete."
