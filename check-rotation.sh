#!/usr/bin/env bash
# =============================================================================
# check-rotation.sh  --  verify outbound IP (egress source) rotation in KumoMTA
# -----------------------------------------------------------------------------
# KumoMTA distributes sends across the IPs in an egress pool using *Weighted
# Round Robin* (WRR). That distribution is PROBABILISTIC and only emerges at
# volume: a couple of spaced-out test mails will keep coming from the first IP
# (an idle scheduled queue resets its round-robin state after ~10 min). See
#   https://docs.kumomta.com/userguide/configuration/sendingips/
#
# This helper injects a BURST of messages to ONE recipient (so they share a
# single scheduled queue and actually rotate), then tallies which egress source
# each delivery attempt used, and checks each source IP's PTR / reverse DNS.
#
#   sudo bash check-rotation.sh you@example.com            # burst of 20
#   sudo bash check-rotation.sh -n 30 you@example.com      # burst of 30
#   sudo bash check-rotation.sh -t you@example.com         # tally only, no send
#
# Use an inbox you control (e.g. a Gmail address); deliveries to a single
# provider share one queue, which is exactly what exercises the rotation.
# =============================================================================
set -euo pipefail

# --- KumoMTA paths (match install.sh) ----------------------------------------
KUMO_ETC="/opt/kumomta/etc"
POLICY_DIR="$KUMO_ETC/policy"
SOURCES_TOML="$POLICY_DIR/sources.toml"
DKIM_TOML="$POLICY_DIR/dkim_data.toml"
LOG_DIR="/var/log/kumomta"
INJECT_URL="http://127.0.0.1:8000/api/inject/v1"

# --- output helpers (match the rest of the project) --------------------------
if [[ -t 1 || -e /dev/tty ]]; then
  RED=$'\033[0;31m'; GRN=$'\033[0;32m'; YEL=$'\033[1;33m'; CYN=$'\033[0;36m'; NC=$'\033[0m'
else
  RED=""; GRN=""; YEL=""; CYN=""; NC=""
fi
info() { printf '  %b•%b %s\n' "$CYN" "$NC" "$*"; }
ok()   { printf '  %b✓%b %s\n' "$GRN" "$NC" "$*"; }
warn() { printf '  %b▲%b %s\n' "$YEL" "$NC" "$*"; }
die()  { printf '  %b✗%b %s\n' "$RED" "$NC" "$*"; exit 1; }
hdr()  { printf '\n%s\n%s\n%s\n' "$(printf '%.0s━' {1..60})" "$*" "$(printf '%.0s━' {1..60})"; }

usage() {
  cat <<USAGE
Usage: sudo bash check-rotation.sh [-n COUNT] [-s SENDER] [-w SECONDS] [-t] RECIPIENT

  RECIPIENT    address to send the burst to (use an inbox you control)
  -n COUNT     number of messages to inject (default 20)
  -s SENDER    envelope sender (default postmaster@<your sending domain>)
  -w SECONDS   seconds to wait for delivery attempts before tallying (default 20)
  -t           tally only: report current distribution for RECIPIENT, do not send
  -h           show this help
USAGE
}

# --- args --------------------------------------------------------------------
COUNT=20
SENDER=""
WAIT=20
TALLY_ONLY="N"
while getopts ":n:s:w:th" opt; do
  case "$opt" in
    n) COUNT="$OPTARG" ;;
    s) SENDER="$OPTARG" ;;
    w) WAIT="$OPTARG" ;;
    t) TALLY_ONLY="Y" ;;
    h) usage; exit 0 ;;
    :) die "Option -$OPTARG requires an argument. (-h for help)" ;;
    \?) die "Unknown option -$OPTARG. (-h for help)" ;;
  esac
done
shift $((OPTIND - 1))
RCPT="${1:-}"

[[ $EUID -eq 0 ]] || die "Please run as root (sudo bash $0) -- reading $LOG_DIR needs root."
[[ -n "$RCPT" ]]  || { usage; die "RECIPIENT is required."; }
[[ "$RCPT" == *@*.* ]] || die "RECIPIENT '$RCPT' does not look like an email address."
[[ "$COUNT" =~ ^[0-9]+$ && "$COUNT" -ge 1 ]] || die "COUNT must be a positive integer."
[[ "$WAIT"  =~ ^[0-9]+$ ]] || die "WAIT must be an integer number of seconds."
[[ -f "$SOURCES_TOML" ]] || die "Not found: $SOURCES_TOML -- run install.sh first."

# --- parse sources.toml: ordered source name -> IP + EHLO --------------------
SRC_NAMES=(); SRC_IPS=(); SRC_EHLOS=()
parse_sources() {
  local line idx
  while IFS= read -r line; do
    if [[ "$line" =~ ^\[source\.\"(.+)\"\] ]]; then
      SRC_NAMES+=("${BASH_REMATCH[1]}"); SRC_IPS+=(""); SRC_EHLOS+=("")
    elif (( ${#SRC_NAMES[@]} > 0 )); then
      idx=$(( ${#SRC_NAMES[@]} - 1 ))
      if [[ "$line" =~ ^source_address[[:space:]]*=[[:space:]]*\"(.+)\" ]]; then
        SRC_IPS[$idx]="${BASH_REMATCH[1]}"
      elif [[ "$line" =~ ^ehlo_domain[[:space:]]*=[[:space:]]*\"(.+)\" ]]; then
        SRC_EHLOS[$idx]="${BASH_REMATCH[1]}"
      fi
    fi
  done < "$SOURCES_TOML"
}
parse_sources
(( ${#SRC_NAMES[@]} > 0 )) || die "No [source.*] entries found in $SOURCES_TOML."

# --- read all (zstd / gzip / plain) log records ------------------------------
collect_logs() {
  local f
  while IFS= read -r f; do
    [[ -f "$f" ]] || continue
    { zstdcat "$f" 2>/dev/null || zcat "$f" 2>/dev/null || cat "$f" 2>/dev/null; } || true
  done < <(find "$LOG_DIR" -type f 2>/dev/null)
}

# Count attempts to RCPT grouped by egress source. Output: "<count> <source>".
# (Any record carrying the recipient AND an egress_source counts -- Delivery,
# TransientFailure, Bounce -- since the source is chosen per attempt.)
tally_sources() {
  collect_logs \
    | grep -a -F "$RCPT" \
    | grep -aoE '"egress_source":"[^"]+"' \
    | sed -E 's/.*"egress_source":"([^"]+)".*/\1/' \
    | sort | uniq -c || true
}

# count_for <source-name> <tally-text>  ->  prints the integer count (0 if none)
count_for() {
  local name="$1" text="$2" c
  c="$(awk -v n="$name" '$2 == n {print $1; found=1} END {if (!found) print 0}' <<< "$text")"
  printf '%s' "${c:-0}"
}

print_distribution() {
  local before_text="$1" after_text="$2"
  local i name ip ehlo b a d total=0 used=0
  printf '\n  %-8s %-18s %-30s %s\n' "SOURCE" "IP" "EHLO / HOSTNAME" "USED"
  printf '  %-8s %-18s %-30s %s\n' "------" "------------------" "------------------------------" "----"
  for i in "${!SRC_NAMES[@]}"; do
    name="${SRC_NAMES[$i]}"; ip="${SRC_IPS[$i]:-?}"; ehlo="${SRC_EHLOS[$i]:-?}"
    b="$(count_for "$name" "$before_text")"
    a="$(count_for "$name" "$after_text")"
    d=$(( a - b )); (( d < 0 )) && d=0
    total=$(( total + d )); (( d > 0 )) && used=$(( used + 1 ))
    printf '  %-8s %-18s %-30s %s\n' "$name" "$ip" "$ehlo" "$d"
  done
  DIST_TOTAL="$total"; DIST_USED="$used"
}

check_ptr() {
  hdr "PTR / reverse DNS (each source IP must resolve to its hostname)"
  if ! command -v dig >/dev/null 2>&1; then
    warn "dig not found (install dnsutils/bind-utils) -- skipping PTR check."
    return 0
  fi
  local i ip ehlo ptr_all ptr
  for i in "${!SRC_NAMES[@]}"; do
    ip="${SRC_IPS[$i]:-}"; ehlo="${SRC_EHLOS[$i]:-}"
    [[ -n "$ip" ]] || continue
    ptr_all="$(dig +short -x "$ip" 2>/dev/null || true)"
    ptr="${ptr_all%%$'\n'*}"
    if [[ -z "$ptr" ]]; then
      warn "$ip  ->  (no PTR record)   expected: ${ehlo}."
    elif [[ "${ptr%.}" == "${ehlo%.}" ]]; then
      ok   "$ip  ->  ${ptr%.}"
    else
      warn "$ip  ->  ${ptr%.}   (expected ${ehlo%.})"
    fi
  done
}

# --- main --------------------------------------------------------------------
hdr "KumoMTA egress-source rotation check"
info "Recipient        : $RCPT"
info "Egress sources   : ${#SRC_NAMES[@]} (${SRC_NAMES[*]})"
systemctl is-active --quiet kumomta 2>/dev/null \
  && ok "kumomta service is running." \
  || warn "kumomta service does not look active (journalctl -u kumomta)."

if [[ "$TALLY_ONLY" == "Y" ]]; then
  hdr "Current distribution for $RCPT (cumulative, from retained logs)"
  print_distribution "" "$(tally_sources)"
  info "Counted $DIST_TOTAL attempt(s) across $DIST_USED of ${#SRC_NAMES[@]} source(s)."
  check_ptr
  exit 0
fi

command -v curl >/dev/null 2>&1 || die "curl not found -- cannot inject."
(( COUNT >= ${#SRC_NAMES[@]} * 3 )) || \
  warn "COUNT=$COUNT is low for ${#SRC_NAMES[@]} IPs; rotation is probabilistic -- consider -n $(( ${#SRC_NAMES[@]} * 4 )) or more."

# Derive the sending domain / envelope sender if not provided.
if [[ -z "$SENDER" ]]; then
  MAIN_DOMAIN="$(awk -F'"' '/^\[domain\./ {print $2; exit}' "$DKIM_TOML" 2>/dev/null || true)"
  [[ -n "${MAIN_DOMAIN:-}" ]] || MAIN_DOMAIN="${SRC_EHLOS[0]#*.}"   # fallback: strip first label of ip-1 EHLO
  [[ -n "$MAIN_DOMAIN" ]] || die "Could not determine sending domain; pass one with -s sender@domain."
  SENDER="postmaster@${MAIN_DOMAIN}"
fi
info "Envelope sender  : $SENDER"

# Baseline (so we only count THIS run's attempts, not previous ones).
BEFORE="$(tally_sources)"

hdr "Injecting a burst of $COUNT message(s) via $INJECT_URL"
RUN_ID="$(date -u +%Y%m%d%H%M%S)"
accepted=0; failed=0
for (( i = 1; i <= COUNT; i++ )); do
  subj="rotation-check ${RUN_ID} #${i}"
  # \n inside content is a JSON newline escape (literal backslash-n), per the
  # KumoMTA HTTP injection API.
  content="Subject: ${subj}\nFrom: ${SENDER}\nTo: ${RCPT}\n\nRotation check ${i}/${COUNT} (run ${RUN_ID})."
  payload="{\"envelope_sender\":\"${SENDER}\",\"recipients\":[{\"email\":\"${RCPT}\"}],\"content\":\"${content}\"}"
  code="$(curl -s -o /dev/null -w '%{http_code}' -H 'Content-Type: application/json' \
            "$INJECT_URL" -d "$payload" 2>/dev/null || echo 000)"
  if [[ "$code" == "200" ]]; then accepted=$(( accepted + 1 )); else failed=$(( failed + 1 )); fi
done
if (( accepted == 0 )); then
  die "No injections were accepted (is the HTTP listener up on 127.0.0.1:8000?). Check: journalctl -u kumomta -n 50"
fi
ok "Injected: $accepted accepted, $failed failed."

info "Waiting ${WAIT}s for delivery attempts to be logged..."
sleep "$WAIT"

hdr "Egress source usage for this run"
print_distribution "$BEFORE" "$(tally_sources)"

echo
info "Counted $DIST_TOTAL logged attempt(s) using $DIST_USED of ${#SRC_NAMES[@]} source(s)."
if (( DIST_USED >= 2 )); then
  ok "Rotation CONFIRMED -- more than one egress source was used."
elif (( DIST_TOTAL == 0 )); then
  warn "No attempts logged yet. Logs can lag (segments rotate every minute) and"
  warn "remote delivery may be deferred. Re-check shortly:  sudo bash $0 -t $RCPT"
else
  warn "Only one source seen so far. This is normal at low volume / if attempts"
  warn "are still pending (WRR is probabilistic; idle queues reset to the first"
  warn "IP after ~10 min). Send more (-n) in one burst, then:  sudo bash $0 -t $RCPT"
fi

check_ptr

echo
info "Inspect live results with:  journalctl -u kumomta -f"
info "Receiver-side check: open the messages in Gmail -> 'Show original' and"
info "compare the 'Received: from' IPs across several of them."
