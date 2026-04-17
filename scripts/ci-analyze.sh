#!/usr/bin/env bash
set -euo pipefail

SCRIPT_DIR="$(cd "$(dirname "${BASH_SOURCE[0]}")" && pwd)"
source "${SCRIPT_DIR}/lib/common.sh"

usage() {
  cat <<EOF
Usage: $(basename "$0") <run-number> [options]

Analyze a failed CI run: fetch logs, extract errors, correlate with Loki.

Options:
  --no-loki      Skip Loki log correlation
  -h, --help     Show this help message
EOF
}

USE_LOKI=true
RUN_NUMBER=""

while [[ $# -gt 0 ]]; do
  case "$1" in
    --no-loki) USE_LOKI=false; shift ;;
    -h|--help) usage; exit 0 ;;
    *)
      if [[ -z "$RUN_NUMBER" ]]; then
        RUN_NUMBER="$1"; shift
      else
        log_error "unexpected argument: $1"; usage; exit 1
      fi
      ;;
  esac
done

if [[ -z "$RUN_NUMBER" ]]; then
  log_error "run number required"
  usage
  exit 1
fi

check_deps fj jq

# --- Fetch run details ---

log_info "Fetching run #${RUN_NUMBER} details..."

run_json=$(fj run view "$RUN_NUMBER" --json id,number,title,status,event,branch,commit,createdAt,startedAt,stoppedAt,url 2>/dev/null) || {
  log_error "run #${RUN_NUMBER} not found"
  exit 1
}

title=$(echo "$run_json" | jq -r '.title')
branch=$(echo "$run_json" | jq -r '.branch')
sha=$(echo "$run_json" | jq -r '.commit[:7]')
created=$(echo "$run_json" | jq -r '.createdAt')
overall_status=$(echo "$run_json" | jq -r '.status')

echo -e "${BOLD}Run #${RUN_NUMBER}${NC} — ${title}"
echo -e "Branch: ${branch}  |  SHA: ${sha}  |  Created: $(relative_time "$created")"
echo -e "Overall: $(status_color "$overall_status")${overall_status}${NC}"
echo ""

if [[ "$overall_status" != "failure" ]]; then
  echo -e "${GREEN}No failures in this run.${NC}"
  exit 0
fi

# --- Fetch and analyze logs ---

echo -e "${BOLD}Analyzing logs:${NC}"
echo ""

logs=$(fj run logs "$RUN_NUMBER" 2>/dev/null || echo "")

if [[ -z "$logs" ]]; then
  echo "  (could not fetch logs)"
  exit 1
fi

# Extract error lines
echo -e "  ${BOLD}Error Summary:${NC}"
error_lines=$(echo "$logs" | grep -iE "error|fail|FAIL|Error" | grep -v "::group\|::endgroup\|##\[" | tail -20)
if [[ -n "$error_lines" ]]; then
  echo "$error_lines" | sed 's/^/    /'
else
  echo "    (no obvious error lines found)"
fi
echo ""

# Try to extract failing derivation/host
failing_drv=$(echo "$logs" | grep -oP 'nixos-system-\K[^-]+' | head -1 || true)
if [[ -n "$failing_drv" ]]; then
  echo -e "  ${BOLD}Affected Host:${NC} ${failing_drv}"

  # Use host-lookup if available
  if [[ -x "${SCRIPT_DIR}/host-lookup.sh" ]]; then
    host_info=$("${SCRIPT_DIR}/host-lookup.sh" "$failing_drv" 2>/dev/null || true)
    if [[ -n "$host_info" ]]; then
      echo "    ${host_info}"
    fi
  fi
  echo ""
fi

# Extract the actual build error (nix build output)
nix_error=$(echo "$logs" | grep -A5 "error:" | head -20)
if [[ -n "$nix_error" ]]; then
  echo -e "  ${BOLD}Nix Build Error:${NC}"
  echo "$nix_error" | sed 's/^/    /'
  echo ""
fi

# Loki correlation
if $USE_LOKI && [[ -n "$failing_drv" ]]; then
  if detect_loki 2>/dev/null; then
    # Query for logs around the build time (+/- 15min)
    build_epoch=$(date -d "$created" +%s 2>/dev/null || date +%s)
    start_epoch=$((build_epoch - 900))
    end_epoch=$((build_epoch + 900))

    echo -e "  ${BOLD}Loki Correlation${NC} (${failing_drv}, +/-15min around build):"

    loki_result=$(curl -sG "$LOKI/loki/api/v1/query_range" \
      --data-urlencode "query={hostname=\"${failing_drv}\"} |~ \"error|fail|FATAL\"" \
      --data-urlencode "start=${start_epoch}" \
      --data-urlencode "end=${end_epoch}" \
      --data-urlencode 'limit=10' \
      --data-urlencode 'direction=backward' 2>/dev/null || echo '{"data":{"result":[]}}')

    loki_count=$(echo "$loki_result" | jq '.data.result | length')
    if [[ "$loki_count" -gt 0 ]]; then
      echo "$loki_result" | jq -r '.data.result[] | .stream as $s | .values[] | "    \(.[0] | tonumber / 1000000000 | strftime("%H:%M:%S")) [\($s.unit // "?")] \(.[1][:120])"' | head -10
    else
      echo "    (no correlated error logs found)"
    fi
    echo ""
  fi
fi

# --- Summary ---

echo -e "${BOLD}━━━ Analysis Summary ━━━${NC}"
echo ""

# Check for common patterns in the logs
if echo "$logs" | grep -q "NAR stream"; then
  echo "Root Cause: NAR stream truncation during nix build (likely cache/download issue)"
  echo "Recommendation: Retry the build; if persistent, check nix cache server health"
elif echo "$logs" | grep -q "hash mismatch"; then
  echo "Root Cause: Hash mismatch in fetched source (upstream changed)"
  echo "Recommendation: Update the affected source hash"
elif echo "$logs" | grep -q "IFD"; then
  echo "Root Cause: Import From Derivation (IFD) failure"
  echo "Recommendation: Check if the IFD source is available/cached"
else
  echo "Root Cause: Build failure (see error details above)"
  echo "Recommendation: Review the nix build errors and fix the configuration"
fi
