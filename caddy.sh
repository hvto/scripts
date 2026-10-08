#!/usr/bin/env bash

set -euo pipefail

VERSION="${CADDY_VERSION:-2.11.4}"

die() {
    echo "error: $*" >&2
    exit 1
}

if [ "$(id -u)" -ne 0 ]; then
    die "this script must be run as root"
fi

command -v systemctl >/dev/null 2>&1 || die "systemd is required"
command -v dpkg >/dev/null 2>&1 || die "Debian/Ubuntu is required"
command -v runuser >/dev/null 2>&1 || die "runuser is required"

echo "Installing dependencies..."

apt-get update
apt-get install -y curl ca-certificates

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

echo "Downloading Caddy ${VERSION} (${ARCH})..."

curl -fL \
    --retry 3 \
    --connect-timeout 10 \
    -o "${TMP_DIR}/${PACKAGE}" \
    "$URL"

echo "Installing Caddy..."

apt-get install -y "${TMP_DIR}/${PACKAGE}"

if ! id caddy >/dev/null 2>&1; then
    die "caddy user was not created by the package"
fi

echo "Configuring Caddy directories..."

install -d -o caddy -g caddy -m 0750 \
    /var/lib/caddy \
    /var/lib/caddy/.local \
    /var/lib/caddy/.local/share \
    /var/lib/caddy/.local/share/caddy \
    /var/lib/caddy/.config \
    /var/lib/caddy/.config/caddy

echo "Fixing Caddy ownership and permissions..."

chown -R caddy:caddy /var/lib/caddy

find /var/lib/caddy -type d -exec chmod 750 {} +
find /var/lib/caddy -type f -exec chmod 640 {} +

echo "Configuring systemd..."

install -d -m 0755 /etc/systemd/system/caddy.service.d

cat > /etc/systemd/system/caddy.service.d/restart.conf <<'EOF'
[Service]
Restart=on-failure
RestartSec=2s
EOF

systemctl daemon-reload
systemctl enable caddy.service

echo "Verifying Caddy permissions..."

for DIR in \
    /var/lib/caddy \
    /var/lib/caddy/.local \
    /var/lib/caddy/.local/share \
    /var/lib/caddy/.local/share/caddy \
    /var/lib/caddy/.config/caddy
do
    if ! runuser -u caddy -- test -w "$DIR"; then
        die "$DIR is not writable by caddy"
    fi
done

echo "Checking certificate storage permissions..."

if ! runuser -u caddy -- \
    mkdir -p /var/lib/caddy/.local/share/caddy/certificates; then
    die "Caddy cannot create certificate storage"
fi

echo "Caddy permissions verified successfully."

echo
echo "Caddy ${VERSION} installed successfully."
echo
echo "Binary:  /usr/bin/caddy"
echo "Config:  /etc/caddy/Caddyfile"
echo "Data:    /var/lib/caddy/.local/share/caddy"
echo "Service: caddy.service"
echo
echo "Restart policy: on-failure (2 seconds)"
echo
echo "Edit configuration:"
echo "  nano /etc/caddy/Caddyfile"
echo
echo "Start Caddy:"
echo "  systemctl start caddy"
echo
echo "Check status:"
echo "  systemctl status caddy"
