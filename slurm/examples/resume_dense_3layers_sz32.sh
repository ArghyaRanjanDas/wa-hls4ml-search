#!/bin/bash
# Resume 3-layer size=32 extension synthesis after a SLURM downtime.
#
# For each group/RF, finds the existing run_* directory, identifies which
# designs still lack a tarball, writes a filtered remaining_joblist.txt,
# patches job_array.sh to use it, and re-submits via sbatch.
#
# inp RF=1 and RF=4 are complete and archived (scratch dirs deleted) — skipped.
# Safe to run multiple times: skips groups that are already complete.
# Run from repo root: bash slurm/examples/resume_dense_3layers_sz32.sh

PARALLELISM=50
CONCURRENT=4

for GROUP in inp l1 l2 l3; do
    for RF in 1 4 8 16; do
        # inp RF=1 and RF=4 are archived; scratch dirs gone — nothing to resume
        [ "$GROUP" = "inp" ] && [ "$RF" -eq 1 ] && { printf "  [ARCH]   sz32-inp   RF=1   — complete and archived\n"; continue; }
        [ "$GROUP" = "inp" ] && [ "$RF" -eq 4 ] && { printf "  [ARCH]   sz32-inp   RF=4   — complete and archived\n"; continue; }

        BASE="$SCRATCH/catapult_dense_3layers_sz32_${GROUP}_rf${RF}"

        # Find most recent run dir (there should be exactly one)
        RUN_DIR=$(ls -d "${BASE}"/run_*/ 2>/dev/null | sort | tail -1)
        if [ -z "$RUN_DIR" ]; then
            printf "  [SKIP]   sz32-%-6s RF=%-2s  — no run dir yet\n" "$GROUP" "$RF"
            continue
        fi

        JOBLIST="${RUN_DIR}joblist.txt"
        TAR_DIR="${RUN_DIR}tarballs"
        TOTAL=$(wc -l < "$JOBLIST")
        DONE=$(ls "${TAR_DIR}"/*.tar.gz 2>/dev/null | wc -l)

        if [ "$DONE" -ge "$TOTAL" ]; then
            printf "  [DONE]   sz32-%-6s RF=%-2s  — %d/%d complete\n" "$GROUP" "$RF" "$DONE" "$TOTAL"
            continue
        fi

        REMAIN_JOBLIST="${RUN_DIR}remaining_joblist.txt"

        # Filter joblist to only jobs whose tarball is missing
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
        printf "  [RESUME] sz32-%-6s RF=%-2s  — %d done, %d remaining\n" \
               "$GROUP" "$RF" "$DONE" "$REMAIN"

        # Compute new array size and write patched sbatch script
        N_TASKS=$(( (REMAIN + PARALLELISM - 1) / PARALLELISM ))
        RESUME_SCRIPT="${RUN_DIR}resume_job_array.sh"

        sed -e "s|${JOBLIST}|${REMAIN_JOBLIST}|g" \
            -e "s|#SBATCH --array=.*|#SBATCH --array=0-$((N_TASKS - 1))%${CONCURRENT}|" \
            "${RUN_DIR}job_array.sh" > "$RESUME_SCRIPT"
        chmod +x "$RESUME_SCRIPT"

        JID=$(sbatch --parsable "$RESUME_SCRIPT")
        printf "           Submitted %d-task array job %s\n" "$N_TASKS" "$JID"
    done
done
