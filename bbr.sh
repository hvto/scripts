#!/usr/bin/env bash
set -euo pipefail

CONFIG_FILE="/etc/sysctl.d/99-hvto-bbr.conf"
MODULES_FILE="/etc/modules-load.d/hvto-bbr.conf"
MARKER="# Managed by hvto/scripts/bbr.sh"

die() {
    echo "error: $*" >&2
    exit 1
}

show_status() {
    echo "Kernel: $(uname -r)"
    sysctl net.ipv4.tcp_available_congestion_control \
        net.ipv4.tcp_congestion_control net.core.default_qdisc
    if command -v tc >/dev/null 2>&1; then
        echo
        echo "Current interface queues:"
        tc qdisc show
    fi
}

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

[ "$(id -u)" -eq 0 ] || die "this script must be run as root"
[ "$(uname -s)" = Linux ] || die "Linux is required"
[ -d /run/systemd/system ] || die "a running systemd host is required"

for cmd in sysctl modprobe flock mktemp install cp cmp awk; do
    command -v "$cmd" >/dev/null 2>&1 || die "required command not found: $cmd"
done

exec 9>/run/lock/hvto-bbr.lock
flock -n 9 || die "another BBR installation is running"
for file in "$CONFIG_FILE" "$MODULES_FILE"; do
    [ ! -L "$file" ] || die "refusing to overwrite symlink: $file"
    if [ -e "$file" ]; then
        [ -f "$file" ] || die "not a regular file: $file"
        IFS= read -r first_line < "$file" || true
        [ "${first_line:-}" = "$MARKER" ] || die "unmanaged configuration exists: $file"
    fi
done

echo "Checking kernel support..."
if ! modprobe tcp_bbr; then
    available="$(sysctl -n net.ipv4.tcp_available_congestion_control)"
    [[ " $available " = *" bbr "* ]] || die "TCP BBR is unavailable in this kernel"
fi
modprobe sch_fq || die "fq is unavailable in this kernel"
available="$(sysctl -n net.ipv4.tcp_available_congestion_control)"
[[ " $available " = *" bbr "* ]] || die "TCP BBR is unavailable in this kernel"

shopt -s nullglob
for file in /etc/sysctl.conf /etc/sysctl.d/*.conf /run/sysctl.d/*.conf \
    /usr/local/lib/sysctl.d/*.conf /usr/lib/sysctl.d/*.conf /lib/sysctl.d/*.conf; do
    [ -f "$file" ] || continue
    [ "$file" != "$CONFIG_FILE" ] || continue
    awk '
        /^[[:space:]]*-?net[.\/]core[.\/]default_qdisc[[:space:]]*=/ ||
        /^[[:space:]]*-?net[.\/]ipv4[.\/]tcp_congestion_control[[:space:]]*=/ {
            print "warning: other sysctl definition: " FILENAME ":" FNR ": " $0 > "/dev/stderr"
        }
    ' "$file"
done

OLD_CC="$(sysctl -n net.ipv4.tcp_congestion_control)"
OLD_QDISC="$(sysctl -n net.core.default_qdisc)"
TMP_DIR="$(mktemp -d)"
CHANGING=0

cleanup() {
    local result=$?
    trap - EXIT
    if [ "$CHANGING" -eq 1 ]; then
        echo "warning: installation failed; restoring previous settings" >&2
        set +e
        for file in "$CONFIG_FILE" "$MODULES_FILE"; do
            name="${file##*/}"
            if [ -f "$TMP_DIR/$name.previous" ]; then
                cp -p "$TMP_DIR/$name.previous" "$file" || echo "error: could not restore $file" >&2
            else
                rm -f "$file" || echo "error: could not remove $file" >&2
            fi
        done
        sysctl -q -w "net.ipv4.tcp_congestion_control=$OLD_CC" \
            "net.core.default_qdisc=$OLD_QDISC" || echo "error: could not restore runtime settings" >&2
    fi
    rm -rf "$TMP_DIR"
    exit "$result"
}
trap cleanup EXIT

for file in "$CONFIG_FILE" "$MODULES_FILE"; do
    if [ -f "$file" ]; then
        cp -p "$file" "$TMP_DIR/${file##*/}.previous"
    fi
done

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

CHANGING=1

sysctl -q -p "$TMP_DIR/sysctl.conf"
[ "$(sysctl -n net.ipv4.tcp_congestion_control)" = bbr ] || die "BBR verification failed"
[ "$(sysctl -n net.core.default_qdisc)" = fq ] || die "fq verification failed"

install -d -m 0755 /etc/sysctl.d /etc/modules-load.d
if ! cmp -s "$TMP_DIR/sysctl.conf" "$CONFIG_FILE"; then
    install -m 0644 "$TMP_DIR/sysctl.conf" "$CONFIG_FILE"
fi
if ! cmp -s "$TMP_DIR/modules.conf" "$MODULES_FILE"; then
    install -m 0644 "$TMP_DIR/modules.conf" "$MODULES_FILE"
fi
CHANGING=0

echo
echo "TCP BBR enabled and saved successfully."
echo "Config:  $CONFIG_FILE"
echo "Modules: $MODULES_FILE"
echo
echo "Other sysctl definitions can override these settings at boot; resolve any warnings."
echo "Existing TCP sockets retain their congestion controller."
echo "Existing listeners may pass their old controller to accepted sockets."
echo "Restart app's during maintenance to refresh listeners."
echo "Existing interface queues are unchanged; inspect them with: tc qdisc show"
echo "A planned reboot normally installs the default queue on recreated interfaces; verify afterwards."
echo
show_status
