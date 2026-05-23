#!/bin/bash
# Copy reports and tarballs from a run to the shared archive.
# Safe to run mid-run or multiple times — partial tarballs are replaced when
# complete, already-copied reports are skipped.
# Usage: bash slurm/examples/archive_run.sh <run_dir> [--yes]
#
# --yes  Skip the interactive prompt and remove scratch data automatically
#        (only when archive counts are fully verified).
#
# Example:
#   bash slurm/examples/archive_run.sh $SCRATCH/catapult_dense_1to3layers/run_20260504_205339_a5d590d6
#   bash slurm/examples/archive_run.sh $SCRATCH/.../run_... --yes

set -euo pipefail

RUN_DIR=""
AUTO_YES=0
for arg in "$@"; do
    case "$arg" in
        --yes|-y) AUTO_YES=1 ;;
        -*) echo "ERROR: unknown flag $arg" >&2; exit 1 ;;
        *)  RUN_DIR="$arg" ;;
    esac
done
[ -n "$RUN_DIR" ] || { echo "Usage: $0 <run_dir> [--yes]" >&2; exit 1; }

ARCHIVE_ROOT="/global/cfs/cdirs/amsc011/shared/wa-hls4ml-catapult"

RUN_NAME=$(basename "$RUN_DIR")
DEST="$ARCHIVE_ROOT/$RUN_NAME"

echo "Archiving $RUN_NAME → $DEST"

mkdir -p "$DEST/reports" "$DEST/tarballs"
echo "$RUN_DIR" > "$DEST/source_dir.txt"

rsync -a --info=progress2 --ignore-existing \
    "$RUN_DIR/data/reports/raw/" "$DEST/reports/"

rsync -a --info=progress2 --size-only \
    "$RUN_DIR/tarballs/" "$DEST/tarballs/"

echo "Done. Archived to $DEST"
echo "  Reports: $(ls "$DEST/reports" | wc -l) files"
echo "  Tarballs: $(ls "$DEST/tarballs" | wc -l) files"

# ── Verify archive completeness before offering to clean scratch ─────────────
JOBS=$(wc -l < "$RUN_DIR/joblist.txt" 2>/dev/null || echo 0)
SCRATCH_TARBALLS=$(ls "$RUN_DIR/tarballs/" 2>/dev/null | wc -l)
ARCH_TARBALLS=$(ls "$DEST/tarballs/" 2>/dev/null | wc -l)
ARCH_REPORTS=$(ls "$DEST/reports/" 2>/dev/null | wc -l)

echo ""
echo "Verification:"
echo "  Expected (joblist):      $JOBS"
echo "  Scratch tarballs:        $SCRATCH_TARBALLS"
echo "  Archived tarballs:       $ARCH_TARBALLS"
echo "  Archived reports:        $ARCH_REPORTS"

if [ "$JOBS" -eq 0 ] || [ "$ARCH_TARBALLS" -ne "$JOBS" ] || [ "$ARCH_REPORTS" -ne "$JOBS" ]; then
    echo ""
    echo "WARNING: archive counts do not match joblist ($JOBS expected)."
    echo "  Scratch data will NOT be removed. Re-run archive once complete."
    exit 0
fi

echo "  ✅ All $JOBS designs verified in archive."
echo ""

# ── Remove scratch data ───────────────────────────────────────────────────────
_do_remove() {
    echo "Removing $RUN_DIR..."
    find "$RUN_DIR" -type f -print0 | xargs -0 -P 64 rm -f
    find "$RUN_DIR" -depth -type d -empty -delete
    echo "Removed."
}

if [ "$AUTO_YES" -eq 1 ]; then
    _do_remove
elif [ -t 0 ]; then
    read -r -p "Remove scratch data at $RUN_DIR? [y/N] " answer
    case "$answer" in
        [yY][eE][sS]|[yY]) _do_remove ;;
        *) echo "Skipped. To remove manually: rm -rf $RUN_DIR" ;;
    esac
else
    echo "Non-interactive mode — skipping scratch removal. Run manually:"
    echo "  rm -rf $RUN_DIR"
fi
