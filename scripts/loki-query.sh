#!/usr/bin/env bash
set -euo pipefail

# CLI wrapper for Loki LogQL queries.
# Sources lib/common.sh for detect_loki() endpoint auto-detection.

SCRIPT_DIR="$(cd "$(dirname "${BASH_SOURCE[0]}")" && pwd)"
source "${SCRIPT_DIR}/lib/common.sh"

# Defaults
MODE="range"
SINCE="1h"
START=""
END=""
LIMIT=100
DIRECTION="backward"
FORMAT="json"
QUERY=""

usage() {
  cat <<EOF
Usage: $(basename "$0") [OPTIONS] <logql-query>

Query Loki logs from the command line.

Options:
  --mode=MODE         range (default) or instant
  --since=DURATION    Time window: 1h, 24h, 7d, etc. (default: 1h)
  --start=EPOCH       Explicit start time (epoch seconds)
  --end=EPOCH         Explicit end time (epoch seconds)
  --limit=N           Max results (default: 100)
  --direction=DIR     backward (default) or forward
  --format=FMT        json (default) or text

Examples:
  $(basename "$0") '{hostname="nas-01"} |= "error"'
  $(basename "$0") --since=24h '{unit="auto-upgrade.service"}'
  $(basename "$0") --mode=instant 'sum by (hostname) (count_over_time({job="systemd-journal"}[1h]))'
  $(basename "$0") --format=text --since=6h '{unit="sshd.service"} |~ "Failed"'
EOF
}

# Parse Nh/Nd/Nw/Nm duration into epoch seconds (start time)
parse_since() {
  local val="$1"
  local num unit
  num="${val%%[hHdDmMwW]*}"
  unit="${val##*[0-9]}"
  case "$unit" in
    h|H) date -d "${num} hours ago" +%s ;;
    d|D) date -d "${num} days ago" +%s ;;
    m|M) date -d "${num} minutes ago" +%s ;;
    w|W) date -d "${num} weeks ago" +%s ;;
    *)   log_error "unsupported time unit in '${val}' (use h/d/m/w)"; exit 1 ;;
  esac
}

while [[ $# -gt 0 ]]; do
  case "$1" in
    --mode=*)      MODE="${1#--mode=}"; shift ;;
    --mode)        MODE="$2"; shift 2 ;;
    --since=*)     SINCE="${1#--since=}"; shift ;;
    --since)       SINCE="$2"; shift 2 ;;
    --start=*)     START="${1#--start=}"; shift ;;
    --start)       START="$2"; shift 2 ;;
    --end=*)       END="${1#--end=}"; shift ;;
    --end)         END="$2"; shift 2 ;;
    --limit=*)     LIMIT="${1#--limit=}"; shift ;;
    --limit)       LIMIT="$2"; shift 2 ;;
    --direction=*) DIRECTION="${1#--direction=}"; shift ;;
    --direction)   DIRECTION="$2"; shift 2 ;;
    --format=*)    FORMAT="${1#--format=}"; shift ;;
    --format)      FORMAT="$2"; shift 2 ;;
    -h|--help)     usage; exit 0 ;;
    -*)            log_error "unknown option: $1"; usage >&2; exit 1 ;;
    *)
      if [[ -z "$QUERY" ]]; then
        QUERY="$1"; shift
      else
        log_error "unexpected argument: $1"; exit 1
      fi
      ;;
  esac
done

if [[ -z "$QUERY" ]]; then
  log_error "no LogQL query provided"
  usage >&2
  exit 1
fi

check_deps curl jq
detect_loki || { echo '{}'; exit 1; }

result=""
if [[ "$MODE" == "range" ]]; then
  [[ -z "$END" ]] && END=$(date +%s)
  [[ -z "$START" ]] && START=$(parse_since "$SINCE")

  result=$(curl -sG --max-time 30 "$LOKI/loki/api/v1/query_range" \
    --data-urlencode "query=${QUERY}" \
    --data-urlencode "start=${START}" \
    --data-urlencode "end=${END}" \
    --data-urlencode "limit=${LIMIT}" \
    --data-urlencode "direction=${DIRECTION}" 2>/dev/null) || { echo '{}'; exit 1; }

elif [[ "$MODE" == "instant" ]]; then
  local_time=$(date +%s)
  result=$(curl -sG --max-time 30 "$LOKI/loki/api/v1/query" \
    --data-urlencode "query=${QUERY}" \
    --data-urlencode "time=${local_time}" 2>/dev/null) || { echo '{}'; exit 1; }

else
  log_error "unknown mode: $MODE (use range or instant)"
  exit 1
fi

if [[ -z "$result" ]]; then
  echo '{}'
  exit 1
fi

if [[ "$FORMAT" == "text" ]]; then
  echo "$result" | jq -r '
    .data.result[] |
    .stream as $s |
    .values[] |
    "\(.[0] | tonumber / 1000000000 | strftime("%Y-%m-%d %H:%M:%S")) [\($s.hostname // "?")] [\($s.unit // $s.job // "?")] \(.[1])"
  ' 2>/dev/null || echo "(no results or parse error)"
else
  echo "$result" | jq . 2>/dev/null || echo "$result"
fi
