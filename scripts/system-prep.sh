#!/usr/bin/env bash
# =============================================================================
# system-prep.sh  ->  one-time OS tuning for an MTA on Ubuntu 22.04
# Run as root:  bash scripts/system-prep.sh
# =============================================================================
set -euo pipefail

echo "==> Setting FQDN hostname"
hostnamectl set-hostname smtp.neumannassociatesnews.io

echo "==> Kernel / network tuning for high socket + file usage"
cat >/etc/sysctl.d/99-kumomta.conf <<'EOF'
fs.file-max = 250000
net.ipv4.tcp_tw_reuse = 1
net.core.somaxconn = 1024
net.ipv4.ip_local_port_range = 10000 65535
EOF
sysctl --system >/dev/null

echo "==> Raising file descriptor limits for the kumod service"
mkdir -p /etc/systemd/system/kumomta.service.d
cat >/etc/systemd/system/kumomta.service.d/limits.conf <<'EOF'
[Service]
LimitNOFILE=256000
EOF

echo "==> Creating spool + log directories"
mkdir -p /var/spool/kumomta/data /var/spool/kumomta/meta /var/log/kumomta
# chown to the kumod user once KumoMTA is installed:
#   chown -R kumod:kumod /var/spool/kumomta /var/log/kumomta

echo
echo "Done. Remaining MANUAL steps (cannot be automated here):"
echo "  1. Open a RackNerd ticket to confirm OUTBOUND PORT 25 is unblocked."
echo "  2. Set PTR records for .52-.57 to match the ehlo names in sources.toml."
echo "  3. Copy the DKIM key into etc/dkim/neumannassociatesnews.io/pmta.key."
echo "  4. Reload systemd:  systemctl daemon-reload"
