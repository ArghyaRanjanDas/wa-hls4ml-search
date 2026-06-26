#!/bin/bash
# Run remaining sz32 groups: l2 RF=16 and l3 RF=1,4,8,16.
#
# Improvements over the previous restart script:
#   - 1-hour SLURM time limit (30 min caused timeouts for larger l2/l3 designs)
#   - resume_if_incomplete: after every iter_manager call, checks tarball count
#     and resubmits missing designs using sacct-based polling (not squeue).
#     This self-recovers from both timeouts and squeue COMPLETING ghosts.
#   - archive_and_clean only runs after completeness is verified.
#
# If iter_manager hangs (squeue ghost): kill it manually with `kill <PID>`.
# The script will detect the incomplete tarballs and resume automatically.
#
# Run from repo root on an interactive CPU node:
#   salloc -N 1 -C cpu --qos=interactive -t 12:00:00 -A amsc011
#   source $SCRATCH/venv_hls4ml/bin/activate
#   bash slurm/examples/run_dense_3layers_sz32_remaining.sh

PARALLELISM=100
CONCURRENT=2
SLURM_TIME=01:00:00

COMMON_ARGS=(
  --catapult_shell Perlmutter_scripts/catapult_shell.sh
  --flow_tcl      util/catapult_hls4ml_flow.tcl
  --license_config license_servers_perlmutter.json
  --cartesian
  --slurm --slurm-qos express_amsc --slurm-time "$SLURM_TIME"
  --slurm-parallelism "$PARALLELISM" --slurm-mem-per-job 4G
)

# ── Helpers ───────────────────────────────────────────────────────────────────

# Poll sacct (not squeue) until a job array is fully done.
# Returns 1 if any tasks FAILED.
wait_for_job() {
    local jid="$1"
    echo "  Waiting for job $jid (sacct, every 30s)..."
    sleep 10  # give sacct time to register the new job
    until ! sacct -j "$jid" --format=State --noheader -P 2>/dev/null \
          | grep -qE "^(RUNNING|PENDING|COMPLETING)$"; do
        sleep 30
    done
    local states
    states=$(sacct -j "$jid" --format=State --noheader -P 2>/dev/null | sort | uniq -c)
    echo "  Job $jid final states: $states"
    if echo "$states" | grep -q "FAILED"; then
        echo "  ERROR: job $jid has FAILED tasks." >&2
        return 1
    fi
}

# After iter_manager returns, check tarball count.
# If incomplete, compute remaining_joblist, resubmit with sacct polling.
# Repeats once — if still incomplete after resume, exits with error.
resume_if_incomplete() {
    local run_dir="$1"
    local joblist="${run_dir}/joblist.txt"
    local tar_dir="${run_dir}/tarballs"
    local total done

    total=$(wc -l < "$joblist")
    done=$(ls "${tar_dir}"/*.tar.gz 2>/dev/null | wc -l)

    if [ "$done" -ge "$total" ]; then
        echo "  Complete ($done/$total)."
        return 0
    fi

    echo "  Incomplete: $done/$total — resuming $(( total - done )) missing designs..."

    local remain_joblist="${run_dir}/remaining_joblist.txt"
    python3 - "$joblist" "$tar_dir" "$remain_joblist" <<'PYEOF'
import sys, os, glob
joblist_path, tar_dir, out_path = sys.argv[1], sys.argv[2], sys.argv[3]
done_tags = {os.path.basename(f)[:-len('.tar.gz')]
             for f in glob.glob(os.path.join(tar_dir, '*.tar.gz'))}
remaining = [line.rstrip('\n') for line in open(joblist_path)
             if line.strip() and os.path.basename(line.split('\t')[0]) not in done_tags]
with open(out_path, 'w') as f:
    f.write('\n'.join(remaining) + '\n')
print(len(remaining))
PYEOF

    local remain n_tasks resume_script jid
    remain=$(wc -l < "$remain_joblist")
    n_tasks=$(( (remain + PARALLELISM - 1) / PARALLELISM ))
    resume_script="${run_dir}/resume_job_array.sh"

    sed -e "s|${joblist}|${remain_joblist}|g" \
        -e "s|#SBATCH --array=.*|#SBATCH --array=0-$((n_tasks - 1))%${CONCURRENT}|" \
        -e "s|#SBATCH --time=.*|#SBATCH --time=${SLURM_TIME}|" \
        "${run_dir}/job_array.sh" > "$resume_script"
    chmod +x "$resume_script"

    jid=$(sbatch --parsable "$resume_script")
    echo "  Submitted resume: $n_tasks-task array job $jid"
    wait_for_job "$jid" || return 1

    # Final verification
    done=$(ls "${tar_dir}"/*.tar.gz 2>/dev/null | wc -l)
    if [ "$done" -lt "$total" ]; then
        echo "  ERROR: still incomplete after resume ($done/$total). Manual intervention needed." >&2
        return 1
    fi
    echo "  Resume complete: $done/$total."
}

# Archive and clean scratch for the most recent run_* dir under BASE.
# Only called after resume_if_incomplete confirms completeness.
archive_and_clean() {
    local base="$1"
    local run_dir
    run_dir=$(ls -d "${base}"/run_*/ 2>/dev/null | sort | tail -1)
    if [ -z "$run_dir" ]; then
        echo "  WARNING: no run dir found in $base — skipping archive" >&2
        return 1
    fi
    bash slurm/examples/archive_run.sh "${run_dir%/}" --yes
}

# Run one group/RF end-to-end: generate+submit via iter_manager, verify,
# resume if needed, then archive.
run_group() {
    local group="$1" rf="$2" model_cfg="$3" flow_cfg="$4"
    local base="$SCRATCH/catapult_dense_3layers_sz32_${group}_rf${rf}"

    echo ""
    echo "=== ${group} RF=${rf} ==="

    python iter_manager_catapult.py \
      -o "$base" \
      --gen_model_config_json "$model_cfg" \
      --flow_config_json "$flow_cfg" \
      "${COMMON_ARGS[@]}"

    # iter_manager may have exited normally or been killed (squeue ghost).
    # Either way, verify and resume if needed.
    local run_dir
    run_dir=$(ls -d "${base}"/run_*/ 2>/dev/null | sort | tail -1)
    if [ -z "$run_dir" ]; then
        echo "  ERROR: no run dir under $base after iter_manager" >&2
        return 1
    fi

    resume_if_incomplete "${run_dir%/}" || return 1

    echo "  Archiving ${group} RF=${rf}..."
    archive_and_clean "$base" || return 1
    echo "  Done: ${group} RF=${rf}."
}

# ── Main ──────────────────────────────────────────────────────────────────────

run_group l2 16 configs/model_sweeps/config_dense_3layers_sz32_l2.json configs/catapult_flow/config_catapult_flow.json

run_group l3  1 configs/model_sweeps/config_dense_3layers_sz32_l3.json configs/catapult_flow/config_catapult_flow_rf1.json
run_group l3  4 configs/model_sweeps/config_dense_3layers_sz32_l3.json configs/catapult_flow/config_catapult_flow_rf4.json
run_group l3  8 configs/model_sweeps/config_dense_3layers_sz32_l3.json configs/catapult_flow/config_catapult_flow_rf8.json
run_group l3 16 configs/model_sweeps/config_dense_3layers_sz32_l3.json configs/catapult_flow/config_catapult_flow.json

echo ""
echo "All done."
