#!/usr/bin/env bash

# ==========================================================
# NexGenAds SSH Dispatcher Setup (SERVER-SIDE)
#
# Run this ON the server (server.nexgenads.space), NOT on
# your local machine. It installs a ForceCommand dispatcher
# so that:
#
#   ssh home@server.nexgenads.space           -> normal shell
#   ssh home@server.nexgenads.space jenkins    -> docker exec into jenkins
#   ssh home@server.nexgenads.space grafana    -> docker exec into grafana
#   ssh home@server.nexgenads.space prometheus -> docker exec into prometheus
#
# Combined with the client-side setup.sh / setup.ps1 aliases,
# this lets you just run: ssh jenkins / ssh grafana / ssh server
#
# Usage:
#   curl -fsSL https://raw.githubusercontent.com/nexgenads-ai/server/main/server-dispatch.sh | bash
#
# Author: NexGenAds
# ==========================================================

set -e

GREEN='\033[0;32m'
RED='\033[0;31m'
BLUE='\033[0;34m'
NC='\033[0m'

success() { echo -e "${GREEN}✓ $1${NC}"; }
info()    { echo -e "${BLUE}$1${NC}"; }
error()   { echo -e "${RED}$1${NC}"; }

DISPATCH_SCRIPT="/usr/local/bin/nexgenads-dispatch.sh"
SSHD_CONFIG="/etc/ssh/sshd_config"
TARGET_USER="${1:-home}"   # override with: bash server-dispatch.sh someuser

echo
echo "=========================================="
echo "   NexGenAds SSH Dispatcher (server-side)"
echo "=========================================="
echo

if [ "$(id -u)" -ne 0 ] && ! command -v sudo >/dev/null 2>&1; then
    error "This script needs root or sudo access."
    exit 1
fi

SUDO=""
if [ "$(id -u)" -ne 0 ]; then
    SUDO="sudo"
fi

# ----------------------------------------------------------
# 1. Install the dispatcher script
# ----------------------------------------------------------

info "Installing dispatcher script at $DISPATCH_SCRIPT ..."

$SUDO tee "$DISPATCH_SCRIPT" > /dev/null << 'EOF'
#!/bin/bash
# NexGenAds SSH dispatcher — routes SSH_ORIGINAL_COMMAND to the right target.
# Add new services by adding a new case below, then re-run server-dispatch.sh
# is NOT required — just edit this file directly and it takes effect immediately.

case "$SSH_ORIGINAL_COMMAND" in
  jenkins)
    exec sudo docker exec -it jenkins bash
    ;;
  grafana)
    exec sudo docker exec -it grafana bash
    ;;
  prometheus)
    exec sudo docker exec -it prometheus bash
    ;;
  "")
    exec "$SHELL" -l
    ;;
  *)
    echo "Unknown target: '$SSH_ORIGINAL_COMMAND'"
    echo "Available: jenkins, grafana, prometheus, (blank for shell)"
    exit 1
    ;;
esac
EOF

$SUDO chmod +x "$DISPATCH_SCRIPT"

success "Dispatcher script installed"

# ----------------------------------------------------------
# 2. Wire it into sshd_config (idempotent)
# ----------------------------------------------------------

info "Configuring sshd for user '$TARGET_USER' ..."

MARKER="# >>> NexGenAds dispatcher for $TARGET_USER >>>"
END_MARKER="# <<< NexGenAds dispatcher for $TARGET_USER <<<"

if $SUDO grep -qF "$MARKER" "$SSHD_CONFIG" 2>/dev/null; then
    success "sshd_config already configured for '$TARGET_USER' — skipping"
else
    {
        echo ""
        echo "$MARKER"
        echo "Match User $TARGET_USER"
        echo "    ForceCommand $DISPATCH_SCRIPT"
        echo "$END_MARKER"
    } | $SUDO tee -a "$SSHD_CONFIG" > /dev/null

    success "sshd_config updated"
fi

# ----------------------------------------------------------
# 3. Validate + restart sshd
# ----------------------------------------------------------

info "Validating sshd config..."

if ! $SUDO sshd -t; then
    error "sshd_config has an error — NOT restarting sshd. Review $SSHD_CONFIG manually."
    exit 1
fi

success "sshd config valid"

info "Restarting sshd..."
$SUDO systemctl restart sshd || $SUDO systemctl restart ssh

success "sshd restarted"

echo
success "Dispatcher setup complete for user '$TARGET_USER'."
echo
echo "Test from your local machine with:"
echo "  ssh -t $TARGET_USER@server.nexgenads.space jenkins"
echo "  ssh -t $TARGET_USER@server.nexgenads.space grafana"
echo
echo "Or with RequestTTY yes set in your ~/.ssh/config aliases, just:"
echo "  ssh jenkins"
echo "  ssh grafana"
echo
