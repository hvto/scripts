#!/usr/bin/env bash
set -euo pipefail

REPO="zhboner/realm"
INSTALL_DIR="/usr/local/bin"
CONFIG_DIR="/etc/realm"
SERVICE_FILE="/etc/systemd/system/realm.service"

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

for cmd in curl tar; do
    if ! command_exists "$cmd"; then
        echo "Installing required packages..."
        apt-get update
        apt-get install -y curl ca-certificates tar
        break
    fi
done

ARCH="$(uname -m)"

case "$ARCH" in
    x86_64|amd64)
        TARGET="x86_64-unknown-linux-musl"
        ;;
    aarch64|arm64)
        TARGET="aarch64-unknown-linux-musl"
        ;;
    armv7l|armv7)
        TARGET="armv7-unknown-linux-musleabihf"
        ;;
    armv6l|armv6)
        TARGET="arm-unknown-linux-musleabihf"
        ;;
    *)
        die "unsupported architecture: $ARCH"
        ;;
esac

echo "Detecting latest Realm version..."

VERSION="$(
    curl -fsSL "https://api.github.com/repos/${REPO}/releases/latest" |
        sed -n 's/.*"tag_name":[[:space:]]*"\([^"]*\)".*/\1/p'
)"

[ -n "$VERSION" ] || die "failed to determine latest Realm version"

ASSET="realm-${TARGET}.tar.gz"
URL="https://github.com/${REPO}/releases/download/${VERSION}/${ASSET}"

TMP_DIR="$(mktemp -d)"

cleanup() {
    rm -rf "$TMP_DIR"
}
trap cleanup EXIT

echo "Installing Realm ${VERSION} (${TARGET})..."

curl -fL \
    --retry 3 \
    --connect-timeout 10 \
    -o "${TMP_DIR}/${ASSET}" \
    "$URL"

tar -xzf "${TMP_DIR}/${ASSET}" -C "$TMP_DIR"

[ -f "${TMP_DIR}/realm" ] || die "realm binary not found in archive"

install -m 0755 "${TMP_DIR}/realm" "${INSTALL_DIR}/realm"

mkdir -p "$CONFIG_DIR"

if [ ! -f "${CONFIG_DIR}/config.toml" ]; then
    cat > "${CONFIG_DIR}/config.toml" <<'EOF'
# Realm configuration
#
# Example:
#
# [[endpoints]]
# listen = "0.0.0.0:5000"
# remote = "1.1.1.1:443"
EOF
fi

cat > "$SERVICE_FILE" <<'EOF'
[Unit]
Description=Realm Network Relay
Documentation=https://github.com/zhboner/realm
After=network-online.target
Wants=network-online.target

[Service]
Type=simple
ExecStart=/usr/local/bin/realm -c /etc/realm/config.toml
Restart=on-failure
RestartSec=3
LimitNOFILE=1048576

[Install]
WantedBy=multi-user.target
EOF

systemctl daemon-reload
systemctl enable realm.service

echo
echo "Realm ${VERSION} installed successfully."
echo
echo "Binary:  /usr/local/bin/realm"
echo "Config:  /etc/realm/config.toml"
echo "Service: /etc/systemd/system/realm.service"
echo
echo "Edit the configuration:"
echo "  nano /etc/realm/config.toml"
echo
echo "Then start Realm:"
echo "  systemctl start realm"
echo
echo "Check status:"
echo "  systemctl status realm"
