#!/bin/bash
# Profiling run: 3-layer dense, all layers 64 neurons, bw=14, RF=1.
# Single design (input=64, layers=64/64/64, relu, bw=14, RF=1).
# Purpose: measure synthesis wall time before committing to a full size-64 sweep.
# Blocks until the SLURM job finishes, then appends a row to node_history.csv.
#
# Run from repo root: bash slurm/examples/run_dense_3layers_profiling_64.sh
source $SCRATCH/venv_hls4ml/bin/activate

REPO_ROOT="$(cd "$(dirname "${BASH_SOURCE[0]}")/../.." && pwd)"
CSV_FILE="$REPO_ROOT/node_history.csv"
OUT_DIR=$SCRATCH/catapult_dense_3layers_profiling_64

python iter_manager_catapult.py \
  -o "$OUT_DIR" \
  --catapult_shell Perlmutter_scripts/catapult_shell.sh \
  --flow_tcl      util/catapult_hls4ml_flow.tcl \
  --license_config license_servers_perlmutter.json \
  --gen_model_config_json configs/model_sweeps/config_dense_3layers_profiling_64.json \
  --flow_config_json configs/catapult_flow/config_catapult_flow_rf1.json \
  --cartesian \
  --slurm --slurm-qos express_amsc --slurm-time 02:00:00 \
  --slurm-parallelism 1 --slurm-mem-per-job 32G

# ── Wait for job and write CSV row ────────────────────────────────────────────
RUN_DIR=$(ls -td "$OUT_DIR"/run_*/ 2>/dev/null | head -1)
JID=$(cat "$RUN_DIR/slurm_job_id.txt" 2>/dev/null)
if [ -z "$JID" ]; then
    echo "Could not find job ID — CSV not written." >&2
    exit 1
fi

echo "Job $JID submitted. Waiting for completion (polling sacct every 30s)..."
until sacct -j "$JID" --format=State --noheader -P 2>/dev/null \
      | grep -qvE "^(RUNNING|PENDING|COMPLETING|)$"; do
    sleep 30
done
echo "Job $JID done. Writing to $CSV_FILE..."

sacct -j "$JID" \
    --format=JobID,NodeList,Start,End,MaxRSS,TotalCPU,CPUTimeRAW \
    --noheader --parsable2 2>/dev/null | \
awk -F'|' '
    function parse_ts(t,    pp, dp, tp) {
        split(t, pp, "T"); split(pp[1], dp, "-"); split(pp[2], tp, ":")
        return mktime(dp[1] " " dp[2] " " dp[3] " " tp[1] " " tp[2] " " tp[3])
    }
    function parse_slurm_t(t,    days, rest, hms) {
        days = 0
        if (index(t, "-") > 0) { days = substr(t, 1, index(t,"-")-1)+0; rest = substr(t, index(t,"-")+1) }
        else rest = t
        split(rest, hms, ":")
        return days*86400 + hms[1]*3600 + hms[2]*60 + int(hms[3]+0)
    }
    $1 ~ /\.extern/ { next }
    {
        split($1, a, "."); id = a[1]
        if ($1 ~ /\.batch/) {
            rss = $5; gsub(/K$/, "", rss); maxrss[id] = rss+0; totalcpu[id] = parse_slurm_t($6)
        } else if ($1 !~ /\./) {
            nd[id]=$2; st[id]=$3; en[id]=$4; cpur[id]=$7+0
        }
    }
    END {
        for (id in nd) {
            if (en[id] == "Unknown" || en[id] == "") continue
            t1 = parse_ts(st[id]); t2 = parse_ts(en[id])
            dur = (t1>0 && t2>t1) ? t2-t1 : -1
            rk = maxrss[id]+0
            ep = (cpur[id]>0) ? int(totalcpu[id]*100/cpur[id]) : -1
            split(id, aid, "_"); array_job = aid[1]
            print nd[id] "|" id "|" array_job "|1|" st[id] "|" en[id] "|" dur "|" rk "|" ep
        }
    }
' | while IFS='|' read -r nd al ar hl st en ds rk ep; do
    [ -f "$CSV_FILE" ] || echo "Node,AllocJob,ArrayJob,HLS,Start,End,RuntimeSecs,MaxRSS_KB,CPUEff_pct" > "$CSV_FILE"
    grep -qF ",$al," "$CSV_FILE" 2>/dev/null || \
        echo "${nd},${al},${ar},${hl},${st},${en},${ds},${rk},${ep}" >> "$CSV_FILE"
done

echo "Done. Row appended to $CSV_FILE"
cat "$CSV_FILE"
