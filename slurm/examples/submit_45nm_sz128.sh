#!/bin/bash
#SBATCH --job-name=45nm_sz128
#SBATCH --account=amsc011
#SBATCH --qos=shared
#SBATCH --nodes=1
#SBATCH --ntasks=1
#SBATCH --cpus-per-task=4
#SBATCH --mem=16G
#SBATCH --constraint=cpu
#SBATCH --time=2-00:00:00
#SBATCH --output=%x_%j.out
#SBATCH --error=%x_%j.err
#
# Nangate 45nm sz128 extension sweep — L=1, 2, or 3 dense networks.
# Synthesises only architectures where at least one size dimension = 128
# (designs with all dims ≤ 64 are already archived from the regular cartesian).
# Archives flat to nangate45/.
# RF=1, 4, 8, 16; each group uses 3 nodes × 100 parallel slots (300 licenses).
#
# Usage:
#   N_LAYERS=1 sbatch slurm/examples/submit_45nm_sz128.sh   # 1-layer (cartesian)
#   N_LAYERS=2 sbatch slurm/examples/submit_45nm_sz128.sh   # 2-layer (cartesian)
#   N_LAYERS=3 sbatch slurm/examples/submit_45nm_sz128.sh   # 3-layer (LHS, N=2500)
#
# Optional env vars:
#   N_LHS        LHS sample count for N_LAYERS=3 (default: 2500)
#   CANDIDATES   override path to candidates file

set -euo pipefail

: "${N_LAYERS:?ERROR: N_LAYERS must be set (1, 2, or 3)}"

REPO_DIR="${SLURM_SUBMIT_DIR:-$(cd "$(dirname "${BASH_SOURCE[0]}")/../.." && pwd)}"
VENV="${WA_HLS4ML_VENV:-${SCRATCH}/venv_hls4ml/bin/activate}"
source "$VENV"
cd "$REPO_DIR"

ARCHIVE_BASE="/global/cfs/cdirs/amsc011/shared/wa-hls4ml-catapult"
ARCHIVE_45NM="${ARCHIVE_BASE}/nangate45"
N_LHS="${N_LHS:-2500}"

if (( N_LAYERS <= 2 )); then
    CAND_DEFAULT="${ARCHIVE_45NM}/nangate45_sz128_${N_LAYERS}layer_cartesian.txt"
else
    CAND_DEFAULT="${ARCHIVE_45NM}/nangate45_sz128_${N_LAYERS}layer_lhs_${N_LHS}.txt"
fi
CANDIDATES="${CANDIDATES:-${CAND_DEFAULT}}"

PARALLELISM=100
SLURM_TIME=06:00:00
SLURM_ACCOUNT=amsc011
SLURM_QOS=express_amsc
SLURM_CONSTRAINT=cpu

LM_LICENSE_FILE=$(python3 -c "
import json
with open('${REPO_DIR}/license_servers_perlmutter.json') as f:
    cfg = json.load(f)
print(':'.join(f\"{s['port']}@{s['host']}\" for s in cfg['servers']))
")

# ── Step 1: Generate candidates file (cartesian or LHS) ──────────────────────

if [ ! -f "$CANDIDATES" ]; then
    if (( N_LAYERS <= 2 )); then
        echo "=== Cartesian enumeration: ${N_LAYERS}-layer sz128, new designs only ==="
        python3 - <<PYEOF
import itertools, os

SIZES    = [4, 8, 16, 32, 64, 128]
BWS      = [4, 6, 8, 10, 12, 14]
ACTS     = ["relu", "sigmoid", "tanh"]
N_LAYERS = int('${N_LAYERS}')
out_path = '${CANDIDATES}'

idx = 0
configs = []
size_dims = [SIZES] * (1 + N_LAYERS)   # input + N_LAYERS layer sizes
act_dims  = [ACTS]  * N_LAYERS

for sizes in itertools.product(*size_dims):
    if not any(s == 128 for s in sizes):   # skip designs already in ≤64 cartesian
        continue
    for bw in BWS:
        for acts in itertools.product(*act_dims):
            stem  = f"dense_${N_LAYERS}l_sz128_{idx}"
            parts = [stem] + [str(s) for s in sizes] + [str(bw)] + list(acts)
            configs.append('\t'.join(parts))
            idx += 1

print(f"  New architectures (at least one dim=128): {idx}")
print(f"  Total designs (×4 RF): {idx * 4}")
os.makedirs(os.path.dirname('${CANDIDATES}'), exist_ok=True)
with open(out_path, 'w') as f:
    f.write('\n'.join(configs) + '\n')
print(f"  Candidates written to {out_path}")
PYEOF
    else
        echo "=== LHS sampling: ${N_LAYERS}-layer sz128, N=${N_LHS}, new designs only ==="
        python3 - <<PYEOF
import os, math
import numpy as np
from scipy.stats.qmc import LatinHypercube

SIZES    = [4, 8, 16, 32, 64, 128]
BWS      = [4, 6, 8, 10, 12, 14]
ACTS     = ["relu", "sigmoid", "tanh"]
N_LAYERS = int('${N_LAYERS}')
N_TARGET = int('${N_LHS}')
out_path = '${CANDIDATES}'

DIM       = 2 + 2 * N_LAYERS   # in + N sizes + bw + N acts
log2_szs  = [math.log2(s) for s in SIZES]
lo_sz, hi_sz = log2_szs[0], log2_szs[-1]

def snap_size(x):
    v = lo_sz + x * (hi_sz - lo_sz)
    return SIZES[min(range(len(SIZES)), key=lambda i: abs(log2_szs[i] - v))]

def snap_bw(x):
    return BWS[max(0, min(len(BWS) - 1, round(x * (len(BWS) - 1))))]

def snap_act(x):
    return ACTS[max(0, min(len(ACTS) - 1, round(x * (len(ACTS) - 1))))]

configs = set()
ordered = []
seed = 42
batch = 0

while len(ordered) < N_TARGET:
    n_raw = max((N_TARGET - len(ordered)) * 3, 500)
    sampler = LatinHypercube(d=DIM, seed=seed + batch)
    raw = sampler.random(n=n_raw)
    batch += 1
    for row in raw:
        in_sz  = snap_size(row[0])
        layers = tuple(snap_size(row[1 + i]) for i in range(N_LAYERS))
        bw     = snap_bw(row[1 + N_LAYERS])
        acts   = tuple(snap_act(row[2 + N_LAYERS + i]) for i in range(N_LAYERS))
        all_sizes = (in_sz,) + layers
        if all(s <= 64 for s in all_sizes):   # skip designs already in ≤64 cartesian
            continue
        key = all_sizes + (bw,) + acts
        if key not in configs:
            configs.add(key)
            ordered.append(key)
            if len(ordered) >= N_TARGET:
                break
    print(f"  batch {batch}: {len(ordered)}/{N_TARGET} unique new designs")

os.makedirs(os.path.dirname('${CANDIDATES}'), exist_ok=True)
with open(out_path, 'w') as f:
    for idx, cfg in enumerate(ordered):
        in_sz  = cfg[0]
        layers = cfg[1:1 + N_LAYERS]
        bw     = cfg[1 + N_LAYERS]
        acts   = cfg[2 + N_LAYERS:]
        stem   = f"dense_${N_LAYERS}l_sz128_{idx}"
        parts  = [stem, str(in_sz)] + [str(s) for s in layers] + [str(bw)] + list(acts)
        f.write('\t'.join(parts) + '\n')
print(f"  Candidates written to {out_path} ({len(ordered)} designs)")
PYEOF
    fi
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

# ── Step 2: For each RF, build models + synthesise (3 nodes) + archive ────────

run_45nm_group() {
    local rf_label="$1"
    local flow_cfg_name="$2"
    local BASE="${SCRATCH}/catapult_45nm_${N_LAYERS}layer_sz128_${rf_label}"

    echo ""
    echo "=== Nangate 45nm ${N_LAYERS}-layer sz128  RF=${rf_label} ==="

    local ts run_id RUN_DIR
    ts=$(date '+%Y%m%d_%H%M%S')
    run_id=$(python3 -c "import uuid; print(uuid.uuid4().hex[:8])")
    RUN_DIR="${BASE}/run_${ts}_${run_id}"
    mkdir -p "${RUN_DIR}/tarballs" "${RUN_DIR}/slurm_logs"
    echo "  Run dir: $RUN_DIR"

    local JOBLIST="${RUN_DIR}/joblist.txt"

    python3 - <<PYEOF
import os, sys, json

sys.path.insert(0, '${REPO_DIR}')
from gen_models import _build_dense_model
from util.catapult_dataflow_config import CatapultDataflowConfig

flow_cfg     = os.path.join('${REPO_DIR}', '${flow_cfg_name}')
run_dir      = '${RUN_DIR}'
repo_dir     = '${REPO_DIR}'
candidates_f = '${CANDIDATES}'
joblist_f    = '${JOBLIST}'
N_LAYERS     = int('${N_LAYERS}')

base_cfg     = CatapultDataflowConfig.load_json(flow_cfg)
build_root   = os.path.join(run_dir, 'build')
data_root    = os.path.join(run_dir, 'data', 'models')
shell_script = os.path.join(repo_dir, 'Perlmutter_scripts', 'catapult_shell.sh')
flow_tcl     = os.path.join(repo_dir, 'util', 'catapult_hls4ml_flow.tcl')

config_params = {
    "weight_int_width": 2,
    "activ_int_width": 2,
    "probs": {"activations": [1, 1, 1, 0]},
}

joblines = []
skipped  = []

with open(candidates_f) as f:
    lines = [l.strip() for l in f if l.strip()]

print(f"  Building {len(lines)} models...")
for i, line in enumerate(lines):
    parts  = line.split('\t')
    stem   = parts[0]
    in_sz  = int(parts[1])
    l_szs  = [int(x) for x in parts[2:2 + N_LAYERS]]
    bw     = int(parts[2 + N_LAYERS])
    acts   = parts[3 + N_LAYERS:3 + 2 * N_LAYERS]

    build_dir = os.path.join(build_root, stem)
    data_dir  = os.path.join(data_root,  stem)
    keras_h5  = os.path.join(build_dir,  'keras_model.h5')

    try:
        os.makedirs(build_dir, exist_ok=True)
        model = _build_dense_model(list(zip(l_szs, acts)), bw, config_params, input_size=in_sz)
        model.save(keras_h5, include_optimizer=False)
    except Exception as e:
        print(f"  Warning: model build failed for {stem}: {e}")
        skipped.append(stem)
        continue

    os.makedirs(data_dir, exist_ok=True)
    cfg      = base_cfg.override(output_dir=os.path.join(build_dir, 'catapult_native'))
    cfg_path = os.path.join(data_dir, 'dataflow_config.json')
    cfg.save_json(cfg_path)
    joblines.append(f'{build_dir}\t{shell_script}\t{flow_tcl}\t{cfg_path}')

    if (i + 1) % 500 == 0:
        print(f"  ... {i+1}/{len(lines)}  ready={len(joblines)}  skipped={len(skipped)}")

with open(joblist_f, 'w') as fout:
    fout.write('\n'.join(joblines) + ('\n' if joblines else ''))

print(f"  Joblist: {len(joblines)} ready,  {len(skipped)} skipped")
if skipped:
    for s in skipped[:10]:
        print(f"    {s}")
    if len(skipped) > 10:
        print(f"    ... and {len(skipped)-10} more")
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
#SBATCH --job-name=45nm_${N_LAYERS}l_sz128_${rf_label}_${part}
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
        echo "  WARNING: $done_count/$total completed after $round rounds"
    else
        echo "  Synthesis complete ($done_count/$total)"
    fi

    echo "  Archiving ${rf_label} → nangate45/ ..."
    bash "${REPO_DIR}/slurm/examples/archive_run.sh" "${RUN_DIR}" --yes
    echo "  Done: 45nm ${N_LAYERS}-layer sz128 ${rf_label}."
}

# ── Main ──────────────────────────────────────────────────────────────────────

run_45nm_group rf1  config_catapult_flow_rf1.json
run_45nm_group rf4  config_catapult_flow_rf4.json
run_45nm_group rf8  config_catapult_flow_rf8.json
run_45nm_group rf16 config_catapult_flow.json

echo ""
echo "Nangate 45nm ${N_LAYERS}-layer sz128 sweep complete."
