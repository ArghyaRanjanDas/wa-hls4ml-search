#!/bin/bash
#SBATCH --job-name=gf22_nlayer_lhs
#SBATCH --account=amsc011
#SBATCH --qos=shared
#SBATCH --nodes=1
#SBATCH --ntasks=1
#SBATCH --cpus-per-task=4
#SBATCH --mem=16G
#SBATCH --constraint=cpu
#SBATCH --time=2-00:00:00
#SBATCH --output=logs/%x_%j.out
#SBATCH --error=logs/%x_%j.err
#
# GF22nm LHS sweep for N-layer dense networks, extracting models from the 45nm archive.
# RF=1, 4, 8, 16; each group uses 3 nodes × 100 parallel slots (300 licenses).
# Archives flat to gf22fdx/.
#
# Usage:
#   N_LAYERS=2 sbatch slurm/examples/submit_gf22_nlayer_lhs.sh
#   N_LAYERS=3 sbatch slurm/examples/submit_gf22_nlayer_lhs.sh
#   N_LAYERS=3 N_LHS=10000 EXCLUDE_FILE=/path/to/prev.txt sbatch ...
#
# Optional env vars:
#   N_LHS          number of LHS samples (default: 5000)
#   EXCLUDE_FILE   path to a previous candidates file to exclude (run_name<TAB>stem)
#   CANDIDATES     override path to candidates file

set -euo pipefail

: "${N_LAYERS:?ERROR: N_LAYERS must be set (e.g. N_LAYERS=2 or N_LAYERS=3)}"

REPO_DIR="${SLURM_SUBMIT_DIR:-$(cd "$(dirname "${BASH_SOURCE[0]}")/../.." && pwd)}"
VENV="${WA_HLS4ML_VENV:-${SCRATCH}/venv_hls4ml/bin/activate}"
source "$VENV"
cd "$REPO_DIR"

ARCHIVE_BASE="/global/cfs/cdirs/amsc011/shared/wa-hls4ml-catapult"
ARCHIVE_45NM="${ARCHIVE_BASE}/nangate45"
ARCHIVE_GF22NM="${ARCHIVE_BASE}/gf22fdx"
N_LHS="${N_LHS:-5000}"
CANDIDATES="${CANDIDATES:-${ARCHIVE_GF22NM}/gf22_lhs_${N_LAYERS}layer_${N_LHS}.txt}"
EXCLUDE_FILE="${EXCLUDE_FILE:-}"

PARALLELISM=100
SLURM_TIME=05:30:00
SLURM_ACCOUNT=amsc011
SLURM_QOS=express_amsc
SLURM_CONSTRAINT=cpu

LM_LICENSE_FILE=$(python3 -c "
import json
with open('${REPO_DIR}/license_servers_perlmutter.json') as f:
    cfg = json.load(f)
print(':'.join(f\"{s['port']}@{s['host']}\" for s in cfg['servers']))
")

# ── Step 1: Generate LHS candidates from 45nm archive ────────────────────────

if [ ! -f "$CANDIDATES" ]; then
    echo "=== Generating LHS candidates (N=${N_LHS}, ${N_LAYERS}-layer) ==="
    exclude_arg=""
    [ -n "$EXCLUDE_FILE" ] && exclude_arg="--exclude ${EXCLUDE_FILE}"
    python3 "${REPO_DIR}/slurm/examples/sample_lhs_from_archive.py" \
        --layers "$N_LAYERS" --n "$N_LHS" \
        $exclude_arg \
        --out "$CANDIDATES"
else
    echo "=== Using existing candidates file ==="
fi
echo "Candidates: $(wc -l < "$CANDIDATES") designs at $CANDIDATES"

# ── Helpers ───────────────────────────────────────────────────────────────────

wait_for_jobs() {
    local tar_dir="$1"; shift
    local jids=("$@")
    echo "  Waiting for SLURM jobs: ${jids[*]}..."
    sleep 30
    local elapsed=0
    while true; do
        local any_running=0
        for jid in "${jids[@]}"; do
            squeue -j "$jid" -h 2>/dev/null | grep -q . && { any_running=1; break; }
        done
        [ "$any_running" -eq 0 ] && break
        sleep 60
        elapsed=$(( elapsed + 60 ))
        if (( elapsed % 300 == 0 )) && [ -n "$tar_dir" ]; then
            local n; n=$(find "$tar_dir" -maxdepth 1 -name "*.tar.gz" 2>/dev/null | wc -l)
            echo "  [$(date '+%H:%M')] tarballs so far: $n"
        fi
    done
    for jid in "${jids[@]}"; do
        local states
        states=$(sacct -j "$jid" --format=State --noheader -P 2>/dev/null | sort | uniq -c)
        echo "  Job $jid final states: $states"
    done
}

# ── Step 2: For each RF, extract models + synthesise (3 nodes) + archive ─────

run_gf22_group() {
    local rf_label="$1"
    local flow_cfg_name="$2"
    local BASE="${SCRATCH}/catapult_gf22_${N_LAYERS}layer_lhs_${rf_label}"

    echo ""
    echo "=== GF22nm ${N_LAYERS}-layer LHS  RF=${rf_label} ==="

    local ts run_id RUN_DIR
    ts=$(date '+%Y%m%d_%H%M%S')
    run_id=$(python3 -c "import uuid; print(uuid.uuid4().hex[:8])")
    RUN_DIR="${BASE}/run_${ts}_${run_id}"
    mkdir -p "${RUN_DIR}/tarballs" "${RUN_DIR}/slurm_logs"
    echo "  Run dir: $RUN_DIR"

    local JOBLIST="${RUN_DIR}/joblist.txt"

    python3 - <<PYEOF
import os, sys, tarfile, json

sys.path.insert(0, '${REPO_DIR}')
from util.catapult_dataflow_config import CatapultDataflowConfig

import tensorflow as tf_mod
try:
    from qkeras.utils import _add_supported_quantized_objects
    _qkeras_co = {}
    _add_supported_quantized_objects(_qkeras_co)
except Exception:
    _qkeras_co = None

def build_keras_h5(mj_content, out_path):
    try:
        if _qkeras_co:
            model = tf_mod.keras.models.model_from_json(mj_content, custom_objects=_qkeras_co)
        else:
            model = tf_mod.keras.models.model_from_json(mj_content)
        model.save(out_path, include_optimizer=False)
        return True
    except Exception as e:
        print(f'    Warning: keras build failed: {e}')
        return False

archive_45nm  = '${ARCHIVE_45NM}'
flow_cfg      = os.path.join('${REPO_DIR}', '${flow_cfg_name}')
run_dir       = '${RUN_DIR}'
repo_dir      = '${REPO_DIR}'
candidates_f  = '${CANDIDATES}'
joblist_f     = '${JOBLIST}'

base_cfg     = CatapultDataflowConfig.load_json(flow_cfg)
build_root   = os.path.join(run_dir, 'build')
data_root    = os.path.join(run_dir, 'data', 'models')
shell_script = os.path.join(repo_dir, 'Perlmutter_scripts', 'catapult_shell.sh')
flow_tcl     = os.path.join(repo_dir, 'util', 'catapult_hls4ml_flow.tcl')

joblines = []
skipped  = []

with open(candidates_f) as f:
    lines = [l.strip() for l in f if l.strip()]

print(f'  Processing {len(lines)} candidates...')
for i, line in enumerate(lines):
    run_name, stem = line.split('\t', 1)
    tb = os.path.join(archive_45nm, run_name, 'tarballs', f'{stem}.tar.gz')

    if not os.path.exists(tb):
        skipped.append(line)
        continue

    run_uuid  = run_name.rsplit('_', 1)[-1]
    tag       = f'{run_uuid}__{stem}'
    build_dir = os.path.join(build_root, tag)
    data_dir  = os.path.join(data_root,  tag)
    keras_h5  = os.path.join(build_dir,  'keras_model.h5')

    try:
        with tarfile.open(tb) as tf_arc:
            members = tf_arc.getnames()
            mj_name = next((x for x in members if x == 'model.json'), None)
            if mj_name is None:
                skipped.append(line)
                continue
            os.makedirs(build_dir, exist_ok=True)
            mj_content = tf_arc.extractfile(tf_arc.getmember(mj_name)).read().decode()
            with open(os.path.join(build_dir, 'model.json'), 'w') as fout:
                fout.write(mj_content)
    except Exception as e:
        print(f'  Warning: tarball failed {stem}: {e}')
        skipped.append(line)
        continue

    if not build_keras_h5(mj_content, keras_h5):
        skipped.append(line)
        continue

    os.makedirs(data_dir, exist_ok=True)
    cfg      = base_cfg.override(output_dir=os.path.join(build_dir, 'catapult_native'))
    cfg_path = os.path.join(data_dir, 'dataflow_config.json')
    cfg.save_json(cfg_path)
    joblines.append(f'{build_dir}\t{shell_script}\t{flow_tcl}\t{cfg_path}')

    if (i + 1) % 500 == 0:
        print(f'  ... {i+1}/{len(lines)}  ready={len(joblines)}  skipped={len(skipped)}')

with open(joblist_f, 'w') as fout:
    fout.write('\n'.join(joblines) + ('\n' if joblines else ''))

print(f'  Joblist: {len(joblines)} designs ready,  {len(skipped)} skipped')
if skipped:
    for s in skipped[:10]:
        print(f'    {s}')
    if len(skipped) > 10:
        print(f'    ... and {len(skipped)-10} more')
PYEOF

    local n_jobs
    n_jobs=$(wc -l < "$JOBLIST" 2>/dev/null || echo 0)
    [[ "$n_jobs" -gt 0 ]] || { echo "ERROR: no designs to synthesize" >&2; return 1; }
    echo "  Ready: $n_jobs synthesis jobs  (3 nodes × $PARALLELISM = $(( PARALLELISM * 3 )) parallel)"

    local n_a=$(( n_jobs / 3 ))
    local n_b=$(( n_jobs / 3 ))
    local n_c=$(( n_jobs - n_a - n_b ))
    local JOBLIST_A="${RUN_DIR}/joblist_a.txt"
    local JOBLIST_B="${RUN_DIR}/joblist_b.txt"
    local JOBLIST_C="${RUN_DIR}/joblist_c.txt"
    head -n "$n_a"                        "$JOBLIST" > "$JOBLIST_A"
    sed -n "$((n_a+1)),$((n_a+n_b))p"     "$JOBLIST" > "$JOBLIST_B"
    tail -n "+$((n_a + n_b + 1))"         "$JOBLIST" > "$JOBLIST_C"
    echo "  Split: node-a=$n_a  node-b=$n_b  node-c=$n_c"

    _make_synth_script() {
        local part="$1" jl="$2"
        local script="${RUN_DIR}/parallel_synth_${part}.sh"
        local jlog="${RUN_DIR}/parallel_${part}.log"
        cat > "$script" <<SBATCH_EOF
#!/bin/bash
#SBATCH --job-name=gf22_${N_LAYERS}l_${rf_label}_${part}
#SBATCH --account=${SLURM_ACCOUNT}
#SBATCH --nodes=1
#SBATCH --ntasks=1
#SBATCH --cpus-per-task=100
#SBATCH --mem=200G
#SBATCH --constraint=${SLURM_CONSTRAINT}
#SBATCH --time=${SLURM_TIME}
#SBATCH --qos=${SLURM_QOS}
#SBATCH --output=${RUN_DIR}/slurm_logs/parallel_${part}.out
#SBATCH --error=${RUN_DIR}/slurm_logs/parallel_${part}.err

set -euo pipefail
source "${VENV}"
export LM_LICENSE_FILE="${LM_LICENSE_FILE}"
cd "${REPO_DIR}"

parallel \\
    --joblog "${jlog}" \\
    --resume-failed \\
    --line-buffer \\
    -j ${PARALLELISM} \\
    python "${REPO_DIR}/iter_manager_catapult.py" -o "${BASE}" --run-single-job {} \\
    < "${jl}"
SBATCH_EOF
        chmod +x "$script"
        echo "$script"
    }

    local SCRIPT_A SCRIPT_B SCRIPT_C
    SCRIPT_A=$(_make_synth_script a "$JOBLIST_A")
    SCRIPT_B=$(_make_synth_script b "$JOBLIST_B")
    SCRIPT_C=$(_make_synth_script c "$JOBLIST_C")

    local total="$n_jobs"
    local done_count max_rounds=20 round=0
    local TAR_DIR="${RUN_DIR}/tarballs"

    local jid_a jid_b jid_c
    jid_a=$(sbatch --parsable "$SCRIPT_A")
    jid_b=$(sbatch --parsable "$SCRIPT_B")
    jid_c=$(sbatch --parsable "$SCRIPT_C")
    echo "  [round 0] Submitted: $jid_a (a, $n_a) + $jid_b (b, $n_b) + $jid_c (c, $n_c)"
    wait_for_jobs "$TAR_DIR" "$jid_a" "$jid_b" "$jid_c"
    done_count=$(find "$TAR_DIR" -maxdepth 1 -name "*.tar.gz" 2>/dev/null | wc -l)
    echo "  [round 0] done: $done_count / $total"

    while (( done_count < total && round < max_rounds )); do
        round=$(( round + 1 ))
        echo "  [round $round] $done_count/$total — $(( total - done_count )) remaining — re-submitting..."
        jid_a=$(sbatch --parsable "$SCRIPT_A")
        jid_b=$(sbatch --parsable "$SCRIPT_B")
        jid_c=$(sbatch --parsable "$SCRIPT_C")
        echo "  [round $round] Submitted: $jid_a + $jid_b + $jid_c"
        wait_for_jobs "$TAR_DIR" "$jid_a" "$jid_b" "$jid_c"
        local prev=$done_count
        done_count=$(find "$TAR_DIR" -maxdepth 1 -name "*.tar.gz" 2>/dev/null | wc -l)
        echo "  [round $round] done: $done_count / $total  (+$(( done_count - prev )) new)"
        (( done_count == prev )) && { echo "  [round $round] no progress — aborting retries" >&2; break; }
    done

    if (( done_count < total )); then
        echo "  WARNING: $done_count/$total completed after $round rounds ($(( total - done_count )) hard failures)"
    else
        echo "  Synthesis complete ($done_count/$total)"
    fi

    echo "  Archiving ${rf_label} → gf22fdx/ ..."
    bash "${REPO_DIR}/slurm/examples/archive_run.sh" "${RUN_DIR}" --yes
    echo "  Done: GF22nm ${N_LAYERS}-layer LHS ${rf_label}."
}

# ── Main ──────────────────────────────────────────────────────────────────────

run_gf22_group rf1  configs/catapult_flow/config_catapult_flow_gf22_rf1.json
run_gf22_group rf4  configs/catapult_flow/config_catapult_flow_gf22_rf4.json
run_gf22_group rf8  configs/catapult_flow/config_catapult_flow_gf22_rf8.json
run_gf22_group rf16 configs/catapult_flow/config_catapult_flow_gf22_rf16.json

echo ""
echo "GF22nm ${N_LAYERS}-layer LHS sweep complete."
