#!/usr/bin/env bash

set -euo pipefail

VERSION="${CADDY_VERSION:-2.11.4}"

die() {
    echo "error: $*" >&2
    exit 1
}

command_exists() {
    command -v "$1" >/dev/null 2>&1
}

if [ "$(id -u)" -ne 0 ]; then
    die "this script must be run as root"
fi

if ! command_exists systemctl; then
    die "systemd is required"
fi

if ! command_exists curl; then
    echo "Installing required packages..."
    apt-get update
    apt-get install -y curl ca-certificates
fi

ARCH="$(dpkg --print-architecture)"

case "$ARCH" in
    amd64|arm64|armhf)
        ;;
    *)
        die "unsupported architecture: $ARCH"
        ;;
esac

PACKAGE="caddy_${VERSION}_linux_${ARCH}.deb"
URL="https://github.com/caddyserver/caddy/releases/download/v${VERSION}/${PACKAGE}"

TMP_DIR="$(mktemp -d)"

cleanup() {
    rm -rf "$TMP_DIR"
}

trap cleanup EXIT

echo "Installing Caddy ${VERSION} (${ARCH})..."

curl -fL \
    --retry 3 \
    --connect-timeout 10 \
    -o "${TMP_DIR}/${PACKAGE}" \
    "$URL"

apt-get install -y "${TMP_DIR}/${PACKAGE}"

mkdir -p /etc/systemd/system/caddy.service.d

cat > /etc/systemd/system/caddy.service.d/restart.conf <<'EOF'
[Service]
Restart=on-failure
RestartSec=2s
EOF

systemctl daemon-reload
systemctl enable caddy.service

echo
echo "Caddy ${VERSION} installed successfully."
echo
echo "Binary: /usr/bin/caddy"
echo "Config: /etc/caddy/Caddyfile"
echo "Service: caddy.service"
echo
echo "Edit the configuration:"
echo " nano /etc/caddy/Caddyfile"
echo
echo "Then start Caddy:"
echo " systemctl start caddy"
echo
echo "Check status:"
echo " systemctl status caddy"
