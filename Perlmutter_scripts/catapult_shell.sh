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
#   --sif <path>        Path to catapult_rocky.sif (default: ~/work/tool-containers/catapult_rocky.sif)
#   --work-dir <path>   Working directory mounted into container (required)
#   --cmd <tcl>         TCL command to run (default: puts [pwd]; exit)
#   --env-setup <mode>  Which env script to source: siemens (default) or genesis
#                       Override via env var ENV_SETUP=...
#   --dry-run           Print apptainer command without running it
#   -h, --help          Show help

set -euo pipefail

SCRIPT_DIR="$(cd "$(dirname "${BASH_SOURCE[0]}")" && pwd)"
ENV_FILE="${SCRIPT_DIR}/.env"

if [[ -f "${ENV_FILE}" ]]; then
    set -o allexport
    source "${ENV_FILE}"
    set +o allexport
fi

# Catapult version. Override with
# CATAPULT_VER=... before invoking this script.
export CATAPULT_VER="${CATAPULT_VER:-2026.1_1}"

# Path to the Catapult install. siemens.sh defaults to a locked-down
# /pscratch/sd/g/gdg/... path which is unreadable to non-`gdg` users; we
# override to a per-user copy under $SCRATCH (each user must rsync their own
# copy first — see QUICKSTART.md). Override with CATAPULT_PATH_OVERRIDE=...
# if your install lives somewhere else.
export CATAPULT_PATH_OVERRIDE="${CATAPULT_PATH_OVERRIDE:-${SCRATCH:-/pscratch/sd/${USER:0:1}/${USER}}/cad/Siemens/Catapult/${CATAPULT_VER}}"

# --env-setup picks which env script to source inside the container:
#   siemens (default, current behavior): ${HOME}/bin/siemens.sh
#   genesis (project tool-containers):   ${TOOL_CONTAINERS}/envsetup.sh
ENV_SETUP_MODE="${ENV_SETUP:-siemens}"

SIF="${HOME}/work/tool-containers/catapult_rocky.sif"
WORK_DIR=""
CATAPULT_CMD='puts [pwd]; exit'
DRY_RUN=0

usage() {
    cat <<'USAGE'
Usage:
  bash Perlmutter_scripts/catapult_shell.sh [options]

Options:
  --sif <path>        Path to catapult_rocky.sif
                      (default: ~/work/tool-containers/catapult_rocky.sif)
  --work-dir <path>   Working directory passed into container
  --cmd <tcl>         TCL command (default: puts [pwd]; exit)
  --env-setup <mode>  Which env to source: siemens (default) or genesis
  --dry-run           Print apptainer command only, do not run
  -h, --help          Show this help

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
        --sif)        SIF="$2"; shift 2 ;;
        --work-dir)   WORK_DIR="$2"; shift 2 ;;
        --cmd)        CATAPULT_CMD="$2"; shift 2 ;;
        --env-setup)  ENV_SETUP_MODE="$2"; shift 2 ;;
        --dry-run)    DRY_RUN=1; shift ;;
        -h|--help)    usage; exit 0 ;;
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

case "${ENV_SETUP_MODE}" in
    siemens)
        ENV_SCRIPT="${HOME}/bin/siemens.sh"
        ;;
    genesis)
        ENV_SCRIPT="${TOOL_CONTAINERS:-/global/homes/g/gdg/research/projects/genesis/tool-containers}/envsetup.sh"
        ;;
    *)
        echo "ERROR: --env-setup must be 'siemens' or 'genesis', got '${ENV_SETUP_MODE}'" >&2
        exit 1
        ;;
esac
[[ -f "${ENV_SCRIPT}" ]] || {
    echo "ERROR: env script not found: ${ENV_SCRIPT}" >&2
    if [[ "${ENV_SETUP_MODE}" == "siemens" ]]; then
        echo "Copy it from correlator4: scp \${FNAL_USER}@correlator4.fnal.gov:~/bin/siemens.sh ~/bin/" >&2
    else
        echo "Set TOOL_CONTAINERS to a directory containing envsetup.sh, or switch to --env-setup siemens" >&2
    fi
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
    --bind /etc/resolv.conf:/etc/resolv.conf:ro
    --bind /etc/hosts:/etc/hosts:ro
)

if [[ -n "${LM_LICENSE_FILE:-}" ]]; then
    # Pass via *_OVERRIDE env vars so we can re-export AFTER siemens.sh —
    # siemens.sh prepends "40003@localhost:" to LM_LICENSE_FILE and sets
    # SALT_LICENSE_SERVER=40003@localhost. Both target a non-existent local
    # daemon (was a tunnel in the old setup), causing mgls_errno=515.
    # Derive SALT_LICENSE_SERVER from the same host as LM_LICENSE_FILE.
    _LF_HOST="${LM_LICENSE_FILE#*@}"
    _LF_HOST="${_LF_HOST%%:*}"
    cmd+=(--env "LM_LICENSE_FILE=${LM_LICENSE_FILE}")
    cmd+=(--env "LM_LICENSE_FILE_OVERRIDE=${LM_LICENSE_FILE}")
    cmd+=(--env "SALT_LICENSE_SERVER_OVERRIDE=40003@${_LF_HOST}")
fi

# Propagate CATAPULT_VER + TOOL_CONTAINERS + CATAPULT_PATH_OVERRIDE into the
# container so we can re-derive the install paths after siemens.sh runs.
cmd+=(--env "CATAPULT_VER=${CATAPULT_VER}")
cmd+=(--env "CATAPULT_PATH_OVERRIDE=${CATAPULT_PATH_OVERRIDE}")
if [[ -n "${TOOL_CONTAINERS:-}" ]]; then
    cmd+=(--env "TOOL_CONTAINERS=${TOOL_CONTAINERS}")
fi

# After sourcing siemens.sh, re-export CATAPULT_PATH and derived vars so we
# point at our local 2026.1_1 copy (siemens.sh hardcodes a locked path).
# Also re-export LM_LICENSE_FILE / SALT_LICENSE_SERVER (siemens.sh prepends bad
# 40003@localhost values that prevent license checkout).
cmd+=(
    "${SIF}"
    /bin/bash -c "source ${ENV_SCRIPT} && \
        export CATAPULT_PATH=\"\${CATAPULT_PATH_OVERRIDE:-\${CATAPULT_PATH}}\" && \
        export MGC_HOME=\"\${CATAPULT_PATH}/Mgc_home\" && \
        export CATAPULT_HOME=\"\${MGC_HOME}\" && \
        export LD_LIBRARY_PATH=\"\${CATAPULT_PATH}/Mgc_home/lib:\${CATAPULT_PATH}/Mgc_home/shared/lib:\${LD_LIBRARY_PATH}\" && \
        export PATH=\"\${CATAPULT_PATH}/Mgc_home/bin:\${PATH}\" && \
        export LM_LICENSE_FILE=\"\${LM_LICENSE_FILE_OVERRIDE:-\${LM_LICENSE_FILE}}\" && \
        export SALT_LICENSE_SERVER=\"\${SALT_LICENSE_SERVER_OVERRIDE:-\${SALT_LICENSE_SERVER}}\" && \
        catapult -product genesis -shell ${CATAPULT_OPTS}"
)

if (( DRY_RUN == 1 )); then
    printf 'DRY_RUN: '; printf '%q ' "${cmd[@]}"; echo
    exit 0
fi

sg amsc011 -c "LD_LIBRARY_PATH=$(printf '%q' "${LD_LIBRARY_PATH:-}") $(printf '%q ' "${cmd[@]}")"
