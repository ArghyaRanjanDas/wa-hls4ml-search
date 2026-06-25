#!/bin/bash
# Re-run failed designs for one archived run group and merge results back into
# the original archive entry.
#
# Parametrized via environment variables (set inline with --wrap):
#   ORIG_RUN      — archive run dir name, e.g. run_20260531_093401_e6edde98
#   MODEL_CFG     — model config JSON,   e.g. configs/model_sweeps/config_dense_3layers_sz64_l1.json
#   FLOW_CFG      — flow config JSON,    e.g. configs/catapult_flow/config_catapult_flow_rf1.json
#   KEEP_SCRATCH  — set to 1 to skip scratch cleanup (for manual inspection)
#
# Submit (all 13 groups in parallel) with submit_reruns.sh or manually:
#   REPO=/global/u2/g/gdg/research/projects/genesis/wa-hls4ml-paper/wa-hls4ml-search
#   sbatch --job-name=rerun_<group> --account=amsc011 --qos=shared \
#     --ntasks=1 --cpus-per-task=2 --mem=16G --constraint=cpu \
#     --time=2-00:00:00 \
#     --output=$SCRATCH/rerun_<group>.out --error=$SCRATCH/rerun_<group>.err \
#     --wrap="source \$SCRATCH/venv_hls4ml/bin/activate && cd $REPO && \
#             ORIG_RUN=<run> MODEL_CFG=<model.json> FLOW_CFG=<flow.json> \
#             bash slurm/examples/run_rerun_failed.sh"

set -euo pipefail

: "${ORIG_RUN:?  env var ORIG_RUN must be set}"
: "${MODEL_CFG:? env var MODEL_CFG must be set}"
: "${FLOW_CFG:?  env var FLOW_CFG must be set}"
KEEP_SCRATCH="${KEEP_SCRATCH:-0}"

PARALLELISM=100
SLURM_TIME=05:30:00
SLURM_ACCOUNT=amsc011
SLURM_QOS=express_amsc
SLURM_CONSTRAINT=cpu

ARCHIVE=/global/cfs/cdirs/amsc011/shared/wa-hls4ml-catapult/nangate45
FAILED_FILE="$ARCHIVE/failed_designs.txt"
ORIG_ARCHIVE="$ARCHIVE/$ORIG_RUN"

[ -f "$FAILED_FILE" ] || { echo "ERROR: $FAILED_FILE not found — check CFS mount" >&2; exit 1; }
[ -d "$ORIG_ARCHIVE" ] || { echo "ERROR: $ORIG_ARCHIVE not found in archive" >&2; exit 1; }

REPO_DIR="${SLURM_SUBMIT_DIR:-$(cd "$(dirname "${BASH_SOURCE[0]}")/../.." && pwd)}"
VENV="${WA_HLS4ML_VENV:-${SCRATCH}/venv_hls4ml/bin/activate}"
source "$VENV"

LM_LICENSE_FILE=$(python3 -c "
import json
with open('${REPO_DIR}/license_servers_perlmutter.json') as f:
    cfg = json.load(f)
print(':'.join(f\"{s['port']}@{s['host']}\" for s in cfg['servers']))
")

# ── Derive scratch base dir from config names ─────────────────────────────────
model_stem=$(basename "$MODEL_CFG" .json | sed 's/^config_//')
case "$(basename "$FLOW_CFG" .json)" in
    configs/catapult_flow/config_catapult_flow_rf1) rf_suffix=rf1  ;;
    configs/catapult_flow/config_catapult_flow_rf4) rf_suffix=rf4  ;;
    configs/catapult_flow/config_catapult_flow_rf8) rf_suffix=rf8  ;;
    configs/catapult_flow/config_catapult_flow)     rf_suffix=rf16 ;;
    *) rf_suffix=$(basename "$FLOW_CFG" .json | grep -oP 'rf\d+' || echo "rf?") ;;
esac
BASE="${SCRATCH}/catapult_${model_stem}_${rf_suffix}_rerun"

echo ""
echo "=== Rerun: $ORIG_RUN ==="
echo "  Model:   $MODEL_CFG"
echo "  Flow:    $FLOW_CFG"
echo "  Base:    $BASE"

# ── Helpers ───────────────────────────────────────────────────────────────────
wait_for_job() {
    local jid="$1"
    echo "  Waiting for SLURM job $jid (squeue, every 60s)..."
    sleep 30
    while squeue -j "$jid" -h 2>/dev/null | grep -q .; do sleep 60; done
    local states
    states=$(sacct -j "$jid" --format=State --noheader -P 2>/dev/null | sort | uniq -c)
    echo "  Job $jid final states: $states"
}

# ── Step 1: re-prepare full design space ─────────────────────────────────────
echo "  Preparing design space..."
python iter_manager_catapult.py \
    -o "$BASE" \
    --gen_model_config_json "$MODEL_CFG" \
    --flow_config_json "$FLOW_CFG" \
    --catapult_shell Perlmutter_scripts/catapult_shell.sh \
    --flow_tcl util/catapult_hls4ml_flow.tcl \
    --cartesian \
    --prepare-only

RUN_DIR=$(ls -d "${BASE}"/run_*/ 2>/dev/null | sort | tail -1)
RUN_DIR="${RUN_DIR%/}"
[[ -n "$RUN_DIR" ]] || { echo "ERROR: no run dir under $BASE" >&2; exit 1; }
echo "  Run dir: $RUN_DIR"

# ── Step 2: filter joblist to failed stems only ───────────────────────────────
# Extract failed stems for this orig run (tab-separated: run_name<TAB>stem)
FAILED_STEMS_FILE=$(mktemp)
grep -F "${ORIG_RUN}	" "$FAILED_FILE" | awk -F'\t' '{print $2}' | sort > "$FAILED_STEMS_FILE"
n_failed=$(wc -l < "$FAILED_STEMS_FILE")
echo "  Failed designs for this run: $n_failed"

while IFS=$'\t' read -r build_path rest; do
    stem=$(basename "$build_path")
    if grep -qxF "$stem" "$FAILED_STEMS_FILE"; then
        printf '%s\t%s\n' "$build_path" "$rest"
    fi
done < "${RUN_DIR}/joblist.txt" > "${RUN_DIR}/joblist_rerun.txt"

n_filtered=$(wc -l < "${RUN_DIR}/joblist_rerun.txt")
echo "  Filtered joblist: $n_filtered designs"
[[ "$n_filtered" -gt 0 ]] || { echo "ERROR: no matching designs found in joblist" >&2; exit 1; }

# ── Step 3: prune non-failed build dirs (inode cleanup) ──────────────────────
echo "  Pruning non-failed build dirs..."
comm -23 \
    <(ls "${RUN_DIR}/build/" | sort) \
    "$FAILED_STEMS_FILE" \
| xargs -P 16 -I{} rm -rf "${RUN_DIR}/build/{}"
rm -f "$FAILED_STEMS_FILE"
echo "  Build dirs remaining: $(ls "${RUN_DIR}/build/" | wc -l)"

# ── Steps 4+5: synthesize with resume loop ────────────────────────────────────
JOBLOG="${RUN_DIR}/parallel.log"
SLURM_LOGS="${RUN_DIR}/slurm_logs"
PARALLEL_SCRIPT="${RUN_DIR}/parallel_synth.sh"
mkdir -p "$SLURM_LOGS"

cat > "$PARALLEL_SCRIPT" <<SBATCH_EOF
#!/bin/bash
#SBATCH --job-name=rerun_${ORIG_RUN:0:22}
#SBATCH --account=${SLURM_ACCOUNT}
#SBATCH --nodes=1
#SBATCH --ntasks=1
#SBATCH --cpus-per-task=200
#SBATCH --mem=400G
#SBATCH --constraint=${SLURM_CONSTRAINT}
#SBATCH --time=${SLURM_TIME}
#SBATCH --qos=${SLURM_QOS}
#SBATCH --output=${SLURM_LOGS}/parallel.out
#SBATCH --error=${SLURM_LOGS}/parallel.err

set -euo pipefail
source "${VENV}"
export LM_LICENSE_FILE="${LM_LICENSE_FILE}"
cd "${REPO_DIR}"

parallel \\
    --joblog "${JOBLOG}" \\
    --resume-failed \\
    --line-buffer \\
    -j ${PARALLELISM} \\
    python "${REPO_DIR}/iter_manager_catapult.py" -o "${BASE}" --run-single-job {} \\
    < "${RUN_DIR}/joblist_rerun.txt"
SBATCH_EOF
chmod +x "$PARALLEL_SCRIPT"

total=$n_filtered
done=$(find "${RUN_DIR}/tarballs" -maxdepth 1 -name "*.tar.gz" 2>/dev/null | wc -l)
max_rounds=20
round=0

jid=$(sbatch --parsable "$PARALLEL_SCRIPT")
echo "  Submitted: $jid ($total designs, $PARALLELISM parallel slots)"
wait_for_job "$jid"
done=$(find "${RUN_DIR}/tarballs" -maxdepth 1 -name "*.tar.gz" 2>/dev/null | wc -l)

while (( done < total && round < max_rounds )); do
    round=$(( round + 1 ))
    echo "  Incomplete: $done/$total — re-submitting (round $round/$max_rounds)..."
    jid=$(sbatch --parsable "$PARALLEL_SCRIPT")
    echo "  Submitted: $jid"
    wait_for_job "$jid"
    done=$(find "${RUN_DIR}/tarballs" -maxdepth 1 -name "*.tar.gz" 2>/dev/null | wc -l)
done

if (( done < total )); then
    echo "ERROR: still incomplete after $max_rounds rounds ($done/$total)" >&2
    exit 1
fi
echo "  Synthesis complete ($done/$total)."

# ── Step 6: merge into original archive ───────────────────────────────────────
echo "  Merging into $ORIG_ARCHIVE ..."
find "${RUN_DIR}/tarballs" -maxdepth 1 -name "*.tar.gz" | while read -r f; do
    dest="${ORIG_ARCHIVE}/tarballs/$(basename "$f")"
    [ -f "$dest" ] || cp "$f" "$dest"
done
find "${RUN_DIR}/data/reports/raw" -maxdepth 1 -name "*.json" 2>/dev/null | while read -r f; do
    dest="${ORIG_ARCHIVE}/reports/$(basename "$f")"
    [ -f "$dest" ] || cp "$f" "$dest"
done

merged_t=$(find "$ORIG_ARCHIVE/tarballs" -maxdepth 1 -name "*.tar.gz" | wc -l)
merged_r=$(find "$ORIG_ARCHIVE/reports"  -maxdepth 1 -name "*.json"   | wc -l)
echo "  Archive now: $merged_t tarballs, $merged_r reports"

# ── Step 7: clean up scratch ──────────────────────────────────────────────────
if [ "$KEEP_SCRATCH" = "1" ]; then
    echo "  KEEP_SCRATCH=1 — scratch preserved for inspection:"
    echo "    $RUN_DIR"
    echo "  Build dirs:  ${RUN_DIR}/build/"
    echo "  Tarballs:    ${RUN_DIR}/tarballs/"
    echo "  Reports:     ${RUN_DIR}/data/reports/raw/"
    echo "  SLURM logs:  ${RUN_DIR}/slurm_logs/"
else
    echo "  Cleaning scratch $RUN_DIR ..."
    find "$RUN_DIR" -type f -print0 | xargs -0 -P 64 rm -f
    find "$RUN_DIR" -depth -type d -empty -delete
fi
echo "Done: $ORIG_RUN"
