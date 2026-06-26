#!/bin/bash
# Track synthesis progress + archive totals

ARCHIVE_BASE=/global/cfs/cdirs/amsc011/shared/wa-hls4ml-catapult
ARCHIVE_45NM="$ARCHIVE_BASE/nangate45"
ARCHIVE_GF22NM="$ARCHIVE_BASE/gf22fdx"
ARCHIVE="$ARCHIVE_GF22NM"   # default; overridden per-section

# ── Colors ───────────────────────────────────────────────────────────────────
if [[ -t 1 ]]; then
    BOLD=$'\e[1m'; DIM=$'\e[2m'; RED=$'\e[31m'; GREEN=$'\e[32m'
    YELLOW=$'\e[33m'; CYAN=$'\e[36m'; RESET=$'\e[0m'
else
    BOLD='' DIM='' RED='' GREEN='' YELLOW='' CYAN='' RESET=''
fi

hdr()  { echo "${BOLD}${CYAN}$*${RESET}"; }
good() { printf '%s' "${GREEN}$*${RESET}"; }
warn() { printf '%s' "${YELLOW}$*${RESET}"; }
bad()  { printf '%s' "${RED}$*${RESET}"; }
dim()  { printf '%s' "${DIM}$*${RESET}"; }

cpad() {
    local str="$1" w="$2"
    local visible; visible=$(printf '%s' "$str" | sed 's/\x1b\[[0-9;]*m//g')
    local pad=$(( w - ${#visible} ))
    printf '%s' "$str"
    (( pad > 0 )) && printf '%*s' "$pad" ''
}

color_pct() {
    local pct="$1"
    if   (( pct == 100 )); then printf '%s' "${BOLD}${GREEN}${pct}%${RESET}"
    elif (( pct >= 75  )); then printf '%s' "${GREEN}${pct}%${RESET}"
    elif (( pct >= 25  )); then printf '%s' "${YELLOW}${pct}%${RESET}"
    else                        printf '%s' "${RED}${pct}%${RESET}"
    fi
}

LABEL_W=26
INDENT=$(( 2 + LABEL_W + 2 ))

# ── check_step: per-RF detailed row ──────────────────────────────────────────
check_step() {
    local label="$1" scratch_pattern="$2" expected="$3"

    local total_tarballs=0 total_archived=0 any_dir=0

    for dir in $scratch_pattern; do
        [ -d "$dir" ] || continue
        any_dir=1
        local tarballs run_name archived
        tarballs=$(ls "${dir}tarballs/" 2>/dev/null | wc -l)
        run_name=$(basename "$dir")
        archived=$(ls "$ARCHIVE/${run_name}/tarballs/" 2>/dev/null | wc -l)
        total_tarballs=$(( total_tarballs + tarballs ))
        total_archived=$(( total_archived + archived ))
    done

    local scratch_base; scratch_base=$(echo "$scratch_pattern" | sed 's|/run_\*/$||')
    for src_file in "$ARCHIVE"/run_*/source_dir.txt; do
        [ -f "$src_file" ] || continue
        local src run_dir archived
        src=$(cat "$src_file"); run_dir=$(dirname "$src_file")
        if [[ "$src" == "$scratch_base"/* ]] && [ ! -d "$src" ]; then
            any_dir=1
            archived=$(ls "${run_dir}/tarballs/" 2>/dev/null | wc -l)
            total_archived=$(( total_archived + archived ))
            total_tarballs=$(( total_tarballs + archived ))
        fi
    done

    local label_col; label_col=$(cpad "$label" "$LABEL_W")

    if [ "$any_dir" -eq 0 ]; then
        printf "  %s  %s\n" "$label_col" "$(dim "⏳ not started  (${expected} designs awaiting)")"
        return
    fi

    local pct=$(( total_tarballs * 100 / (expected > 0 ? expected : 1) ))
    local pct_col; pct_col=$(color_pct "$pct")
    local progress="${CYAN}${total_tarballs}${RESET} / ${expected}"

    local is_running=0 state_col
    if [ "$total_tarballs" -ge "$expected" ]; then
        state_col="$(good "✅ complete")"
    elif [ "$SLURM_ACTIVE" -gt 0 ]; then
        state_col="$(warn "🔄 running (${SLURM_ACTIVE} job)")"
        is_running=1
    else
        state_col="$(warn "⏸  paused")"
    fi
    printf "  %s  %s  (%s)  %s\n" "$label_col" "$progress" "$pct_col" "$state_col"

    local archive_col
    if   [ "$total_archived" -ge "$expected" ]; then archive_col="$(good "✅ archived")"
    elif [ "$total_archived" -gt 0            ]; then archive_col="$(warn "⚠  partial (${total_archived}/${expected})")"
    else                                              archive_col="$(bad  "❌ not archived")"
    fi
    printf "  %*s%s\n" "$INDENT" "" "$archive_col"

    if [ "$is_running" -eq 1 ]; then
        local slug; slug=$(printf '%s' "$label" | tr -cs 'a-zA-Z0-9-' '_')
        local bfile="${TMPDIR:-/tmp}/chkprog_batch_${USER}_${slug}.dat"
        local now; now=$(date +%s)
        echo "$now $total_tarballs" >> "$bfile"
        awk -v c="$(( now - 600 ))" '$1 >= c' "$bfile" > "${bfile}.tmp" 2>/dev/null && mv "${bfile}.tmp" "$bfile"
        local nlines; nlines=$(wc -l < "$bfile" 2>/dev/null || echo 0)
        local remaining=$(( expected - total_tarballs ))
        if [ "$nlines" -lt 3 ]; then
            printf "  %*s%s\n" "$INDENT" "" "$(dim "ETA: warming up...")"
        else
            local dc dt
            { read -r dc dt; } < <(awk 'NR==1{t0=$1;c0=$2} END{print $2-c0, $1-t0}' "$bfile")
            if [ "${dc:-0}" -le 0 ] || [ "${dt:-0}" -le 0 ]; then
                printf "  %*s%s\n" "$INDENT" "" "$(warn "ETA: stalled (no new tarballs)")"
            else
                local eta_sec=$(( remaining * dt / dc ))
                local h=$(( eta_sec / 3600 )) m=$(( (eta_sec % 3600) / 60 ))
                local rate_hr=$(( dc * 3600 / dt ))
                local finish; finish=$(date -d "@$(( now + eta_sec ))" '+%Y-%m-%d %H:%M' 2>/dev/null)
                printf "  %*sRate: ~%s/hr  ETA: %s  (done ~%s)\n" "$INDENT" "" \
                    "$(good "$rate_hr")" "${YELLOW}${h}h ${m}m${RESET}" "${BOLD}${finish}${RESET}"
            fi
        fi
    fi
}

# ── check_phase: auto-compact when all 4 RFs are fully archived ───────────────
# Usage: check_phase TITLE EXPECTED_PER_RF SCRATCH_PFX_NORF ARCHIVE_DIR
#   SCRATCH_PFX_NORF: base without _rfN, e.g. catapult_45nm_4layer_lhs
# Prints one compact ✅ line when done; hdr+detail when in progress;
# single ⏳ line when not started.
check_phase() {
    local title="$1" expected="$2" pfx="$3" archive_dir="$4"

    ARCHIVE="$archive_dir"

    local any_exists=0 total_archived=0 n_rf_done=0
    for RF in rf1 rf4 rf8 rf16; do
        local rf_archived=0

        # Count from archive via run name (scratch still live)
        for dir in "$SCRATCH/${pfx}_${RF}"/run_*/; do
            [ -d "$dir" ] || continue
            any_exists=1
            local run_name; run_name=$(basename "$dir")
            local n; n=$(ls "$archive_dir/${run_name}/tarballs/" 2>/dev/null | wc -l)
            rf_archived=$(( rf_archived + n ))
        done

        # Count from archive source_dir.txt (scratch deleted)
        for src_file in "$archive_dir"/run_*/source_dir.txt; do
            [ -f "$src_file" ] || continue
            local src; src=$(cat "$src_file")
            [[ "$src" == "$SCRATCH/${pfx}_${RF}/"* ]] || continue
            any_exists=1
            if [ ! -d "$src" ]; then
                local run_dir; run_dir=$(dirname "$src_file")
                local n; n=$(ls "${run_dir}/tarballs/" 2>/dev/null | wc -l)
                rf_archived=$(( rf_archived + n ))
            fi
        done

        total_archived=$(( total_archived + rf_archived ))
        [ "$rf_archived" -ge "$expected" ] && n_rf_done=$(( n_rf_done + 1 ))
    done

    if [ "$any_exists" -eq 0 ]; then
        printf "  %s\n" "$(dim "⏳ ${title} — not started")"
        return
    fi

    if [ "$n_rf_done" -eq 4 ]; then
        printf "  %s\n" "$(good "✅ ${title} — ${total_archived} designs")"
        return
    fi

    # Partially done: show detailed view
    hdr "[ ${title} ]"
    for RF in rf1 rf4 rf8 rf16; do
        local latest_run
        latest_run=$(ls -d "$SCRATCH/${pfx}_${RF}"/run_*/ 2>/dev/null | sort | tail -1)
        local pattern="${latest_run:-$SCRATCH/${pfx}_${RF}/run_*/}"
        check_step "${title} RF=${RF}" "$pattern" "$expected"
    done
    echo ""
}

INTERVAL=15

print_status() {
    SLURM_ACTIVE=$(squeue -u "$USER" -h 2>/dev/null | wc -l)
    clear
    echo ""
    printf '%s' "$BOLD"
    echo "=========================================================="
    echo " wa-hls4ml ASIC — Synthesis Progress"
    echo " $(date '+%Y-%m-%d %H:%M:%S')  (refreshing every ${INTERVAL}s, Ctrl+C to stop)"
    echo "=========================================================="
    printf '%s' "$RESET"
    echo ""

    # ── Static: fully complete, immutable baselines ───────────────────────────
    hdr "[ GF22FDX — complete ]"
    printf "  %s\n" "$(good "✅ 1-layer cartesian ×4 RF            1,800 designs")"
    printf "  %s\n" "$(good "✅ 2-layer LHS pass 1+2 ×4 RF         7,328 designs")"
    printf "  %s\n" "$(good "✅ 3-layer LHS pass 1+2 ×4 RF        34,474 designs")"
    echo ""

    hdr "[ Nangate 45nm — cartesian, complete ]"
    printf "  %s\n" "$(good "✅ 1-layer ×4 RF                      1,800 designs")"
    printf "  %s\n" "$(good "✅ 2-layer ×4 RF                     27,000 designs")"
    printf "  %s\n" "$(good "✅ 3-layer ×4 RF                    405,000 designs")"
    printf "  %s\n" "$(dim  "   + 1,341 legacy/fixed-weight (excluded from training)")"
    echo ""

    # ── Dynamic: LHS sweeps (auto-compact when all 4 RFs archived) ───────────
    ARCHIVE="$ARCHIVE_45NM"
    for NL in 4 5 6 8 10; do
        local nl_n=0
        for cand in "$ARCHIVE_45NM"/nangate45_lhs_${NL}layer_*.txt; do
            [ -f "$cand" ] || continue
            nl_n=$(( nl_n + $(wc -l < "$cand") ))
        done
        if [ "$nl_n" -eq 0 ]; then
            printf "  %s\n" "$(dim "⏳ 45nm ${NL}-layer LHS — not started")"
        else
            check_phase "45nm ${NL}-layer LHS" "$nl_n" "catapult_45nm_${NL}layer_lhs" "$ARCHIVE_45NM"
        fi
    done
    echo ""

    # ── Dynamic: sz128 extensions ─────────────────────────────────────────────
    local sz128_1l=0 sz128_2l=0 sz128_3l=0
    [ -f "$ARCHIVE_45NM/nangate45_1layer_sz128_cartesian.txt" ] && \
        sz128_1l=$(wc -l < "$ARCHIVE_45NM/nangate45_1layer_sz128_cartesian.txt")
    [ -f "$ARCHIVE_45NM/nangate45_2layer_sz128_cartesian.txt" ] && \
        sz128_2l=$(wc -l < "$ARCHIVE_45NM/nangate45_2layer_sz128_cartesian.txt")
    local sz128_3l_cand
    sz128_3l_cand=$(ls "$ARCHIVE_45NM"/nangate45_3layer_sz128_lhs_*.txt 2>/dev/null | head -1)
    [ -n "$sz128_3l_cand" ] && sz128_3l=$(wc -l < "$sz128_3l_cand")

    if [ "$sz128_1l" -eq 0 ]; then
        printf "  %s\n" "$(dim "⏳ 45nm 1-layer sz128 cartesian — not started")"
    else
        check_phase "45nm 1-layer sz128" "$sz128_1l" "catapult_45nm_1layer_sz128" "$ARCHIVE_45NM"
    fi
    if [ "$sz128_2l" -eq 0 ]; then
        printf "  %s\n" "$(dim "⏳ 45nm 2-layer sz128 cartesian — not started")"
    else
        check_phase "45nm 2-layer sz128" "$sz128_2l" "catapult_45nm_2layer_sz128" "$ARCHIVE_45NM"
    fi
    if [ "$sz128_3l" -eq 0 ]; then
        printf "  %s\n" "$(dim "⏳ 45nm 3-layer sz128 LHS — not started")"
    else
        check_phase "45nm 3-layer sz128 LHS" "$sz128_3l" "catapult_45nm_3layer_sz128_lhs" "$ARCHIVE_45NM"
    fi
    echo ""

    # ── Archive totals ────────────────────────────────────────────────────────
    hdr "[ Archive ] $ARCHIVE_BASE"

    local total45=0
    for d in "$ARCHIVE_45NM"/run_*/tarballs/; do
        [ -d "$d" ] || continue
        total45=$(( total45 + $(ls "$d" 2>/dev/null | wc -l) ))
    done
    local EXCL_45="run_20260504_205339_a5d590d6 run_20260505_145920_de8c3504 run_20260506_074423_a88bd7d9 run_20260507_143427_1450d680"
    local excl45=0
    for r in $EXCL_45; do
        excl45=$(( excl45 + $(ls "$ARCHIVE_45NM/$r/tarballs/" 2>/dev/null | wc -l) ))
    done
    local train45=$(( total45 - excl45 ))

    local total22=0
    for d in "$ARCHIVE_GF22NM"/run_*/tarballs/; do
        [ -d "$d" ] || continue
        total22=$(( total22 + $(ls "$d" 2>/dev/null | wc -l) ))
    done
    local EXCL_22="run_20260606_203554_855c8660 run_20260606_204655_feeb9a79 run_20260606_205745_4cd92899 run_20260606_211113_92ff518d"
    local excl22=0
    for r in $EXCL_22; do
        excl22=$(( excl22 + $(ls "$ARCHIVE_GF22NM/$r/tarballs/" 2>/dev/null | wc -l) ))
    done
    local train22=$(( total22 - excl22 ))

    local total=$(( total45 + total22 ))
    local training=$(( train45 + train22 ))

    printf "  Nangate 45nm:  %s total  /  %s training-eligible  %s\n" \
        "${CYAN}${total45}${RESET}" "${GREEN}${train45}${RESET}" \
        "$(dim "(excl. ${excl45} fixed-weights/partial)")"
    printf "  GF22FDX:       %s total  /  %s training-eligible  %s\n" \
        "${CYAN}${total22}${RESET}" "${GREEN}${train22}${RESET}" \
        "$(dim "(excl. ${excl22} ghost runs)")"
    printf "  Combined:      %s total  /  %s training-eligible\n" \
        "${CYAN}${total}${RESET}" "${BOLD}${GREEN}${training}${RESET}"
    echo ""
}

while true; do
    print_status
    sleep "$INTERVAL"
done
