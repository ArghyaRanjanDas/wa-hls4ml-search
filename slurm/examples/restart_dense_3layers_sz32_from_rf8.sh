#!/bin/bash
# Run sz32 extension from inp RF=8 onwards.
# - inp RF=1 and RF=4 are complete and archived — skipped entirely.
# - inp RF=8: resumes from existing run dir if present (or fresh if dir is gone);
#             all 10,368 designs are pending since catapult_shell.sh is now fixed.
# - inp RF=16, l1/l2/l3 all RF: fresh iter_manager runs.
#
# After each group completes, archives to the shared CFS store and removes the
# scratch directory automatically to keep $SCRATCH free.
#
# Run from repo root on an interactive CPU node:
#   salloc -N 1 -C cpu --qos=interactive -t 4:00:00 -A amsc011
#   bash slurm/examples/restart_dense_3layers_sz32_from_rf8.sh

source $SCRATCH/venv_hls4ml/bin/activate

COMMON_ARGS=(
  --catapult_shell Perlmutter_scripts/catapult_shell.sh
  --flow_tcl      util/catapult_hls4ml_flow.tcl
  --license_config license_servers_perlmutter.json
  --cartesian
  --slurm --slurm-qos express_amsc --slurm-time 00:30:00
  --slurm-parallelism 50 --slurm-mem-per-job 8G
)

PARALLELISM=50
CONCURRENT=4

# Archive the most recent run_* dir under BASE and remove scratch.
archive_and_clean() {
    local base="$1"
    local run_dir
    run_dir=$(ls -d "${base}"/run_*/ 2>/dev/null | sort | tail -1)
    if [ -z "$run_dir" ]; then
        echo "  WARNING: no run dir found in $base — skipping archive" >&2
        return
    fi
    bash slurm/examples/archive_run.sh "${run_dir%/}" --yes
}

# ── 1. inp RF=8: fresh run or resume from existing run dir ───────────────────
echo "=== inp RF=8 ==="
BASE="$SCRATCH/catapult_dense_3layers_sz32_inp_rf8"
RUN_DIR=$(ls -d "${BASE}"/run_*/ 2>/dev/null | sort | tail -1)

if [ -z "$RUN_DIR" ]; then
    echo "  No run dir found — running fresh via iter_manager"
    python iter_manager_catapult.py \
      -o "$BASE" \
      --gen_model_config_json "configs/model_sweeps/config_dense_3layers_sz32_inp.json" \
      --flow_config_json "configs/catapult_flow/config_catapult_flow_rf8.json" \
      "${COMMON_ARGS[@]}"
else
    JOBLIST="${RUN_DIR}joblist.txt"
    TAR_DIR="${RUN_DIR}tarballs"
    DONE=$(ls "${TAR_DIR}"/*.tar.gz 2>/dev/null | wc -l)
    TOTAL=$(wc -l < "$JOBLIST")

    if [ "$DONE" -ge "$TOTAL" ]; then
        echo "  Already complete ($DONE/$TOTAL) — skipping synthesis"
    else
        REMAIN_JOBLIST="${RUN_DIR}remaining_joblist.txt"
        python3 - "$JOBLIST" "$TAR_DIR" "$REMAIN_JOBLIST" <<'PYEOF'
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

        REMAIN=$(wc -l < "$REMAIN_JOBLIST")
        echo "  $DONE done, $REMAIN remaining — resubmitting"
        N_TASKS=$(( (REMAIN + PARALLELISM - 1) / PARALLELISM ))
        RESUME_SCRIPT="${RUN_DIR}resume_job_array.sh"
        sed -e "s|${JOBLIST}|${REMAIN_JOBLIST}|g" \
            -e "s|#SBATCH --array=.*|#SBATCH --array=0-$((N_TASKS - 1))%${CONCURRENT}|" \
            "${RUN_DIR}job_array.sh" > "$RESUME_SCRIPT"
        chmod +x "$RESUME_SCRIPT"
        JID=$(sbatch --parsable "$RESUME_SCRIPT")
        echo "  Submitted $N_TASKS-task array job $JID — waiting for completion..."
        until ! sacct -j "$JID" --format=State --noheader -P 2>/dev/null \
              | grep -qE "^(RUNNING|PENDING|COMPLETING)$"; do
            sleep 30
        done
        if sacct -j "$JID" --format=State --noheader -P 2>/dev/null \
           | grep -qE "^FAILED"; then
            echo "  ERROR: inp RF=8 job FAILED — check ${RUN_DIR}slurm_logs/ for details" >&2
            exit 1
        fi
        echo "  inp RF=8 done."
    fi
fi
echo "  Archiving inp RF=8..."
archive_and_clean "$BASE"

# ── 2. Fresh runs for inp RF=16 and all l1/l2/l3 groups ─────────────────────
for GROUP in inp l1 l2 l3; do
    for RF in 1 4 8 16; do
        # inp RF=1,4,8 already handled above — skip
        [ "$GROUP" = "inp" ] && [ "$RF" -ne 16 ] && continue

        if [ "$RF" -eq 16 ]; then
            FLOW_CFG=configs/catapult_flow/config_catapult_flow.json
        else
            FLOW_CFG=configs/catapult_flow/config_catapult_flow_rf${RF}.json
        fi
        echo "=== ${GROUP} RF=${RF} ==="
        python iter_manager_catapult.py \
          -o "$SCRATCH/catapult_dense_3layers_sz32_${GROUP}_rf${RF}" \
          --gen_model_config_json "configs/model_sweeps/config_dense_3layers_sz32_${GROUP}.json" \
          --flow_config_json "$FLOW_CFG" \
          "${COMMON_ARGS[@]}"
        echo "  Archiving ${GROUP} RF=${RF}..."
        archive_and_clean "$SCRATCH/catapult_dense_3layers_sz32_${GROUP}_rf${RF}"
    done
done

echo "All done."
