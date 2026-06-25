#!/bin/bash
#SBATCH --job-name=recover_2l_sz128_rf1
#SBATCH --account=amsc011
#SBATCH --qos=shared
#SBATCH --nodes=1
#SBATCH --ntasks=1
#SBATCH --cpus-per-task=4
#SBATCH --mem=8G
#SBATCH --constraint=cpu
#SBATCH --time=2-00:00:00
#SBATCH --output=%x_%j.out
#SBATCH --error=%x_%j.err
#
# Recovery script for 45nm 2-layer sz128 RF=1 synthesis.
# Resubmits the 3 synthesis nodes with QOS=regular (48h wall time) so that
# heavy 128x128 designs that timed out under express_amsc (6h) can complete.
# GNU parallel --resume-failed skips the 1,470 already-successful designs.
#
# Usage:
#   sbatch slurm/examples/recover_45nm_2layer_sz128_rf1.sh

set -euo pipefail

RUN_DIR="/pscratch/sd/g/gdg/catapult_45nm_2layer_sz128_rf1/run_20260613_110449_079328c7"
REPO_DIR="${SLURM_SUBMIT_DIR:-$(cd "$(dirname "${BASH_SOURCE[0]}")/../.." && pwd)}"
ARCHIVE_45NM="/global/cfs/cdirs/amsc011/shared/wa-hls4ml-catapult/nangate45"

TOTAL=4914
TAR_DIR="${RUN_DIR}/tarballs"

echo "=== Recovery: 45nm 2-layer sz128 RF=1 ==="
echo "Run dir: $RUN_DIR"
echo "Tarballs so far: $(ls "$TAR_DIR" 2>/dev/null | wc -l) / $TOTAL"
echo ""

# ── Patch synth scripts: swap qos + wall time, write _regular variants ─────────

for part in a b c; do
    src="${RUN_DIR}/parallel_synth_${part}.sh"
    dst="${RUN_DIR}/parallel_synth_${part}_regular.sh"
    sed \
        -e 's/--qos=express_amsc/--qos=regular/' \
        -e 's/--time=06:00:00/--time=1-22:00:00/' \
        -e "s/--job-name=45nm_2l_sz128_rf1_${part}/--job-name=recover_2l_rf1_${part}/" \
        "$src" > "$dst"
    chmod +x "$dst"
    echo "Patched: $dst"
done
echo ""

wait_for_jobs() {
    local jids=("$@")
    echo "  Waiting for jobs: ${jids[*]}"
    sleep 30
    local elapsed=0
    while true; do
        local any=0
        for jid in "${jids[@]}"; do
            squeue -j "$jid" -h 2>/dev/null | grep -q . && { any=1; break; }
        done
        [ "$any" -eq 0 ] && break
        sleep 120
        elapsed=$(( elapsed + 120 ))
        if (( elapsed % 600 == 0 )); then
            local n; n=$(ls "$TAR_DIR" 2>/dev/null | wc -l)
            echo "  [$(date '+%H:%M')] tarballs: $n / $TOTAL"
        fi
    done
    for jid in "${jids[@]}"; do
        local states
        states=$(sacct -j "$jid" --format=State --noheader -P 2>/dev/null | sort | uniq -c)
        echo "  Job $jid final states: $states"
    done
}

# ── Submit all 3 nodes in parallel, retry up to 10 rounds ─────────────────────

done_count=$(ls "$TAR_DIR" 2>/dev/null | wc -l)
max_rounds=10
round=0
prev=0

jid_a=$(sbatch --parsable "${RUN_DIR}/parallel_synth_a_regular.sh")
jid_b=$(sbatch --parsable "${RUN_DIR}/parallel_synth_b_regular.sh")
jid_c=$(sbatch --parsable "${RUN_DIR}/parallel_synth_c_regular.sh")
echo "[round 0] Submitted: $jid_a (a) + $jid_b (b) + $jid_c (c)"
wait_for_jobs "$jid_a" "$jid_b" "$jid_c"
done_count=$(ls "$TAR_DIR" 2>/dev/null | wc -l)
echo "[round 0] done: $done_count / $TOTAL"

while (( done_count < TOTAL && round < max_rounds )); do
    round=$(( round + 1 ))
    echo "[round $round] $done_count/$TOTAL — re-submitting..."
    jid_a=$(sbatch --parsable "${RUN_DIR}/parallel_synth_a_regular.sh")
    jid_b=$(sbatch --parsable "${RUN_DIR}/parallel_synth_b_regular.sh")
    jid_c=$(sbatch --parsable "${RUN_DIR}/parallel_synth_c_regular.sh")
    echo "[round $round] Submitted: $jid_a + $jid_b + $jid_c"
    wait_for_jobs "$jid_a" "$jid_b" "$jid_c"
    prev=$done_count
    done_count=$(ls "$TAR_DIR" 2>/dev/null | wc -l)
    echo "[round $round] done: $done_count / $TOTAL  (+$(( done_count - prev )) new)"
    (( done_count == prev )) && { echo "[round $round] no progress — aborting retries" >&2; break; }
done

echo ""
if (( done_count < TOTAL )); then
    echo "WARNING: $done_count/$TOTAL completed after $round rounds"
else
    echo "Synthesis complete ($done_count/$TOTAL)"
fi

echo "Archiving rf1 (incremental) → nangate45/ ..."
bash "${REPO_DIR}/slurm/examples/archive_run.sh" "${RUN_DIR}" --yes
echo "Done."
