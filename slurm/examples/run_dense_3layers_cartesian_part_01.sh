#!/bin/bash
# Part 01/10 — 3-layer cartesian, RF=1
# Array tasks 0-40 → designs 0–655 (656 designs)
#
# Run run_dense_3layers_cartesian_rf1.sh first to generate the build dirs.
# Usage: bash slurm/examples/run_dense_3layers_cartesian_part_01.sh

RUN_DIR=$(ls -dt "$SCRATCH"/catapult_dense_3layers_cartesian_rf1/run_*/ 2>/dev/null | head -1)
RUN_DIR="${RUN_DIR%/}"

[ -n "$RUN_DIR" ] || { echo "ERROR: no run directory found under $SCRATCH/catapult_dense_3layers_cartesian_rf1/"; exit 1; }
[ -f "$RUN_DIR/job_array.sh" ] || { echo "ERROR: $RUN_DIR/job_array.sh not found — run the RF=1 init script first"; exit 1; }

echo "Submitting Part 01/10: array tasks 0-40 (designs 0-655)..."
JOB_ID=$(sbatch --array=0-40%12 --parsable "$RUN_DIR/job_array.sh")
echo "Part 01 submitted: job $JOB_ID"
echo "part=01 job=$JOB_ID tasks=0-40 designs=0-655" >> "$RUN_DIR/slurm_job_ids.txt"
