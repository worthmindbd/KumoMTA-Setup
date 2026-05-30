#!/usr/bin/env bash
# =============================================================================
# KumoMTA interactive installer  (Ubuntu 22.04 LTS)
# -----------------------------------------------------------------------------
# Guided setup: system checks -> interactive config -> install KumoMTA ->
# SSL (Let's Encrypt) -> DKIM -> policy generation -> validate -> start.
# At the end it prints (and saves) ALL DNS entries and SMTP credentials.
#
#   sudo bash scripts/install.sh
#
# Re-runnable: existing config is backed up before being overwritten.
# =============================================================================
set -euo pipefail

# ----------------------------------------------------------------------------
# Tunable repo locations (verify against https://docs.kumomta.com if install
# fails -- these are the current official endpoints).
# ----------------------------------------------------------------------------
KUMO_GPG_URL="https://openrepo.kumomta.com/public.gpg"
KUMO_LIST_URL="https://openrepo.kumomta.com/files/kumomta-ubuntu22.list"
KUMO_KEYRING="/usr/share/keyrings/kumomta.gpg"

KUMO_ETC="/opt/kumomta/etc"
POLICY_DIR="$KUMO_ETC/policy"
DKIM_DIR="$KUMO_ETC/dkim"
TLS_DIR="$KUMO_ETC/tls"
SECRETS_ENV="$KUMO_ETC/secrets.env"
SPOOL_DIR="/var/spool/kumomta"
LOG_DIR="/var/log/kumomta"
SUMMARY_FILE="/root/kumomta-install-summary.txt"
INSTALL_LOG="/var/log/kumomta-install.log"
KUMO_USER="kumod"

# ----------------------------------------------------------------------------
# Styling / logging helpers
# ----------------------------------------------------------------------------
if [[ -t 1 ]]; then
  RED=$'\033[0;31m'; GRN=$'\033[0;32m'; YEL=$'\033[1;33m'
  BLU=$'\033[0;36m'; BLD=$'\033[1m'; NC=$'\033[0m'
else
  RED=""; GRN=""; YEL=""; BLU=""; BLD=""; NC=""
fi
info()   { echo "${BLU}[*]${NC} $*"; }
ok()     { echo "${GRN}[OK]${NC} $*"; }
warn()   { echo "${YEL}[!]${NC} $*"; }
err()    { echo "${RED}[X]${NC} $*" >&2; }
header() { echo; echo "${BLD}============================================================${NC}"; echo "${BLD} $*${NC}"; echo "${BLD}============================================================${NC}"; }
die()    { err "$*"; exit 1; }

# ask "Prompt" "default"  ->  echoes the chosen value (prompt goes to stderr)
ask() {
  local prompt="$1" default="${2:-}" reply
  if [[ -n "$default" ]]; then
    read -rp "$(printf '%s [%s]: ' "$prompt" "$default")" reply
    echo "${reply:-$default}"
  else
    read -rp "$(printf '%s: ' "$prompt")" reply
    echo "$reply"
  fi
}

# confirm "Question" "Y|N"  ->  returns 0 for yes, 1 for no
confirm() {
  local q="$1" def="${2:-Y}" reply hint
  case "$def" in Y|y) hint="Y/n";; *) hint="y/N";; esac
  read -rp "$(printf '%s [%s]: ' "$q" "$hint")" reply
  reply="${reply:-$def}"
  [[ "$reply" =~ ^[Yy] ]]
}

# gen_password  ->  strong alnum password without relying on openssl being present yet
gen_password() {
  if command -v openssl >/dev/null 2>&1; then
    openssl rand -base64 24 | tr -dc 'A-Za-z0-9' | cut -c1-24
  else
    LC_ALL=C tr -dc 'A-Za-z0-9' </dev/urandom | head -c 24
  fi
}

# ask_secret "Prompt"  ->  reads silently, echoes value
ask_secret() {
  local prompt="$1" reply
  read -rsp "$(printf '%s: ' "$prompt")" reply; echo >&2
  echo "$reply"
}

# ask_num "Prompt" "default"  ->  echoes a validated positive integer
ask_num() {
  local prompt="$1" default="${2:-}" reply
  while :; do
    reply=$(ask "$prompt" "$default")
    if [[ "$reply" =~ ^[1-9][0-9]*$ ]]; then echo "$reply"; return 0; fi
    warn "Please enter a positive whole number." >&2
  done
}

# ----------------------------------------------------------------------------
# Global state (filled in by gather_inputs)
# ----------------------------------------------------------------------------
MAIN_DOMAIN=""; PRIMARY_FQDN=""
declare -a IPS=() SUBS=() FQDNS=()
SMTP_USER=""; SMTP_PASS=""
DAILY_LIMIT=""; PER_IP_HOURLY=""; WARMUP="N"; START_RATE=""
LE_EMAIL=""; SETUP_SSL="Y"
DKIM_SELECTOR="default"; DKIM_MODE="new"; DKIM_EXISTING_PATH=""
DMARC_RUA=""; SETUP_FW="Y"

# ============================================================================
# 1. PREFLIGHT CHECKS
# ============================================================================
require_root() { [[ $EUID -eq 0 ]] || die "Please run as root (sudo bash $0)"; }

check_os() {
  header "System requirement checks"
  if [[ -r /etc/os-release ]]; then . /etc/os-release; fi
  if [[ "${ID:-}" == "ubuntu" && "${VERSION_ID:-}" == "22.04" ]]; then
    ok "OS: Ubuntu 22.04 LTS"
  else
    warn "OS is ${PRETTY_NAME:-unknown} -- this script targets Ubuntu 22.04. Continuing anyway."
  fi
}

check_resources() {
  local cores ram_mb disk_gb
  cores=$(nproc)
  ram_mb=$(free -m | awk '/^Mem:/{print $2}')
  disk_gb=$(df -BG --output=avail / | tail -1 | tr -dc '0-9')

  if (( cores >= 4 )); then ok "CPU cores: $cores"; else warn "CPU cores: $cores (KumoMTA recommends >= 4 for production)"; fi
  if (( ram_mb >= 4000 )); then ok "RAM: ${ram_mb} MB"; else warn "RAM: ${ram_mb} MB (>= 4 GB recommended)"; fi
  if (( disk_gb >= 20 )); then ok "Free disk on /: ${disk_gb} GB"; else warn "Free disk on /: ${disk_gb} GB (low for spool+logs)"; fi
}

check_port25_outbound() {
  info "Testing OUTBOUND port 25 (needed to deliver mail)..."
  if timeout 6 bash -c 'exec 3<>/dev/tcp/gmail-smtp-in.l.google.com/25' 2>/dev/null; then
    exec 3>&- 2>/dev/null || true
    ok "Outbound port 25 is open."
  else
    warn "Outbound port 25 appears BLOCKED or filtered."
    warn "Open a ticket with your VPS provider (RackNerd) to unblock it,"
    warn "otherwise remote delivery will fail with connection timeouts."
  fi
}

check_conflicts() {
  local svc found=0
  for svc in postfix sendmail exim4 opensmtpd; do
    if systemctl is-active --quiet "$svc" 2>/dev/null; then
      warn "Conflicting MTA running: $svc (it likely holds port 25)."
      found=1
      if confirm "Stop and disable $svc?" "Y"; then
        systemctl stop "$svc" || true
        systemctl disable "$svc" || true
        ok "Disabled $svc."
      fi
    fi
  done
  (( found == 0 )) && ok "No conflicting MTA detected."
}

detect_ips() {
  mapfile -t DETECTED < <(ip -4 -o addr show scope global | awk '{print $4}' | cut -d/ -f1)
  (( ${#DETECTED[@]} > 0 )) || die "No global IPv4 addresses detected."
  ok "Detected ${#DETECTED[@]} IPv4 address(es): ${DETECTED[*]}"
  # IPv6 awareness
  if ip -6 -o addr show scope global 2>/dev/null | grep -q inet6; then
    info "IPv6 is present, but this installer configures IPv4 sending only"
    info "(stricter provider rules for IPv6 -> not recommended without dedicated PTR)."
  else
    info "No global IPv6 detected -> IPv4-only setup (recommended here)."
  fi
}

# ============================================================================
# 2. INTERACTIVE CONFIGURATION
# ============================================================================
valid_domain() { [[ "$1" =~ ^[a-zA-Z0-9.-]+\.[a-zA-Z]{2,}$ ]]; }

gather_inputs() {
  header "Configuration"

  while :; do
    MAIN_DOMAIN=$(ask "Main sending domain (From: domain)" "")
    valid_domain "$MAIN_DOMAIN" && break || warn "Enter a valid domain, e.g. example.com"
  done

  # --- select sending IPs ---
  echo; info "Available IPv4 addresses:"
  local i
  for i in "${!DETECTED[@]}"; do printf '   [%d] %s\n' "$i" "${DETECTED[$i]}"; done
  local sel
  sel=$(ask "IP indexes to use for sending (space separated, or 'all')" "all")
  if [[ "$sel" == "all" ]]; then
    IPS=("${DETECTED[@]}")
  else
    IPS=()
    for i in $sel; do [[ -n "${DETECTED[$i]:-}" ]] && IPS+=("${DETECTED[$i]}"); done
  fi
  (( ${#IPS[@]} > 0 )) || die "No IPs selected."

  # --- subdomain naming ---
  echo
  info "HELO/PTR subdomain for each IP (primary -> 'smtp', others -> mta1, mta2, ...)."
  local auto
  if confirm "Auto-generate subdomain names (smtp, mta1, mta2, ...)?" "Y"; then auto="Y"; else auto="N"; fi
  SUBS=(); FQDNS=()
  for i in "${!IPS[@]}"; do
    local default_sub
    if (( i == 0 )); then default_sub="smtp"; else default_sub="mta$i"; fi
    local sub
    if [[ "$auto" == "Y" ]]; then sub="$default_sub"; else sub=$(ask "  Subdomain for ${IPS[$i]}" "$default_sub"); fi
    SUBS+=("$sub")
    FQDNS+=("${sub}.${MAIN_DOMAIN}")
  done
  PRIMARY_FQDN="${FQDNS[0]}"

  # --- SMTP auth credentials ---
  echo
  SMTP_USER=$(ask "SMTP AUTH username (for MailWizz/Listmonk injection)" "news@${MAIN_DOMAIN}")
  if confirm "Auto-generate a strong SMTP password?" "Y"; then
    SMTP_PASS=$(gen_password)
    ok "Generated SMTP password."
  else
    while :; do
      SMTP_PASS=$(ask_secret "Enter SMTP password (min 12 chars)")
      (( ${#SMTP_PASS} >= 12 )) && break || warn "Too short."
    done
  fi

  # --- volume / rate / warmup ---
  echo
  info "Sending volume & rate (best-practice guidance)."
  DAILY_LIMIT=$(ask_num "Target TOTAL daily send volume (all IPs)" "50000")
  local per_ip_day cap8h
  per_ip_day=$(( DAILY_LIMIT / ${#IPS[@]} ))
  cap8h=$(( per_ip_day / 8 + 1 ))
  info "  ${#IPS[@]} IP(s) -> ~${per_ip_day}/day per IP (~${cap8h}/h if sent over 8h)."
  info "  NOTE: the rate below is a PER-IP, PER-PROVIDER hourly cap (how KumoMTA"
  info "        shaping works), not a single global daily counter."
  PER_IP_HOURLY=$(ask_num "Per-IP, per-provider hourly cap" "2500")

  if confirm "Enable WARMUP mode (start with a low rate and ramp up manually)?" "N"; then
    WARMUP="Y"
    START_RATE=$(ask_num "  Warmup STARTING per-IP/hr rate" "200")
  fi

  # --- DKIM ---
  echo
  DKIM_SELECTOR=$(ask "DKIM selector" "default")
  if confirm "Re-use an EXISTING DKIM private key (e.g. migrated from PowerMTA)?" "N"; then
    DKIM_MODE="existing"
    while :; do
      DKIM_EXISTING_PATH=$(ask "  Path to existing DKIM private key (.pem/.key)")
      [[ -r "$DKIM_EXISTING_PATH" ]] && break || warn "File not readable: $DKIM_EXISTING_PATH"
    done
  else
    DKIM_MODE="new"
  fi

  # --- SSL ---
  echo
  if confirm "Obtain a Let's Encrypt TLS certificate for ${PRIMARY_FQDN}?" "Y"; then
    SETUP_SSL="Y"
    while :; do
      LE_EMAIL=$(ask "  Email for Let's Encrypt (renewal notices)" "postmaster@${MAIN_DOMAIN}")
      [[ "$LE_EMAIL" == *@* ]] && break || warn "Enter a valid email."
    done
  else
    SETUP_SSL="N"
    warn "Skipping SSL -- you must configure tls_certificate/tls_private_key yourself."
  fi

  # --- DMARC + firewall ---
  echo
  DMARC_RUA=$(ask "DMARC aggregate-report email (rua)" "dmarc@${MAIN_DOMAIN}")
  if confirm "Configure UFW firewall (allow SSH, 25, 80, 443, 587, 465)?" "Y"; then SETUP_FW="Y"; else SETUP_FW="N"; fi
}

confirm_summary() {
  header "Review configuration"
  echo "  Main domain        : $MAIN_DOMAIN"
  echo "  Primary hostname   : $PRIMARY_FQDN"
  echo "  Sending IPs / HELO :"
  local i
  for i in "${!IPS[@]}"; do printf '     %-16s -> %s\n' "${IPS[$i]}" "${FQDNS[$i]}"; done
  echo "  SMTP username      : $SMTP_USER"
  echo "  SMTP password      : (hidden, shown in final summary)"
  echo "  Daily volume target: $DAILY_LIMIT"
  echo "  Per-IP/provider cap: ${PER_IP_HOURLY}/hr"
  echo "  Warmup mode        : $WARMUP${WARMUP:+ (start ${START_RATE:-}/hr)}"
  echo "  DKIM selector      : $DKIM_SELECTOR ($DKIM_MODE key)"
  echo "  Let's Encrypt SSL  : $SETUP_SSL"
  echo "  DMARC rua          : $DMARC_RUA"
  echo "  Configure firewall : $SETUP_FW"
  echo
  confirm "Proceed with installation?" "Y" || die "Aborted by user."
}

# ============================================================================
# 3. INSTALL + OS PREP
# ============================================================================
install_dependencies() {
  header "Installing dependencies"
  export DEBIAN_FRONTEND=noninteractive
  apt-get update -y
  apt-get install -y --no-install-recommends curl gnupg ca-certificates openssl ufw dnsutils
  ok "Base packages installed."
}

install_kumomta() {
  header "Installing KumoMTA"
  if command -v kumod >/dev/null 2>&1 || [[ -x /opt/kumomta/sbin/kumod ]]; then
    ok "KumoMTA already installed -- skipping repo setup."
    return
  fi
  curl -fsSL "$KUMO_GPG_URL" | gpg --yes --dearmor -o "$KUMO_KEYRING"
  curl -fsSL "$KUMO_LIST_URL" | tee /etc/apt/sources.list.d/kumomta.list >/dev/null
  apt-get update -y
  apt-get install -y kumomta
  ok "KumoMTA package installed."
}

system_prep() {
  header "OS tuning"
  hostnamectl set-hostname "$PRIMARY_FQDN"
  grep -q "$PRIMARY_FQDN" /etc/hosts 2>/dev/null || \
    echo "127.0.1.1 ${PRIMARY_FQDN} ${SUBS[0]}" >> /etc/hosts

  cat >/etc/sysctl.d/99-kumomta.conf <<'EOF'
fs.file-max = 250000
net.ipv4.tcp_tw_reuse = 1
net.core.somaxconn = 1024
net.ipv4.ip_local_port_range = 10000 65535
EOF
  sysctl --system >/dev/null
  ok "sysctl tuning applied."

  mkdir -p "$SPOOL_DIR/data" "$SPOOL_DIR/meta" "$LOG_DIR" "$POLICY_DIR" "$DKIM_DIR" "$TLS_DIR"
  ok "Directories created."
}

# ============================================================================
# 4. DNS PREVIEW  (must exist before SSL)
# ============================================================================
build_spf() {
  local spf="v=spf1"; local ip
  for ip in "${IPS[@]}"; do spf+=" ip4:$ip"; done
  echo "$spf -all"
}

print_dns_preview() {
  header "DNS entries to create NOW (before SSL issuance)"
  echo "Create these A records at your DNS provider, then set PTR (rDNS) at your VPS host:"
  echo
  printf '  %-28s %-6s %s\n' "NAME" "TYPE" "VALUE"
  local i
  for i in "${!IPS[@]}"; do
    printf '  %-28s %-6s %s\n' "${FQDNS[$i]}." "A" "${IPS[$i]}"
  done
  echo
  echo "PTR / reverse DNS (set these in your VPS provider panel):"
  for i in "${!IPS[@]}"; do
    printf '  %-16s PTR -> %s\n' "${IPS[$i]}" "${FQDNS[$i]}"
  done
  echo
  warn "Port 80 must be reachable and ${PRIMARY_FQDN} must resolve to this server for SSL."
}

wait_for_dns() {
  [[ "$SETUP_SSL" == "Y" ]] || return 0
  echo
  while :; do
    local resolved
    resolved=$(getent hosts "$PRIMARY_FQDN" | awk '{print $1}' | head -1 || true)
    if [[ -n "$resolved" ]]; then
      ok "${PRIMARY_FQDN} resolves to ${resolved}."
      [[ " ${IPS[*]} " == *" $resolved "* ]] || warn "...but that IP is not in your sending set. Continue only if intentional."
      break
    fi
    warn "${PRIMARY_FQDN} does not resolve yet."
    confirm "Re-check DNS now? (No = skip SSL)" "Y" || { SETUP_SSL="N"; warn "Skipping SSL."; return 0; }
  done
}

# ============================================================================
# 5. SSL  (Let's Encrypt via certbot standalone)
# ============================================================================
setup_ssl() {
  [[ "$SETUP_SSL" == "Y" ]] || return 0
  header "SSL certificate (Let's Encrypt)"
  apt-get install -y certbot

  # Free port 80 for standalone challenge if a web server is running.
  systemctl stop nginx apache2 2>/dev/null || true

  if certbot certonly --standalone --non-interactive --agree-tos \
      -m "$LE_EMAIL" -d "$PRIMARY_FQDN" --preferred-challenges http; then
    ok "Certificate issued for ${PRIMARY_FQDN}."
  else
    warn "certbot failed. Continuing WITHOUT SSL; fix DNS/port 80 and re-run certbot later."
    SETUP_SSL="N"
    return 0
  fi

  deploy_certs   # copy into kumod-readable location
  install_cert_renew_hook
}

deploy_certs() {
  local live="/etc/letsencrypt/live/${PRIMARY_FQDN}"
  cp "$live/fullchain.pem" "$TLS_DIR/fullchain.pem"
  cp "$live/privkey.pem"  "$TLS_DIR/privkey.pem"
  chown -R "$KUMO_USER:$KUMO_USER" "$TLS_DIR"
  chmod 600 "$TLS_DIR/privkey.pem"
  ok "Certs copied to $TLS_DIR (readable by $KUMO_USER)."
}

install_cert_renew_hook() {
  mkdir -p /etc/letsencrypt/renewal-hooks/deploy
  cat >/etc/letsencrypt/renewal-hooks/deploy/10-kumomta.sh <<EOF
#!/bin/sh
cp /etc/letsencrypt/live/${PRIMARY_FQDN}/fullchain.pem ${TLS_DIR}/fullchain.pem
cp /etc/letsencrypt/live/${PRIMARY_FQDN}/privkey.pem  ${TLS_DIR}/privkey.pem
chown -R ${KUMO_USER}:${KUMO_USER} ${TLS_DIR}
chmod 600 ${TLS_DIR}/privkey.pem
systemctl restart kumomta
EOF
  chmod +x /etc/letsencrypt/renewal-hooks/deploy/10-kumomta.sh
  ok "Renewal deploy-hook installed (auto-reloads KumoMTA)."
}

# ============================================================================
# 6. DKIM
# ============================================================================
DKIM_RECORD=""
setup_dkim() {
  header "DKIM signing key"
  local keydir="$DKIM_DIR/$MAIN_DOMAIN"
  local keyfile="$keydir/$DKIM_SELECTOR.key"
  mkdir -p "$keydir"

  if [[ "$DKIM_MODE" == "existing" ]]; then
    cp "$DKIM_EXISTING_PATH" "$keyfile"
    ok "Re-used existing DKIM key -> $keyfile"
    warn "Keep the matching public key published at ${DKIM_SELECTOR}._domainkey.${MAIN_DOMAIN}."
    DKIM_RECORD="(unchanged -- keep your existing published record)"
  else
    openssl genrsa -out "$keyfile" 2048 2>/dev/null
    local tmp pub
    tmp=$(mktemp)
    openssl rsa -in "$keyfile" -pubout -out "$tmp" 2>/dev/null
    pub=$(grep -v '^-----' "$tmp" | tr -d '\n')
    rm -f "$tmp"
    DKIM_RECORD="v=DKIM1; k=rsa; p=${pub}"
    ok "Generated 2048-bit DKIM key -> $keyfile"
  fi
  chown -R "$KUMO_USER:$KUMO_USER" "$DKIM_DIR"
  chmod 600 "$keyfile"
}

# ============================================================================
# 7. POLICY GENERATION
# ============================================================================
backup_existing() {
  if [[ -f "$POLICY_DIR/init.lua" ]]; then
    local bk="$POLICY_DIR/backup-$(date +%Y%m%d-%H%M%S)"
    mkdir -p "$bk"; cp -a "$POLICY_DIR"/*.toml "$POLICY_DIR"/init.lua "$bk"/ 2>/dev/null || true
    ok "Backed up existing policy to $bk"
  fi
}

write_sources_toml() {
  local f="$POLICY_DIR/sources.toml" i
  {
    echo "# Generated by install.sh -- egress sources (one per sending IP) + pool"
    for i in "${!IPS[@]}"; do
      echo
      echo "[source.\"ip-$((i+1))\"]"
      echo "source_address = \"${IPS[$i]}\""
      echo "ehlo_domain = \"${FQDNS[$i]}\""
    done
    echo
    for i in "${!IPS[@]}"; do
      echo "[pool.\"send-pool\".\"ip-$((i+1))\"]"
      echo "weight = 1"
    done
  } > "$f"
  ok "Wrote $f"
}

write_dkim_toml() {
  local f="$POLICY_DIR/dkim_data.toml"
  cat > "$f" <<EOF
# Generated by install.sh
[base]
selector = "${DKIM_SELECTOR}"
algo = "sha256"
header_canonicalization = "Relaxed"
body_canonicalization = "Relaxed"
headers = ["From", "To", "Subject", "Date", "MIME-Version", "Content-Type", "Message-ID"]

[domain."${MAIN_DOMAIN}"]
selector = "${DKIM_SELECTOR}"
# key path convention: ${DKIM_DIR}/${MAIN_DOMAIN}/${DKIM_SELECTOR}.key
EOF
  ok "Wrote $f"
}

write_shaping_toml() {
  local f="$POLICY_DIR/shaping.toml"
  local rate="${PER_IP_HOURLY}/hr"
  local default_rate="$rate"
  [[ "$WARMUP" == "Y" ]] && default_rate="${START_RATE}/hr"
  {
    echo "# Generated by install.sh -- overrides layered on the community baseline."
    [[ "$WARMUP" == "Y" ]] && echo "# WARMUP MODE: default starts low; raise toward ${rate} as reputation builds."
    echo
    echo "[\"default\"]"
    echo "max_message_rate = \"${default_rate}\""
    echo "connection_limit = 10"
    echo
    local d
    for d in gmail.com yahoo.com outlook.com; do
      echo "[\"$d\"]"
      echo "connection_limit = 5"
      echo "max_message_rate = \"${default_rate}\""
      echo
    done
  } > "$f"
  ok "Wrote $f"
}

write_queues_toml() {
  local f="$POLICY_DIR/queues.toml"
  cat > "$f" <<EOF
# Generated by install.sh
[queue.default]
egress_pool = "send-pool"
max_age = "1d"
EOF
  ok "Wrote $f"
}

write_listener_domains_toml() {
  local f="$POLICY_DIR/listener_domains.toml"
  cat > "$f" <<EOF
# Generated by install.sh -- inbound OOB bounce / FBL handling, no open relay
["${MAIN_DOMAIN}"]
log_oob = true
log_arf = true
relay_to = false
EOF
  ok "Wrote $f"
}

write_secrets() {
  install -m 600 /dev/null "$SECRETS_ENV"
  echo "SMTP_NEWS_PASSWORD=${SMTP_PASS}" > "$SECRETS_ENV"
  chown "$KUMO_USER:$KUMO_USER" "$SECRETS_ENV"
  mkdir -p /etc/systemd/system/kumomta.service.d
  cat >/etc/systemd/system/kumomta.service.d/override.conf <<EOF
[Service]
EnvironmentFile=${SECRETS_ENV}
LimitNOFILE=256000
EOF
  systemctl daemon-reload
  ok "SMTP password stored in $SECRETS_ENV (600) and wired via systemd."
}

write_init_lua() {
  local f="$POLICY_DIR/init.lua"
  local tls_block=""
  if [[ "$SETUP_SSL" == "Y" ]]; then
    tls_block="    tls_certificate = '${TLS_DIR}/fullchain.pem',
    tls_private_key = '${TLS_DIR}/privkey.pem',"
  fi
  cat > "$f" <<EOF
-- Generated by install.sh -- KumoMTA main policy
-- Validate:  sudo -u ${KUMO_USER} /opt/kumomta/sbin/kumod --policy ${f} --validate
local kumo = require 'kumo'
local sources = require 'policy-extras.sources'
local dkim_sign = require 'policy-extras.dkim_sign'
local shaping = require 'policy-extras.shaping'
local listener_domains = require 'policy-extras.listener_domains'
local queue_module = require 'policy-extras.queue'

sources:setup { '${POLICY_DIR}/sources.toml' }
local dkim_signer = dkim_sign:setup { '${POLICY_DIR}/dkim_data.toml' }
local shaper = shaping:setup { '${POLICY_DIR}/shaping.toml' }
local queue_helper = queue_module:setup { '${POLICY_DIR}/queues.toml' }

kumo.on('init', function()
  kumo.define_spool { name = 'data', path = '${SPOOL_DIR}/data', kind = 'RocksDB' }
  kumo.define_spool { name = 'meta', path = '${SPOOL_DIR}/meta', kind = 'RocksDB' }
  kumo.configure_local_logs { log_dir = '${LOG_DIR}' }

  kumo.start_esmtp_listener {
    listen = '0.0.0.0:25',
    hostname = '${PRIMARY_FQDN}',
    relay_hosts = { '127.0.0.1', '::1' },
  }

  kumo.start_esmtp_listener {
    listen = '0.0.0.0:587',
    hostname = '${PRIMARY_FQDN}',
    relay_hosts = { '127.0.0.1' },
${tls_block}
  }

  kumo.start_http_listener {
    listen = '127.0.0.1:8000',
    trusted_hosts = { '127.0.0.1', '::1' },
  }
end)

kumo.on('smtp_server_auth_plain', function(authcred, conn_meta)
  return authcred.username == '${SMTP_USER}'
    and authcred.password == os.getenv('SMTP_NEWS_PASSWORD')
end)

kumo.on('get_listener_domain',
  listener_domains:setup { '${POLICY_DIR}/listener_domains.toml' })

kumo.on('smtp_server_message_received', function(msg)
  queue_helper:apply(msg)
  dkim_signer(msg)
end)

kumo.on('http_message_generated', function(msg)
  queue_helper:apply(msg)
  dkim_signer(msg)
end)
EOF
  ok "Wrote $f"
}

write_all_configs() {
  header "Generating KumoMTA policy"
  backup_existing
  write_sources_toml
  write_dkim_toml
  write_shaping_toml
  write_queues_toml
  write_listener_domains_toml
  write_secrets
  write_init_lua
  chown -R "$KUMO_USER:$KUMO_USER" "$POLICY_DIR" "$SPOOL_DIR" "$LOG_DIR"
}

# ============================================================================
# 8. VALIDATE + START
# ============================================================================
validate_and_start() {
  header "Validating & starting KumoMTA"
  if sudo -u "$KUMO_USER" /opt/kumomta/sbin/kumod --policy "$POLICY_DIR/init.lua" --validate; then
    ok "Policy validated."
  else
    die "Policy validation FAILED. Review $POLICY_DIR/init.lua (compare with the shipped example policy)."
  fi
  systemctl enable kumomta >/dev/null 2>&1 || true
  systemctl restart kumomta
  sleep 2
  if systemctl is-active --quiet kumomta; then ok "KumoMTA is running."; else
    err "KumoMTA failed to start. Check: journalctl -u kumomta -n 50"
  fi
}

setup_firewall() {
  [[ "$SETUP_FW" == "Y" ]] || return 0
  header "Firewall (UFW)"
  ufw allow OpenSSH >/dev/null 2>&1 || ufw allow 22/tcp >/dev/null
  ufw allow 25/tcp  >/dev/null
  ufw allow 80/tcp  >/dev/null
  ufw allow 443/tcp >/dev/null
  ufw allow 587/tcp >/dev/null
  ufw allow 465/tcp >/dev/null
  yes | ufw enable >/dev/null 2>&1 || true
  ok "UFW configured (SSH, 25, 80, 443, 587, 465 allowed)."
}

# ============================================================================
# 9. FINAL OUTPUT
# ============================================================================
print_summary() {
  local spf; spf=$(build_spf)
  {
    echo "============================================================"
    echo " KumoMTA install summary  ($(date))"
    echo "============================================================"
    echo
    echo "## DNS RECORDS (create at your DNS provider)"
    echo
    printf '%-32s %-6s %s\n' "NAME" "TYPE" "VALUE"
    local i
    for i in "${!IPS[@]}"; do
      printf '%-32s %-6s %s\n' "${FQDNS[$i]}." "A" "${IPS[$i]}"
    done
    echo
    printf '%-32s %-6s %s\n' "${MAIN_DOMAIN}." "TXT" "${spf}"
    printf '%-32s %-6s %s\n' "${DKIM_SELECTOR}._domainkey.${MAIN_DOMAIN}." "TXT" "${DKIM_RECORD}"
    printf '%-32s %-6s %s\n' "_dmarc.${MAIN_DOMAIN}." "TXT" "v=DMARC1; p=none; rua=mailto:${DMARC_RUA}; fo=1"
    printf '%-32s %-6s %s\n' "${MAIN_DOMAIN}." "MX" "10 ${PRIMARY_FQDN}.   (optional: receive OOB bounces)"
    echo
    echo "## PTR / REVERSE DNS  (set at your VPS provider -- must match):"
    for i in "${!IPS[@]}"; do
      printf '  %-16s -> %s\n' "${IPS[$i]}" "${FQDNS[$i]}"
    done
    echo
    echo "## SMTP CREDENTIALS (for MailWizz / Listmonk)"
    echo "  Server / Host : ${PRIMARY_FQDN}"
    if [[ "$SETUP_SSL" == "Y" ]]; then
      echo "  Port          : 587  (STARTTLS)   |  also try 465 if your version supports implicit TLS"
      echo "  Encryption    : STARTTLS / TLS"
    else
      echo "  Port          : 587  (configure TLS before production!)"
      echo "  Encryption    : (none yet -- SSL was skipped)"
    fi
    echo "  Username      : ${SMTP_USER}"
    echo "  Password      : ${SMTP_PASS}"
    echo
    echo "## SENDING PROFILE"
    echo "  IPs in pool   : ${#IPS[@]}"
    echo "  Per-IP/provider hourly cap : ${PER_IP_HOURLY}/hr"
    [[ "$WARMUP" == "Y" ]] && echo "  Warmup        : starting at ${START_RATE}/hr -- raise gradually in shaping.toml"
    echo "  Daily target  : ${DAILY_LIMIT}"
    echo
    echo "## NEXT STEPS"
    echo "  1. Confirm all PTR records match the A records above."
    echo "  2. Send a test mail; verify SPF/DKIM/DMARC pass (e.g. mail-tester)."
    echo "  3. Watch logs:  journalctl -u kumomta -f   and   ${LOG_DIR}/"
    [[ "$DKIM_MODE" == "new" ]] && echo "  4. DKIM TXT records can be long; some DNS panels need them split into 255-char chunks."
    echo "============================================================"
  } | tee "$SUMMARY_FILE"
  chmod 600 "$SUMMARY_FILE"
  echo
  ok "Summary saved to $SUMMARY_FILE (root-only)."
}

# ============================================================================
# MAIN
# ============================================================================
main() {
  header "KumoMTA interactive installer"
  require_root
  check_os
  check_resources
  detect_ips
  check_port25_outbound
  check_conflicts
  gather_inputs
  confirm_summary
  # Start logging the (non-interactive) installation phase to a file as well.
  exec > >(tee -a "$INSTALL_LOG") 2>&1
  install_dependencies
  install_kumomta
  system_prep
  print_dns_preview
  wait_for_dns
  setup_ssl
  setup_dkim
  write_all_configs
  validate_and_start
  setup_firewall
  print_summary
  header "Done."
}

main "$@"
