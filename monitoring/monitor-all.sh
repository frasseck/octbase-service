#!/usr/bin/env bash
#
# monitor-all.sh — Octbase fleet monitor (runs as root via octbase-monitor.timer).
#
# For every client registered in /etc/octbase/clients.d/*.conf (files written
# by create-instance.yml) it:
#   1. runs check-health.sh inside the client's rootless-podman context
#      (container layer + application /health layer),
#   2. optionally probes the public edge: https://<domain>/health,
#   3. measures the account's disk usage (du of HOME_DIR, cached — refreshed
#      at most every DISK_INTERVAL seconds) against DISK_QUOTA_GB and flags
#      DEGRADED at DISK_ALERT_PCT% of the quota,
# then aggregates everything into /var/lib/octbase-monitor/status.json and,
# on any per-client state CHANGE, mails ALERT_EMAIL (via sendmail) and logs
# to stderr (→ journal).
#
# Usage: monitor-all.sh [--print]
#   --print   also pretty-print the per-client states to stdout
#
# Exit codes: 0 all OK, 1 any DEGRADED, 2 any DOWN, 3 environment error.
set -uo pipefail

CONF=/etc/octbase/monitor.conf
[ -f "$CONF" ] && . "$CONF"
ALERT_EMAIL="${ALERT_EMAIL:-}"
EDGE_PROBE="${EDGE_PROBE:-1}"
DISK_ALERT_PCT="${DISK_ALERT_PCT:-90}"
DISK_INTERVAL="${DISK_INTERVAL:-3600}"   # seconds between du runs per client

CHECK=/usr/local/lib/octbase/check-health.sh
REGISTRY=/etc/octbase/clients.d
STATE_DIR=/var/lib/octbase-monitor
STATUS_FILE="$STATE_DIR/status.json"
LAST_FILE="$STATE_DIR/last-states"

PRINT=0
[ "${1:-}" = "--print" ] && PRINT=1

[ -x "$CHECK" ] || { echo "missing $CHECK — run install-monitoring.yml" >&2; exit 3; }
mkdir -p "$STATE_DIR"

worse() { # echo the more severe of two states
  case "$1$2" in
    *DOWN*) echo DOWN ;;
    *DEGRADED*) echo DEGRADED ;;
    *) echo OK ;;
  esac
}

overall=OK
exit_code=0
changes=""
json_clients=""
declare -A new_states

shopt -s nullglob
confs=("$REGISTRY"/*.conf)
if [ ${#confs[@]} -eq 0 ]; then
  echo "no clients registered in $REGISTRY" >&2
fi

# Registry confs may override EDGE_PROBE per client (e.g. while a new
# client's DNS/edge setup is still pending) — remember the global default.
GLOBAL_EDGE_PROBE="$EDGE_PROBE"

for f in "${confs[@]}"; do
  NAME="" USER_ACCT="" DOMAIN="" FRONTEND_PORT="" API_PORT="" HOME_DIR="" DISK_QUOTA_GB=""
  EDGE_PROBE="$GLOBAL_EDGE_PROBE"
  . "$f"
  [ -n "$NAME" ] && [ -n "$USER_ACCT" ] || continue

  state=OK detail=""
  uid="$(id -u "$USER_ACCT" 2>/dev/null)"
  if [ -z "$uid" ]; then
    state=DOWN detail="linux account missing"
  else
    out="$(sudo -u "$USER_ACCT" XDG_RUNTIME_DIR="/run/user/$uid" \
           "$CHECK" --project octbase --json 2>/dev/null)"
    rc=$?
    case $rc in
      0) state=OK detail="stack ok" ;;
      1) state=DEGRADED detail="stack degraded" ;;
      *) state=DOWN detail="stack down (rc=$rc)" ;;
    esac
    # Edge probe: the same /health, but through DNS + edge proxy + TLS.
    if [ "$EDGE_PROBE" = 1 ] && [ -n "$DOMAIN" ]; then
      # NB: no "|| echo 000" inside the substitution — a failing curl still
      # prints its -w output, which would yield a two-line value.
      code="$(curl -so /dev/null -w '%{http_code}' --max-time 10 "https://$DOMAIN/health" 2>/dev/null)" || code=000
      if [ "$code" = "200" ]; then
        detail="$detail; edge 200"
      else
        state="$(worse "$state" DEGRADED)"
        detail="$detail; edge $code (dns/proxy/tls?)"
      fi
    fi
  fi

  # Disk usage vs quota. du is not free, so the value is cached and refreshed
  # at most every DISK_INTERVAL seconds; the freshest cached value is judged
  # on every run.
  disk_json=""
  if [ -n "$HOME_DIR" ] && [ -d "$HOME_DIR" ]; then
    cache="$STATE_DIR/disk-$NAME"
    now="$(date +%s)"
    bytes="" ts=0
    [ -f "$cache" ] && read -r bytes ts < "$cache"
    if [ -z "$bytes" ] || [ $((now - ts)) -ge "$DISK_INTERVAL" ]; then
      bytes="$(du -sb --one-file-system "$HOME_DIR" 2>/dev/null | cut -f1)"
      [ -n "$bytes" ] && echo "$bytes $now" > "$cache"
    fi
    if [ -n "$bytes" ] && [ "${DISK_QUOTA_GB:-0}" -gt 0 ] 2>/dev/null; then
      pct=$(( bytes * 100 / (DISK_QUOTA_GB * 1024 * 1024 * 1024) ))
      disk_json=",\"disk_bytes\":$bytes,\"disk_quota_gb\":$DISK_QUOTA_GB,\"disk_pct\":$pct"
      if [ "$pct" -ge "$DISK_ALERT_PCT" ]; then
        state="$(worse "$state" DEGRADED)"
        detail="$detail; disk ${pct}% of ${DISK_QUOTA_GB}G quota (ALERT >=${DISK_ALERT_PCT}%)"
      else
        detail="$detail; disk ${pct}% of ${DISK_QUOTA_GB}G"
      fi
    elif [ -n "$bytes" ]; then
      disk_json=",\"disk_bytes\":$bytes"
    fi
  fi

  new_states["$NAME"]="$state"
  overall="$(worse "$overall" "$state")"
  case $state in DEGRADED) [ $exit_code -lt 1 ] && exit_code=1 ;; DOWN) exit_code=2 ;; esac

  # Unseen clients count as previously OK: a client that is already broken
  # the first time it is observed must alert too, not stay silently down.
  prev="$(grep "^$NAME=" "$LAST_FILE" 2>/dev/null | cut -d= -f2)"
  prev="${prev:-OK}"
  if [ "$prev" != "$state" ]; then
    changes="${changes}${NAME}: ${prev} -> ${state} (${detail})\n"
  fi

  detail="${detail//$'\n'/ }"   # keep status.json single-line-safe
  [ -n "$json_clients" ] && json_clients="$json_clients,"
  json_clients="$json_clients\"$NAME\":{\"state\":\"$state\",\"detail\":\"${detail//\"/\'}\"$disk_json}"
  [ $PRINT -eq 1 ] && printf '%-12s %-9s %s\n' "$NAME" "$state" "$detail"
done

# Write-then-rename: readers of status.json must never see a partial file.
printf '{"overall":"%s","ts":"%s","clients":{%s}}\n' \
  "$overall" "$(date -u +%Y-%m-%dT%H:%M:%SZ)" "$json_clients" > "$STATUS_FILE.new"
mv "$STATUS_FILE.new" "$STATUS_FILE"

: > "$LAST_FILE.new"
for n in "${!new_states[@]}"; do echo "$n=${new_states[$n]}" >> "$LAST_FILE.new"; done
mv "$LAST_FILE.new" "$LAST_FILE"

if [ -n "$changes" ]; then
  printf 'STATE CHANGES:\n%b' "$changes" >&2
  if [ -n "$ALERT_EMAIL" ] && command -v sendmail >/dev/null 2>&1; then
    {
      echo "To: $ALERT_EMAIL"
      echo "Subject: [octbase-monitor] state change on $(hostname) — overall $overall"
      echo
      printf '%b' "$changes"
      echo
      echo "Full status: $STATUS_FILE"
    } | sendmail -t
  fi
fi

[ $PRINT -eq 1 ] && echo "==> overall: $overall"
exit $exit_code
