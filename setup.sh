#!/usr/bin/env bash

# ==========================================================
# NexGenAds SSH Setup
# Supports:
#   - Ubuntu / Debian
#   - Fedora / RHEL / CentOS
#   - Arch Linux
#   - macOS
#
# Installs:
#   - cloudflared (if missing)
#   - SSH configuration
#
# Reads:
#   servers.conf   (alias|host|username|target)
#     - target is OPTIONAL. If set, the alias sends "target"
#       as the SSH remote command, which the server-side
#       dispatcher (server-dispatch.sh, run once on the
#       server) turns into a docker exec into that service.
#       Leave blank for a plain login shell.
#
# Author: NexGenAds
# ==========================================================

set -e

# ----------------------------------------------------------
# Colors + helper functions (must be defined before use)
# ----------------------------------------------------------

GREEN='\033[0;32m'
RED='\033[0;31m'
YELLOW='\033[1;33m'
BLUE='\033[0;34m'
NC='\033[0m'

success() {
    echo -e "${GREEN}✓ $1${NC}"
}

info() {
    echo -e "${BLUE}$1${NC}"
}

warn() {
    echo -e "${YELLOW}$1${NC}"
}

error() {
    echo -e "${RED}$1${NC}"
}

# ----------------------------------------------------------
# Setup + cleanup
# ----------------------------------------------------------

REPO="https://raw.githubusercontent.com/nexgenads-ai/server/main"

TMP_DIR=$(mktemp -d)
SERVERS_FILE="$TMP_DIR/servers.conf"
CONFIG_FILE="$HOME/.ssh/config"

trap 'rm -rf "$TMP_DIR"' EXIT

echo
echo "=========================================="
echo "      NexGenAds SSH Installer"
echo "=========================================="
echo

# ----------------------------------------------------------
# Download server configuration
# ----------------------------------------------------------

info "Downloading server configuration..."

curl -fsSL "$REPO/servers.conf" -o "$SERVERS_FILE"

if [ ! -s "$SERVERS_FILE" ]; then
    error "Failed to download servers.conf"
    exit 1
fi

success "Downloaded servers.conf"

# ----------------------------------------------------------
# Detect OS
# ----------------------------------------------------------

OS="$(uname -s)"

case "$OS" in
    Linux*)
        PLATFORM="linux"
        ;;
    Darwin*)
        PLATFORM="macos"
        ;;
    *)
        error "Unsupported operating system: $OS"
        exit 1
        ;;
esac

success "Detected $PLATFORM"

# ----------------------------------------------------------
# Check SSH Client
# ----------------------------------------------------------

if ! command -v ssh >/dev/null 2>&1; then
    error "OpenSSH client is not installed."
    exit 1
fi

success "OpenSSH found"

# ----------------------------------------------------------
# Install Cloudflared
# ----------------------------------------------------------

install_linux() {

    if command -v cloudflared >/dev/null 2>&1; then
        success "Cloudflared already installed"
        return
    fi

    info "Installing Cloudflared..."

    if command -v apt >/dev/null 2>&1; then

        curl -fsSL https://pkg.cloudflare.com/cloudflare-main.gpg \
        | sudo gpg --dearmor \
        -o /usr/share/keyrings/cloudflare-main.gpg

        echo \
"deb [signed-by=/usr/share/keyrings/cloudflare-main.gpg] https://pkg.cloudflare.com/cloudflared any main" \
        | sudo tee /etc/apt/sources.list.d/cloudflared.list >/dev/null

        sudo apt update
        sudo apt install -y cloudflared

    elif command -v dnf >/dev/null 2>&1; then

        sudo dnf install -y cloudflared

    elif command -v yum >/dev/null 2>&1; then

        sudo yum install -y cloudflared

    elif command -v pacman >/dev/null 2>&1; then

        sudo pacman -Sy --noconfirm cloudflared

    else

        error "Unsupported Linux distribution."
        exit 1

    fi

    success "Cloudflared installed"

}

install_macos() {

    if command -v cloudflared >/dev/null 2>&1; then
        success "Cloudflared already installed"
        return
    fi

    if ! command -v brew >/dev/null 2>&1; then
        error "Homebrew is required."
        echo
        echo "Install Homebrew:"
        echo "https://brew.sh"
        exit 1
    fi

    info "Installing Cloudflared..."

    brew install cloudflared

    success "Cloudflared installed"

}

if [ "$PLATFORM" = "linux" ]; then
    install_linux
else
    install_macos
fi

# ----------------------------------------------------------
# Prepare SSH Directory
# ----------------------------------------------------------

mkdir -p "$HOME/.ssh"
chmod 700 "$HOME/.ssh"

touch "$CONFIG_FILE"
chmod 600 "$CONFIG_FILE"

START_MARKER="# >>> NexGenAds SSH START >>>"
END_MARKER="# <<< NexGenAds SSH END <<<"

TMP_FILE=$(mktemp)

if grep -q "$START_MARKER" "$CONFIG_FILE"; then

    awk -v start="$START_MARKER" -v end="$END_MARKER" '

    $0==start {skip=1;next}
    $0==end {skip=0;next}

    !skip

    ' "$CONFIG_FILE" > "$TMP_FILE"

    mv "$TMP_FILE" "$CONFIG_FILE"

fi

{
echo
echo "$START_MARKER"

while IFS="|" read -r ALIAS HOST USERNAME CONTAINER
do

    [ -z "$ALIAS" ] && continue
    [[ "$ALIAS" =~ ^# ]] && continue

    # trim whitespace from container field
    CONTAINER="$(echo "$CONTAINER" | xargs)"

cat <<EOF

Host $ALIAS
    HostName $HOST
    User $USERNAME
    ProxyCommand cloudflared access ssh --hostname %h
EOF

    if [ -n "$CONTAINER" ]; then
cat <<EOF
    RequestTTY yes
    RemoteCommand $CONTAINER
EOF
    fi

    echo

done < "$SERVERS_FILE"

echo "$END_MARKER"

} >> "$CONFIG_FILE"

# ----------------------------------------------------------
# Summary
# ----------------------------------------------------------

echo
success "SSH configuration installed."

echo
echo "Available hosts:"
echo

awk -F'|' '
/^#/ {next}
NF>=1 && $1 != "" {
    if (NF>=4 && $4 != "") {
        printf "  ssh %s   (-> container: %s)\n", $1, $4
    } else {
        printf "  ssh %s\n", $1
    }
}
' "$SERVERS_FILE"

echo
success "Installation completed successfully!"
