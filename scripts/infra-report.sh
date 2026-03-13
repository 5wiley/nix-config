#!/usr/bin/env bash
set -euo pipefail

# Run all infrastructure report queries in parallel and output combined JSON.
# Uses loki-query.sh for Loki queries, direct curl for Prometheus alerts.

SCRIPT_DIR="$(cd "$(dirname "${BASH_SOURCE[0]}")" && pwd)"
source "${SCRIPT_DIR}/lib/common.sh"

SINCE="24h"

usage() {
  cat <<EOF
Usage: $(basename "$0") [OPTIONS]

Run infrastructure health queries in parallel and output combined JSON.

Options:
  --since=DURATION    Time window: 1h, 24h, 7d, etc. (default: 24h)
  -h, --help          Show this help

Examples:
  $(basename "$0")              # Last 24 hours (default)
  $(basename "$0") --since=12h  # Last 12 hours
  $(basename "$0") --since=7d   # Last 7 days
EOF
}

while [[ $# -gt 0 ]]; do
  case "$1" in
    --since=*) SINCE="${1#--since=}"; shift ;;
    --since)   SINCE="$2"; shift 2 ;;
    -h|--help) usage; exit 0 ;;
    *)         log_error "unexpected: $1"; usage >&2; exit 1 ;;
  esac
done

check_deps curl jq
detect_loki || exit 1

LQ="${SCRIPT_DIR}/loki-query.sh"
LOG_HOSTS=$("${SCRIPT_DIR}/host-lookup.sh" --log-hosts | tr '\n' ' ')

# Temp dir for parallel results
TMPDIR=$(mktemp -d)
trap 'rm -rf "$TMPDIR"' EXIT

# Helper: run loki-query.sh, write {} on failure
lq() {
  local outfile="$1"; shift
  "$LQ" "$@" > "$TMPDIR/$outfile" 2>/dev/null || echo '{}' > "$TMPDIR/$outfile"
}

# --- Launch all queries in parallel ---

# 1. Hosts actively reporting
lq 01-hosts-reporting.json --mode=instant \
  'count by (hostname) (count_over_time({job="systemd-journal"}[1h]))' &

# 2. Error counts by host
lq 02-error-counts.json --mode=instant \
  "sum by (hostname) (count_over_time({job=\"systemd-journal\", priority=~\"err|crit|alert|emerg\"}[${SINCE}]))" &

# 3. Top error-producing units
lq 03-top-error-units.json --mode=instant \
  "topk(15, sum by (hostname, unit) (count_over_time({job=\"systemd-journal\", priority=~\"err|crit|alert|emerg\"}[${SINCE}])))" &

# 4. Error log lines (syslog priority)
lq 04-error-lines.json --since="$SINCE" --limit=200 \
  '{job="systemd-journal", priority=~"err|crit|alert|emerg"}' &

# 4b. Application-level errors (text-based)
lq 04b-app-errors.json --mode=instant \
  "topk(20, sum by (hostname, unit) (count_over_time({job=\"systemd-journal\"} |~ \"(?i)\\\\bERROR\\\\b\" [${SINCE}])))" &

# 5. Auto-upgrade outcomes
lq 05-auto-upgrades.json --since="$SINCE" --limit=200 \
  '{unit="auto-upgrade.service"} |~ "completed successfully|FATAL|failed|started"' &

# 6. Restic backup outcomes
lq 06-restic-backups.json --since="$SINCE" --limit=100 \
  '{hostname="nas-01"} |= "restic-backups" |~ "Finished|Failed|Starting"' &

# 7. UPS status
lq 07-ups-status.json --since="$SINCE" --limit=50 \
  '{unit="upsmon.service"} |~ "unavailable|connect failed|Communications restored"' &

# 8. Service failures
lq 08-service-failures.json --since="$SINCE" --limit=200 \
  '{job="systemd-journal"} |~ "Failed to start|entered failed state|Main process exited, code=exited, status=1"' &

# 9. OOM kills / ZFS issues
lq 09-oom-zfs.json --since="$SINCE" --limit=100 \
  '{job="systemd-journal"} |~ "Out of memory|oom-kill|Killed process|FAULTED|degraded"' &

# 10. Kernel errors
lq 10-kernel-errors.json --since="$SINCE" --limit=100 \
  '{job="systemd-journal", transport="kernel", priority=~"err|crit|alert|emerg"}' &

# 11. SSH auth failures
lq 11-ssh-failures.json --since="$SINCE" --limit=100 \
  '{unit="sshd.service"} |~ "Failed|Invalid user"' &

# 12. Syncoid errors
lq 12-syncoid.json --since="$SINCE" --limit=100 \
  '{job="systemd-journal"} |~ "syncoid" |~ "error|fail|CRITICAL"' &

# 13. Forgejo log scraper errors
lq 13-forgejo-scraper.json --since="$SINCE" --limit=50 \
  '{unit="forgejo-log-scraper.service"} |~ "ERROR"' &

# 14. Forgejo CI failures
lq 14-forgejo-ci.json --since="$SINCE" --limit=50 \
  '{job="forgejo-actions"} |~ "FAIL|ERROR|error"' &

# 15. Prometheus alerts
curl -sf --max-time 10 http://admin:9001/api/v1/alerts \
  > "$TMPDIR/15-prometheus-alerts.json" 2>/dev/null \
  || echo '{}' > "$TMPDIR/15-prometheus-alerts.json" &

# 16. Disk/store usage (Prometheus)
curl -sf --max-time 10 -G http://admin:9001/api/v1/query \
  --data-urlencode 'query=100 - ((node_filesystem_avail_bytes{fstype!~"tmpfs|overlay|nsfs|squashfs"} / node_filesystem_size_bytes{fstype!~"tmpfs|overlay|nsfs|squashfs"}) * 100)' \
  --data-urlencode "time=$(date +%s)" \
  > "$TMPDIR/16-disk-usage.json" 2>/dev/null \
  || echo '{}' > "$TMPDIR/16-disk-usage.json" &

# Wait for all
wait

# --- Assemble combined JSON ---
assemble_args=()
for f in "$TMPDIR"/*.json; do
  key=$(basename "$f" .json | sed 's/^[0-9]*[a-b]*-//')
  assemble_args+=(--slurpfile "$key" "$f")
done

jq -n \
  --arg window "$SINCE" \
  --arg log_hosts "$LOG_HOSTS" \
  --arg generated_at "$(date -u +%Y-%m-%dT%H:%M:%SZ)" \
  --slurpfile hosts_reporting    "$TMPDIR/01-hosts-reporting.json" \
  --slurpfile error_counts       "$TMPDIR/02-error-counts.json" \
  --slurpfile top_error_units    "$TMPDIR/03-top-error-units.json" \
  --slurpfile error_lines        "$TMPDIR/04-error-lines.json" \
  --slurpfile app_errors         "$TMPDIR/04b-app-errors.json" \
  --slurpfile auto_upgrades      "$TMPDIR/05-auto-upgrades.json" \
  --slurpfile restic_backups     "$TMPDIR/06-restic-backups.json" \
  --slurpfile ups_status         "$TMPDIR/07-ups-status.json" \
  --slurpfile service_failures   "$TMPDIR/08-service-failures.json" \
  --slurpfile oom_zfs            "$TMPDIR/09-oom-zfs.json" \
  --slurpfile kernel_errors      "$TMPDIR/10-kernel-errors.json" \
  --slurpfile ssh_failures       "$TMPDIR/11-ssh-failures.json" \
  --slurpfile syncoid            "$TMPDIR/12-syncoid.json" \
  --slurpfile forgejo_scraper    "$TMPDIR/13-forgejo-scraper.json" \
  --slurpfile forgejo_ci         "$TMPDIR/14-forgejo-ci.json" \
  --slurpfile prometheus_alerts  "$TMPDIR/15-prometheus-alerts.json" \
  --slurpfile disk_usage         "$TMPDIR/16-disk-usage.json" \
  '{
    meta: {
      window: $window,
      expected_hosts: ($log_hosts | split(" ") | map(select(. != ""))),
      generated_at: $generated_at
    },
    hosts_reporting: $hosts_reporting[0],
    error_counts: $error_counts[0],
    top_error_units: $top_error_units[0],
    error_lines: $error_lines[0],
    app_errors: $app_errors[0],
    auto_upgrades: $auto_upgrades[0],
    restic_backups: $restic_backups[0],
    ups_status: $ups_status[0],
    service_failures: $service_failures[0],
    oom_zfs: $oom_zfs[0],
    kernel_errors: $kernel_errors[0],
    ssh_failures: $ssh_failures[0],
    syncoid: $syncoid[0],
    forgejo_scraper: $forgejo_scraper[0],
    forgejo_ci: $forgejo_ci[0],
    prometheus_alerts: $prometheus_alerts[0],
    disk_usage: $disk_usage[0]
  }'
