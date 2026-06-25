#!/bin/bash
#SBATCH --job-name=sz64_inp_rerun
#SBATCH --account=amsc011
#SBATCH --qos=shared
#SBATCH --nodes=1
#SBATCH --ntasks=1
#SBATCH --cpus-per-task=10
#SBATCH --mem=16G
#SBATCH --time=2-00:00:00
#SBATCH --constraint=cpu
#SBATCH --output=%x_%j.out
#SBATCH --error=%x_%j.err
#
# Targeted rerun for 514 failed sz64-inp designs (missing QOFRSummary).
# After synthesis the new tarballs and JSON reports are written BACK into the
# original archive run directory, replacing the bad files in-place.
# make check should pass cleanly afterwards.
#
#   rf1_l1b:  228 failures  (run_20260604_200216_be9fcdf2)
#   rf8_l1a:  160 failures  (run_20260605_031557_3b90ed92)
#   rf16_l1a: 126 failures  (run_20260605_143602_67b69911)
#
# Usage:
#   sbatch slurm/examples/run_dense_3layers_sz64_inp_rerun.sh
#
# Optional env vars:
#   FAILED_FILE   path to failed_designs.txt  (default: nangate45/failed_designs.txt)

set -euo pipefail

PARALLELISM=100
SLURM_TIME=05:30:00
SLURM_ACCOUNT=amsc011
SLURM_QOS=express_amsc
SLURM_CONSTRAINT=cpu

REPO_DIR="${SLURM_SUBMIT_DIR:-$(cd "$(dirname "${BASH_SOURCE[0]}")/../.." && pwd)}"
VENV="${WA_HLS4ML_VENV:-${SCRATCH}/venv_hls4ml/bin/activate}"
source "$VENV"
cd "$REPO_DIR"

ARCHIVE_45NM="/global/cfs/cdirs/amsc011/shared/wa-hls4ml-catapult/nangate45"
FAILED_FILE="${FAILED_FILE:-${ARCHIVE_45NM}/failed_designs.txt}"

LM_LICENSE_FILE=$(python3 -c "
import json
with open('${REPO_DIR}/license_servers_perlmutter.json') as f:
    cfg = json.load(f)
print(':'.join(f\"{s['port']}@{s['host']}\" for s in cfg['servers']))
")

# ── Helpers ───────────────────────────────────────────────────────────────────

wait_for_job() {
    local jid="$1"
    echo "  Waiting for SLURM job $jid..."
    sleep 30
    while squeue -j "$jid" -h 2>/dev/null | grep -q .; do sleep 60; done
    local states
    states=$(sacct -j "$jid" --format=State --noheader -P 2>/dev/null | sort | uniq -c)
    echo "  Job $jid final states: $states"
}

resume_if_incomplete() {
    local run_dir="$1" rerun_joblist="$2"
    local tar_dir="${run_dir}/tarballs"
    local total done max_rounds=20 round=0

    total=$(wc -l < "$rerun_joblist")
    done=$(find "${tar_dir}" -maxdepth 1 -name "*.tar.gz" 2>/dev/null | wc -l)

    while (( done < total && round < max_rounds )); do
        round=$(( round + 1 ))
        echo "  Incomplete: $done/$total — re-submitting (round $round/$max_rounds)..."
        local jid
        jid=$(sbatch --parsable "${run_dir}/parallel_synth.sh")
        echo "  Submitted: $jid"
        wait_for_job "$jid"
        local prev=$done
        done=$(find "${tar_dir}" -maxdepth 1 -name "*.tar.gz" 2>/dev/null | wc -l)
        (( done == prev )) && { echo "  No progress — aborting retries"; break; }
    done

    if (( done >= total )); then
        echo "  Complete ($done/$total)."
        return 0
    fi
    echo "  WARNING: $done/$total after $round rounds ($(( total - done )) hard failures)"
    return 0
}

# Replace bad tarball + report in the original archive run dir with new ones.
# Uses .tmp + mv for atomic writes — if anything fails the original file is untouched.
replace_in_archive() {
    local scratch_tar_dir="$1" orig_run="$2"
    local orig_tarballs="${ARCHIVE_45NM}/${orig_run}/tarballs"
    local orig_reports="${ARCHIVE_45NM}/${orig_run}/reports"
    local replaced=0 failed=0

    echo "  Replacing in archive: ${ARCHIVE_45NM}/${orig_run}"

    # Clean up any leftover .tmp files from a previous interrupted run
    find "$orig_tarballs" "$orig_reports" -maxdepth 1 -name "*.tmp" -delete 2>/dev/null || true

    for tb in "${scratch_tar_dir}"/*.tar.gz; do
        [ -f "$tb" ] || continue
        stem=$(basename "$tb" .tar.gz)

        # Verify the new tarball has a complete QOFRSummary before touching anything
        has_qofr=$(tar -xOf "$tb" report.json 2>/dev/null | python3 -c "
import json,sys
r=json.load(sys.stdin)
q=r.get('QOFRSummary',{})
print('ok' if q and q.get('total_area') is not None else 'bad')
" 2>/dev/null || echo "err")

        if [ "$has_qofr" != "ok" ]; then
            echo "    SKIP (still bad/err): $stem"
            failed=$((failed + 1))
            continue
        fi

        # Atomically replace tarball: copy to .tmp, then rename
        if ! cp -f "$tb" "${orig_tarballs}/${stem}.tar.gz.tmp"; then
            echo "    ERROR: cp failed for tarball $stem — original untouched"
            failed=$((failed + 1))
            continue
        fi
        mv -f "${orig_tarballs}/${stem}.tar.gz.tmp" "${orig_tarballs}/${stem}.tar.gz"

        # Atomically replace report JSON: extract to .tmp, then rename
        if ! tar -xOf "$tb" report.json > "${orig_reports}/${stem}.json.tmp" 2>/dev/null; then
            echo "    ERROR: JSON extraction failed for $stem — original JSON untouched"
            rm -f "${orig_reports}/${stem}.json.tmp"
            failed=$((failed + 1))
            continue
        fi
        mv -f "${orig_reports}/${stem}.json.tmp" "${orig_reports}/${stem}.json"

        replaced=$((replaced + 1))
    done

    echo "  Replaced $replaced  |  Still bad (hard failures): $failed"
}

run_rerun_group() {
    local label="$1" orig_run="$2" model_cfg="$3" flow_cfg="$4"
    local base="${SCRATCH}/catapult_dense_3layers_sz64_${label}_rerun"

    echo ""
    echo "=== sz64 ${label} rerun ==="
    echo "  Original archive run: $orig_run"

    # Extract failed stems for this run
    local stems_file
    stems_file=$(mktemp)
    grep -P "^${orig_run}\t" "$FAILED_FILE" | cut -f2 > "$stems_file" || true
    local n_failed
    n_failed=$(wc -l < "$stems_file")
    echo "  Failed stems: $n_failed"
    if [[ "$n_failed" -eq 0 ]]; then
        echo "  Nothing to rerun."
        rm "$stems_file"
        return 0
    fi

    # Generate full cartesian joblist (builds keras model files for all designs)
    python iter_manager_catapult.py \
        -o "$base" \
        --gen_model_config_json "$model_cfg" \
        --flow_config_json "$flow_cfg" \
        --catapult_shell Perlmutter_scripts/catapult_shell.sh \
        --flow_tcl util/catapult_hls4ml_flow.tcl \
        --cartesian \
        --prepare-only

    local run_dir
    run_dir=$(ls -d "${base}"/run_*/ 2>/dev/null | sort | tail -1 || true)
    run_dir="${run_dir%/}"
    [[ -n "$run_dir" ]] || { echo "ERROR: no run dir created under $base" >&2; rm "$stems_file"; return 1; }
    echo "  Run dir: $run_dir"

    # Filter full joblist to failed stems only
    local full_joblist="${run_dir}/joblist.txt"
    local rerun_joblist="${run_dir}/joblist_rerun.txt"

    python3 - <<PYEOF
stems = set()
with open("$stems_file") as f:
    for line in f:
        s = line.strip()
        if s:
            stems.add(s)

kept = []
with open("$full_joblist") as f:
    for line in f:
        build_dir = line.split('\t')[0]
        stem = build_dir.rstrip('/').split('/')[-1]
        if stem in stems:
            kept.append(line)

with open("$rerun_joblist", 'w') as f:
    f.writelines(kept)

found = {l.split('\t')[0].rstrip('/').split('/')[-1] for l in kept}
missing = stems - found
print(f"  Matched {len(kept)}/{len(stems)} failed stems in joblist")
if missing:
    print(f"  WARNING: {len(missing)} stems not found: {sorted(missing)[:5]}")
PYEOF

    rm "$stems_file"

    local n_jobs
    n_jobs=$(wc -l < "$rerun_joblist")
    [[ "$n_jobs" -gt 0 ]] || { echo "ERROR: filtered joblist is empty" >&2; return 1; }
    echo "  Rerun joblist: $n_jobs designs"

    local slurm_logs="${run_dir}/slurm_logs"
    local joblog="${run_dir}/parallel_rerun.log"
    local parallel_script="${run_dir}/parallel_synth.sh"
    mkdir -p "$slurm_logs"

    cat > "$parallel_script" <<SBATCH_EOF
#!/bin/bash
#SBATCH --job-name=sz64_${label}_rerun
#SBATCH --account=${SLURM_ACCOUNT}
#SBATCH --nodes=1
#SBATCH --ntasks=1
#SBATCH --cpus-per-task=200
#SBATCH --mem=400G
#SBATCH --constraint=${SLURM_CONSTRAINT}
#SBATCH --time=${SLURM_TIME}
#SBATCH --qos=${SLURM_QOS}
#SBATCH --output=${slurm_logs}/parallel.out
#SBATCH --error=${slurm_logs}/parallel.err

set -euo pipefail
source "${VENV}"
export LM_LICENSE_FILE="${LM_LICENSE_FILE}"
cd "${REPO_DIR}"

parallel \\
    --joblog "${joblog}" \\
    --resume-failed \\
    --line-buffer \\
    -j ${PARALLELISM} \\
    python "${REPO_DIR}/iter_manager_catapult.py" -o "${base}" --run-single-job {} \\
    < "${rerun_joblist}"
SBATCH_EOF
    chmod +x "$parallel_script"

    local jid
    jid=$(sbatch --parsable "$parallel_script")
    echo "  Submitted: $jid ($n_jobs designs, $PARALLELISM parallel slots)"
    wait_for_job "$jid"

    resume_if_incomplete "${run_dir}" "${rerun_joblist}"

    # Replace bad files in the original archive run dir with the new successful ones
    replace_in_archive "${run_dir}/tarballs" "$orig_run"

    echo "  Done: ${label} rerun."
}

# ── Main ──────────────────────────────────────────────────────────────────────

echo "Failed designs file: $FAILED_FILE"
echo "Total entries (excl comments): $(grep -vc '^#' "$FAILED_FILE" || true)"
echo ""

run_rerun_group inp_rf1_l1b  run_20260604_200216_be9fcdf2 \
    configs/model_sweeps/config_dense_3layers_sz64_inp_l1b.json configs/catapult_flow/config_catapult_flow_rf1.json

run_rerun_group inp_rf8_l1a  run_20260605_031557_3b90ed92 \
    configs/model_sweeps/config_dense_3layers_sz64_inp_l1a.json configs/catapult_flow/config_catapult_flow_rf8.json

run_rerun_group inp_rf16_l1a run_20260605_143602_67b69911 \
    configs/model_sweeps/config_dense_3layers_sz64_inp_l1a.json configs/catapult_flow/config_catapult_flow.json

echo ""
echo "sz64 inp rerun complete. Run 'make check' to verify."
