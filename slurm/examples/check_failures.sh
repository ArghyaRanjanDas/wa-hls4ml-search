#!/bin/bash
# Check which syntheses failed in a run directory.
# Reports three categories:
#   (1) Build dirs with no JSON report   — Catapult produced no parseable output
#   (2) Build dirs with no tarball       — report parsed but tarball creation failed
#   (3) SLURM tasks that failed          — non-zero exit or FAILED state in sacct
# Also dumps the last 20 lines of .err for any flagged SLURM tasks.
#
# Usage:
#   bash slurm/examples/check_failures.sh <run_dir>
#
# Example:
#   bash slurm/examples/check_failures.sh $SCRATCH/catapult_dense_1to3layers_cartesian/run_20260504_205339_a5d590d6

set -uo pipefail

RUN_DIR=${1:?Usage: $0 <run_dir>}

BUILD_ROOT="$RUN_DIR/build"
REPORT_DIR="$RUN_DIR/data/reports/raw"
TARBALL_DIR="$RUN_DIR/tarballs"
SLURM_LOGS="$RUN_DIR/slurm_logs"
JOBID_FILE="$RUN_DIR/slurm_job_id.txt"

NO_REPORT=()
NO_TARBALL=()

echo "=== Synthesis failure check: $RUN_DIR ==="
echo

# ── (1) Missing reports ─────────────────────────────────────────────────────
echo "--- (1) Build dirs missing JSON report ---"
if [ -d "$BUILD_ROOT" ]; then
    while IFS= read -r -d '' build_dir; do
        tag=$(basename "$(dirname "$build_dir")")
        report="$REPORT_DIR/${tag}.json"
        if [ ! -f "$report" ]; then
            NO_REPORT+=("$tag")
            echo "  MISSING REPORT: $tag"
        fi
    done < <(find "$BUILD_ROOT" -mindepth 2 -maxdepth 2 -type d -name "catapult_native" -print0 | sort -z)
else
    echo "  (no build directory found)"
fi
[ ${#NO_REPORT[@]} -eq 0 ] && echo "  (none)"
echo

# ── (2) Missing tarballs ─────────────────────────────────────────────────────
echo "--- (2) Build dirs missing tarball ---"
if [ -d "$BUILD_ROOT" ]; then
    while IFS= read -r -d '' build_dir; do
        tag=$(basename "$(dirname "$build_dir")")
        tarball="$TARBALL_DIR/${tag}.tar.gz"
        if [ ! -f "$tarball" ]; then
            NO_TARBALL+=("$tag")
            echo "  MISSING TARBALL: $tag"
        fi
    done < <(find "$BUILD_ROOT" -mindepth 2 -maxdepth 2 -type d -name "catapult_native" -print0 | sort -z)
else
    echo "  (no build directory found)"
fi
[ ${#NO_TARBALL[@]} -eq 0 ] && echo "  (none)"
echo

# ── (3) SLURM task failures ──────────────────────────────────────────────────
echo "--- (3) SLURM task failures ---"
FAILED_TASKS=()

if [ -f "$JOBID_FILE" ]; then
    JOB_ID=$(cat "$JOBID_FILE")
    echo "  Job ID: $JOB_ID"
    if command -v sacct &>/dev/null; then
        while IFS= read -r line; do
            task_id=$(echo "$line" | awk '{print $1}')
            state=$(echo "$line" | awk '{print $2}')
            exit_code=$(echo "$line" | awk '{print $3}')
            # Skip header, batch/extern sub-steps, and successful tasks
            [[ "$task_id" == "JobID" ]] && continue
            [[ "$task_id" == *".batch" || "$task_id" == *".extern" ]] && continue
            if [[ "$state" == "FAILED" || "$state" == "TIMEOUT" || "$state" == "CANCELLED" ]] || \
               [[ "$exit_code" != "0:0" && "$exit_code" != "" ]]; then
                FAILED_TASKS+=("$task_id")
                echo "  FAILED: $task_id  state=$state  exit=$exit_code"
            fi
        done < <(sacct -j "$JOB_ID" --format=JobID,State,ExitCode --noheader --parsable2 2>/dev/null | \
                 awk -F'|' '{print $1, $2, $3}')
    else
        echo "  sacct not available — skipping SLURM check"
    fi
elif [ -d "$SLURM_LOGS" ]; then
    # No job ID file; try to infer from log filenames (task_<N>.err)
    echo "  (no slurm_job_id.txt — scanning .err files for non-empty output)"
    while IFS= read -r err_file; do
        if [ -s "$err_file" ]; then
            task=$(basename "$err_file" .err)
            FAILED_TASKS+=("$task")
            echo "  NON-EMPTY STDERR: $err_file"
        fi
    done < <(find "$SLURM_LOGS" -name "task_*.err" | sort)
else
    echo "  (no SLURM logs found)"
fi
[ ${#FAILED_TASKS[@]} -eq 0 ] && echo "  (none)"
echo

# ── Dump stderr for failed SLURM tasks ───────────────────────────────────────
if [ ${#FAILED_TASKS[@]} -gt 0 ] && [ -d "$SLURM_LOGS" ]; then
    echo "--- Stderr tails for failed tasks ---"
    for task_id in "${FAILED_TASKS[@]}"; do
        # task_id may be "12345_7" (array) or "task_7" (from scan fallback)
        arr_idx="${task_id##*_}"
        err_file="$SLURM_LOGS/task_${arr_idx}.err"
        if [ ! -f "$err_file" ]; then
            err_file="$SLURM_LOGS/${task_id}.err"
        fi
        if [ -f "$err_file" ]; then
            echo
            echo "  [$task_id] last 20 lines of $(basename "$err_file"):"
            tail -n 20 "$err_file" | sed 's/^/    /'
        fi
    done
    echo
fi

# ── Summary ───────────────────────────────────────────────────────────────────
echo "=== Summary ==="
echo "  Missing reports : ${#NO_REPORT[@]}"
echo "  Missing tarballs: ${#NO_TARBALL[@]}"
echo "  Failed SLURM tasks: ${#FAILED_TASKS[@]}"

TOTAL_BUILDS=0
if [ -d "$BUILD_ROOT" ]; then
    TOTAL_BUILDS=$(find "$BUILD_ROOT" -mindepth 2 -maxdepth 2 -type d -name "catapult_native" | wc -l)
fi
TOTAL_REPORTS=0
[ -d "$REPORT_DIR" ] && TOTAL_REPORTS=$(find "$REPORT_DIR" -name "*.json" | wc -l)
echo "  Completed reports: $TOTAL_REPORTS / $TOTAL_BUILDS builds"
