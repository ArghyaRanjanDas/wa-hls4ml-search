#!/bin/bash
# sz64 l1 group: input ∈ {4,8,16,32}, l1=64, l2/l3 ∈ {4,8,16,32,64}
#
# 4 batches: one per RF value — 16,200 designs each, 64,800 total.
#
# Run from repo root on an interactive CPU node:
#   salloc -N 1 -C cpu --qos=interactive -t 4:00:00 -A amsc011
#   source $SCRATCH/venv_hls4ml/bin/activate
#   bash slurm/examples/run_dense_3layers_sz64_l1.sh

set -euo pipefail

PARALLELISM=100
SLURM_TIME=48:00:00
SLURM_ACCOUNT=amsc011
SLURM_QOS=regular
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
    echo "  Waiting for SLURM job $jid (sacct, every 60s)..."
    sleep 15
    until ! sacct -j "$jid" --format=State --noheader -P 2>/dev/null \
          | grep -qE "^(RUNNING|PENDING|COMPLETING)$"; do
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
    local total done

    total=$(wc -l < "$joblist")
    done=$(ls "${tar_dir}"/*.tar.gz 2>/dev/null | wc -l)

    if (( done >= total )); then
        echo "  Complete ($done/$total)."
        return 0
    fi

    echo "  Incomplete: $done/$total — re-submitting with --resume-failed..."
    local jid
    jid=$(sbatch --parsable "${run_dir}/parallel_synth.sh")
    echo "  Re-submitted: $jid"
    wait_for_job "$jid"

    done=$(ls "${tar_dir}"/*.tar.gz 2>/dev/null | wc -l)
    if (( done < total )); then
        echo "  ERROR: still incomplete after resume ($done/$total)" >&2
        return 1
    fi
    echo "  Resume complete: $done/$total."
}

run_group() {
    local label="$1" model_cfg="$2" flow_cfg="$3"
    local base="${SCRATCH}/catapult_dense_3layers_sz64_${label}"

    echo ""
    echo "=== sz64 ${label} ==="

    local run_dir
    run_dir=$(ls -d "${base}"/run_*/ 2>/dev/null | sort | tail -1)
    run_dir="${run_dir%/}"

    if [[ -z "$run_dir" || ! -f "${run_dir}/joblist.txt" ]]; then
        python iter_manager_catapult.py \
            -o "$base" \
            --gen_model_config_json "$model_cfg" \
            --flow_config_json "$flow_cfg" \
            --catapult_shell Perlmutter_scripts/catapult_shell.sh \
            --flow_tcl util/catapult_hls4ml_flow.tcl \
            --cartesian \
            --prepare-only

        run_dir=$(ls -d "${base}"/run_*/ 2>/dev/null | sort | tail -1)
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

    cat > "$parallel_script" <<SBATCH_EOF
#!/bin/bash
#SBATCH --job-name=catapult_sz64_${label}
#SBATCH --account=${SLURM_ACCOUNT}
#SBATCH --nodes=1
#SBATCH --ntasks=1
#SBATCH --cpus-per-task=200
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

run_group l1_rf1  config_dense_3layers_sz64_l1.json config_catapult_flow_rf1.json
run_group l1_rf4  config_dense_3layers_sz64_l1.json config_catapult_flow_rf4.json
run_group l1_rf8  config_dense_3layers_sz64_l1.json config_catapult_flow_rf8.json
run_group l1_rf16 config_dense_3layers_sz64_l1.json config_catapult_flow.json

echo ""
echo "All l1 batches done."
