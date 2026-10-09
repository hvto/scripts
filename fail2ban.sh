#!/usr/bin/env bash
set -euo pipefail

CONFIG_FILE="/etc/fail2ban/jail.d/99-sshd.local"

die() {
    echo "error: $*" >&2
    exit 1
}

[ "$(id -u)" -eq 0 ] || die "this script must be run as root"
command -v apt-get >/dev/null 2>&1 || die "apt-get is required (Debian/Ubuntu)"
command -v systemctl >/dev/null 2>&1 || die "systemd is required"

if [ -f "$CONFIG_FILE" ]; then
    echo "Existing configuration: $CONFIG_FILE"
    echo "Keeping existing configuration unchanged."
else
    echo "Installing Fail2Ban dependencies..."
fi

apt-get update
apt-get install -y fail2ban nftables python3-systemd

if [ ! -e "$CONFIG_FILE" ]; then
    install -d -m 0755 /etc/fail2ban/jail.d
    cat > "$CONFIG_FILE" <<'EOF'
[DEFAULT]
banaction = nftables[type=multiport]
dbfile = None

[sshd]
enabled = true
filter = sshd
backend = systemd
port = 22
mode = aggressive
maxretry = 3
findtime = 10m
bantime = 24h
EOF
    echo "Created $CONFIG_FILE"
fi

echo "Validating Fail2Ban configuration..."
fail2ban-client -t || die "configuration test failed; service was not restarted"

echo "Enabling and restarting Fail2Ban..."
systemctl enable fail2ban
systemctl restart fail2ban
systemctl is-active --quiet fail2ban || die "Fail2Ban service is not active"
fail2ban-client status sshd || die "SSH jail is not active"

echo "Fail2Ban SSH protection is active."
echo "Config: $CONFIG_FILE"
echo "Check status: fail2ban-client status sshd"
