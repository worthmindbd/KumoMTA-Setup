#!/usr/bin/env bash
# =============================================================================
# KumoMTA clean-install setup  (Rocky Linux 8 / 9)
# -----------------------------------------------------------------------------
# Interactive installer for a FRESH KumoMTA outbound sending server.
# Guided setup: system checks -> interactive config -> install KumoMTA ->
# SSL (Let's Encrypt) -> DKIM -> policy generation -> validate -> start.
# At the end it prints (and saves) ALL DNS entries and SMTP credentials.
#
# Targets Rocky Linux 8 and 9 (and binary-compatible EL8/EL9 rebuilds such as
# AlmaLinux / RHEL / CentOS Stream). KumoMTA officially recommends Rocky Linux.
#
# PREREQUISITES (see README.md):
#   * A records for each IP's hostname (smtp, mta1, mta2, ...) ALREADY created
#   * PTR / reverse DNS for each IP set at your VPS provider
#   * Ports 25 and 587 (plus 80 for SSL) open / unblocked by your provider
#     (KumoMTA uses STARTTLS only -- no implicit-TLS/465 listener)
#
#   sudo bash install.sh
#
# Re-runnable: existing config is backed up before being overwritten.
# =============================================================================
set -euo pipefail

# ----------------------------------------------------------------------------
# Official KumoMTA dnf/yum repo definition (Rocky Linux 8/9).
# Verified against https://docs.kumomta.com/userguide/installation/linux/
# The .repo file uses $releasever, so the same file works on EL8 and EL9.
# It defines two repos: "kumomta-stable" (the kumomta package, what we install)
# and "kumomta-dev" (the kumomta-dev package, pre-release/testing only).
# ----------------------------------------------------------------------------
KUMO_REPO_URL="https://openrepo.kumomta.com/files/kumomta-rocky.repo"
KUMO_REPO_FILE="/etc/yum.repos.d/kumomta.repo"
# Base of the stable RPM repo (used only by the direct-.rpm fallback). The
# ${rhel} placeholder is filled in at runtime from `rpm -E %rhel`.
KUMO_PKG_BASE_TMPL="https://pkgs.kumomta.com/kumomta-rockylinux-%s-stable"

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

# Filled in by check_os(): the EL major version (8 or 9).
EL_VER=""

# ----------------------------------------------------------------------------
# Styling + terminal-safe IO
#
# Value-returning helpers (ask/ask_num/ask_secret) run inside $( ... ), which
# captures stdout. So ALL human-facing UI (prompts, menus, status, spinners)
# is written to the controlling terminal ($UI) and never to stdout. This is
# what makes prompts reliably visible.
# ----------------------------------------------------------------------------
if [[ -t 1 || -e /dev/tty ]]; then
  RED=$'\033[0;31m'; GRN=$'\033[0;32m'; YEL=$'\033[1;33m'
  BLU=$'\033[0;34m'; CYN=$'\033[0;36m'; MAG=$'\033[0;35m'
  DIM=$'\033[2m'; BLD=$'\033[1m'; NC=$'\033[0m'
else
  RED=""; GRN=""; YEL=""; BLU=""; CYN=""; MAG=""; DIM=""; BLD=""; NC=""
fi

# Pick a destination for interactive UI that is always visible.
if { : >/dev/tty; } 2>/dev/null; then UI=/dev/tty; else UI=/dev/stderr; fi

# Append a de-coloured copy of UI lines to the install log (best effort).
_log() {
  { printf '%s ' "$(date '+%F %T')"
    printf '%b\n' "$*" | sed 's/\x1b\[[0-9;]*m//g'
  } >>"$INSTALL_LOG" 2>/dev/null || true
}

say()    { printf '%b\n' "$*" >"$UI"; _log "$*"; }
info()   { say "  ${BLU}•${NC} $*"; }
ok()     { say "  ${GRN}✓${NC} $*"; }
warn()   { say "  ${YEL}▲${NC} $*"; }
err()    { say "  ${RED}✗${NC} $*"; }
die()    { err "$*"; exit 1; }

header() {
  say ""
  say "${MAG}${BLD}━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━${NC}"
  say "${BLD}  $*${NC}"
  say "${MAG}${BLD}━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━${NC}"
}

# read one line from the real terminal (works inside command substitution)
_readline() { local __v="$1"; IFS= read -r "$__v" 2>/dev/null </dev/tty || printf -v "$__v" '%s' ""; }

# ask "Prompt" "default"  ->  echoes the chosen value
ask() {
  local prompt="$1" default="${2:-}" reply
  if [[ -n "$default" ]]; then
    printf '  %b➜%b %s %b[%s]%b: ' "$CYN" "$NC" "$prompt" "$DIM" "$default" "$NC" >"$UI"
  else
    printf '  %b➜%b %s: ' "$CYN" "$NC" "$prompt" >"$UI"
  fi
  _readline reply
  echo "${reply:-$default}"
}

# confirm "Question" "Y|N"  ->  returns 0 for yes, 1 for no
confirm() {
  local q="$1" def="${2:-Y}" reply hint
  case "$def" in Y|y) hint="Y/n";; *) hint="y/N";; esac
  printf '  %b?%b %s %b[%s]%b: ' "$YEL" "$NC" "$q" "$DIM" "$hint" "$NC" >"$UI"
  _readline reply
  reply="${reply:-$def}"
  [[ "$reply" =~ ^[Yy] ]]
}

# ask_secret "Prompt"  ->  reads silently, echoes value
ask_secret() {
  local prompt="$1" reply
  printf '  %b➜%b %s: ' "$CYN" "$NC" "$prompt" >"$UI"
  IFS= read -rs reply 2>/dev/null </dev/tty || reply=""
  printf '\n' >"$UI"
  echo "$reply"
}

# ask_num "Prompt" "default"  ->  echoes a validated positive integer
ask_num() {
  local prompt="$1" default="${2:-}" reply
  while :; do
    reply=$(ask "$prompt" "$default")
    if [[ "$reply" =~ ^[1-9][0-9]*$ ]]; then echo "$reply"; return 0; fi
    warn "Please enter a positive whole number."
  done
}

# gen_password  ->  strong alnum password (no dependency on openssl being present yet)
gen_password() {
  if command -v openssl >/dev/null 2>&1; then
    openssl rand -base64 24 | tr -dc 'A-Za-z0-9' | cut -c1-24
  else
    # Read a FINITE chunk first. Piping the infinite /dev/urandom straight into
    # `head -c` lets `head` close the pipe, killing `tr` with SIGPIPE (exit 141);
    # under `set -o pipefail` that would propagate as a failure and abort the
    # script. Reading a fixed 512 bytes up front avoids the early pipe close.
    head -c 512 /dev/urandom | LC_ALL=C tr -dc 'A-Za-z0-9' | cut -c1-24
  fi
}

# run_step "Message" cmd [args...]
# Runs cmd in the background (output -> install log) while animating a spinner,
# then prints a tick/cross. Returns the command's exit status.
run_step() {
  local msg="$1"; shift
  _log "RUN: $*"
  if [[ -z "$NC" ]]; then          # no TTY/colour: plain, no animation
    local rc=0
    say "  … $msg"
    "$@" >>"$INSTALL_LOG" 2>&1 || rc=$?
    (( rc == 0 )) && say "  ✓ $msg" || say "  ✗ $msg (details: $INSTALL_LOG)"
    return "$rc"
  fi
  local frames=('⠋' '⠙' '⠹' '⠸' '⠼' '⠴' '⠦' '⠧' '⠇' '⠏') i=0 rc=0
  ( "$@" ) >>"$INSTALL_LOG" 2>&1 &
  local pid=$!
  while kill -0 "$pid" 2>/dev/null; do
    printf '\r  %b%s%b %s ' "$CYN" "${frames[i]}" "$NC" "$msg" >"$UI"
    i=$(( (i + 1) % ${#frames[@]} ))
    sleep 0.1
  done
  wait "$pid" || rc=$?
  if (( rc == 0 )); then
    printf '\r  %b✓%b %s\033[K\n' "$GRN" "$NC" "$msg" >"$UI"; _log "OK: $msg"
  else
    printf '\r  %b✗%b %s\033[K\n' "$RED" "$NC" "$msg" >"$UI"; _log "FAIL($rc): $msg"
  fi
  return "$rc"
}

banner() {
  say ""
  say "${CYN}${BLD}  ┌────────────────────────────────────────────────────┐${NC}"
  say "${CYN}${BLD}  │   KumoMTA  •  Guided Installer for Rocky Linux 8/9  │${NC}"
  say "${CYN}${BLD}  └────────────────────────────────────────────────────┘${NC}"
  say "  ${DIM}A full install log is written to ${INSTALL_LOG}${NC}"
}

# ----------------------------------------------------------------------------
# Global state (filled in by gather_inputs)
# ----------------------------------------------------------------------------
MAIN_DOMAIN=""; PRIMARY_FQDN=""
declare -a IPS=() SUBS=() FQDNS=()
SMTP_USER=""; SMTP_PASS=""
DAILY_LIMIT=""; PER_IP_HOURLY=""; WARMUP="N"; START_RATE=""
LE_EMAIL=""; SETUP_SSL="Y"
DKIM_SELECTOR="kumo"
DMARC_RUA=""; SETUP_FW="Y"
TEST_SEND="N"; TEST_RCPT=""

# ============================================================================
# 1. PREFLIGHT CHECKS
# ============================================================================
require_root() { [[ $EUID -eq 0 ]] || die "Please run as root (sudo bash $0)"; }

check_os() {
  header "System requirement checks"
  local id="" ver="" pretty=""
  if [[ -r /etc/os-release ]]; then
    # shellcheck disable=SC1091
    . /etc/os-release
    id="${ID:-}"; ver="${VERSION_ID:-}"; pretty="${PRETTY_NAME:-}"
  fi
  # Prefer the RPM macro for the EL major version; fall back to VERSION_ID.
  EL_VER="$(rpm -E %rhel 2>/dev/null || true)"
  [[ "$EL_VER" =~ ^[0-9]+$ ]] || EL_VER="${ver%%.*}"

  case "$id" in
    rocky)                 : ;;                       # primary target
    rhel|almalinux|centos) : ;;                       # binary-compatible EL
    *) warn "OS is ${pretty:-unknown} -- this installer targets Rocky Linux 8/9. Continuing anyway." ;;
  esac

  if [[ "$EL_VER" == "8" || "$EL_VER" == "9" ]]; then
    ok "OS: ${pretty:-EL${EL_VER}} (EL${EL_VER} family)"
  else
    warn "Detected EL major version '${EL_VER:-?}'. KumoMTA RPMs target EL8/EL9 -- continuing anyway."
    [[ "$EL_VER" =~ ^[0-9]+$ ]] || EL_VER="9"
  fi

  command -v dnf >/dev/null 2>&1 || die "'dnf' not found -- this installer requires a dnf/yum based system (Rocky Linux 8/9)."
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
    warn "Open a ticket with your VPS provider to unblock it,"
    warn "otherwise remote delivery will fail with connection timeouts."
  fi
}

check_conflicts() {
  local svc found=0
  # Rocky ships Postfix as the default MTA and it is frequently enabled, so it
  # is the most likely thing holding port 25. exim4 is Debian-only -> "exim".
  for svc in postfix sendmail exim opensmtpd; do
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
  # IPv6 awareness. Capture the output and match in-shell rather than piping
  # into `grep -q`, which (under `set -o pipefail`) can be killed by SIGPIPE and
  # report a false negative.
  local v6
  v6="$(ip -6 -o addr show scope global 2>/dev/null || true)"
  if [[ "$v6" == *inet6* ]]; then
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
  DKIM_SELECTOR=$(ask "DKIM selector" "kumo")

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
  if confirm "Configure firewalld (allow SSH, 25, 80, 587)?" "Y"; then SETUP_FW="Y"; else SETUP_FW="N"; fi

  # --- post-install test send ---
  echo
  if confirm "Send a test email after install (to confirm delivery)?" "Y"; then
    TEST_SEND="Y"
    while :; do
      TEST_RCPT=$(ask "  Test recipient address (use an inbox you control)")
      [[ "$TEST_RCPT" == *@*.* ]] && break || warn "Enter a valid email address."
    done
  fi
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
  echo "  DKIM selector      : $DKIM_SELECTOR (new 2048-bit key)"
  echo "  Let's Encrypt SSL  : $SETUP_SSL"
  echo "  DMARC rua          : $DMARC_RUA"
  echo "  Configure firewall : $SETUP_FW"
  if [[ "$TEST_SEND" == "Y" ]]; then echo "  Post-install test  : Y -> $TEST_RCPT"; else echo "  Post-install test  : N"; fi
  echo
  confirm "Proceed with installation?" "Y" || die "Aborted by user."
}

# ============================================================================
# 3. INSTALL + OS PREP
# ============================================================================
install_dependencies() {
  header "Installing dependencies"
  run_step "Refreshing dnf metadata" dnf -y makecache || warn "dnf makecache reported issues (continuing)."
  # NOTE: do NOT install the 'curl' package here. Rocky ships 'curl-minimal',
  # which already provides the curl command; pulling in the full 'curl' package
  # conflicts with curl-minimal and aborts the whole transaction.
  #   gnupg2   -> gpg (key handling)         bind-utils -> dig (DNS checks)
  #   firewalld-> firewall-cmd               gzip/zstd  -> read repo + kumo logs
  run_step "Installing prerequisites (gnupg2, openssl, firewalld, bind-utils, gzip, zstd)" \
    dnf -y install gnupg2 ca-certificates openssl firewalld bind-utils gzip zstd \
    || die "Failed to install base packages."
  if ! command -v curl >/dev/null 2>&1; then
    run_step "Installing curl" dnf -y install --allowerasing curl || die "curl is required but could not be installed."
  fi
}

# Does dnf currently offer the 'kumomta' package? (no pipe -> no SIGPIPE issue)
kumo_have_candidate() {
  dnf -q list --available kumomta >/dev/null 2>&1
}

# Best-effort: surface WHY dnf is not offering the package (repo / gpg / network).
kumo_show_repo_diag() {
  info "Diagnosing the KumoMTA repository..."
  local out diag
  out="$(dnf -v makecache --repo 'kumomta-stable' 2>&1 || true)"
  diag="$(printf '%s\n' "$out" | grep -iE 'kumomta|pkgs\.kumomta|openrepo|error|fail|gpg|denied|not found|cannot' || true)"
  if [[ -n "$diag" ]]; then
    while IFS= read -r line; do warn "$line"; done <<< "$diag"
  fi
  warn "Repo file: $(ls -l "$KUMO_REPO_FILE" 2>/dev/null || echo "MISSING ($KUMO_REPO_FILE)")"
  return 0
}

# Fallback installer used when dnf's metadata cannot offer the package despite
# the repo being reachable. Locates the newest STABLE kumomta .rpm matching the
# host arch from the repo's primary.xml and installs it via dnf (so deps still
# resolve and the GPG key is honoured).
kumo_install_via_rpm() {
  local rel arch base repomd primary plist rpmrel url
  rel="${EL_VER:-$(rpm -E %rhel 2>/dev/null || echo 9)}"
  arch="$(uname -m)"
  # shellcheck disable=SC2059
  base="$(printf "$KUMO_PKG_BASE_TMPL" "$rel")"

  repomd="$(curl -fsSL "$base/repodata/repomd.xml" 2>/dev/null || true)"
  [[ -n "$repomd" ]] || { err "Could not read repo metadata from $base"; return 1; }
  # First primary.xml.gz href (pure-bash first line -> no SIGPIPE from head).
  primary="$(printf '%s' "$repomd" | tr '<' '\n' | grep 'location href=' | grep 'primary.xml.gz' | sed -E 's/.*href="([^"]+)".*/\1/')"
  primary="${primary%%$'\n'*}"
  [[ -n "$primary" ]] || { err "Could not locate primary.xml.gz in $base"; return 1; }

  # Newest kumomta rpm for our arch (sort ascending, take last line in bash).
  plist="$(curl -fsSL "$base/$primary" 2>/dev/null | gunzip 2>/dev/null \
            | tr '<' '\n' | grep -E "location href=\"[^\"]*kumomta[^\"]*\.${arch}\.rpm\"" \
            | sed -E 's/.*href="([^"]+)".*/\1/' | sort || true)"
  rpmrel="${plist##*$'\n'}"
  [[ -n "$rpmrel" ]] || { err "No stable kumomta .rpm found for arch '$arch' in $base"; return 1; }

  url="$base/$rpmrel"
  run_step "Installing kumomta from the repo RPM ($(basename "$rpmrel"))" \
    dnf -y install "$url" \
    || return 1
  return 0
}

install_kumomta() {
  header "Installing KumoMTA"
  if command -v kumod >/dev/null 2>&1 || [[ -x /opt/kumomta/sbin/kumod ]]; then
    ok "KumoMTA already installed -- skipping repo setup."
    return
  fi

  # Add the official KumoMTA repo. We write the .repo file directly rather than
  # via `dnf config-manager --add-repo`, so we don't depend on dnf-plugins-core
  # being present (it isn't on minimal images). This is exactly what
  # config-manager would do. The file enables the stable + dev repos and pins
  # the GPG key; `dnf install kumomta` pulls the STABLE package.
  run_step "Adding the KumoMTA repository" \
    curl -fsSL "$KUMO_REPO_URL" -o "$KUMO_REPO_FILE" \
    || die "Could not download the KumoMTA repo file from $KUMO_REPO_URL (check network / provider docs)."
  [[ -s "$KUMO_REPO_FILE" ]] || die "The downloaded repo file $KUMO_REPO_FILE is empty."
  chmod 644 "$KUMO_REPO_FILE"
  ok "Wrote $KUMO_REPO_FILE"

  run_step "Refreshing dnf metadata for the KumoMTA repo" dnf -y makecache \
    || die "dnf makecache failed after adding the KumoMTA repo."

  # 1) Normal install.
  if kumo_have_candidate; then
    if run_step "Installing the KumoMTA package" dnf -y install kumomta \
       && [[ -x /opt/kumomta/sbin/kumod ]]; then
      ok "KumoMTA package installed."
      return
    fi
    warn "dnf offered the package but the install did not complete; retrying with a clean cache."
  else
    warn "kumomta not offered yet -- clearing the dnf cache and refreshing metadata."
  fi

  # 2) Clean re-acquire of metadata, then retry the normal install.
  run_step "Clearing dnf cache and refreshing metadata" \
    bash -c 'dnf clean all >/dev/null 2>&1; dnf -y makecache' || true
  if run_step "Installing the KumoMTA package (retry)" dnf -y install kumomta \
     && [[ -x /opt/kumomta/sbin/kumod ]]; then
    ok "KumoMTA package installed."
    return
  fi

  # 3) Direct .rpm fallback straight from the (reachable) stable repo.
  warn "dnf could not install 'kumomta'; falling back to a direct .rpm install."
  kumo_show_repo_diag
  if kumo_install_via_rpm && [[ -x /opt/kumomta/sbin/kumod ]]; then
    ok "KumoMTA package installed (direct .rpm from the stable repo)."
    return
  fi

  err "The 'kumomta' package could not be installed via dnf or direct download."
  die "Check $KUMO_REPO_FILE and https://docs.kumomta.com/userguide/installation/linux/"
}

system_prep() {
  header "OS tuning"
  hostnamectl set-hostname "$PRIMARY_FQDN"
  grep -q "$PRIMARY_FQDN" /etc/hosts 2>/dev/null || \
    echo "${IPS[0]} ${PRIMARY_FQDN} ${SUBS[0]}" >> /etc/hosts

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
# 4. DNS VERIFICATION  (A records must already exist; see README)
# ============================================================================
build_spf() {
  local spf="v=spf1"; local ip
  for ip in "${IPS[@]}"; do spf+=" ip4:$ip"; done
  echo "$spf -all"
}

print_dns_preview() {
  header "Required A records (these should ALREADY exist -- see README)"
  printf '  %-28s %-6s %s\n' "NAME" "TYPE" "VALUE"
  local i
  for i in "${!IPS[@]}"; do
    printf '  %-28s %-6s %s\n' "${FQDNS[$i]}." "A" "${IPS[$i]}"
  done
  echo
  echo "  PTR / reverse DNS (set in your VPS provider panel -- must match):"
  for i in "${!IPS[@]}"; do
    printf '    %-16s PTR -> %s\n' "${IPS[$i]}" "${FQDNS[$i]}"
  done
  echo
  info "DKIM / SPF / DMARC will be generated and PRINTED after install."
}

# query real DNS (dig bypasses /etc/hosts); returns space-padded A records
_dns_a() { dig +short A "$1" 2>/dev/null | tr '\n' ' '; }

verify_dns() {
  header "Verifying DNS A records"
  local i got
  while :; do
    local all_ok=1
    for i in "${!FQDNS[@]}"; do
      got=" $(_dns_a "${FQDNS[$i]}") "
      if [[ "$got" == *" ${IPS[$i]} "* ]]; then
        ok "${FQDNS[$i]} -> ${IPS[$i]}"
      elif [[ "$got" =~ [0-9] ]]; then
        warn "${FQDNS[$i]} ->${got}(expected ${IPS[$i]})"; all_ok=0
      else
        warn "${FQDNS[$i]} has NO A record yet (expected ${IPS[$i]})"; all_ok=0
      fi
    done
    (( all_ok == 1 )) && { ok "All A records resolve correctly."; break; }
    echo
    warn "Create/fix the A records above at your DNS provider, then re-check."
    confirm "Re-check DNS now? (No = continue anyway)" "Y" || { warn "Continuing without complete DNS."; break; }
  done

  # SSL needs the primary hostname to resolve to one of our IPs + port 80.
  if [[ "$SETUP_SSL" == "Y" ]]; then
    got=" $(_dns_a "$PRIMARY_FQDN") "
    if [[ "$got" == *" ${IPS[0]} "* ]]; then
      ok "Primary ${PRIMARY_FQDN} resolves correctly -- SSL can proceed."
    else
      warn "Primary ${PRIMARY_FQDN} does not resolve to ${IPS[0]} (got:${got})."
      confirm "Attempt Let's Encrypt anyway?" "N" || { SETUP_SSL="N"; warn "Skipping SSL."; }
    fi
  fi
}

# ============================================================================
# 5. SSL  (Let's Encrypt via certbot standalone)
# ============================================================================
setup_ssl() {
  [[ "$SETUP_SSL" == "Y" ]] || return 0
  header "SSL certificate (Let's Encrypt)"

  # On EL8/EL9 certbot lives in EPEL.
  run_step "Enabling EPEL repository" dnf -y install epel-release \
    || warn "Could not install epel-release (certbot may be unavailable)."
  if ! run_step "Installing certbot" dnf -y install certbot; then
    warn "Failed to install certbot; continuing WITHOUT SSL."
    warn "Enable EPEL and run 'dnf install certbot' manually, then re-run certbot."
    SETUP_SSL="N"
    return 0
  fi

  # Let's Encrypt's HTTP-01 challenge must reach this host on inbound TCP/80.
  # Rocky enables firewalld by default (the public zone blocks 80), and our
  # firewall step runs LATER, so open 80 right now -- otherwise the standalone
  # challenge times out and SSL gets skipped. Runtime add takes effect
  # immediately (no reload); the permanent add survives reboots.
  if systemctl is-active --quiet firewalld 2>/dev/null; then
    firewall-cmd --add-port=80/tcp >/dev/null 2>&1 || true
    firewall-cmd --permanent --add-port=80/tcp >/dev/null 2>&1 || true
    info "Opened TCP/80 in firewalld for the Let's Encrypt challenge."
  fi

  # Free port 80 for the standalone challenge if a web server is running.
  systemctl stop nginx httpd 2>/dev/null || true

  if run_step "Requesting certificate for ${PRIMARY_FQDN}" \
      certbot certonly --standalone --non-interactive --agree-tos \
      -m "$LE_EMAIL" -d "$PRIMARY_FQDN" --preferred-challenges http; then
    ok "Certificate issued for ${PRIMARY_FQDN}."
  else
    warn "certbot failed. Continuing WITHOUT SSL."
    warn "Most common cause: inbound TCP/80 not reachable (provider firewall)."
    warn "Once port 80 is open, enable SSL anytime with:  sudo bash enable-ssl.sh"
    say "  ${DIM}(see the certbot output near the end of ${INSTALL_LOG})${NC}"
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

  if [[ -s "$keyfile" ]]; then
    ok "Existing DKIM key found -> $keyfile (reusing, not regenerating)."
  else
    openssl genrsa -out "$keyfile" 2048 2>/dev/null
    ok "Generated 2048-bit DKIM key -> $keyfile"
  fi

  # Derive the public-key DNS record from the private key (works either way).
  local tmp pub
  tmp=$(mktemp)
  openssl rsa -in "$keyfile" -pubout -out "$tmp" 2>/dev/null
  pub=$(grep -v '^-----' "$tmp" | tr -d '\n')
  rm -f "$tmp"
  DKIM_RECORD="v=DKIM1; k=rsa; p=${pub}"

  chown -R "$KUMO_USER:$KUMO_USER" "$DKIM_DIR"
  chmod 600 "$keyfile"
}

# ============================================================================
# 7. POLICY GENERATION
# ============================================================================
backup_existing() {
  if [[ -f "$POLICY_DIR/init.lua" ]]; then
    local bk
    bk="$POLICY_DIR/backup-$(date +%Y%m%d-%H%M%S)"
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
  # Follows https://docs.kumomta.com/userguide/configuration/dkim/
  # The dkim_sign helper auto-derives the key path as:
  #   ${DKIM_DIR}/${MAIN_DOMAIN}/${DKIM_SELECTOR}.key
  # headers: the RFC 6376 section 5.4.1 recommended set (NOT Content-Type /
  # MIME-Version, which downstream relays may legitimately alter and break the
  # signature). over_sign guards against DKIM replay attacks.
  cat > "$f" <<EOF
# Generated by install.sh
[base]
over_sign = true
headers = [
  "From", "Reply-To", "Subject", "Date", "To", "Cc",
  "Resent-Date", "Resent-From", "Resent-To", "Resent-Cc",
  "In-Reply-To", "References", "List-Id", "List-Help",
  "List-Unsubscribe", "List-Subscribe", "List-Post",
  "List-Owner", "List-Archive",
]

[domain."${MAIN_DOMAIN}"]
selector = "${DKIM_SELECTOR}"
algo = "sha256"
EOF
  ok "Wrote $f"
}

write_shaping_toml() {
  local f="$POLICY_DIR/shaping.toml"
  local rate="${PER_IP_HOURLY}/hr"
  local default_rate="$rate"
  [[ "$WARMUP" == "Y" ]] && default_rate="${START_RATE}/hr"
  {
    echo "# Generated by install.sh -- custom overrides layered ON TOP of the"
    echo "# KumoMTA-maintained /opt/kumomta/share/policy-extras/shaping.toml."
    echo "# That maintained file already defines per-provider rules (Google,"
    echo "# Yahoo, Outlook, ...) with correct MX matching + TLS, so we only set"
    echo "# global defaults here."
    echo "#"
    echo "# Do NOT add per-domain blocks for provider-hosted domains such as"
    echo "# gmail.com / yahoo.com / outlook.com -- they belong to a provider"
    echo "# 'site' and KumoMTA will error with 'also matched by provider'."
    echo "# Use a [provider.\"name\"] block (see the trafficshaping userguide) if"
    echo "# you need to override one."
    [[ "$WARMUP" == "Y" ]] && echo "# WARMUP: default starts low (${default_rate}); raise toward ${rate} as reputation builds."
    echo
    echo "[\"default\"]"
    echo "connection_limit = 10"
    echo "max_message_rate = \"${default_rate}\""
  } > "$f"
  ok "Wrote $f"
}

write_queues_toml() {
  local f="$POLICY_DIR/queues.toml"
  cat > "$f" <<EOF
# Generated by install.sh -- route all mail through our sending IP pool.
# See https://docs.kumomta.com/userguide/configuration/queuemanagement/
[queue.default]
egress_pool = "send-pool"
max_age = "24 hours"
EOF
  ok "Wrote $f"
}

write_listener_domains_toml() {
  local f="$POLICY_DIR/listener_domains.toml"
  # https://docs.kumomta.com/userguide/configuration/domains/
  # "*" is the default for every destination domain: accept + log OOB bounce
  # and ARF/FBL reports, but never open-relay. relay_from_authz lets an
  # SMTP-authenticated client (authz_id == our SMTP user) relay to anywhere --
  # this is what authorizes MailWizz/Listmonk injection. (Successful AUTH alone
  # does NOT grant relay; this list is the documented mechanism.)
  cat > "$f" <<EOF
# Generated by install.sh -- OOB bounce / FBL handling + authenticated relay
["*"]
relay_to = false
log_oob = true
log_arf = true
relay_from_authz = ["${SMTP_USER}"]
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
-- Generated by install.sh -- KumoMTA policy.
-- Modeled on the official example policy:
--   https://docs.kumomta.com/userguide/configuration/example/
-- Validate:  runuser -u ${KUMO_USER} -- /opt/kumomta/sbin/kumod --policy ${f} --validate
local kumo = require 'kumo'
local sources = require 'policy-extras.sources'
local dkim_sign = require 'policy-extras.dkim_sign'
local shaping = require 'policy-extras.shaping'
local listener_domains = require 'policy-extras.listener_domains'
local queue_module = require 'policy-extras.queue'

-- Policy helpers (each reads its own TOML; see the userguide chapters).
sources:setup { '${POLICY_DIR}/sources.toml' }
local dkim_signer = dkim_sign:setup { '${POLICY_DIR}/dkim_data.toml' }

-- Traffic shaping must be set up BEFORE the queue helper: both register a
-- get_queue_config handler and KumoMTA requires queue.lua to register LAST.
-- shaping:setup auto-includes the KumoMTA-maintained shaping.toml; we layer
-- our overrides (shaping.toml) on top of it.
local shaper = shaping:setup { '${POLICY_DIR}/shaping.toml' }

-- Queue helper LAST among get_queue_config registrants.
local queue_helper = queue_module:setup { '${POLICY_DIR}/queues.toml' }

kumo.on('init', function()
  -- Spool: message bodies (data) and envelope/metadata (meta).
  kumo.define_spool { name = 'data', path = '${SPOOL_DIR}/data', kind = 'RocksDB' }
  kumo.define_spool { name = 'meta', path = '${SPOOL_DIR}/meta', kind = 'RocksDB' }

  -- Local disk logging.
  kumo.configure_local_logs {
    log_dir = '${LOG_DIR}',
    max_segment_duration = '1 minute',
  }

  -- Classify bounces using the bundled IANA ruleset.
  kumo.configure_bounce_classifier {
    files = { '/opt/kumomta/share/bounce_classifier/iana.toml' },
  }

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

  -- NOTE: KumoMTA supports STARTTLS only (not implicit TLS / SMTPS), so there
  -- is no listener on 465; injectors should submit on 587 with STARTTLS.

  kumo.start_http_listener {
    listen = '127.0.0.1:8000',
    trusted_hosts = { '127.0.0.1', '::1' },
  }
end)

-- Per-destination-domain relay/OOB/FBL policy (no open relay).
kumo.on('get_listener_domain',
  listener_domains:setup { '${POLICY_DIR}/listener_domains.toml' })

-- Traffic shaping handler. shaping:setup (above) returns the egress-path
-- handler; older versions return an object exposing get_egress_path_config,
-- so support both. (Shaping was set up above, before the queue helper.)
if type(shaper) == 'function' then
  kumo.on('get_egress_path_config', shaper)
else
  kumo.on('get_egress_path_config', shaper.get_egress_path_config)
end

-- Inbound SMTP AUTH PLAIN. KumoMTA passes FOUR args (authz, authc/username,
-- password, conn_meta) and only offers AUTH after STARTTLS. Returning true
-- marks the session authenticated, which is what permits relay for that client.
kumo.on('smtp_server_auth_plain', function(authz, authc, password, conn_meta)
  return authc == '${SMTP_USER}'
    and password == os.getenv('SMTP_NEWS_PASSWORD')
end)

kumo.on('smtp_server_message_received', function(msg)
  -- Guard against SMTP smuggling (reject non-canonical line endings).
  local failed = msg:check_fix_conformance('NON_CANONICAL_LINE_ENDINGS', '')
  if failed then
    kumo.reject(552, string.format('5.6.0 %s', failed))
  end
  queue_helper:apply(msg)
  -- DKIM signing MUST come last so nothing alters the message afterwards.
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
  # runuser is part of util-linux (always present on EL) and, unlike sudo, needs
  # no sudoers entry to drop to the service account.
  if run_step "Validating policy (kumod --validate)" \
       runuser -u "$KUMO_USER" -- /opt/kumomta/sbin/kumod --policy "$POLICY_DIR/init.lua" --validate; then
    ok "Policy validated."
  else
    err "Policy validation FAILED. Last lines of the log:"
    tail -n 25 "$INSTALL_LOG" >"$UI" 2>/dev/null || true
    die "Fix the policy and re-run. Full log: $INSTALL_LOG"
  fi
  systemctl enable kumomta >/dev/null 2>&1 || true
  run_step "Starting the KumoMTA service" systemctl restart kumomta || true
  sleep 2
  if systemctl is-active --quiet kumomta; then
    ok "KumoMTA is running."
  else
    err "KumoMTA failed to start. Check: journalctl -u kumomta -n 50"
  fi
}

setup_firewall() {
  [[ "$SETUP_FW" == "Y" ]] || return 0
  header "Firewall (firewalld)"
  if ! run_step "Enabling firewalld" bash -c 'systemctl enable --now firewalld'; then
    warn "Could not start firewalld; skipping firewall configuration."
    return 0
  fi
  # SSH as a service (falls back to the raw port); mail/web/submission as ports.
  firewall-cmd --permanent --add-service=ssh   >/dev/null 2>&1 || firewall-cmd --permanent --add-port=22/tcp  >/dev/null 2>&1 || true
  firewall-cmd --permanent --add-port=25/tcp   >/dev/null 2>&1 || true   # SMTP (inbound bounces; outbound delivery)
  firewall-cmd --permanent --add-port=80/tcp   >/dev/null 2>&1 || true   # Let's Encrypt issuance + renewal
  firewall-cmd --permanent --add-port=587/tcp  >/dev/null 2>&1 || true   # submission (STARTTLS)
  firewall-cmd --reload >/dev/null 2>&1 || true
  ok "firewalld configured (allowed: SSH, 25, 80, 587)."
  info "Note: KumoMTA supports STARTTLS only (no implicit-TLS/465), so submit on 587."
}

# ============================================================================
# 8b. POST-INSTALL TEST SEND  (HTTP injection API + log tail)
# ============================================================================
do_test_send() {
  [[ "$TEST_SEND" == "Y" ]] || return 0
  header "Post-install test send -> ${TEST_RCPT}"
  command -v curl >/dev/null 2>&1 || { warn "curl not found; skipping test send."; return 0; }

  local sender="postmaster@${MAIN_DOMAIN}"
  local subj
  subj="KumoMTA test $(date -u +%Y-%m-%dT%H:%M:%SZ)"
  local body="KumoMTA post-install test from ${PRIMARY_FQDN}. If you received this, injection + delivery work."
  # Build JSON; \n inside content is a literal backslash-n (a JSON newline escape).
  local nl='\n'
  local content="Subject: ${subj}${nl}From: ${sender}${nl}To: ${TEST_RCPT}${nl}${nl}${body}"
  local payload="{\"envelope_sender\":\"${sender}\",\"recipients\":[{\"email\":\"${TEST_RCPT}\"}],\"content\":\"${content}\"}"

  local respfile code
  respfile=$(mktemp)
  info "Injecting via http://127.0.0.1:8000/api/inject/v1 ..."
  code=$(curl -s -o "$respfile" -w '%{http_code}' \
        -H 'Content-Type: application/json' \
        'http://127.0.0.1:8000/api/inject/v1' -d "$payload" 2>/dev/null || echo "000")

  if [[ "$code" == "200" ]]; then
    ok "Injection accepted (HTTP 200): $(cat "$respfile")"
  else
    warn "Injection failed (HTTP ${code}): $(cat "$respfile" 2>/dev/null)"
    warn "Inspect with: journalctl -u kumomta -n 50"
    rm -f "$respfile"; return 0
  fi
  rm -f "$respfile"

  info "Waiting ~10s for a delivery attempt, then showing recent log activity..."
  sleep 10
  # KumoMTA log segments may be zstd/gzip/plain -- try each, grep for the recipient.
  # Capture+parse in-shell instead of `... | sort | head -1`, since `head`
  # closing the pipe can kill `sort` with SIGPIPE (exit 141) and, under
  # `set -o pipefail`, abort the whole script during this final step.
  local newest logs
  logs="$(find "$LOG_DIR" -type f -printf '%T@ %p\n' 2>/dev/null | sort -nr || true)"
  newest=""
  if [[ -n "$logs" ]]; then
    newest="${logs%%$'\n'*}"   # first (newest) line: "<mtime> <path>"
    newest="${newest#* }"      # strip the leading mtime field
  fi
  if [[ -n "$newest" && -f "$newest" ]]; then
    info "Newest log segment: $newest"
    { zstdcat "$newest" 2>/dev/null || zcat "$newest" 2>/dev/null || cat "$newest" 2>/dev/null; } \
      | grep -a -iE "${TEST_RCPT}|Delivery|Reception|Bounce|TransientFailure" | tail -8 || true
  else
    info "No log segment flushed yet (this is normal -- logs buffer briefly)."
  fi
  echo
  info "Follow live results with:   journalctl -u kumomta -f"
  info "Then check the recipient inbox (and spam folder) for: ${subj}"
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
      echo "  Port          : 587  (STARTTLS)"
      echo "  Encryption    : STARTTLS   (KumoMTA does NOT support implicit TLS / 465)"
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
    echo "  4. DKIM TXT records can be long; some DNS panels need them split into 255-char chunks."
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
  require_root
  banner
  check_os
  check_resources
  detect_ips
  check_port25_outbound
  check_conflicts
  gather_inputs
  confirm_summary
  install_dependencies
  install_kumomta
  system_prep
  print_dns_preview
  verify_dns
  setup_ssl
  setup_dkim
  write_all_configs
  validate_and_start
  setup_firewall
  do_test_send
  print_summary
  header "Setup complete"
  ok "Add the DNS records shown above, confirm your PTRs, then send a test."
}

main "$@"
