#!/usr/bin/env bash

set -euo pipefail

CONFIG_FILE="/etc/sysctl.d/99-hvto-bbr.conf"
MODULES_FILE="/etc/modules-load.d/hvto-bbr.conf"
MARKER="# Managed by hvto/scripts/bbr.sh"

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

show_status() {
    echo "Kernel: $(uname -r)"

    sysctl \
        net.ipv4.tcp_available_congestion_control \
        net.ipv4.tcp_congestion_control \
        net.core.default_qdisc

    if command -v tc >/dev/null 2>&1; then
        echo
        echo "Current interface queues:"
        tc qdisc show
    fi
}

# Arguments
case "${1:-enable}" in
    status)
        [ "$#" -eq 1 ] || die "usage: bbr.sh [enable|status]"
        show_status
        exit 0
        ;;
    enable)
        [ "$#" -le 1 ] || die "usage: bbr.sh [enable|status]"
        ;;
    -h|--help)
        echo "Usage: bbr.sh [enable|status]"
        echo "Enable the kernel's TCP BBR and set fq as the default queue."
        echo "Existing interface queues and service processes are not restarted."
        exit 0
        ;;
    *)
        die "usage: bbr.sh [enable|status]"
        ;;
esac

# Requirements
[ "$(id -u)" -eq 0 ] || die "this script must be run as root"
[ "$(uname -s)" = Linux ] || die "Linux is required"
[ -d /run/systemd/system ] || die "a running systemd host is required"

for cmd in sysctl modprobe flock mktemp install cp cmp awk; do
    command -v "$cmd" >/dev/null 2>&1 || \
        die "required command not found: $cmd"
done

# Lock
exec 9>/run/lock/hvto-bbr.lock

flock -n 9 || \
    die "another BBR installation is running"

# Check existing configuration
info "Checking existing configuration..."

for file in "$CONFIG_FILE" "$MODULES_FILE"; do
    [ ! -L "$file" ] || \
        die "refusing to overwrite symlink: $file"

    if [ -e "$file" ]; then
        [ -f "$file" ] || \
            die "not a regular file: $file"

        IFS= read -r first_line < "$file" || true

        [ "${first_line:-}" = "$MARKER" ] || \
            die "unmanaged configuration exists: $file"
    fi
done

# Kernel support
info "Checking kernel support..."

if ! modprobe tcp_bbr; then
    available="$(sysctl -n net.ipv4.tcp_available_congestion_control)"

    [[ " $available " = *" bbr "* ]] || \
        die "TCP BBR is unavailable in this kernel"
fi

modprobe sch_fq || \
    die "fq is unavailable in this kernel"

available="$(sysctl -n net.ipv4.tcp_available_congestion_control)"

[[ " $available " = *" bbr "* ]] || \
    die "TCP BBR is unavailable in this kernel"

success "Kernel supports TCP BBR and fq"

# Check conflicting sysctl definitions
info "Checking for conflicting sysctl definitions..."

shopt -s nullglob

for file in \
    /etc/sysctl.conf \
    /etc/sysctl.d/*.conf \
    /run/sysctl.d/*.conf \
    /usr/local/lib/sysctl.d/*.conf \
    /usr/lib/sysctl.d/*.conf \
    /lib/sysctl.d/*.conf
do
    [ -f "$file" ] || continue
    [ "$file" != "$CONFIG_FILE" ] || continue

    while IFS= read -r warning; do
        warn "$warning"
    done < <(
        awk '
            /^[[:space:]]*-?net[.\/]core[.\/]default_qdisc[[:space:]]*=/ ||
            /^[[:space:]]*-?net[.\/]ipv4[.\/]tcp_congestion_control[[:space:]]*=/ {
                print "other sysctl definition: " FILENAME ":" FNR ": " $0
            }
        ' "$file"
    )
done

# Save current runtime settings
OLD_CC="$(sysctl -n net.ipv4.tcp_congestion_control)"
OLD_QDISC="$(sysctl -n net.core.default_qdisc)"

TMP_DIR="$(mktemp -d)"
CHANGING=0

# Cleanup and rollback
cleanup() {
    local result=$?

    trap - EXIT

    if [ "$CHANGING" -eq 1 ]; then
        warn "Installation failed; restoring previous settings"

        set +e

        for file in "$CONFIG_FILE" "$MODULES_FILE"; do
            name="${file##*/}"

            if [ -f "$TMP_DIR/$name.previous" ]; then
                cp -p "$TMP_DIR/$name.previous" "$file" || \
                    printf '%s[ERROR]%s Could not restore %s\n' \
                        "$RED" "$RESET" "$file" >&2
            else
                rm -f "$file" || \
                    printf '%s[ERROR]%s Could not remove %s\n' \
                        "$RED" "$RESET" "$file" >&2
            fi
        done

        sysctl -q -w \
            "net.ipv4.tcp_congestion_control=$OLD_CC" \
            "net.core.default_qdisc=$OLD_QDISC" || \
            printf '%s[ERROR]%s Could not restore runtime settings\n' \
                "$RED" "$RESET" >&2
    fi

    rm -rf "$TMP_DIR"

    exit "$result"
}

trap cleanup EXIT

# Backup managed files
for file in "$CONFIG_FILE" "$MODULES_FILE"; do
    if [ -f "$file" ]; then
        cp -p "$file" "$TMP_DIR/${file##*/}.previous"
    fi
done

# Generate configuration
cat > "$TMP_DIR/sysctl.conf" <<EOF
$MARKER
# TCP only; Hysteria/QUIC congestion control is configured by the application.
net.core.default_qdisc = fq
net.ipv4.tcp_congestion_control = bbr
EOF

cat > "$TMP_DIR/modules.conf" <<EOF
$MARKER
tcp_bbr
sch_fq
EOF

# Apply runtime settings
info "Enabling TCP BBR and fq..."

CHANGING=1

sysctl -q -p "$TMP_DIR/sysctl.conf"

[ "$(sysctl -n net.ipv4.tcp_congestion_control)" = bbr ] || \
    die "BBR verification failed"

[ "$(sysctl -n net.core.default_qdisc)" = fq ] || \
    die "fq verification failed"

success "TCP BBR and fq enabled"

# Save persistent configuration
info "Saving configuration..."

install -d -m 0755 \
    /etc/sysctl.d \
    /etc/modules-load.d

if ! cmp -s "$TMP_DIR/sysctl.conf" "$CONFIG_FILE"; then
    install -m 0644 "$TMP_DIR/sysctl.conf" "$CONFIG_FILE"
fi

if ! cmp -s "$TMP_DIR/modules.conf" "$MODULES_FILE"; then
    install -m 0644 "$TMP_DIR/modules.conf" "$MODULES_FILE"
fi

CHANGING=0

success "Configuration saved"

# Result
echo
success "TCP BBR enabled and saved successfully"
echo
echo "Config:  $CONFIG_FILE"
echo "Modules: $MODULES_FILE"
echo

warn "Other sysctl definitions may override these settings at boot"
warn "Existing TCP sockets retain their congestion controller"
warn "Existing listeners may pass their old controller to accepted sockets"
warn "Existing interface queues are unchanged"

echo
echo "Restart applications during maintenance if needed."
echo "Check interface queues: tc qdisc show"
echo "Verify settings after the next reboot."
echo

show_status
