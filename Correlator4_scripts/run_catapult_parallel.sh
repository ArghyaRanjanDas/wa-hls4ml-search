#!/usr/bin/env bash
set -euo pipefail

SCRIPT_DIR="$(cd "$(dirname "${BASH_SOURCE[0]}")" && pwd)"
REPO_DIR="$(cd "${SCRIPT_DIR}/.." && pwd)"

VENV_PATH="${REPO_DIR}/.venv"
INPUT_GLOB=""
OUTPUT_ROOT=""
HLSPROJ_ROOT=""
JOBS=5
MAX_BATCHES=0

RF_LOWER=82
RF_UPPER=83
RF_STEP=1
HLS4ML_STRAT="latency"
PART="xcu250-figd2104-2L-e"
REPORT_BACKEND="catapult"
CATAPULT_CMD=""
CATAPULT_REPORT_JSON=""
CONV_MODE=0
VSYNTH_MODE=0
DRY_RUN=0

usage() {
  cat <<'USAGE'
Usage:
  ./Correlator4_scripts/run_catapult_parallel.sh --input-glob <glob> --output-root <dir> --hlsproj-root <dir> [options]

Required:
  --input-glob <glob>            Glob for batch JSON files
  --output-root <dir>            Root output directory
  --hlsproj-root <dir>           Root hlsproj directory

Options:
  --venv <path>                  Python venv path (default: <repo>/.venv)
  --jobs <int>                   GNU parallel concurrency (default: 5)
  --max-batches <int>            Run first N matched batches (0 = all)
  --rf-lower <int>               RF lower (default: 82)
  --rf-upper <int>               RF upper exclusive (default: 83)
  --rf-step <int>                RF step (default: 1)
  --hls4ml-strat <str>           hls4ml strategy (default: latency)
  --part <str>                   Target part (default: xcu250-figd2104-2L-e)
  --report-backend <str>         vivado | catapult (default: catapult)
  --catapult-cmd <str>           Optional catapult command template
  --catapult-report-json <path>  Optional catapult report JSON path
  --conv                         Pass -c to iter_manager_v2.py
  --vsynth                       Pass -v to iter_manager_v2.py
  --dry-run                      Print planned jobs only
  -h, --help                     Show help
USAGE
}

while [[ $# -gt 0 ]]; do
  case "$1" in
    --input-glob) INPUT_GLOB="$2"; shift 2 ;;
    --output-root) OUTPUT_ROOT="$2"; shift 2 ;;
    --hlsproj-root) HLSPROJ_ROOT="$2"; shift 2 ;;
    --venv) VENV_PATH="$2"; shift 2 ;;
    --jobs) JOBS="$2"; shift 2 ;;
    --max-batches) MAX_BATCHES="$2"; shift 2 ;;
    --rf-lower) RF_LOWER="$2"; shift 2 ;;
    --rf-upper) RF_UPPER="$2"; shift 2 ;;
    --rf-step) RF_STEP="$2"; shift 2 ;;
    --hls4ml-strat) HLS4ML_STRAT="$2"; shift 2 ;;
    --part) PART="$2"; shift 2 ;;
    --report-backend) REPORT_BACKEND="$2"; shift 2 ;;
    --catapult-cmd) CATAPULT_CMD="$2"; shift 2 ;;
    --catapult-report-json) CATAPULT_REPORT_JSON="$2"; shift 2 ;;
    --conv) CONV_MODE=1; shift ;;
    --vsynth) VSYNTH_MODE=1; shift ;;
    --dry-run) DRY_RUN=1; shift ;;
    -h|--help) usage; exit 0 ;;
    *) echo "ERROR: unknown argument: $1" >&2; usage; exit 1 ;;
  esac
done

[[ -n "${INPUT_GLOB}" ]] || { echo "ERROR: --input-glob is required" >&2; exit 1; }
[[ -n "${OUTPUT_ROOT}" ]] || { echo "ERROR: --output-root is required" >&2; exit 1; }
[[ -n "${HLSPROJ_ROOT}" ]] || { echo "ERROR: --hlsproj-root is required" >&2; exit 1; }
[[ -f "${VENV_PATH}/bin/activate" ]] || { echo "ERROR: venv not found: ${VENV_PATH}" >&2; exit 1; }
command -v parallel >/dev/null 2>&1 || { echo "ERROR: GNU parallel not found in PATH" >&2; exit 1; }
[[ "${JOBS}" =~ ^[0-9]+$ ]] || { echo "ERROR: --jobs must be integer" >&2; exit 1; }
[[ "${MAX_BATCHES}" =~ ^[0-9]+$ ]] || { echo "ERROR: --max-batches must be integer" >&2; exit 1; }
[[ "${RF_LOWER}" =~ ^[0-9]+$ ]] || { echo "ERROR: --rf-lower must be integer" >&2; exit 1; }
[[ "${RF_UPPER}" =~ ^[0-9]+$ ]] || { echo "ERROR: --rf-upper must be integer" >&2; exit 1; }
[[ "${RF_STEP}" =~ ^[0-9]+$ ]] || { echo "ERROR: --rf-step must be integer" >&2; exit 1; }
(( JOBS > 0 )) || { echo "ERROR: --jobs must be > 0" >&2; exit 1; }
(( RF_STEP > 0 )) || { echo "ERROR: --rf-step must be > 0" >&2; exit 1; }
(( RF_UPPER > RF_LOWER )) || { echo "ERROR: --rf-upper must be > --rf-lower" >&2; exit 1; }

mapfile -t _matches < <(compgen -G "${INPUT_GLOB}" || true)
(( ${#_matches[@]} > 0 )) || { echo "ERROR: no files matched: ${INPUT_GLOB}" >&2; exit 1; }
mapfile -t BATCH_FILES < <(printf '%s\n' "${_matches[@]}" | sort)

if (( MAX_BATCHES > 0 && ${#BATCH_FILES[@]} > MAX_BATCHES )); then
  BATCH_FILES=("${BATCH_FILES[@]:0:MAX_BATCHES}")
fi

mkdir -p "${OUTPUT_ROOT}" "${HLSPROJ_ROOT}"
JOBLOG="${OUTPUT_ROOT}/parallel_joblog_$(date +%Y%m%d_%H%M%S).tsv"

run_one_batch() {
  local input_json="$1"
  local batch_name
  batch_name="$(basename "${input_json}" .json)"
  local out_dir="${OUTPUT_ROOT}/${batch_name}"
  local hls_dir="${HLSPROJ_ROOT}/${batch_name}"
  mkdir -p "${out_dir}" "${hls_dir}"

  source "${VENV_PATH}/bin/activate"
  cd "${REPO_DIR}"

  local cmd=(
    python iter_manager_v2.py
    -f "${input_json}"
    -o "${out_dir}"
    --hlsproj "${hls_dir}"
    --part "${PART}"
    --hls4ml_strat "${HLS4ML_STRAT}"
    --rf_lower "${RF_LOWER}"
    --rf_upper "${RF_UPPER}"
    --rf_step "${RF_STEP}"
    --report_backend "${REPORT_BACKEND}"
  )
  if [[ -n "${CATAPULT_CMD}" ]]; then
    cmd+=(--catapult_cmd "${CATAPULT_CMD}")
  fi
  if [[ -n "${CATAPULT_REPORT_JSON}" ]]; then
    cmd+=(--catapult_report_json "${CATAPULT_REPORT_JSON}")
  fi
  if (( CONV_MODE == 1 )); then
    cmd+=(-c)
  fi
  if (( VSYNTH_MODE == 1 )); then
    cmd+=(-v)
  fi

  echo "START batch=${batch_name} pid=$$ time=$(date +%T)"
  "${cmd[@]}"
  echo "DONE  batch=${batch_name} pid=$$ time=$(date +%T)"
}

export -f run_one_batch
export REPO_DIR VENV_PATH OUTPUT_ROOT HLSPROJ_ROOT
export RF_LOWER RF_UPPER RF_STEP HLS4ML_STRAT PART REPORT_BACKEND
export CATAPULT_CMD CATAPULT_REPORT_JSON CONV_MODE VSYNTH_MODE

echo "Batches: ${#BATCH_FILES[@]}  parallel jobs: ${JOBS}"
echo "Job log: ${JOBLOG}"

if (( DRY_RUN == 1 )); then
  printf '%s\n' "${BATCH_FILES[@]:0:5}"
  exit 0
fi

printf '%s\n' "${BATCH_FILES[@]}" | \
  parallel --line-buffer --halt soon,fail=1 --joblog "${JOBLOG}" -j "${JOBS}" run_one_batch {}

echo "All parallel jobs completed."

