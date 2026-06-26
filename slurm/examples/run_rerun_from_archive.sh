#!/bin/bash
# Re-run failed designs using model files extracted from sibling RF archive runs.
# No --prepare-only needed: model weights and flow configs are in the archive.
#
# Parametrized via environment variables (set inline with --wrap):
#   ORIG_RUN      — archive run dir name, e.g. run_20260531_093401_e6edde98
#   FLOW_CFG      — flow config JSON (sets RF),  e.g. configs/catapult_flow/config_catapult_flow_rf1.json
#   KEEP_SCRATCH  — set to 1 to skip scratch cleanup (for inspection, default 0)
#
# MODEL_CFG is no longer needed — model weights come from sibling RF tarballs.
#
# Replaces run_rerun_failed.sh. See submit_reruns.sh to submit all groups.

set -euo pipefail

: "${ORIG_RUN:?  env var ORIG_RUN must be set}"
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

# ── Derive scratch base dir ───────────────────────────────────────────────────
flow_stem=$(basename "$FLOW_CFG" .json)
case "$flow_stem" in
    configs/catapult_flow/config_catapult_flow_rf1) rf_suffix=rf1  ;;
    configs/catapult_flow/config_catapult_flow_rf4) rf_suffix=rf4  ;;
    configs/catapult_flow/config_catapult_flow_rf8) rf_suffix=rf8  ;;
    configs/catapult_flow/config_catapult_flow)     rf_suffix=rf16 ;;
    *) rf_suffix=$(echo "$flow_stem" | grep -oP 'rf\d+' || echo "rf?") ;;
esac
source_path=$(cat "$ORIG_ARCHIVE/source_dir.txt" 2>/dev/null || echo "")
arch_base=$(echo "$source_path" | grep -oP '(?<=/)[^/]*dense_[^/]+(?=_rf\d+/)' | head -1 || echo "rerun")
BASE="${SCRATCH}/${arch_base}_${rf_suffix}_rerun2"

echo ""
echo "=== Rerun from archive: $ORIG_RUN ==="
echo "  Flow:    $FLOW_CFG  (RF suffix: $rf_suffix)"
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

# ── Create timestamped run dir ────────────────────────────────────────────────
ts=$(date '+%Y%m%d_%H%M%S')
run_id=$(python3 -c "import uuid; print(uuid.uuid4().hex[:8])")
RUN_DIR="${BASE}/run_${ts}_${run_id}"
mkdir -p "$RUN_DIR/tarballs" "$RUN_DIR/slurm_logs"
echo "  Run dir: $RUN_DIR"

# ── Step 1+2: extract model files from sibling archives, build joblist ────────
FAILED_STEMS_FILE=$(mktemp)
grep -F "${ORIG_RUN}	" "$FAILED_FILE" | awk -F'\t' '{print $2}' | sort > "$FAILED_STEMS_FILE"
n_failed=$(wc -l < "$FAILED_STEMS_FILE")
echo "  Failed designs for this run: $n_failed"

SKIPPED_FILE=$(mktemp)
JOBLIST="${RUN_DIR}/joblist_rerun.txt"

python3 - <<PYEOF
import os, sys, tarfile, glob, json

sys.path.insert(0, '${REPO_DIR}')
from util.catapult_dataflow_config import CatapultDataflowConfig

archive    = '${ARCHIVE}'
orig_run   = '${ORIG_RUN}'
flow_cfg   = os.path.join('${REPO_DIR}', '${FLOW_CFG}')
run_dir    = '${RUN_DIR}'
repo_dir   = '${REPO_DIR}'
failed_f   = '${FAILED_STEMS_FILE}'
skipped_f  = '${SKIPPED_FILE}'
joblist_f  = '${JOBLIST}'

# Identify sibling archive dirs (same arch group, any other RF)
source_path = open(f'{archive}/{orig_run}/source_dir.txt').read().strip()
import re
arch_dir = os.path.basename(os.path.dirname(source_path))
m = re.search(r'(catapult_dense_\S+?)_rf\d+', arch_dir)
arch_group  = m.group(1) if m else None
print(f'  Arch group: {arch_group}')

sibling_runs = []
for src_file in glob.glob(f'{archive}/run_*/source_dir.txt'):
    rd = os.path.dirname(src_file)
    if rd == f'{archive}/{orig_run}':
        continue
    src = open(src_file).read().strip()
    if arch_group and arch_group in os.path.basename(os.path.dirname(src)):
        sibling_runs.append(rd)
print(f'  Sibling RF archive runs found: {len(sibling_runs)}')

# Load flow config
base_cfg = CatapultDataflowConfig.load_json(flow_cfg)

build_root = os.path.join(run_dir, 'build')
data_root  = os.path.join(run_dir, 'data', 'models')
os.makedirs(build_root, exist_ok=True)
os.makedirs(data_root,  exist_ok=True)

shell_script = os.path.join(repo_dir, 'Perlmutter_scripts', 'catapult_shell.sh')
flow_tcl     = os.path.join(repo_dir, 'util', 'catapult_hls4ml_flow.tcl')

failed_stems = [l.strip() for l in open(failed_f) if l.strip()]
joblines = []
skipped  = []

for stem in failed_stems:
    build_dir  = os.path.join(build_root, stem)
    data_dir   = os.path.join(data_root, stem)
    keras_h5   = os.path.join(build_dir, 'keras_model.h5')

    # Find model_weights.h5 from any sibling tarball for this stem
    found = False
    for sib in sibling_runs:
        tb = os.path.join(sib, 'tarballs', f'{stem}.tar.gz')
        if not os.path.exists(tb):
            continue
        try:
            with tarfile.open(tb) as tf:
                members = tf.getnames()
                # Extract model.json (architecture) and reconstruct full Keras h5.
                # Weight values don't affect HLS synthesis (csim=0, SCVerify=0),
                # so we build from architecture only — same as _prepare_single_model.
                mj = next((x for x in members if x == 'model.json'), None)
                if mj is None:
                    continue
                os.makedirs(build_dir, exist_ok=True)
                mj_content = tf.extractfile(tf.getmember(mj)).read().decode()
                mj_path = os.path.join(build_dir, 'model.json')
                with open(mj_path, 'w') as f_out:
                    f_out.write(mj_content)
                # Build full Keras model h5 from architecture (random weights)
                try:
                    import tensorflow as tf_mod
                    try:
                        from qkeras.utils import _add_supported_quantized_objects
                        co = {}
                        _add_supported_quantized_objects(co)
                        model = tf_mod.keras.models.model_from_json(mj_content, custom_objects=co)
                    except Exception:
                        model = tf_mod.keras.models.model_from_json(mj_content)
                    model.save(keras_h5, include_optimizer=False)
                except Exception as e:
                    print(f'  Warning: model build failed for {stem}: {e}')
                    continue
            found = True
            break
        except Exception as e:
            print(f'  Warning: failed to extract from {tb}: {e}')
            continue

    if not found:
        skipped.append(stem)
        continue

    # Build dataflow_config.json
    os.makedirs(data_dir, exist_ok=True)
    cfg = base_cfg.override(output_dir=os.path.join(build_dir, 'catapult_native'))
    cfg_path = os.path.join(data_dir, 'dataflow_config.json')
    cfg.save_json(cfg_path)

    joblines.append(f'{build_dir}\t{shell_script}\t{flow_tcl}\t{cfg_path}')

# Write outputs
with open(joblist_f, 'w') as f:
    f.write('\n'.join(joblines) + ('\n' if joblines else ''))
with open(skipped_f, 'w') as f:
    f.write('\n'.join(skipped) + ('\n' if skipped else ''))

print(f'  Joblist: {len(joblines)} designs')
if skipped:
    print(f'  Skipped (no sibling tarball for any RF): {len(skipped)}')
    for s in skipped:
        print(f'    {s}')
PYEOF

n_jobs=$(wc -l < "$JOBLIST" 2>/dev/null || echo 0)
[[ "$n_jobs" -gt 0 ]] || { echo "ERROR: no designs to synthesize (all skipped or setup failed)" >&2; exit 1; }
echo "  Ready to synthesize: $n_jobs designs"

# ── Steps 3+4: synthesis with resume loop ─────────────────────────────────────
JOBLOG="${RUN_DIR}/parallel.log"
PARALLEL_SCRIPT="${RUN_DIR}/parallel_synth.sh"

cat > "$PARALLEL_SCRIPT" <<SBATCH_EOF
#!/bin/bash
#SBATCH --job-name=rerun2_${ORIG_RUN:0:20}
#SBATCH --account=${SLURM_ACCOUNT}
#SBATCH --nodes=1
#SBATCH --ntasks=1
#SBATCH --cpus-per-task=200
#SBATCH --mem=400G
#SBATCH --constraint=${SLURM_CONSTRAINT}
#SBATCH --time=${SLURM_TIME}
#SBATCH --qos=${SLURM_QOS}
#SBATCH --output=${RUN_DIR}/slurm_logs/parallel.out
#SBATCH --error=${RUN_DIR}/slurm_logs/parallel.err

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
    < "${JOBLIST}"
SBATCH_EOF
chmod +x "$PARALLEL_SCRIPT"

total=$n_jobs
done_count=$(find "${RUN_DIR}/tarballs" -maxdepth 1 -name "*.tar.gz" 2>/dev/null | wc -l)
max_rounds=20
round=0

jid=$(sbatch --parsable "$PARALLEL_SCRIPT")
echo "  Submitted: $jid ($total designs, $PARALLELISM parallel slots)"
wait_for_job "$jid"
done_count=$(find "${RUN_DIR}/tarballs" -maxdepth 1 -name "*.tar.gz" 2>/dev/null | wc -l)

while (( done_count < total && round < max_rounds )); do
    round=$(( round + 1 ))
    echo "  Incomplete: $done_count/$total — re-submitting (round $round/$max_rounds)..."
    jid=$(sbatch --parsable "$PARALLEL_SCRIPT")
    echo "  Submitted: $jid"
    wait_for_job "$jid"
    done_count=$(find "${RUN_DIR}/tarballs" -maxdepth 1 -name "*.tar.gz" 2>/dev/null | wc -l)
done

if (( done_count < total )); then
    echo "ERROR: still incomplete after $max_rounds rounds ($done_count/$total)" >&2
    exit 1
fi
echo "  Synthesis complete ($done_count/$total)."

# ── Step 5: merge into original archive ───────────────────────────────────────
echo "  Merging into $ORIG_ARCHIVE ..."
find "${RUN_DIR}/tarballs" -maxdepth 1 -name "*.tar.gz" | while read -r f; do
    dest="${ORIG_ARCHIVE}/tarballs/$(basename "$f")"
    [ -f "$dest" ] || cp "$f" "$dest"
done
# Reports: always overwrite — a rerun may produce a better report than what's archived
find "${RUN_DIR}/data/reports/raw" -maxdepth 1 -name "*.json" 2>/dev/null | while read -r f; do
    cp -f "$f" "${ORIG_ARCHIVE}/reports/$(basename "$f")"
done

merged_t=$(find "$ORIG_ARCHIVE/tarballs" -maxdepth 1 -name "*.tar.gz" | wc -l)
merged_r=$(find "$ORIG_ARCHIVE/reports"  -maxdepth 1 -name "*.json"   | wc -l)
echo "  Archive now: $merged_t tarballs, $merged_r reports"

# ── Step 6: clean scratch ──────────────────────────────────────────────────────
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

rm -f "$FAILED_STEMS_FILE" "$SKIPPED_FILE"
echo "Done: $ORIG_RUN"
