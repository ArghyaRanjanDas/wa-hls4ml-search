#!/usr/bin/env bash
# catapult_shell.sh — Launch Catapult inside Apptainer on Perlmutter
#
# Perlmutter equivalent of Correlator4_scripts/catapult_shell.sh.
# Calls apptainer exec directly (no tool-containers Makefile needed).
#
# Usage:
#   bash Perlmutter_scripts/catapult_shell.sh \
#     --work-dir /path/to/build/dir \
#     --cmd 'puts [pwd]; exit'
#
# Options:
#   --sif <path>       Path to catapult_rocky.sif (default: ~/work/catapult_rocky.sif)
#   --work-dir <path>  Working directory mounted into container (required)
#   --cmd <tcl>        TCL command to run (default: puts [pwd]; exit)
#   --dry-run          Print apptainer command without running it
#   -h, --help         Show help

set -euo pipefail

SCRIPT_DIR="$(cd "$(dirname "${BASH_SOURCE[0]}")" && pwd)"
ENV_FILE="${SCRIPT_DIR}/.env"

if [[ -f "${ENV_FILE}" ]]; then
    set -o allexport
    source "${ENV_FILE}"
    set +o allexport
fi

SIF="${HOME}/work/tool-containers/catapult_rocky.sif"
WORK_DIR=""
CATAPULT_CMD='puts [pwd]; exit'
DRY_RUN=0

usage() {
    cat <<'USAGE'
Usage:
  bash Perlmutter_scripts/catapult_shell.sh [options]

Options:
  --sif <path>       Path to catapult_rocky.sif
                     (default: ~/work/catapult_rocky.sif)
  --work-dir <path>  Working directory passed into container
  --cmd <tcl>        TCL command (default: puts [pwd]; exit)
  --dry-run          Print apptainer command only, do not run
  -h, --help         Show this help

Examples:
  # Dry-run to verify setup:
  bash Perlmutter_scripts/catapult_shell.sh \
    --dry-run --work-dir "$(pwd)" --cmd 'puts [pwd]; exit'

  # Real probe (verifies license checkout):
  bash Perlmutter_scripts/catapult_shell.sh \
    --work-dir "$(pwd)" --cmd 'puts [pwd]; exit'
USAGE
}

while [[ $# -gt 0 ]]; do
    case "$1" in
        --sif)       SIF="$2"; shift 2 ;;
        --work-dir)  WORK_DIR="$2"; shift 2 ;;
        --cmd)       CATAPULT_CMD="$2"; shift 2 ;;
        --dry-run)   DRY_RUN=1; shift ;;
        -h|--help)   usage; exit 0 ;;
        *) echo "ERROR: unknown argument: $1" >&2; usage; exit 1 ;;
    esac
done

# Resolve apptainer: check PATH first, then CVMFS (Perlmutter), then module
_APPTAINER_BIN=""
if command -v apptainer &>/dev/null; then
    _APPTAINER_BIN="$(command -v apptainer)"
elif [[ -x "/cvmfs/oasis.opensciencegrid.org/mis/apptainer/current/bin/apptainer" ]]; then
    _APPTAINER_BIN="/cvmfs/oasis.opensciencegrid.org/mis/apptainer/current/bin/apptainer"
elif command -v module &>/dev/null; then
    module load apptainer 2>/dev/null || true
    command -v apptainer &>/dev/null && _APPTAINER_BIN="$(command -v apptainer)"
fi
[[ -n "${_APPTAINER_BIN}" ]] || { echo "ERROR: apptainer not found (tried PATH, CVMFS, module)." >&2; exit 1; }

[[ -f "${SIF}" ]] || { echo "ERROR: SIF not found: ${SIF}" >&2; exit 1; }
[[ -n "${WORK_DIR}" ]] || { echo "ERROR: --work-dir is required" >&2; usage; exit 1; }
[[ -d "${WORK_DIR}" ]] || { echo "ERROR: work dir not found: ${WORK_DIR}" >&2; exit 1; }

SIEMENS_ENV="${HOME}/bin/siemens.sh"
[[ -f "${SIEMENS_ENV}" ]] || {
    echo "ERROR: siemens.sh not found at ${SIEMENS_ENV}" >&2
    echo "Copy it from correlator4: scp adas1@correlator4.fnal.gov:~/bin/siemens.sh ~/bin/" >&2
    exit 1
}

CATAPULT_OPTS=""
if [[ -n "${CATAPULT_CMD}" ]]; then
    CATAPULT_OPTS="-eval '${CATAPULT_CMD}'"
fi

# On Perlmutter, $HOME (/global/homes/a/...) is a symlink to the real path
# (/global/u2/a/...). Bind both so TCL dofile paths resolve inside the container.
_HOME_REAL="$(readlink -f "${HOME}")"

cmd=(
    "${_APPTAINER_BIN}" exec
    --contain
    --no-mount hostfs
    --pwd "${WORK_DIR}"
    --bind "${HOME}"
    --bind "${_HOME_REAL}"
    --bind /tmp
    --bind "${WORK_DIR}"
    --bind /pscratch:/pscratch
    --bind /etc/group:/etc/group:ro
)

if [[ -n "${LM_LICENSE_FILE:-}" ]]; then
    cmd+=(--env "LM_LICENSE_FILE=${LM_LICENSE_FILE}")
fi

cmd+=(
    "${SIF}"
    /bin/bash -c "source ${SIEMENS_ENV} && catapult -shell ${CATAPULT_OPTS}"
)

if (( DRY_RUN == 1 )); then
    printf 'DRY_RUN: '; printf '%q ' "${cmd[@]}"; echo
    exit 0
fi

sg amsc011 -c "LD_LIBRARY_PATH=$(printf '%q' "${LD_LIBRARY_PATH:-}") $(printf '%q ' "${cmd[@]}")"
