#!/usr/bin/env bash
# =============================================================================
# check-deliverability.sh  --  verify the DNS/auth records KumoMTA needs to land
# -----------------------------------------------------------------------------
# Re-runnable, read-only helper. It checks LIVE public DNS against what this
# install actually set up, deriving everything from the generated policy:
#   sources.toml   -> sending IPs + per-IP hostnames (EHLO / forward A / PTR)
#   dkim_data.toml -> sending domain + DKIM selector
#   <selector>.key -> the real public key to compare against the published TXT
#
# It validates:
#   * forward A   : each sending hostname -> its IP
#   * PTR / rDNS  : each IP -> its hostname (the big one for inbox placement)
#   * SPF         : one v=spf1 TXT, lists every sending IP, ends -all/~all
#   * DKIM        : v=DKIM1 TXT at <selector>._domainkey.<domain> whose p= key
#                   matches the installed private key
#   * DMARC       : v=DMARC1 TXT at _dmarc.<domain>
#   * STARTTLS    : the :587 submission listener offers STARTTLS with a cert
#                   valid for the primary hostname (skip with -T)
#
#   sudo bash check-deliverability.sh                 # auto-detect everything
#   bash check-deliverability.sh -d example.com -s kumo
#   bash check-deliverability.sh -T                   # skip the live TLS probe
#
# Needs `dig` (dnsutils/bind-utils) and, for DKIM verification + TLS, `openssl`.
# DNS is checked from THIS host's resolver; allow time for records to propagate.
# =============================================================================
set -uo pipefail   # NOTE: no -e; checks must continue and aggregate failures.

# --- KumoMTA paths (match install.sh) ----------------------------------------
KUMO_ETC="/opt/kumomta/etc"
POLICY_DIR="$KUMO_ETC/policy"
DKIM_DIR="$KUMO_ETC/dkim"
SOURCES_TOML="$POLICY_DIR/sources.toml"
DKIM_TOML="$POLICY_DIR/dkim_data.toml"

# --- output helpers (match the rest of the project) --------------------------
if [[ -t 1 || -e /dev/tty ]]; then
  RED=$'\033[0;31m'; GRN=$'\033[0;32m'; YEL=$'\033[1;33m'; CYN=$'\033[0;36m'; NC=$'\033[0m'
else
  RED=""; GRN=""; YEL=""; CYN=""; NC=""
fi
info() { printf '  %b•%b %s\n' "$CYN" "$NC" "$*"; }
ok()   { printf '  %b✓%b %s\n' "$GRN" "$NC" "$*"; }
warn() { printf '  %b▲%b %s\n' "$YEL" "$NC" "$*"; }
bad()  { printf '  %b✗%b %s\n' "$RED" "$NC" "$*"; }
die()  { printf '  %b✗%b %s\n' "$RED" "$NC" "$*"; exit 1; }
hdr()  { printf '\n%s\n%s\n%s\n' "$(printf '%.0s━' {1..60})" "$*" "$(printf '%.0s━' {1..60})"; }

# Tally so the exit code is meaningful (0 = all good, 1 = problems).
PASS=0; FAILN=0; WARN=0
pass() { ok   "$*"; PASS=$(( PASS + 1 )); }
fail() { bad  "$*"; FAILN=$(( FAILN + 1 )); }
soft() { warn "$*"; WARN=$(( WARN + 1 )); }

usage() {
  cat <<USAGE
Usage: bash check-deliverability.sh [-d DOMAIN] [-s SELECTOR] [-T] [-h]

  -d DOMAIN    sending domain (default: auto-detected from dkim_data.toml)
  -s SELECTOR  DKIM selector (default: auto-detected from dkim_data.toml)
  -T           skip the live STARTTLS/cert probe on :587
  -h           show this help

Exit status is 0 when every check passes, 1 otherwise.
USAGE
}

DOMAIN=""; SELECTOR=""; SKIP_TLS="N"
while getopts ":d:s:Th" opt; do
  case "$opt" in
    d) DOMAIN="$OPTARG" ;;
    s) SELECTOR="$OPTARG" ;;
    T) SKIP_TLS="Y" ;;
    h) usage; exit 0 ;;
    :) die "Option -$OPTARG requires an argument. (-h for help)" ;;
    \?) die "Unknown option -$OPTARG. (-h for help)" ;;
  esac
done

command -v dig >/dev/null 2>&1 || die "dig not found -- install dnsutils (apt) / bind-utils (dnf)."

# --- parse sources.toml: ordered source -> IP + hostname ---------------------
SRC_IPS=(); SRC_HOSTS=()
parse_sources() {
  local line idx=-1
  while IFS= read -r line; do
    if [[ "$line" =~ ^\[source\.\"(.+)\"\] ]]; then
      SRC_IPS+=(""); SRC_HOSTS+=(""); idx=$(( ${#SRC_IPS[@]} - 1 ))
    elif (( idx >= 0 )); then
      if [[ "$line" =~ ^source_address[[:space:]]*=[[:space:]]*\"(.+)\" ]]; then
        SRC_IPS[$idx]="${BASH_REMATCH[1]}"
      elif [[ "$line" =~ ^ehlo_domain[[:space:]]*=[[:space:]]*\"(.+)\" ]]; then
        SRC_HOSTS[$idx]="${BASH_REMATCH[1]}"
      fi
    fi
  done < "$SOURCES_TOML"
}

# --- DNS helpers (dig bypasses /etc/hosts) -----------------------------------
dns_a()   { dig +short A    "$1" 2>/dev/null | grep -E '^[0-9.]+$' || true; }
dns_ptr() { dig +short -x   "$1" 2>/dev/null || true; }
# TXT can be split into 255-char quoted chunks; strip quotes + whitespace and join.
dns_txt() { dig +short TXT  "$1" 2>/dev/null | sed -E 's/" +"//g; s/"//g' || true; }

# normalise a hostname for comparison (drop trailing dot)
nodot() { printf '%s' "${1%.}"; }

# ============================================================================
# resolve domain / selector if not given
# ============================================================================
[[ -f "$SOURCES_TOML" ]] || die "Not found: $SOURCES_TOML -- run install.sh first."
parse_sources
(( ${#SRC_IPS[@]} > 0 )) || die "No [source.*] entries found in $SOURCES_TOML."

if [[ -z "$DOMAIN" ]]; then
  DOMAIN="$(awk -F'"' '/^\[domain\./ {print $2; exit}' "$DKIM_TOML" 2>/dev/null || true)"
  [[ -n "$DOMAIN" ]] || die "Could not auto-detect the sending domain; pass it with -d."
fi
if [[ -z "$SELECTOR" ]]; then
  SELECTOR="$(awk -F'"' '/^[[:space:]]*selector[[:space:]]*=/ {print $2; exit}' "$DKIM_TOML" 2>/dev/null || true)"
  [[ -n "$SELECTOR" ]] || SELECTOR="kumo"
fi
PRIMARY_FQDN="${SRC_HOSTS[0]:-}"

hdr "KumoMTA deliverability check"
info "Sending domain : $DOMAIN"
info "DKIM selector  : $SELECTOR  (record at ${SELECTOR}._domainkey.${DOMAIN})"
info "Sending IPs    : ${#SRC_IPS[@]}"
info "Primary host   : ${PRIMARY_FQDN:-<unknown>}"
info "DNS answers come from THIS host's resolver; allow time for propagation."

# ============================================================================
# 1. forward A records
# ============================================================================
hdr "Forward A records (hostname -> IP)"
for i in "${!SRC_IPS[@]}"; do
  ip="${SRC_IPS[$i]}"; host="${SRC_HOSTS[$i]:-}"
  [[ -n "$host" ]] || { soft "source #$((i+1)) ($ip) has no ehlo_domain in sources.toml"; continue; }
  got="$(dns_a "$host" | tr '\n' ' ')"
  if [[ " $got " == *" $ip "* ]]; then
    pass "$host -> $ip"
  elif [[ -n "$got" ]]; then
    fail "$host -> ${got}(expected $ip)"
  else
    fail "$host has NO A record (expected $ip)"
  fi
done

# ============================================================================
# 2. PTR / reverse DNS
# ============================================================================
hdr "PTR / reverse DNS (IP -> hostname)  -- critical for inbox placement"
for i in "${!SRC_IPS[@]}"; do
  ip="${SRC_IPS[$i]}"; host="$(nodot "${SRC_HOSTS[$i]:-}")"
  ptr="$(dns_ptr "$ip")"; ptr1="$(nodot "${ptr%%$'\n'*}")"
  if [[ -z "$ptr1" ]]; then
    fail "$ip -> (no PTR)   expected $host  [set this in your VPS provider panel]"
  elif [[ "$ptr1" == "$host" ]]; then
    pass "$ip -> $ptr1"
  else
    fail "$ip -> $ptr1   (expected $host)"
  fi
done

# ============================================================================
# 3. SPF
# ============================================================================
hdr "SPF (TXT on $DOMAIN)"
spf="$(dns_txt "$DOMAIN" | grep -i 'v=spf1' | head -1)"
if [[ -z "$spf" ]]; then
  fail "No v=spf1 TXT record found on $DOMAIN"
else
  spf_count="$(dns_txt "$DOMAIN" | grep -ic 'v=spf1')"
  (( spf_count > 1 )) && soft "More than one SPF record found ($spf_count) -- RFC 7208 allows only ONE; receivers will permerror."
  info "found: $spf"
  missing=""
  for i in "${!SRC_IPS[@]}"; do
    ip="${SRC_IPS[$i]}"
    # accept the IP listed directly as ip4:, or covered by an ip4 CIDR is not
    # checked here (we only assert each exact IP appears).
    [[ "$spf" == *"ip4:$ip"* ]] || missing+=" $ip"
  done
  if [[ -n "$missing" ]]; then
    fail "SPF is missing sending IP(s):$missing"
  else
    pass "SPF lists all ${#SRC_IPS[@]} sending IP(s)"
  fi
  if [[ "$spf" =~ -all ]]; then
    pass "SPF ends with -all (hardfail)"
  elif [[ "$spf" =~ ~all ]]; then
    soft "SPF ends with ~all (softfail) -- installer default is -all; fine, but stricter is better"
  elif [[ "$spf" =~ \+all ]]; then
    fail "SPF ends with +all -- this authorises the whole internet; never use it"
  else
    soft "SPF has no explicit all mechanism -- consider adding -all"
  fi
fi

# ============================================================================
# 4. DKIM  (published p= must match the installed private key)
# ============================================================================
hdr "DKIM (TXT at ${SELECTOR}._domainkey.${DOMAIN})"
dkim_fqdn="${SELECTOR}._domainkey.${DOMAIN}"
dkim_txt="$(dns_txt "$dkim_fqdn" | grep -i 'v=DKIM1' | head -1)"
if [[ -z "$dkim_txt" ]]; then
  fail "No v=DKIM1 TXT record found at $dkim_fqdn"
else
  pub_published="$(printf '%s' "$dkim_txt" | sed -E 's/.*[;[:space:]]p=//; s/[;[:space:]].*$//' | tr -d ' ')"
  if [[ -z "$pub_published" ]]; then
    fail "DKIM record found but has an empty p= (key revoked?)"
  else
    pass "DKIM record present at $dkim_fqdn"
    keyfile="$DKIM_DIR/$DOMAIN/$SELECTOR.key"
    if command -v openssl >/dev/null 2>&1 && [[ -r "$keyfile" ]]; then
      pub_expected="$(openssl rsa -in "$keyfile" -pubout 2>/dev/null | grep -v '^-----' | tr -d '\n')"
      if [[ -z "$pub_expected" ]]; then
        soft "Could not derive the public key from $keyfile -- skipping match."
      elif [[ "$pub_published" == "$pub_expected" ]]; then
        pass "Published DKIM key MATCHES the installed private key"
      else
        fail "Published DKIM key does NOT match $keyfile (stale/short record?)"
      fi
    elif [[ ! -r "$keyfile" ]]; then
      soft "Cannot read $keyfile (run with sudo) -- skipped key-match; record exists."
    else
      soft "openssl not found -- skipped DKIM key-match; record exists."
    fi
  fi
fi

# ============================================================================
# 5. DMARC
# ============================================================================
hdr "DMARC (TXT at _dmarc.${DOMAIN})"
dmarc_txt="$(dns_txt "_dmarc.${DOMAIN}" | grep -i 'v=DMARC1' | head -1)"
if [[ -z "$dmarc_txt" ]]; then
  fail "No v=DMARC1 TXT record found at _dmarc.${DOMAIN}"
else
  info "found: $dmarc_txt"
  pass "DMARC record present"
  if   [[ "$dmarc_txt" =~ p=reject ]]; then pass "DMARC policy: p=reject (strongest)"
  elif [[ "$dmarc_txt" =~ p=quarantine ]]; then soft "DMARC policy: p=quarantine (tighten to reject once confident)"
  elif [[ "$dmarc_txt" =~ p=none ]]; then soft "DMARC policy: p=none (monitoring only -- installer default; move to quarantine/reject later)"
  else soft "DMARC record has no recognisable p= policy"; fi
fi

# ============================================================================
# 6. STARTTLS on :587
# ============================================================================
if [[ "$SKIP_TLS" == "Y" ]]; then
  hdr "STARTTLS on :587 (skipped with -T)"
elif ! command -v openssl >/dev/null 2>&1; then
  hdr "STARTTLS on :587"
  soft "openssl not found -- skipping the live TLS probe."
elif [[ -z "$PRIMARY_FQDN" ]]; then
  hdr "STARTTLS on :587"
  soft "Primary hostname unknown -- skipping the TLS probe."
else
  hdr "STARTTLS on :587 (submission)"
  tls_out="$(openssl s_client -starttls smtp -connect "${PRIMARY_FQDN}:587" \
               -servername "$PRIMARY_FQDN" -verify_return_error </dev/null 2>/dev/null)"
  if [[ -z "$tls_out" ]]; then
    fail "Could not establish STARTTLS to ${PRIMARY_FQDN}:587 (port blocked, or service down?)"
  else
    if printf '%s' "$tls_out" | grep -q 'Verify return code: 0 (ok)'; then
      pass "STARTTLS works and the certificate chain verifies"
    else
      vr="$(printf '%s' "$tls_out" | grep -i 'Verify return code' | tail -1 | sed 's/^ *//')"
      soft "STARTTLS works but verification was not clean: ${vr:-unknown}"
    fi
    subj_cn="$(printf '%s' "$tls_out" | grep -oiE 'subject=.*CN ?= ?[^,/]+' | sed -E 's/.*CN ?= ?//' | tr -d ' ' | tail -1)"
    if [[ -n "$subj_cn" ]]; then
      if [[ "$(nodot "$subj_cn")" == "$(nodot "$PRIMARY_FQDN")" ]]; then
        pass "Certificate CN matches ${PRIMARY_FQDN}"
      else
        soft "Certificate CN is '$subj_cn' (connected to $PRIMARY_FQDN)"
      fi
    fi
  fi
fi

# ============================================================================
# summary
# ============================================================================
hdr "Summary"
info "Passed: $PASS   Problems: $FAILN   Warnings: $WARN"
if (( FAILN == 0 )); then
  ok "No blocking problems found. For a real-world score, also send a message to"
  ok "a seed test such as mail-tester.com and review SPF/DKIM/DMARC alignment."
  exit 0
else
  bad "Found $FAILN problem(s) above -- fix these before sending production mail."
  info "Tip: DNS changes can take time to propagate; re-run after updating records."
  exit 1
fi
