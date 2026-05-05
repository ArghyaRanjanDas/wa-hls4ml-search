#!/bin/bash
# Copy reports and tarballs from a run to the shared archive.
# Safe to run mid-run or multiple times — partial tarballs are replaced when
# complete, already-copied reports are skipped.
# Usage: bash slurm/examples/archive_run.sh <run_dir>
#
# Example:
#   bash slurm/examples/archive_run.sh $SCRATCH/catapult_dense_1to3layers/run_20260504_205339_a5d590d6

set -euo pipefail

RUN_DIR=${1:?Usage: $0 <run_dir>}
ARCHIVE_ROOT="/global/cfs/cdirs/amsc011/shared/wa-hls4ml-catapult"

RUN_NAME=$(basename "$RUN_DIR")
DEST="$ARCHIVE_ROOT/$RUN_NAME"

echo "Archiving $RUN_NAME → $DEST"

mkdir -p "$DEST/reports" "$DEST/tarballs"

rsync -av --ignore-existing \
    "$RUN_DIR/data/reports/raw/" "$DEST/reports/"

rsync -av --size-only \
    "$RUN_DIR/tarballs/" "$DEST/tarballs/"

echo "Done. Archived to $DEST"
echo "  Reports: $(ls "$DEST/reports" | wc -l) files"
echo "  Tarballs: $(ls "$DEST/tarballs" | wc -l) files"
