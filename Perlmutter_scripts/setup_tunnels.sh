#!/usr/bin/env bash
# setup_tunnels.sh — Forward Catapult licenses from correlator4 to Perlmutter
#
# Auto-detects which license server is reachable on correlator4 and sets up
# the appropriate tunnel. Writes license_servers_active.json with actual license
# count so iter_manager can use the right parallelism.
#
# Supported license servers (tried in order of preference):
#
#   fasic-135413.fnal.gov  (5 licenses) — reverse tunnel via port 2210
#     Prerequisites (one-time, NOT this script):
#       1. On fasic-135413: ssh -fNT -R 127.0.0.1:2210:localhost:22 ${FNAL_USER}@correlator4.fnal.gov
#       2. Perlmutter SSH public key in fasic-135413:~/.ssh/authorized_keys
#
#   fasic-admin1.fnal.gov  (1 license) — direct port forward on correlator4
#     Prerequisites (one-time, NOT this script):
#       On correlator4: ssh -fN -g -L 1717:fasic-admin1.fnal.gov:1717 \
#                                  -L 40003:fasic-admin1.fnal.gov:40003 \
#                                  ${FNAL_USER}@fasic-admin1.fnal.gov
#
# Usage (on Perlmutter):
#   KRB5_CONFIG=~/krb5.conf bash Perlmutter_scripts/setup_tunnels.sh
#
# Output:
#   Perlmutter_scripts/license_servers_active.json  (pass to --license_config)
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
REVERSE_PORT=2210
CORRELATOR4=correlator4.fnal.gov

echo "=== Catapult License Tunnel Setup ==="
echo "FNAL user:   ${FNAL_USER}"
echo "Correlator4: ${CORRELATOR4}"
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
# Capture KRB5 ccache FIRST — before any SSH calls.
# On Perlmutter, systemd sets the default ccache to DIR:/run/user/.../krb5cc
# (empty). SSH/GSSAPI falls back to "no credentials" unless we explicitly
# prefix KRB5CCNAME on every ssh invocation.
# ---------------------------------------------------------------------------
_KRB5CCNAME=$(KRB5_CONFIG="${HOME}/krb5.conf" klist 2>/dev/null | awk '/Ticket cache:/{print $3}')
export KRB5CCNAME="${_KRB5CCNAME}"

_SSH_OPTS="-o GSSAPIAuthentication=yes -o GSSAPIDelegateCredentials=yes \
           -o PreferredAuthentications=gssapi-with-mic \
           -o StrictHostKeyChecking=no -o BatchMode=yes -o ConnectTimeout=15"

# ---------------------------------------------------------------------------
# Auto-detect which license server is available on correlator4
# ---------------------------------------------------------------------------
echo "--- Detecting license server on correlator4 ---"

SELECTED_SERVER=""
SELECTED_LICENSES=0

# Prefer fasic-135413 (5 licenses): detected by port 2210 on correlator4
if KRB5CCNAME="${_KRB5CCNAME}" ssh ${_SSH_OPTS} "${FNAL_USER}@${CORRELATOR4}" \
       "ss -ltn | grep -q ':${REVERSE_PORT}'" 2>/dev/null; then
    SELECTED_SERVER="fasic-135413"
    SELECTED_LICENSES=5
    echo "Detected fasic-135413 reverse tunnel (port ${REVERSE_PORT}) — 5 licenses"

# Fallback: fasic-admin1 (1 license): detected by port 1717 on correlator4
elif KRB5CCNAME="${_KRB5CCNAME}" ssh ${_SSH_OPTS} "${FNAL_USER}@${CORRELATOR4}" \
       "ss -ltn | grep -q ':${LICENSE_PORT}'" 2>/dev/null; then
    SELECTED_SERVER="fasic-admin1"
    SELECTED_LICENSES=1
    echo "Detected fasic-admin1 direct forward (port ${LICENSE_PORT}) — 1 license"

else
    echo "ERROR: no license server reachable on correlator4."
    echo ""
    echo "To use fasic-135413 (5 licenses) — run this ON fasic-135413:"
    echo "  ssh -fNT -R 127.0.0.1:${REVERSE_PORT}:localhost:22 ${FNAL_USER}@${CORRELATOR4}"
    echo ""
    echo "To use fasic-admin1 (1 license) — run this ON correlator4:"
    echo "  ssh -fN -g -L ${LICENSE_PORT}:fasic-admin1.fnal.gov:${LICENSE_PORT} \\"
    echo "            -L ${CATAPULT_PORT}:fasic-admin1.fnal.gov:${CATAPULT_PORT} \\"
    echo "            ${FNAL_USER}@fasic-admin1.fnal.gov"
    exit 1
fi

# ---------------------------------------------------------------------------
# Build tmux tunnel commands based on selected server
# ---------------------------------------------------------------------------

# Strip CVMFS apptainer paths from LD_LIBRARY_PATH (conflicts with libkrb5support.so)
_CLEAN_LD="export LD_LIBRARY_PATH=\$(echo \"\$LD_LIBRARY_PATH\" | tr ':' '\n' | grep -v cvmfs | tr '\n' ':' | sed 's/:\$//'); "

_SSH_COMMON_OPTS="-o ServerAliveInterval=60 -o ServerAliveCountMax=5 \
  -o ExitOnForwardFailure=yes -o StrictHostKeyChecking=no -o UserKnownHostsFile=/dev/null"

echo ""
echo "--- Starting license tunnel(s) in tmux session 'catapult_tunnels' ---"
tmux kill-session -t catapult_tunnels 2>/dev/null || true

if [[ "${SELECTED_SERVER}" == "fasic-135413" ]]; then
    # Step 2: Forward port 2210 from Perlmutter to correlator4 (GSSAPI auth)
    TUNNEL_STEP2="${_CLEAN_LD}export KRB5_CONFIG=${HOME}/krb5.conf; export KRB5CCNAME=${_KRB5CCNAME}; \
while true; do \
  KRB5CCNAME=${_KRB5CCNAME} ssh -N ${_SSH_COMMON_OPTS} \
    -o GSSAPIAuthentication=yes -o GSSAPIDelegateCredentials=yes \
    -o PreferredAuthentications=gssapi-with-mic \
    -L ${REVERSE_PORT}:127.0.0.1:${REVERSE_PORT} \
    ${FNAL_USER}@${CORRELATOR4}; \
  echo 'Step2 tunnel dropped, reconnecting in 5s...'; sleep 5; \
done"

    # Step 3: Forward license ports via port 2210 to fasic-135413 (key auth)
    TUNNEL_STEP3="while true; do \
  while ! ss -ltn | grep -q ':${REVERSE_PORT}'; do \
    echo 'Waiting for port ${REVERSE_PORT}...'; sleep 2; \
  done; \
  ssh -N -p ${REVERSE_PORT} ${_SSH_COMMON_OPTS} \
    -L ${LICENSE_PORT}:127.0.0.1:${LICENSE_PORT} \
    -L ${CATAPULT_PORT}:127.0.0.1:${CATAPULT_PORT} \
    ${FNAL_USER}@localhost; \
  echo 'Step3 tunnel dropped, reconnecting in 5s...'; sleep 5; \
done"

    tmux new-session  -d -s catapult_tunnels -n licenses  "${TUNNEL_STEP2}"
    tmux new-window      -t catapult_tunnels -n licenses2 "${TUNNEL_STEP3}"

else
    # fasic-admin1: single hop, correlator4 already has ports forwarded
    TUNNEL_CMD="${_CLEAN_LD}export KRB5_CONFIG=${HOME}/krb5.conf; export KRB5CCNAME=${_KRB5CCNAME}; \
while true; do \
  KRB5CCNAME=${_KRB5CCNAME} ssh -N ${_SSH_COMMON_OPTS} \
    -o GSSAPIAuthentication=yes -o GSSAPIDelegateCredentials=yes \
    -o PreferredAuthentications=gssapi-with-mic \
    -L ${LICENSE_PORT}:127.0.0.1:${LICENSE_PORT} \
    -L ${CATAPULT_PORT}:127.0.0.1:${CATAPULT_PORT} \
    ${FNAL_USER}@${CORRELATOR4}; \
  echo 'Tunnel dropped, reconnecting in 5s...'; sleep 5; \
done"

    tmux new-session -d -s catapult_tunnels -n licenses "${TUNNEL_CMD}"
fi

echo "Waiting 8s for tunnel(s) to establish..."
sleep 8

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
    # Write license_servers_active.json so iter_manager knows actual license count
    ACTIVE_JSON="${SCRIPT_DIR}/license_servers_active.json"
    printf '{"servers": [{"host": "127.0.0.1", "port": %d, "licenses": %d}]}\n' \
        "${LICENSE_PORT}" "${SELECTED_LICENSES}" > "${ACTIVE_JSON}"

    echo ""
    echo "=== All tunnels up ==="
    echo "Server:  ${SELECTED_SERVER} (${SELECTED_LICENSES} license(s))"
    echo "Ports:   ${LICENSE_PORT} and ${CATAPULT_PORT} available at localhost"
    echo "Config:  ${ACTIVE_JSON}"
    echo ""
    echo "Next steps:"
    echo "  1. Detach tmux:  Ctrl+B D"
    echo "  2. Run synthesis:"
    echo "       python iter_manager_catapult.py ... \\"
    echo "           --license_config Perlmutter_scripts/license_servers_active.json"
    echo ""
    echo "To reconnect later:"
    echo "  ssh ${NERSC_USER}@$(hostname).perlmutter.nersc.gov"
    echo "  tmux attach -t catapult_tunnels"
else
    echo ""
    echo "Tunnel did not come up fully. Check tmux:"
    echo "  tmux attach -t catapult_tunnels"
fi
