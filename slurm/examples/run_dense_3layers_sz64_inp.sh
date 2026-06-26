#!/bin/bash
# sz64 inp group: input=64, l1/l2/l3 ∈ {4,8,16,32,64}
# 8 batches: 4 RF values × 2 l1-size ranges
#   l1a: l1 ∈ {4,8,16,32} → 16,200 designs/batch
#   l1b: l1 = 64          →  4,050 designs/batch
#
# ── Two-level scheduling ──────────────────────────────────────────────────────
# This script is an ORCHESTRATOR: it loops over RF groups, submitting one
# synthesis batch job at a time (express_amsc, 5.5 h, 100 Catapult slots) and
# waiting for it to finish before moving to the next.  The orchestrator itself
# uses almost no CPU — it just polls squeue every 60 s.
#
# PREFERRED — submit the orchestrator as a shared batch job (2 CPUs, 48 h):
#
#   REPO=/global/u2/g/gdg/research/projects/genesis/wa-hls4ml-paper/wa-hls4ml-search
#   sbatch --job-name=orch_sz64_inp --account=amsc011 \
#     --ntasks=1 --cpus-per-task=2 --mem=16G --constraint=cpu \
#     --time=48:00:00 --qos=shared \
#     --output=$SCRATCH/orch_sz64_inp.out --error=$SCRATCH/orch_sz64_inp.err \
#     --wrap="source \$SCRATCH/venv_hls4ml/bin/activate && \
#             cd $REPO && bash slurm/examples/run_dense_3layers_sz64_inp.sh"
#
# ALTERNATIVE — run interactively (session must outlive all rounds, ~86 h):
#   salloc -N 1 -C cpu --qos=interactive -t 4:00:00 -A amsc011
#   source $SCRATCH/venv_hls4ml/bin/activate
#   bash slurm/examples/run_dense_3layers_sz64_inp.sh
#
# Crash recovery: re-submitting the same command always resumes from where it
# left off — existing run dirs and completed tarballs are reused automatically.
# Run ONE group at a time to stay within the 100-license limit.
# ─────────────────────────────────────────────────────────────────────────────

set -euo pipefail

PARALLELISM=128
SLURM_TIME=05:30:00
SLURM_ACCOUNT=amsc011
SLURM_QOS=express_amsc
SLURM_CONSTRAINT=cpu

REPO_DIR="$(cd "$(dirname "${BASH_SOURCE[0]}")/../.." && pwd)"
VENV="${WA_HLS4ML_VENV:-${SCRATCH}/venv_hls4ml/bin/activate}"

LM_LICENSE_FILE=$(python3 -c "
import json
with open('${REPO_DIR}/license_servers_perlmutter.json') as f:
    cfg = json.load(f)
print(':'.join(f\"{s['port']}@{s['host']}\" for s in cfg['servers']))
")

# ── Helpers ───────────────────────────────────────────────────────────────────

wait_for_job() {
    local jid="$1"
    echo "  Waiting for SLURM job $jid (squeue, every 60s)..."
    sleep 30
    while squeue -j "$jid" -h 2>/dev/null | grep -q .; do
        sleep 60
    done
    local states
    states=$(sacct -j "$jid" --format=State --noheader -P 2>/dev/null | sort | uniq -c)
    echo "  Job $jid final states: $states"
}

resume_if_incomplete() {
    local run_dir="$1"
    local joblist="${run_dir}/joblist.txt"
    local tar_dir="${run_dir}/tarballs"
    local total done max_rounds=20 round=0

    total=$(wc -l < "$joblist")
    done=$(ls "${tar_dir}"/*.tar.gz 2>/dev/null | wc -l)

    while (( done < total && round < max_rounds )); do
        round=$(( round + 1 ))
        echo "  Incomplete: $done/$total — re-submitting (round $round/$max_rounds)..."
        local jid
        jid=$(sbatch --parsable "${run_dir}/parallel_synth.sh")
        echo "  Submitted: $jid"
        wait_for_job "$jid"
        done=$(ls "${tar_dir}"/*.tar.gz 2>/dev/null | wc -l)
    done

    if (( done >= total )); then
        echo "  Complete ($done/$total)."
        return 0
    fi
    echo "  ERROR: still incomplete after $max_rounds rounds ($done/$total)" >&2
    return 1
}

run_group() {
    local label="$1" model_cfg="$2" flow_cfg="$3"
    local base="${SCRATCH}/catapult_dense_3layers_sz64_${label}"

    echo ""
    echo "=== sz64 ${label} ==="

    # Reuse existing run_dir if present (crash recovery / manual resume)
    local run_dir
    run_dir=$(ls -d "${base}"/run_*/ 2>/dev/null | sort | tail -1 || true)
    run_dir="${run_dir%/}"

    if [[ -z "$run_dir" || ! -f "${run_dir}/joblist.txt" ]]; then
        # Phase 1: model generation — fast, runs on this interactive node
        python iter_manager_catapult.py \
            -o "$base" \
            --gen_model_config_json "$model_cfg" \
            --flow_config_json "$flow_cfg" \
            --catapult_shell Perlmutter_scripts/catapult_shell.sh \
            --flow_tcl util/catapult_hls4ml_flow.tcl \
            --cartesian \
            --prepare-only

        run_dir=$(ls -d "${base}"/run_*/ 2>/dev/null | sort | tail -1 || true)
        run_dir="${run_dir%/}"
    else
        echo "  Reusing: $run_dir"
    fi

    [[ -n "$run_dir" ]] || { echo "ERROR: no run dir created under $base" >&2; return 1; }

    local joblist="${run_dir}/joblist.txt"
    local joblog="${run_dir}/parallel.log"
    local slurm_logs="${run_dir}/slurm_logs"
    local parallel_script="${run_dir}/parallel_synth.sh"
    mkdir -p "$slurm_logs"

    # Phase 2: write SLURM batch job (always rewritten — idempotent)
    cat > "$parallel_script" <<SBATCH_EOF
#!/bin/bash
#SBATCH --job-name=catapult_sz64_${label}
#SBATCH --account=${SLURM_ACCOUNT}
#SBATCH --nodes=1
#SBATCH --ntasks=1
#SBATCH --cpus-per-task=256
#SBATCH --mem=400G
#SBATCH --constraint=${SLURM_CONSTRAINT}
#SBATCH --time=${SLURM_TIME}
#SBATCH --qos=${SLURM_QOS}
#SBATCH --output=${slurm_logs}/parallel.out
#SBATCH --error=${slurm_logs}/parallel.err

set -euo pipefail
source "${VENV}"
export LM_LICENSE_FILE="${LM_LICENSE_FILE}"
cd "${REPO_DIR}"

parallel \\
    --joblog "${joblog}" \\
    --resume-failed \\
    --line-buffer \\
    -j ${PARALLELISM} \\
    python "${REPO_DIR}/iter_manager_catapult.py" -o "${base}" --run-single-job {} \\
    < "${joblist}"
SBATCH_EOF
    chmod +x "$parallel_script"

    local jid
    jid=$(sbatch --parsable "$parallel_script")
    echo "  Submitted: $jid ($(wc -l < "$joblist") designs, $PARALLELISM parallel slots)"
    wait_for_job "$jid"

    resume_if_incomplete "${run_dir}" || return 1

    echo "  Archiving ${label}..."
    bash slurm/examples/archive_run.sh "${run_dir}" --yes
    echo "  Done: ${label}."
}

# ── Main ──────────────────────────────────────────────────────────────────────

# RF=1 (configs/catapult_flow/config_catapult_flow_rf1.json)
run_group inp_rf1_l1a configs/model_sweeps/config_dense_3layers_sz64_inp_l1a.json configs/catapult_flow/config_catapult_flow_rf1.json
run_group inp_rf1_l1b configs/model_sweeps/config_dense_3layers_sz64_inp_l1b.json configs/catapult_flow/config_catapult_flow_rf1.json

# RF=4
run_group inp_rf4_l1a configs/model_sweeps/config_dense_3layers_sz64_inp_l1a.json configs/catapult_flow/config_catapult_flow_rf4.json
run_group inp_rf4_l1b configs/model_sweeps/config_dense_3layers_sz64_inp_l1b.json configs/catapult_flow/config_catapult_flow_rf4.json

# RF=8
run_group inp_rf8_l1a configs/model_sweeps/config_dense_3layers_sz64_inp_l1a.json configs/catapult_flow/config_catapult_flow_rf8.json
run_group inp_rf8_l1b configs/model_sweeps/config_dense_3layers_sz64_inp_l1b.json configs/catapult_flow/config_catapult_flow_rf8.json

# RF=16 (configs/catapult_flow/config_catapult_flow.json = default RF=16)
run_group inp_rf16_l1a configs/model_sweeps/config_dense_3layers_sz64_inp_l1a.json configs/catapult_flow/config_catapult_flow.json
run_group inp_rf16_l1b configs/model_sweeps/config_dense_3layers_sz64_inp_l1b.json configs/catapult_flow/config_catapult_flow.json

echo ""
echo "All inp batches done."
