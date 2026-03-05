#!/usr/bin/env bash
set -euo pipefail

SCRIPT_DIR="$(cd "$(dirname "${BASH_SOURCE[0]}")" && pwd)"
REPO_DIR="$(cd "${SCRIPT_DIR}/.." && pwd)"

TOOL_CONTAINERS_DIR="${HOME}/work/tool-containers"
TOOL_CONTAINERS_MAKEFILE="Makefile.rocky.apptainer"
WORK_DIR="${REPO_DIR}"
CATAPULT_CMD='puts [pwd]; exit'
CATAPULT_SCRIPT=""
DRY_RUN=0

usage() {
  cat <<'USAGE'
Usage:
  ./scripts/catapult_shell.sh [options]

Options:
  --tool-containers-dir <path>   Directory with Makefile.rocky.apptainer
  --makefile <file>              Makefile name (default: Makefile.rocky.apptainer)
  --work-dir <path>              WORK_DIR passed into make catapult-shell
  --cmd <tcl>                    CATAPULT_CMD (default: puts [pwd]; exit)
  --script <path>                CATAPULT_SCRIPT path
  --dry-run                      Print command only
  -h, --help                     Show help

Examples:
  ./scripts/catapult_shell.sh
  ./scripts/catapult_shell.sh --cmd 'puts [pwd]; puts [exec ls]; exit'
USAGE
}

while [[ $# -gt 0 ]]; do
  case "$1" in
    --tool-containers-dir) TOOL_CONTAINERS_DIR="$2"; shift 2 ;;
    --makefile) TOOL_CONTAINERS_MAKEFILE="$2"; shift 2 ;;
    --work-dir) WORK_DIR="$2"; shift 2 ;;
    --cmd) CATAPULT_CMD="$2"; shift 2 ;;
    --script) CATAPULT_SCRIPT="$2"; shift 2 ;;
    --dry-run) DRY_RUN=1; shift ;;
    -h|--help) usage; exit 0 ;;
    *) echo "ERROR: unknown argument: $1" >&2; usage; exit 1 ;;
  esac
done

[[ -d "${TOOL_CONTAINERS_DIR}" ]] || { echo "ERROR: tool containers dir not found: ${TOOL_CONTAINERS_DIR}" >&2; exit 1; }
[[ -f "${TOOL_CONTAINERS_DIR}/${TOOL_CONTAINERS_MAKEFILE}" ]] || {
  echo "ERROR: makefile not found: ${TOOL_CONTAINERS_DIR}/${TOOL_CONTAINERS_MAKEFILE}" >&2
  exit 1
}
[[ -d "${WORK_DIR}" ]] || { echo "ERROR: work dir not found: ${WORK_DIR}" >&2; exit 1; }
if [[ -n "${CATAPULT_SCRIPT}" ]]; then
  [[ -f "${CATAPULT_SCRIPT}" ]] || { echo "ERROR: script not found: ${CATAPULT_SCRIPT}" >&2; exit 1; }
fi

cmd=(make
  -C "${TOOL_CONTAINERS_DIR}"
  -f "${TOOL_CONTAINERS_MAKEFILE}"
  catapult-shell
  "WORK_DIR=${WORK_DIR}"
  "CATAPULT_CMD=${CATAPULT_CMD}"
)
if [[ -n "${CATAPULT_SCRIPT}" ]]; then
  cmd+=("CATAPULT_SCRIPT=${CATAPULT_SCRIPT}")
fi
if [[ -n "${LM_LICENSE_FILE:-}" ]]; then
  cmd+=("LM_LICENSE_FILE=${LM_LICENSE_FILE}")
fi

if (( DRY_RUN == 1 )); then
  printf 'DRY_RUN: '; printf '%q ' "${cmd[@]}"; echo
  exit 0
fi

"${cmd[@]}"
