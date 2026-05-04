#!/bin/bash
# Remove run directories from $SCRATCH/catapult_runs.
# By default does a dry run — pass --confirm to actually delete.
# Run from anywhere: bash slurm/examples/clean_runs.sh [--confirm] [--keep N]
#
# Options:
#   --confirm      Actually delete (default is dry run)
#   --keep N       Keep the N most recent runs (default: 0, delete all)

set -euo pipefail

RUNS_DIR="${SCRATCH}/catapult_runs"
CONFIRM=0
KEEP=0

while [[ $# -gt 0 ]]; do
    case "$1" in
        --confirm) CONFIRM=1; shift ;;
        --keep)    KEEP="$2"; shift 2 ;;
        *) echo "Unknown option: $1"; exit 1 ;;
    esac
done

if [[ ! -d "$RUNS_DIR" ]]; then
    echo "Nothing to clean: $RUNS_DIR does not exist."
    exit 0
fi

# List runs sorted newest-first
mapfile -t ALL_RUNS < <(ls -1dt "$RUNS_DIR"/run_* 2>/dev/null)

TOTAL=${#ALL_RUNS[@]}
if [[ $TOTAL -eq 0 ]]; then
    echo "No runs found in $RUNS_DIR."
    exit 0
fi

# Determine which runs to delete (skip the N most recent)
if [[ $KEEP -ge $TOTAL ]]; then
    echo "Keeping all $TOTAL run(s) (--keep $KEEP >= total $TOTAL)."
    exit 0
fi

TO_DELETE=("${ALL_RUNS[@]:$KEEP}")

echo "Found $TOTAL run(s) in $RUNS_DIR"
echo "Keeping $KEEP most recent, deleting $((TOTAL - KEEP)):"
for d in "${TO_DELETE[@]}"; do
    SIZE=$(du -sh "$d" 2>/dev/null | cut -f1)
    echo "  $SIZE  $d"
done

if [[ $CONFIRM -eq 0 ]]; then
    echo ""
    echo "Dry run — nothing deleted. Re-run with --confirm to delete."
    exit 0
fi

echo ""
for d in "${TO_DELETE[@]}"; do
    echo "Removing $d ..."
    rm -rf "$d"
done
echo "Done."
