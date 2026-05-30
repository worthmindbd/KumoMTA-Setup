#!/usr/bin/env bash
# =============================================================================
# enable-ssl.sh  --  obtain a Let's Encrypt cert and wire it into KumoMTA
# -----------------------------------------------------------------------------
# Run this AFTER install.sh if the SSL step was skipped (e.g. certbot couldn't
# reach port 80 the first time). It is safe to re-run (idempotent): it issues /
# renews the certificate, deploys it where kumod can read it, enables STARTTLS
# on the :587 submission listener in init.lua, installs the renewal deploy-hook,
# validates the policy, and restarts KumoMTA.
#
#   sudo bash enable-ssl.sh                 # auto-detects hostname, prompts email
#   sudo bash enable-ssl.sh smtp.example.com you@example.com
#
# Targets Rocky Linux 8/9 (EL8/EL9). KumoMTA supports STARTTLS only (no 465).
# =============================================================================
set -euo pipefail

KUMO_ETC="/opt/kumomta/etc"
POLICY_DIR="$KUMO_ETC/policy"
TLS_DIR="$KUMO_ETC/tls"
INIT_LUA="$POLICY_DIR/init.lua"
KUMO_USER="kumod"
KUMOD_BIN="/opt/kumomta/sbin/kumod"

if [[ -t 1 || -e /dev/tty ]]; then
  RED=$'\033[0;31m'; GRN=$'\033[0;32m'; YEL=$'\033[1;33m'; CYN=$'\033[0;36m'; NC=$'\033[0m'
else
  RED=""; GRN=""; YEL=""; CYN=""; NC=""
fi
info() { printf '  %b•%b %s\n' "$CYN" "$NC" "$*"; }
ok()   { printf '  %b✓%b %s\n' "$GRN" "$NC" "$*"; }
warn() { printf '  %b▲%b %s\n' "$YEL" "$NC" "$*"; }
die()  { printf '  %b✗%b %s\n' "$RED" "$NC" "$*"; exit 1; }

[[ $EUID -eq 0 ]] || die "Please run as root (sudo bash $0)"
[[ -x "$KUMOD_BIN" ]] || die "KumoMTA not found at $KUMOD_BIN -- run install.sh first."
[[ -f "$INIT_LUA"  ]] || die "Policy file not found at $INIT_LUA -- run install.sh first."

# --- hostname (cert CN) ---------------------------------------------------
FQDN="${1:-}"
if [[ -z "$FQDN" ]]; then
  FQDN="$(hostname -f 2>/dev/null || hostname 2>/dev/null || true)"
  read -r -p "  Hostname for the certificate [${FQDN}]: " _in </dev/tty || true
  FQDN="${_in:-$FQDN}"
fi
[[ "$FQDN" == *.*.* || "$FQDN" == *.* ]] || die "Refusing to use a non-FQDN hostname: '$FQDN'"

# --- contact email --------------------------------------------------------
LE_EMAIL="${2:-}"
if [[ -z "$LE_EMAIL" ]]; then
  read -r -p "  Email for Let's Encrypt (renewal notices) [postmaster@${FQDN#*.}]: " _em </dev/tty || true
  LE_EMAIL="${_em:-postmaster@${FQDN#*.}}"
fi
[[ "$LE_EMAIL" == *@* ]] || die "Invalid email: '$LE_EMAIL'"

echo
info "Hostname : $FQDN"
info "Email    : $LE_EMAIL"
echo

# --- ensure certbot is installed (EPEL) -----------------------------------
if ! command -v certbot >/dev/null 2>&1; then
  info "Installing certbot from EPEL..."
  dnf -y install epel-release >/dev/null 2>&1 || warn "Could not install epel-release."
  dnf -y install certbot >/dev/null 2>&1 || die "Failed to install certbot (enable EPEL and retry)."
  ok "certbot installed."
fi

# --- make sure inbound TCP/80 is open for the HTTP-01 challenge -----------
if systemctl is-active --quiet firewalld 2>/dev/null; then
  firewall-cmd --add-port=80/tcp >/dev/null 2>&1 || true
  firewall-cmd --permanent --add-port=80/tcp >/dev/null 2>&1 || true
  ok "Opened TCP/80 in firewalld."
fi
# Sanity-check that the public DNS name points here (best effort).
if command -v dig >/dev/null 2>&1; then
  resolved="$(dig +short A "$FQDN" 2>/dev/null | tr '\n' ' ')"
  [[ -n "$resolved" ]] && info "DNS: ${FQDN} -> ${resolved}" \
    || warn "No A record resolves for ${FQDN} yet -- certbot will fail until it does."
fi

# Free port 80 for the standalone challenge.
systemctl stop nginx httpd 2>/dev/null || true

# --- issue / renew the certificate ----------------------------------------
info "Requesting certificate (standalone HTTP-01 on port 80)..."
if ! certbot certonly --standalone --non-interactive --agree-tos \
      -m "$LE_EMAIL" -d "$FQDN" --preferred-challenges http --keep-until-expiring; then
  echo
  die "certbot failed. Almost always this means inbound TCP/80 cannot reach this
     host from the internet. Check your VPS provider's firewall / security group
     (allow 80), confirm ${FQDN} resolves to this server, then re-run this script."
fi
ok "Certificate available for ${FQDN}."

LIVE="/etc/letsencrypt/live/${FQDN}"
[[ -f "$LIVE/fullchain.pem" && -f "$LIVE/privkey.pem" ]] \
  || die "Expected certs not found under $LIVE"

# --- deploy where kumod can read them -------------------------------------
mkdir -p "$TLS_DIR"
cp "$LIVE/fullchain.pem" "$TLS_DIR/fullchain.pem"
cp "$LIVE/privkey.pem"  "$TLS_DIR/privkey.pem"
chown -R "$KUMO_USER:$KUMO_USER" "$TLS_DIR"
chmod 600 "$TLS_DIR/privkey.pem"
ok "Deployed certs to $TLS_DIR (owned by $KUMO_USER)."

# --- enable STARTTLS on the :587 listener in init.lua (idempotent) --------
if grep -q 'tls_certificate' "$INIT_LUA"; then
  ok "init.lua already references a TLS certificate -- leaving the policy as-is."
else
  cp -a "$INIT_LUA" "${INIT_LUA}.pre-ssl.$(date +%Y%m%d-%H%M%S)"
  # Insert the two tls_* lines right after the relay_hosts line that belongs to
  # the 0.0.0.0:587 submission listener (NOT the :25 listener).
  awk -v cert="$TLS_DIR/fullchain.pem" -v key="$TLS_DIR/privkey.pem" '
    /listen[[:space:]]*=[[:space:]]*.0\.0\.0\.0:587./ { in587=1 }
    { print }
    in587 && /relay_hosts/ {
      print "    tls_certificate = \x27" cert "\x27,"
      print "    tls_private_key = \x27" key "\x27,"
      in587=0
    }
  ' "$INIT_LUA" > "${INIT_LUA}.tmp"
  if grep -q 'tls_certificate' "${INIT_LUA}.tmp"; then
    mv "${INIT_LUA}.tmp" "$INIT_LUA"
    chown "$KUMO_USER:$KUMO_USER" "$INIT_LUA"
    ok "Enabled STARTTLS on the :587 listener in init.lua."
  else
    rm -f "${INIT_LUA}.tmp"
    warn "Could not auto-edit init.lua (unexpected layout). Add these lines to the"
    warn "0.0.0.0:587 listener block manually, then restart kumomta:"
    echo "      tls_certificate = '${TLS_DIR}/fullchain.pem',"
    echo "      tls_private_key = '${TLS_DIR}/privkey.pem',"
  fi
fi

# --- renewal deploy-hook (auto-redeploy + reload on renew) ----------------
mkdir -p /etc/letsencrypt/renewal-hooks/deploy
cat >/etc/letsencrypt/renewal-hooks/deploy/10-kumomta.sh <<EOF
#!/bin/sh
cp /etc/letsencrypt/live/${FQDN}/fullchain.pem ${TLS_DIR}/fullchain.pem
cp /etc/letsencrypt/live/${FQDN}/privkey.pem  ${TLS_DIR}/privkey.pem
chown -R ${KUMO_USER}:${KUMO_USER} ${TLS_DIR}
chmod 600 ${TLS_DIR}/privkey.pem
systemctl restart kumomta
EOF
chmod +x /etc/letsencrypt/renewal-hooks/deploy/10-kumomta.sh
ok "Installed certbot renewal deploy-hook (auto-reloads KumoMTA)."

# --- validate + restart ---------------------------------------------------
info "Validating policy..."
if runuser -u "$KUMO_USER" -- "$KUMOD_BIN" --policy "$INIT_LUA" --validate; then
  ok "Policy validated."
else
  die "Policy validation FAILED -- a backup of init.lua was saved next to it (.pre-ssl.*)."
fi

systemctl restart kumomta
sleep 2
if systemctl is-active --quiet kumomta; then
  ok "KumoMTA restarted with TLS enabled."
else
  die "KumoMTA failed to start. Check: journalctl -u kumomta -n 50"
fi

echo
ok "SSL is now active. Submit on port 587 with STARTTLS:"
echo "      Host: ${FQDN}   Port: 587   Encryption: STARTTLS"
