
#!/usr/bin/env bash

set -euo pipefail

VERSION="${CADDY_VERSION:-2.11.4}"

# Colors
if [ -t 1 ] && [ -z "${NO_COLOR:-}" ] && [ "${TERM:-}" != "dumb" ]; then
    BLUE=$'\033[0;34m'
    GREEN=$'\033[0;32m'
    YELLOW=$'\033[0;33m'
    RED=$'\033[0;31m'
    RESET=$'\033[0m'
else
    BLUE=""
    GREEN=""
    YELLOW=""
    RED=""
    RESET=""
fi

info() {
    printf '%s[INFO]%s %s\n' "$BLUE" "$RESET" "$*"
}

success() {
    printf '%s[OK]%s %s\n' "$GREEN" "$RESET" "$*"
}

warn() {
    printf '%s[WARN]%s %s\n' "$YELLOW" "$RESET" "$*" >&2
}

die() {
    printf '%s[ERROR]%s %s\n' "$RED" "$RESET" "$*" >&2
    exit 1
}

# Requirements
[ "$(id -u)" -eq 0 ] || die "this script must be run as root"

for cmd in systemctl dpkg dpkg-deb apt-get runuser getent sha256sum; do
    command -v "$cmd" >/dev/null 2>&1 || die "missing command: $cmd"
done

[[ "$VERSION" =~ ^[0-9]+\.[0-9]+\.[0-9]+$ ]] || \
    die "invalid Caddy version: $VERSION"

ARCH="$(dpkg --print-architecture)"

case "$ARCH" in
    amd64|arm64|armhf) ;;
    *) die "unsupported architecture: $ARCH" ;;
esac

# Dependencies
info "Installing dependencies..."

apt-get update
apt-get install -y --no-install-recommends curl ca-certificates

# Download
PACKAGE="caddy_${VERSION}_linux_${ARCH}.deb"
CHECKSUMS="caddy_${VERSION}_checksums.txt"
BASE_URL="https://github.com/caddyserver/caddy/releases/download/v${VERSION}"

TMP_DIR="$(mktemp -d)"
trap 'rm -rf "$TMP_DIR"' EXIT

INSTALLED_VERSION="$(dpkg-query -W -f='${Version}' caddy 2>/dev/null || true)"

if [ "$INSTALLED_VERSION" = "$VERSION" ]; then
    success "Caddy ${VERSION} already installed"
else
    info "Downloading Caddy ${VERSION} (${ARCH})..."

    curl -fsSL --retry 3 --connect-timeout 10 \
        -o "$TMP_DIR/$PACKAGE" \
        "$BASE_URL/$PACKAGE"

    curl -fsSL --retry 3 --connect-timeout 10 \
        -o "$TMP_DIR/$CHECKSUMS" \
        "$BASE_URL/$CHECKSUMS"

    # Verify checksum
    info "Verifying checksum..."

    (
        cd "$TMP_DIR"
        grep -E "^[0-9a-fA-F]{64} [ *]${PACKAGE}$" "$CHECKSUMS" |
            sha256sum -c -
    ) || die "checksum verification failed"

    # Verify package metadata
    [ "$(dpkg-deb -f "$TMP_DIR/$PACKAGE" Package)" = "caddy" ] || \
        die "invalid package name"

    [ "$(dpkg-deb -f "$TMP_DIR/$PACKAGE" Architecture)" = "$ARCH" ] || \
        die "invalid package architecture"

    PKG_VERSION="$(dpkg-deb -f "$TMP_DIR/$PACKAGE" Version)"

    case "$PKG_VERSION" in
        "$VERSION"|"$VERSION"-*|"$VERSION"+*) ;;
        *) die "unexpected package version: $PKG_VERSION" ;;
    esac

    # Check dependencies
    info "Checking package dependencies..."

    APT_PLAN="$(
        apt-get -s --no-install-recommends install "$TMP_DIR/$PACKAGE"
    )" || die "dependency resolution failed"

    if printf '%s\n' "$APT_PLAN" |
        grep -Eq '^Inst (docker|docker\.io|docker-ce|docker-ce-cli|containerd|containerd\.io|podman|runc)([ :]|$)'; then
        die "installation would install container runtime packages"
    fi

    # Install
    info "Installing Caddy..."

    apt-get install -y --no-install-recommends "$TMP_DIR/$PACKAGE"

    success "Caddy ${VERSION} installed"
fi

# Verify installation
command -v caddy >/dev/null 2>&1 || \
    die "Caddy binary not found"

id caddy >/dev/null 2>&1 || \
    die "caddy user not found"

systemctl cat caddy.service >/dev/null 2>&1 || \
    die "caddy.service not found"

SERVICE_USER="$(systemctl show caddy.service -p User --value)"
[ "$SERVICE_USER" = "caddy" ] || \
    die "caddy.service must run as user caddy"

CADDY_HOME="$(getent passwd caddy | cut -d: -f6)"
[ "$CADDY_HOME" = "/var/lib/caddy" ] || \
    die "unexpected Caddy home: $CADDY_HOME"

# Storage permissions
info "Checking Caddy storage..."

install -d -o caddy -g caddy -m 0700 /var/lib/caddy

for dir in \
    /var/lib/caddy/.local \
    /var/lib/caddy/.local/share \
    /var/lib/caddy/.local/share/caddy \
    /var/lib/caddy/.config \
    /var/lib/caddy/.config/caddy
do
    if [ ! -d "$dir" ]; then
        runuser -u caddy -- mkdir -m 0700 "$dir" || \
            die "cannot create directory: $dir"
    fi
done

for dir in \
    /var/lib/caddy \
    /var/lib/caddy/.local/share/caddy \
    /var/lib/caddy/.config/caddy
do
    runuser -u caddy -- test -w "$dir" || \
        die "directory not writable by caddy: $dir"
done

success "Storage permissions verified"

# Systemd
info "Configuring systemd..."

install -d -m 0755 /etc/systemd/system/caddy.service.d

OVERRIDE="/etc/systemd/system/caddy.service.d/restart.conf"

if [ ! -e "$OVERRIDE" ]; then
    cat > "$OVERRIDE" <<'EOF'
[Service]
Restart=on-failure
RestartSec=2s
EOF
    success "Restart policy configured"
else
    warn "Existing restart override preserved"
fi

systemctl daemon-reload
systemctl enable caddy.service >/dev/null

# Final checks
info "Checking service configuration..."

SERVICE_GROUP="$(systemctl show caddy.service -p Group --value)"

if [ -n "$SERVICE_GROUP" ] && [ "$SERVICE_GROUP" != "caddy" ]; then
    die "unexpected service group: $SERVICE_GROUP"
fi

if systemctl is-active --quiet caddy.service; then
    success "Caddy service is running"
else
    warn "Caddy service is not running"
    warn "Start it with: systemctl start caddy"
fi

# Result
echo
success "Caddy ${VERSION} is ready"
echo
echo "Binary:  /usr/bin/caddy"
echo "Config:  /etc/caddy/Caddyfile"
echo "Data:    /var/lib/caddy/.local/share/caddy"
echo "Service: caddy.service"
echo
echo "Start:   systemctl start caddy"
echo "Status:  systemctl status caddy"
echo "Logs:    journalctl -u caddy -f"
