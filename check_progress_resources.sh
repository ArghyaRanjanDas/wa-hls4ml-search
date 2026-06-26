#!/bin/bash
# Monitor SLURM resource usage and synthesis progress for active catapult HLS4ML jobs.
# Usage:
#   ./check_progress_resources.sh              — live monitor (polls squeue)
#   ./check_progress_resources.sh <JOB_ID>...  — a posteriori report for past jobs
#   -n N   — show last N history entries (default: 5)
#
# Completed tasks are appended (once) to node_history.csv next to this script.

SCRIPT_DIR="$(cd "$(dirname "${BASH_SOURCE[0]}")" && pwd)"
CSV_FILE="$SCRIPT_DIR/node_history.csv"

INTERVAL=30
HISTORY_LIMIT=5

# ── Colors (disabled when not a terminal) ────────────────────────────────────
if [[ -t 1 ]]; then
    BOLD=$'\e[1m'
    DIM=$'\e[2m'
    RED=$'\e[31m'
    GREEN=$'\e[32m'
    YELLOW=$'\e[33m'
    CYAN=$'\e[36m'
    RESET=$'\e[0m'
else
    BOLD='' DIM='' RED='' GREEN='' YELLOW='' CYAN='' RESET=''
fi

hdr()  { echo "${BOLD}${CYAN}$*${RESET}"; }
good() { printf '%s' "${GREEN}$*${RESET}"; }
warn() { printf '%s' "${YELLOW}$*${RESET}"; }
bad()  { printf '%s' "${RED}$*${RESET}"; }
dim()  { printf '%s' "${DIM}$*${RESET}"; }

# cpad STR WIDTH — print STR left-padded to WIDTH visible columns.
# ANSI escape codes are stripped before measuring length so padding is correct.
cpad() {
    local str="$1" w="$2"
    local visible
    visible=$(printf '%s' "$str" | sed 's/\x1b\[[0-9;]*m//g')
    local pad=$(( w - ${#visible} ))
    printf '%s' "$str"
    (( pad > 0 )) && printf '%*s' "$pad" ''
}

mb_to_human() {
    awk -v v="$1" 'BEGIN {
        if      (v >= 1048576) printf "%.1f TB", v/1048576
        else if (v >= 1024)    printf "%.0f GB", v/1024
        else                   printf "%d MB",   v
    }'
}

kb_to_human() {
    awk -v v="$1" 'BEGIN {
        if      (v >= 1073741824) printf "%.1f GB", v/1048576
        else if (v >= 1048576)    printf "%.1f GB", v/1048576
        else if (v >= 1024)       printf "%.0f MB", v/1024
        else                      printf "%d KB",   v
    }'
}

# Convert SLURM time string (D-HH:MM:SS, HH:MM:SS, or M:SS) to seconds.
parse_slurm_time() {
    local t="$1" days=0 h=0 m=0 s=0
    if [[ "$t" == *-* ]]; then
        days="${t%-*}"
        t="${t#*-}"
    fi
    IFS=: read -r h m s <<< "$t"
    if [ -z "$s" ]; then
        echo $(( days * 86400 + 10#${h:-0} * 60 + 10#${m:-0} ))
    else
        echo $(( days * 86400 + 10#${h:-0} * 3600 + 10#${m:-0} * 60 + 10#${s%%.*} ))
    fi
}

# Color a progress percentage: red <25, yellow <75, green >=75, bold-green =100.
color_pct() {
    local pct="$1"
    if   (( pct == 100 )); then printf '%s' "${BOLD}${GREEN}${pct}%${RESET}"
    elif (( pct >= 75  )); then printf '%s' "${GREEN}${pct}%${RESET}"
    elif (( pct >= 25  )); then printf '%s' "${YELLOW}${pct}%${RESET}"
    else                        printf '%s' "${RED}${pct}%${RESET}"
    fi
}

# Color a load-average value relative to expected parallelism.
color_load() {
    local load="$1" par="${2:-100}"
    if [[ "$load" == "n/a" ]]; then dim "n/a"; return; fi
    local iload; iload=$(printf '%.0f' "$load" 2>/dev/null || echo 0)
    local lo=$(( par * 60 / 100 ))
    local hi=$(( par * 110 / 100 ))
    if   (( iload > hi  )); then bad  "$load"
    elif (( iload >= lo )); then good "$load"
    else                         warn "$load"
    fi
}

# Color a job state string.
color_state() {
    case "$1" in
        RUNNING)  good  "$1" ;;
        PENDING)  warn  "$1" ;;
        FAILED|CANCELLED|TIMEOUT) bad "$1" ;;
        COMPLETED) dim  "$1" ;;
        *) printf '%s' "$1" ;;
    esac
}

# Given a job name like catapult_sz64_l3_rf1, return the most recent run_dir.
run_dir_for_job() {
    local name="$1"
    local label="${name#catapult_sz64_}"
    local base="${SCRATCH}/catapult_dense_3layers_sz64_${label}"
    local d
    d=$(ls -d "${base}"/run_*/ 2>/dev/null | sort | tail -1 || true)
    echo "${d%/}"
}

# Return the -j N parallelism from parallel_synth.sh in a run_dir.
parallelism_for_run_dir() {
    local run_dir="$1"
    local script="${run_dir}/parallel_synth.sh"
    if [[ -f "$script" ]]; then
        grep -oP '(?<=-j )\d+' "$script" 2>/dev/null | head -1
    fi
}

print_resources() {
    local CSV_TMP
    CSV_TMP=$(mktemp)

    clear
    echo ""
    printf '%s' "${BOLD}"
    echo "=========================================================="
    echo " SLURM Resource Monitor — catapult HLS4ML jobs"
    echo " $(date '+%Y-%m-%d %H:%M:%S')  (refreshing every ${INTERVAL}s, Ctrl+C to stop)"
    echo "=========================================================="
    printf '%s\n' "${RESET}"

    # ── Active job overview ───────────────────────────────────────────────────
    hdr "[ Active Jobs ]"
    local running pending
    running=$(squeue -u "$USER" -t RUNNING  -h 2>/dev/null | wc -l)
    pending=$(squeue -u "$USER" -t PENDING  -h 2>/dev/null | wc -l)
    printf "  Running: %s   Pending: %s\n\n" \
        "$(good "$running")" "$(warn "$pending")"

    printf "  ${BOLD}%-20s  %-30s  %-10s  %-12s  %-16s  %s${RESET}\n" \
        "JOBID" "NAME" "STATE" "TIME" "QOS" "NODE/REASON"
    while IFS='|' read -r jid jname state elapsed qos node reason; do
        local state_col info
        state_col=$(color_state "$state")
        if [[ "$state" == "PENDING" ]]; then
            info="$(warn "$reason")"
        else
            info="$node"
        fi
        printf "  %-20s  %-30s  %s  %-12s  %-16s  %s\n" \
            "$jid" "$jname" "$(cpad "$state_col" 10)" "$elapsed" "$qos" "$info"
    done < <(squeue -u "$USER" -h -o "%i|%j|%T|%M|%q|%N|%R" 2>/dev/null | head -29)
    echo ""

    # ── Scratch quota ────────────────────────────────────────────────────────
    hdr "[ Scratch Quota — $SCRATCH ]"
    local quota_raw
    quota_raw=$(lfs quota -u "$USER" "$SCRATCH" 2>/dev/null)
    if [[ -n "$quota_raw" ]]; then
        # Disk usage (kbytes used / soft-quota)  — values are on line 4
        local kb_used kb_quota f_used f_quota
        read -r kb_used kb_quota _ _ f_used f_quota _ < \
            <(echo "$quota_raw" | awk 'NR==4{print $1, $2, $3, $4, $5, $6, $7}')
        # Strip trailing * (over-quota marker) from values
        kb_used="${kb_used%\*}"; kb_quota="${kb_quota%\*}"
        f_used="${f_used%\*}";   f_quota="${f_quota%\*}"

        # Disk bar
        local disk_pct=0
        [[ "${kb_quota:-0}" -gt 0 ]] && disk_pct=$(( kb_used * 100 / kb_quota ))
        local disk_used_h disk_quota_h
        disk_used_h=$(kb_to_human "${kb_used:-0}")
        disk_quota_h=$(kb_to_human "${kb_quota:-0}")
        local disk_col
        if   (( disk_pct >= 90 )); then disk_col=$(bad  "${disk_used_h} / ${disk_quota_h}  (${disk_pct}%) ⚠")
        elif (( disk_pct >= 75 )); then disk_col=$(warn "${disk_used_h} / ${disk_quota_h}  (${disk_pct}%)")
        else                            disk_col=$(good "${disk_used_h} / ${disk_quota_h}  (${disk_pct}%)")
        fi
        printf "  Disk:   %s\n" "$disk_col"

        # Inode bar
        local inode_pct=0
        [[ "${f_quota:-0}" -gt 0 ]] && inode_pct=$(( f_used * 100 / f_quota ))
        local inode_col
        if   (( inode_pct >= 90 )); then inode_col=$(bad  "${f_used} / ${f_quota}  (${inode_pct}%) ⚠")
        elif (( inode_pct >= 75 )); then inode_col=$(warn "${f_used} / ${f_quota}  (${inode_pct}%)")
        else                            inode_col=$(good "${f_used} / ${f_quota}  (${inode_pct}%)")
        fi
        printf "  Inodes: %s\n" "$inode_col"
    else
        dim "  lfs quota not available."
    fi
    echo ""

    # ── Synthesis progress ────────────────────────────────────────────────────
    hdr "[ Synthesis Progress ]"
    local _found_progress=0

    # sz64 / sz32 cartesian jobs
    while IFS='|' read -r raw_id name node; do
        [[ "$name" != catapult_sz64_* ]] && continue
        _found_progress=1
        local run_dir
        run_dir=$(run_dir_for_job "$name")
        if [[ -n "$run_dir" && -f "${run_dir}/joblist.txt" ]]; then
            local total done_count pct
            total=$(wc -l < "${run_dir}/joblist.txt")
            done_count=$(ls "${run_dir}/tarballs"/*.tar.gz 2>/dev/null | wc -l)
            pct=$(( done_count * 100 / (total > 0 ? total : 1) ))
            local log_lines
            log_lines=$(wc -l < "${run_dir}/parallel.log" 2>/dev/null || echo 1)
            local completed_jobs=$(( log_lines - 1 ))
            local pct_col
            pct_col=$(color_pct "$pct")
            printf "  %s  %5d / %5d  (%s)  joblog: %d entries\n" \
                "$(cpad "${CYAN}${name}${RESET}" 34)" \
                "$done_count" "$total" "$pct_col" "$completed_jobs"
        else
            printf "  %s  %s\n" "$(cpad "${CYAN}${name}${RESET}" 34)" "$(warn "run_dir not found")"
        fi
    done < <(squeue -u "$USER" -t RUNNING -h -o "%i|%j|%N" 2>/dev/null)

    # 2-layer sz128 RF=1 recovery jobs (all parts share one tarball dir)
    local RF1_RUN_DIR="/pscratch/sd/g/gdg/catapult_45nm_2layer_sz128_rf1/run_20260613_110449_079328c7"
    local RF1_TOTAL=4914
    local rf1_running rf1_pending rf1_done rf1_pct
    rf1_running=$(squeue -u "$USER" -h -o "%j" 2>/dev/null | grep -c "^recover_2l_rf1_" || true)
    rf1_pending=$(squeue -u "$USER" -h -t PENDING -o "%j" 2>/dev/null | grep -c "^recover_2l_rf1_" || true)
    rf1_done=$(ls "${RF1_RUN_DIR}/tarballs/" 2>/dev/null | wc -l)
    if (( rf1_running > 0 || rf1_pending > 0 || rf1_done > 0 )); then
        _found_progress=1
        rf1_pct=$(( rf1_done * 100 / RF1_TOTAL ))
        printf "  %s  %5d / %5d  (%s)  nodes: %s running  %s pending\n" \
            "$(cpad "${CYAN}recover_2l_sz128_rf1${RESET}" 34)" \
            "$rf1_done" "$RF1_TOTAL" "$(color_pct "$rf1_pct")" \
            "$rf1_running" "$rf1_pending"
    fi

    [[ $_found_progress -eq 0 ]] && dim "  No running synthesis jobs." && echo ""
    echo ""

    # ── Per-node memory for catapult jobs ────────────────────────────────────
    hdr "[ Memory per Node — catapult jobs ]"

    declare -A catapult_parents
    local running_task_ids=""
    local -a running_tasks
    if [ ${#APOSTERIORI_IDS[@]} -gt 0 ]; then
        for jid in "${APOSTERIORI_IDS[@]}"; do
            catapult_parents["$jid"]=1
        done
    else
        while IFS='|' read -r raw_id name node; do
            [[ "$name" != *catapult* && "$name" != recover_2l_rf1* ]] && continue
            parent="${raw_id%%_*}"
            catapult_parents["$parent"]=1
            running_task_ids="${running_task_ids},${raw_id}"
            running_tasks+=("${raw_id}|${node}|${parent}|${name}")
        done < <(squeue -u "$USER" -t RUNNING -h -o "%i|%j|%N" 2>/dev/null)
        running_task_ids="${running_task_ids#,}"
    fi

    if [ ${#catapult_parents[@]} -eq 0 ]; then
        dim "  No running catapult jobs."; echo ""
    fi

    declare -A alloc_elapsed_secs alloc_ncpus
    while IFS='|' read -r raw_id elapsed ncpus; do
        local secs
        secs=$(parse_slurm_time "$elapsed")
        alloc_elapsed_secs["$raw_id"]=$secs
        alloc_ncpus["$raw_id"]=$ncpus
    done < <(squeue -u "$USER" -t RUNNING -h -o "%i|%M|%C" 2>/dev/null)

    local sstat_target="$running_task_ids"
    if [ -z "$sstat_target" ]; then
        local pt; for pt in "${!catapult_parents[@]}"; do
            sstat_target="${sstat_target},${pt}"
        done
        sstat_target="${sstat_target#,}"
    fi
    declare -A node_maxrss_kb
    if [ -n "$sstat_target" ]; then
        while IFS='|' read -r stepid maxrss_raw node; do
            [[ "$stepid" != *".batch" ]] && continue
            local mkb
            if   [[ "$maxrss_raw" == *G ]]; then local _v="${maxrss_raw%G}"; mkb=$(( ${_v%%.*} * 1048576 ))
            elif [[ "$maxrss_raw" == *M ]]; then local _v="${maxrss_raw%M}"; mkb=$(( ${_v%%.*} * 1024 ))
            elif [[ "$maxrss_raw" == *K ]]; then mkb="${maxrss_raw%K}"
            else mkb="${maxrss_raw:-0}"
            fi
            local existing="${node_maxrss_kb[$node]:-0}"
            [[ "$mkb" -gt "$existing" ]] && node_maxrss_kb["$node"]="$mkb"
        done < <(sstat -j "$sstat_target" --allsteps \
                     --format=JobID,MaxRSS,NodeList \
                     --noheader --parsable2 2>/dev/null)
    fi

    local sstat_rows=()
    local all_nodes_list=""
    for task_entry in "${running_tasks[@]}"; do
        IFS='|' read -r task_id node parent name <<< "$task_entry"
        local maxrss_kb="${node_maxrss_kb[$node]:-0}"
        sstat_rows+=("${task_id}|${maxrss_kb}|${node}|${parent}|${name}")
        all_nodes_list="${all_nodes_list},${node}"
    done

    if [ ${#sstat_rows[@]} -eq 0 ]; then
        dim "  No sstat data yet (tasks just started)."; echo ""; echo ""
    else

    declare -A node_total_mb
    local node_list="${all_nodes_list#,}"
    local cur_node=""
    while IFS= read -r line; do
        if [[ "$line" =~ NodeName=([^[:space:]]+) ]]; then
            cur_node="${BASH_REMATCH[1]}"
        fi
        if [[ "$line" =~ RealMemory=([0-9]+) ]] && [ -n "$cur_node" ]; then
            node_total_mb["$cur_node"]="${BASH_REMATCH[1]}"
        fi
    done < <(scontrol show node "$node_list" 2>/dev/null)

    # Node load averages via SSH (best-effort)
    declare -A node_load
    local unique_nodes
    unique_nodes=$(echo "$all_nodes_list" | tr ',' '\n' | sort -u | tr '\n' ' ')
    for nd in $unique_nodes; do
        [[ -z "$nd" ]] && continue
        local load1
        load1=$(ssh -o BatchMode=yes -o ConnectTimeout=3 "$nd" \
                    "awk '{print \$1}' /proc/loadavg" 2>/dev/null || echo "n/a")
        node_load["$nd"]="$load1"
    done

    printf "  ${BOLD}%-14s  %-14s  %-8s  %-12s  %-12s  %-10s  %s${RESET}\n" \
        "Node" "AllocJob" "Parallel" "NodeMem" "MaxRSS" "Load(1m)" "CPUEff"
    printf "  %-14s  %-14s  %-8s  %-12s  %-12s  %-10s  %s\n" \
        "----" "--------" "--------" "-------" "------" "--------" "------"

    for row in "${sstat_rows[@]}"; do
        IFS='|' read -r alloc maxrss_kb node parent name <<< "$row"
        local maxrss_h nodemem_h eff="n/a" parallelism="-"
        maxrss_h=$(kb_to_human "${maxrss_kb:-0}")
        local total_mb="${node_total_mb[$node]:-0}"
        nodemem_h=$(mb_to_human "$total_mb")
        local total_kb=$(( total_mb * 1024 ))

        # Memory warning color
        local maxrss_disp="$maxrss_h"
        if [ "${maxrss_kb:-0}" -gt 0 ] && [ "$total_kb" -gt 0 ]; then
            local mem_pct=$(( maxrss_kb * 100 / total_kb ))
            if   (( mem_pct > 80 )); then maxrss_disp="$(bad "${maxrss_h} ⚠ ${mem_pct}%")"
            elif (( mem_pct > 60 )); then maxrss_disp="$(warn "$maxrss_h")"
            fi
        fi

        # Parallelism from parallel_synth.sh
        if [[ "$name" == catapult_sz64_* ]]; then
            local _rdir
            _rdir=$(run_dir_for_job "$name")
            [[ -n "$_rdir" ]] && parallelism=$(parallelism_for_run_dir "$_rdir")
        elif [[ "$name" == recover_2l_rf1* ]]; then
            local _part="${name##*_s}"; _part="${_part%%v*}"
            local _s
            for _s in "${RF1_RUN_DIR}/parallel_synth_shared_${_part}_v2.sh" \
                       "${RF1_RUN_DIR}/parallel_synth_shared_${_part}.sh"; do
                [[ -f "$_s" ]] && { parallelism=$(grep -oP '(?<=-j )\d+' "$_s" | head -1); break; }
            done
        fi
        parallelism="${parallelism:--}"

        local load_str
        load_str=$(color_load "${node_load[$node]:-n/a}" "$parallelism")

        printf "  %s  %-14s  %-8s  %-12s  %s  %s  %s\n" \
            "$(cpad "${CYAN}${node}${RESET}" 14)" \
            "$alloc" "$parallelism" "$nodemem_h" \
            "$(cpad "$maxrss_disp" 12)" \
            "$(cpad "$load_str" 10)" \
            "$eff"
    done | sort -k1

    echo ""
    fi

    # ── Node history: begin/end/MaxRSS per completed or running task ─────────
    hdr "[ Node History — catapult tasks ]"

    # Single sacct call for all user jobs in last 7 days — filter by name in awk.
    # This avoids one sacct call per job (which was 100+ calls and too slow).
    local since; since=$(date -d '7 days ago' '+%Y-%m-%dT%H:%M:%S' 2>/dev/null || \
                         date -v-7d '+%Y-%m-%dT%H:%M:%S' 2>/dev/null)

    printf "  ${BOLD}%-14s  %-16s  %-20s  %-20s  %-14s  %-12s  %s${RESET}\n" \
        "Node" "AllocJob" "Start" "End" "Runtime" "MaxRSS" "CPUEff"
    printf "  %-14s  %-16s  %-20s  %-20s  %-14s  %-12s  %s\n" \
        "----" "--------" "-----" "---" "-------" "------" "------"

    sacct -u "$USER" \
        --format=JobID,JobName,NodeList,Start,End,MaxRSS,TotalCPU,CPUTimeRAW \
        --starttime="$since" --noheader --parsable2 2>/dev/null | \
    awk -F'|' -v csv_tmp="$CSV_TMP" '
        function fmt_dur(secs,    h, m, s) {
            h = int(secs / 3600); m = int((secs % 3600) / 60); s = secs % 60
            if (h > 0) return sprintf("%dh %02dm %02ds", h, m, s)
            if (m > 0) return sprintf("%dm %02ds", m, s)
            return sprintf("%ds", s)
        }
        function parse_ts(t,    pp, dp, tp) {
            split(t, pp, "T"); split(pp[1], dp, "-"); split(pp[2], tp, ":")
            return mktime(dp[1] " " dp[2] " " dp[3] " " tp[1] " " tp[2] " " tp[3])
        }
        function parse_slurm_t(t,    days, rest, hms) {
            days = 0
            if (index(t, "-") > 0) { days = substr(t,1,index(t,"-")-1)+0; rest = substr(t,index(t,"-")+1) }
            else rest = t
            split(rest, hms, ":")
            return days*86400 + hms[1]*3600 + hms[2]*60 + int(hms[3]+0)
        }
        $1 ~ /\.extern/ { next }
        $2 !~ /^catapult_sz64|^catapult_sz32|^rerun_|^recover_/ { next }
        {
            split($1, a, "."); id = a[1]
            if ($1 ~ /\.batch/) { rss=$6; gsub(/K$/,"",rss); maxrss[id]=rss+0; totalcpu[id]=parse_slurm_t($7) }
            else if ($1 !~ /\./) { node[id]=$3; jname[id]=$2; start[id]=$4; end_t[id]=$5; cputimeraw[id]=$8+0 }
        }
        END {
            for (id in node) {
                rss_kb = maxrss[id]+0
                if      (rss_kb >= 1048576) rss_h = sprintf("%.1f GB", rss_kb/1048576)
                else if (rss_kb >= 1024)    rss_h = sprintf("%.0f MB", rss_kb/1024)
                else if (rss_kb > 0)        rss_h = sprintf("%d KB", rss_kb)
                else                        rss_h = "n/a"
                if (end_t[id] == "Unknown" || end_t[id] == "") {
                    end_str = "running..."; dur = "running..."; dur_secs = -1
                } else {
                    end_str  = end_t[id]
                    t1 = parse_ts(start[id]); t2 = parse_ts(end_t[id])
                    dur_secs = (t1>0 && t2>t1) ? t2-t1 : -1
                    dur = (dur_secs > 0) ? fmt_dur(dur_secs) : "n/a"
                }
                cpur = cputimeraw[id]+0; tcpu = totalcpu[id]+0
                if (cpur > 0) { eff_pct = int(tcpu*100/cpur); eff = sprintf("%.0f%%", tcpu*100/cpur) }
                else          { eff_pct = -1; eff = "n/a" }
                print node[id] "|" id "|" start[id] "|" end_str "|" dur "|" rss_h "|" eff "|" dur_secs "|" rss_kb "|" eff_pct
                if (csv_tmp != "" && end_t[id] != "Unknown" && end_t[id] != "")
                    print node[id] "|" id "|" "-" "|" start[id] "|" end_t[id] "|" dur_secs "|" rss_kb "|" eff_pct >> csv_tmp
            }
        }
    ' | sort -t'|' -k3 | tail -"$HISTORY_LIMIT" | \
    while IFS='|' read -r nd id st end_str dur rss_h eff dur_secs rss_kb eff_pct; do
        local end_col dur_col eff_col
        if [[ "$end_str" == "running..." ]]; then
            end_col=$(warn "$end_str"); dur_col=$(warn "$dur")
        else
            end_col=$(dim "$end_str"); dur_col="${GREEN}${dur}${RESET}"
        fi
        if [[ "$eff" == "n/a" ]]; then
            eff_col=$(dim "n/a")
        elif (( eff_pct >= 50 )); then
            eff_col="${GREEN}${eff}${RESET}"
        else
            eff_col="${YELLOW}${eff}${RESET}"
        fi
        printf "  %s  %-16s  %-20s  %s  %s  %-12s  %s\n" \
            "$(cpad "${CYAN}${nd}${RESET}" 14)" \
            "$id" "$st" \
            "$(cpad "$end_col" 20)" \
            "$(cpad "$dur_col" 14)" \
            "$rss_h" "$eff_col"
    done

    echo ""

    # ── Append new completed rows to permanent CSV ────────────────────────────
    if [ -f "$CSV_TMP" ] && [ -s "$CSV_TMP" ]; then
        if [ ! -f "$CSV_FILE" ]; then
            echo "Node,AllocJob,Parallel,Start,End,RuntimeSecs,MaxRSS_KB,CPUEff_pct" \
                > "$CSV_FILE"
        fi
        while IFS='|' read -r nd al par st en ds rk ep; do
            grep -qF ",$al," "$CSV_FILE" 2>/dev/null || \
                echo "${nd},${al},${par},${st},${en},${ds},${rk},${ep}" >> "$CSV_FILE"
        done < "$CSV_TMP"
    fi
    rm -f "$CSV_TMP"
}

# ── Entry point ──────────────────────────────────────────────────────────────
APOSTERIORI_IDS=()

REMAINING_ARGS=()
while [[ $# -gt 0 ]]; do
    case "$1" in
        -n) HISTORY_LIMIT="${2:?-n requires a number}"; shift 2 ;;
        -n*) HISTORY_LIMIT="${1#-n}"; shift ;;
        *) REMAINING_ARGS+=("$1"); shift ;;
    esac
done
set -- "${REMAINING_ARGS[@]}"

if [ $# -gt 0 ]; then
    APOSTERIORI_IDS=("$@")
    print_resources
else
    while true; do
        print_resources
        sleep "$INTERVAL"
    done
fi
