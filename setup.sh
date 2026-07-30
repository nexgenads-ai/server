#!/usr/bin/env bash
set -e

HOSTNAME="server.nexgenads.space"
USERNAME="home"

echo "======================================="
echo " Cloudflare SSH Setup"
echo "======================================="

# Detect OS
OS="$(uname -s)"

install_cloudflared_linux() {
    if command -v cloudflared >/dev/null 2>&1; then
        echo "✓ cloudflared already installed"
        return
    fi

    echo "Installing cloudflared..."

    curl -fsSL https://pkg.cloudflare.com/cloudflare-main.gpg \
      | sudo gpg --dearmor -o /usr/share/keyrings/cloudflare-main.gpg

    echo "deb [signed-by=/usr/share/keyrings/cloudflare-main.gpg] https://pkg.cloudflare.com/cloudflared any main" \
      | sudo tee /etc/apt/sources.list.d/cloudflared.list >/dev/null

    sudo apt update
    sudo apt install -y cloudflared
}

install_cloudflared_macos() {
    if command -v cloudflared >/dev/null 2>&1; then
        echo "✓ cloudflared already installed"
        return
    fi

    if ! command -v brew >/dev/null 2>&1; then
        echo "Homebrew is required."
        echo "Install it from https://brew.sh"
        exit 1
    fi

    brew install cloudflared
}

# Install cloudflared
case "$OS" in
    Linux*)
        install_cloudflared_linux
        ;;
    Darwin*)
        install_cloudflared_macos
        ;;
    *)
        echo "Unsupported OS: $OS"
        exit 1
        ;;
esac

# Verify SSH exists
if ! command -v ssh >/dev/null 2>&1; then
    echo "OpenSSH client is not installed."
    exit 1
fi

mkdir -p ~/.ssh
chmod 700 ~/.ssh

CONFIG_FILE="$HOME/.ssh/config"

if ! grep -q "$HOSTNAME" "$CONFIG_FILE" 2>/dev/null; then

cat <<EOF >> "$CONFIG_FILE"

Host $HOSTNAME
    HostName $HOSTNAME
    User $USERNAME
    ProxyCommand cloudflared access ssh --hostname %h

EOF

echo "✓ SSH configuration added."

else
    echo "✓ SSH configuration already exists."
fi

chmod 600 "$CONFIG_FILE"

echo
echo "======================================="
echo "Setup Complete!"
echo "======================================="
echo
echo "Connect using:"
echo
echo "ssh $USERNAME@$HOSTNAME"
echo
