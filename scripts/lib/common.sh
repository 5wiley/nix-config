#!/usr/bin/env bash
# Shared library for infrastructure tooling scripts.
# Source this file; do not execute directly.
#
# Provides: colors, logging, dependency checking, Forgejo API helpers,
#           Loki endpoint detection, and time formatting utilities.

# Guard against direct execution
if [[ "${BASH_SOURCE[0]}" == "${0}" ]]; then
  echo "error: common.sh is a library — source it, don't execute it" >&2
  exit 1
fi

# ---------- Colors (disabled when not a terminal) ----------

if [[ -t 1 ]]; then
  RED='\033[0;31m'
  GREEN='\033[0;32m'
  YELLOW='\033[0;33m'
  BLUE='\033[0;34m'
  BOLD='\033[1m'
  NC='\033[0m'
else
  RED='' GREEN='' YELLOW='' BLUE='' BOLD='' NC=''
fi

# ---------- Logging ----------

log_error() { echo -e "${RED}error:${NC} $*" >&2; }
log_info()  { echo -e "${BLUE}::${NC} $*" >&2; }

# ---------- Dependency checks ----------

# Usage: check_deps curl jq yq
check_deps() {
  local missing=()
  for cmd in "$@"; do
    command -v "$cmd" &>/dev/null || missing+=("$cmd")
  done
  if [[ ${#missing[@]} -gt 0 ]]; then
    log_error "missing required tools: ${missing[*]}"
    exit 1
  fi
}

# ---------- Loki endpoint detection ----------

detect_loki() {
  if curl -sf --max-time 3 https://loki.bobtail-clownfish.ts.net/ready >/dev/null 2>&1; then
    LOKI="https://loki.bobtail-clownfish.ts.net"
  elif curl -sf --max-time 3 http://nas-01.lan:3100/ready >/dev/null 2>&1; then
    LOKI="http://nas-01.lan:3100"
  else
    log_error "Loki appears to be down (both Tailscale and LAN endpoints unreachable)"
    return 1
  fi
}

# ---------- Formatting helpers ----------

status_color() {
  case "$1" in
    success)   echo -n "${GREEN}" ;;
    failure)   echo -n "${RED}" ;;
    running)   echo -n "${BLUE}" ;;
    cancelled) echo -n "${YELLOW}" ;;
    *)         echo -n "" ;;
  esac
}

relative_time() {
  local timestamp="$1"
  local then_epoch now_epoch diff
  then_epoch=$(date -d "$timestamp" +%s 2>/dev/null) || return
  now_epoch=$(date +%s)
  diff=$((now_epoch - then_epoch))
  if (( diff < 60 )); then echo "${diff}s ago"
  elif (( diff < 3600 )); then echo "$((diff / 60))m ago"
  elif (( diff < 86400 )); then echo "$((diff / 3600))h ago"
  else echo "$((diff / 86400))d ago"
  fi
}
