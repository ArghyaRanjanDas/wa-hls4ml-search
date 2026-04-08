#!/usr/bin/env bash
# setup_tunnels_simple.sh — EXPERIMENTAL single-step tunnel setup (not used in pipeline)
#
# Alternative to setup_tunnels.sh using a single autossh with ProxyJump.
# Kept for future reference and testing — the active script is setup_tunnels.sh (3-step).
#
# How it works:
#   A single autossh connects Perlmutter → correlator4 (ProxyJump) → fasic-admin1,
#   forwarding fasic-admin1's local license ports to Perlmutter's localhost.
#   This replaces the entire 3-step reverse-tunnel architecture with one command.
#
# Requires: autossh, tmux, kinit
#   kinit ${FNAL_USER}@FNAL.GOV   (run this before the script)
#   fasic-admin1 accepts Kerberos so no ME Division password prompt.
#
# Usage:
#   source .env           # or export FNAL_USER and NERSC_USER manually
#   bash setup_tunnels_simple.sh

set -euo pipefail

SCRIPT_DIR="$(cd "$(dirname "${BASH_SOURCE[0]}")" && pwd)"
ENV_FILE="${SCRIPT_DIR}/.env"

if [[ -f "${ENV_FILE}" ]]; then
    set -o allexport
    source "${ENV_FILE}"
    set +o allexport
fi

if [[ -z "${FNAL_USER:-}" ]]; then
    read -rp "FNAL username (correlator4 / fasic-admin1): " FNAL_USER
fi
if [[ -z "${NERSC_USER:-}" ]]; then
    read -rp "NERSC username (perlmutter): " NERSC_USER
fi

LICENSE_PORT=1717
CATAPULT_PORT=40003
CORRELATOR4=correlator4.fnal.gov
FASIC=fasic-admin1.fnal.gov

echo "=== Catapult License Tunnel Setup (simple / experimental) ==="
echo "FNAL user:      ${FNAL_USER}"
echo "License server: ${FASIC}"
echo "Via:            ${CORRELATOR4} (ProxyJump)"
echo ""
echo "NOTE: This is the experimental single-step script."
echo "      Use setup_tunnels.sh (3-step) for the tested pipeline."
echo ""

if ! hostname -f | grep -q "perlmutter"; then
    echo "WARNING: this script should be run on a Perlmutter login node."
    echo "Current host: $(hostname -f)"
    read -rp "Continue anyway? [y/N] " confirm
    [[ "${confirm}" =~ ^[Yy]$ ]] || exit 1
fi

echo "Starting autossh license tunnel in tmux session 'catapult_tunnels_simple'..."

AUTOSSH_CMD="autossh -M 0 -N -g \
  -o ServerAliveInterval=60 \
  -o ServerAliveCountMax=5 \
  -o GSSAPIAuthentication=yes \
  -o GSSAPIDelegateCredentials=yes \
  -o PreferredAuthentications=gssapi-with-mic \
  -o ProxyJump=${FNAL_USER}@${CORRELATOR4} \
  -L ${LICENSE_PORT}:localhost:${LICENSE_PORT} \
  -L ${CATAPULT_PORT}:localhost:${CATAPULT_PORT} \
  ${FNAL_USER}@${FASIC}; read"

if tmux has-session -t catapult_tunnels_simple 2>/dev/null; then
    tmux new-window -t catapult_tunnels_simple: -n licenses "${AUTOSSH_CMD}"
else
    tmux new-session -d -s catapult_tunnels_simple -n licenses "${AUTOSSH_CMD}"
fi

echo "Waiting 8s for tunnel to establish..."
sleep 8

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
    echo "=== Tunnel up ==="
    echo "License ports ${LICENSE_PORT} and ${CATAPULT_PORT} available at localhost."
    echo ""
    echo "Next steps:"
    echo "  1. Detach tmux: Ctrl+B D"
    echo "  2. Run synthesis: python iter_manager_catapult.py ... --license_config license_servers_perlmutter.json"
    echo ""
    echo "To reconnect later:"
    echo "  ssh ${NERSC_USER}@$(hostname).perlmutter.nersc.gov"
    echo "  tmux attach -t catapult_tunnels_simple"
else
    echo ""
    echo "Some ports did not come up. Check tmux for errors:"
    echo "  tmux attach -t catapult_tunnels_simple"
fi
