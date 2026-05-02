#!/usr/bin/env bash
# setup_tunnels.sh — Forward Catapult licenses from correlator4 to Perlmutter
#
# Simplified approach: correlator4 already has ports 1717 and 40003 forwarded
# from fasic-admin1 (the user's normal license SSH). This script just bridges
# Perlmutter → correlator4:1717/40003 in a tmux session.
#
# Prerequisites (run before this script):
#   1. On Perlmutter: KRB5_CONFIG=~/krb5.conf kinit ${FNAL_USER}@FNAL.GOV
#   2. On correlator4: ensure license forward is running:
#        ssh -N -g -L 1717:fasic-admin1.fnal.gov:1717 \
#                  -L 40003:fasic-admin1.fnal.gov:40003 \
#                  adas1@fasic-admin1.fnal.gov &
#      (this is normally already running when doing synthesis on correlator4)
#
# Usage (on Perlmutter):
#   KRB5_CONFIG=~/krb5.conf bash Perlmutter_scripts/setup_tunnels.sh
#
# Reconnect after laptop close:
#   ssh ${NERSC_USER}@<same-login-node>.perlmutter.nersc.gov
#   tmux attach -t catapult_tunnels

set -euo pipefail

SCRIPT_DIR="$(cd "$(dirname "${BASH_SOURCE[0]}")" && pwd)"
ENV_FILE="${SCRIPT_DIR}/.env"

if [[ -f "${ENV_FILE}" ]]; then
    set -o allexport
    source "${ENV_FILE}"
    set +o allexport
fi

if [[ -z "${FNAL_USER:-}" ]]; then
    read -rp "FNAL username (correlator4): " FNAL_USER
fi
if [[ -z "${NERSC_USER:-}" ]]; then
    read -rp "NERSC username (perlmutter): " NERSC_USER
fi

export KRB5_CONFIG="${KRB5_CONFIG:-${HOME}/krb5.conf}"
LICENSE_PORT=1717
CATAPULT_PORT=40003
CORRELATOR4=correlator4.fnal.gov

echo "=== Catapult License Tunnel Setup ==="
echo "FNAL user:    ${FNAL_USER}"
echo "Correlator4:  ${CORRELATOR4}"
echo "Forwarding:   ${LICENSE_PORT} + ${CATAPULT_PORT} via correlator4"
echo ""

# ---------------------------------------------------------------------------
# Verify we are on Perlmutter
# ---------------------------------------------------------------------------
if ! hostname -f | grep -q "perlmutter"; then
    echo "WARNING: this script should be run on a Perlmutter login node."
    echo "Current host: $(hostname -f)"
    read -rp "Continue anyway? [y/N] " confirm
    [[ "${confirm}" =~ ^[Yy]$ ]] || exit 1
fi

# ---------------------------------------------------------------------------
# Verify correlator4 has the license ports forwarded (prerequisite check)
# ---------------------------------------------------------------------------
echo "--- Checking correlator4 has license ports forwarded ---"
_SSH_OPTS="-o GSSAPIAuthentication=yes -o GSSAPIDelegateCredentials=yes \
           -o PreferredAuthentications=gssapi-with-mic \
           -o StrictHostKeyChecking=no -o BatchMode=yes -o ConnectTimeout=15"

MISSING_PORTS=""
for PORT in ${LICENSE_PORT} ${CATAPULT_PORT}; do
    if ! ssh ${_SSH_OPTS} "${FNAL_USER}@${CORRELATOR4}" \
             "ss -ltn | grep -q ':${PORT}'" 2>/dev/null; then
        MISSING_PORTS="${MISSING_PORTS} ${PORT}"
    fi
done

if [[ -n "${MISSING_PORTS}" ]]; then
    echo "ERROR: correlator4 is missing license ports:${MISSING_PORTS}"
    echo ""
    echo "Start the license forward on correlator4 first:"
    echo "  ssh ${FNAL_USER}@${CORRELATOR4}"
    echo "  ssh -fN -g -L 1717:fasic-admin1.fnal.gov:1717 \\"
    echo "            -L 40003:fasic-admin1.fnal.gov:40003 \\"
    echo "            ${FNAL_USER}@fasic-admin1.fnal.gov"
    exit 1
fi
echo "correlator4 has ports ${LICENSE_PORT} and ${CATAPULT_PORT} forwarded."

# ---------------------------------------------------------------------------
# Capture KRB5 ccache so tmux window inherits it
# ---------------------------------------------------------------------------
_KRB5CCNAME=$(KRB5_CONFIG="${HOME}/krb5.conf" klist 2>/dev/null | awk '/Ticket cache:/{print $3}')
export KRB5CCNAME="${_KRB5CCNAME}"

# Strip CVMFS apptainer paths from LD_LIBRARY_PATH (conflicts with libkrb5support.so)
_CLEAN_LD="export LD_LIBRARY_PATH=\$(echo \"\$LD_LIBRARY_PATH\" | tr ':' '\n' | grep -v cvmfs | tr '\n' ':' | sed 's/:\$//'); "

# ---------------------------------------------------------------------------
# Start tmux tunnel: Perlmutter → correlator4:1717/40003
# ---------------------------------------------------------------------------
echo ""
echo "--- Starting license tunnel in tmux ---"

TUNNEL_CMD="${_CLEAN_LD}export KRB5_CONFIG=${HOME}/krb5.conf; export KRB5CCNAME=${_KRB5CCNAME}; \
while true; do \
  ssh -N \
    -o ServerAliveInterval=60 \
    -o ServerAliveCountMax=5 \
    -o ExitOnForwardFailure=yes \
    -o GSSAPIAuthentication=yes \
    -o GSSAPIDelegateCredentials=yes \
    -o PreferredAuthentications=gssapi-with-mic \
    -o StrictHostKeyChecking=no \
    -o UserKnownHostsFile=/dev/null \
    -L ${LICENSE_PORT}:127.0.0.1:${LICENSE_PORT} \
    -L ${CATAPULT_PORT}:127.0.0.1:${CATAPULT_PORT} \
    ${FNAL_USER}@${CORRELATOR4}; \
  echo 'Tunnel dropped, reconnecting in 5s...'; sleep 5; \
done"

tmux kill-session -t catapult_tunnels 2>/dev/null || true
tmux new-session -d -s catapult_tunnels -n licenses "${TUNNEL_CMD}"

echo "Waiting 6s for tunnel to establish..."
sleep 6

# ---------------------------------------------------------------------------
# Verify
# ---------------------------------------------------------------------------
OK=1
for PORT in ${LICENSE_PORT} ${CATAPULT_PORT}; do
    if ss -ltnp | grep -q ":${PORT}"; then
        echo "Port ${PORT} is forwarded."
    else
        echo "WARNING: port ${PORT} not detected."
        OK=0
    fi
done

if (( OK == 1 )); then
    echo ""
    echo "=== All tunnels up ==="
    echo "License ports ${LICENSE_PORT} and ${CATAPULT_PORT} available at localhost."
    echo ""
    echo "Next steps:"
    echo "  1. Detach tmux:  Ctrl+B D"
    echo "  2. Run synthesis: python iter_manager_catapult.py ... --license_config license_servers_perlmutter.json"
    echo ""
    echo "To reconnect later:"
    echo "  ssh ${NERSC_USER}@$(hostname).perlmutter.nersc.gov"
    echo "  tmux attach -t catapult_tunnels"
else
    echo ""
    echo "Tunnel did not come up. Check tmux:"
    echo "  tmux attach -t catapult_tunnels"
fi
