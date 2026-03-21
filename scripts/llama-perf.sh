#!/usr/bin/env bash
set -euo pipefail

# llama-swap performance analyzer.
# Queries Loki for llama-server logs and reports on context window usage,
# KV cache pressure, throughput, and overall model health.

SCRIPT_DIR="$(cd "$(dirname "${BASH_SOURCE[0]}")" && pwd)"
source "${SCRIPT_DIR}/lib/common.sh"

# Defaults
SINCE="24h"
MODEL=""

usage() {
  cat <<EOF
Usage: $(basename "$0") [OPTIONS]

Analyze llama-swap model performance from Loki logs.

Options:
  --since=DURATION    Time window: 1h, 24h, 7d (default: 24h)
  --model=NAME        Filter to specific model name
  -h, --help          Show this help

Reports:
  - KV cache utilization and pressure events
  - Context window usage distribution
  - Prompt eval and generation throughput
  - Cache hit efficiency
  - Error summary

Examples:
  $(basename "$0")                           # Last 24h, all models
  $(basename "$0") --since=7d               # Last 7 days
  $(basename "$0") --model=qwen3.5-35b-a3b-coding
EOF
  exit 0
}

# ---------- Argument parsing ----------

while [[ $# -gt 0 ]]; do
  case "$1" in
    --since=*) SINCE="${1#*=}" ;;
    --model=*) MODEL="${1#*=}" ;;
    -h|--help) usage ;;
    *) log_error "unknown option: $1"; usage ;;
  esac
  shift
done

check_deps curl jq

# ---------- Loki setup ----------

detect_loki || exit 1
log_info "Using Loki at: $LOKI"

# Convert shorthand durations (1h, 24h, 7d) to date-compatible format
parse_duration() {
  local dur="$1"
  if [[ "$dur" =~ ^([0-9]+)h$ ]]; then echo "${BASH_REMATCH[1]} hours"
  elif [[ "$dur" =~ ^([0-9]+)d$ ]]; then echo "${BASH_REMATCH[1]} days"
  elif [[ "$dur" =~ ^([0-9]+)m$ ]]; then echo "${BASH_REMATCH[1]} minutes"
  else echo "$dur"  # pass through as-is
  fi
}

START=$(date -d "$(parse_duration "$SINCE") ago" +%s)
END=$(date +%s)

loki_query() {
  local query="$1"
  local limit="${2:-500}"
  curl -sG "$LOKI/loki/api/v1/query_range" \
    --data-urlencode "query=$query" \
    --data-urlencode "start=$START" \
    --data-urlencode "end=$END" \
    --data-urlencode "limit=$limit" \
    --data-urlencode "direction=backward"
}

extract_lines() {
  jq -r '.data.result[] | .values[] | .[1]'
}

# ---------- Data collection ----------

log_info "Collecting data for last ${SINCE}..."

# KV cache state
CACHE_DATA=$(loki_query '{unit="llama-swap.service"} |~ "cache state:"' 500 | extract_lines)

# Timing data (prompt eval + generation)
TIMING_DATA=$(loki_query '{unit="llama-swap.service"} |~ "prompt eval time|eval time =|total time ="' 1000 | extract_lines)

# Context usage (new prompt entries)
CONTEXT_DATA=$(loki_query '{unit="llama-swap.service"} |~ "new prompt, n_ctx_slot"' 500 | extract_lines)

# Prompt processing (batch sizes show cache efficiency)
PROMPT_DATA=$(loki_query '{unit="llama-swap.service"} |~ "prompt processing done"' 500 | extract_lines)

# Errors
ERROR_DATA=$(loki_query '{unit="llama-swap.service"} |~ "failed to find free space|Context size.*exceeded|exceeds the available|ExitError"' 200 | extract_lines)

# Model swaps
SWAP_DATA=$(loki_query '{unit="llama-swap.service"} |~ "Unloading model"' 100 | extract_lines)

# ---------- KV Cache Analysis ----------

echo ""
echo -e "${BOLD}═══════════════════════════════════════════════════${NC}"
echo -e "${BOLD}  llama-swap Performance Report (last ${SINCE})${NC}"
echo -e "${BOLD}═══════════════════════════════════════════════════${NC}"

echo ""
echo -e "${BOLD}── KV Cache ──${NC}"

if [[ -n "$CACHE_DATA" ]]; then
  # Parse: "cache state: N prompts, XXXX.XXX MiB (limits: YYYY.YYY MiB, NNNN tokens, NNNN est)"
  CACHE_STATS=$(echo "$CACHE_DATA" \
    | sed -n 's/.*: \([0-9]*\) prompts, \([0-9.]*\) MiB (limits: \([0-9.]*\) MiB, \([0-9]*\) tokens.*/\1 \2 \3 \4/p')

  if [[ -n "$CACHE_STATS" ]]; then
    USED_VALUES=$(echo "$CACHE_STATS" | awk '{print $2}')
    LIMIT=$(echo "$CACHE_STATS" | head -1 | awk '{print $3}')
    TOKEN_LIMIT=$(echo "$CACHE_STATS" | head -1 | awk '{print $4}')
    COUNT=$(echo "$USED_VALUES" | wc -l)
    MIN=$(echo "$USED_VALUES" | sort -n | head -1)
    MAX=$(echo "$USED_VALUES" | sort -n | tail -1)
    AVG=$(echo "$USED_VALUES" | awk '{sum+=$1} END {printf "%.1f", sum/NR}')
    MAX_PCT=$(echo "$MAX $LIMIT" | awk '{printf "%.1f", ($1/$2)*100}')
    AVG_PCT=$(echo "$AVG $LIMIT" | awk '{printf "%.1f", ($1/$2)*100}')

    printf "  %-28s %s\n" "Cache limit:" "${LIMIT} MiB"
    printf "  %-28s %s\n" "Token limit (total):" "${TOKEN_LIMIT}"
    printf "  %-28s %s\n" "Samples:" "${COUNT}"
    printf "  %-28s %s\n" "Min usage:" "${MIN} MiB"
    printf "  %-28s %s (%s%%)\n" "Avg usage:" "${AVG} MiB" "${AVG_PCT}"
    printf "  %-28s %s (%s%%)\n" "Max usage:" "${MAX} MiB" "${MAX_PCT}"

    # Prompt count distribution
    PROMPT_COUNTS=$(echo "$CACHE_STATS" | awk '{print $1}')
    MAX_PROMPTS=$(echo "$PROMPT_COUNTS" | sort -n | tail -1)
    AVG_PROMPTS=$(echo "$PROMPT_COUNTS" | awk '{sum+=$1} END {printf "%.1f", sum/NR}')
    printf "  %-28s %s (max %s)\n" "Avg cached prompts:" "${AVG_PROMPTS}" "${MAX_PROMPTS}"
  fi
else
  echo "  No cache state data found"
fi

# ---------- KV Cache Errors ----------

echo ""
echo -e "${BOLD}── KV Cache Health ──${NC}"

if [[ -n "$ERROR_DATA" ]]; then
  KV_FAILURES=$(echo "$ERROR_DATA" | grep -c "failed to find free space" || true)
  CTX_EXCEEDED=$(echo "$ERROR_DATA" | grep -c "Context size.*exceeded\|exceeds the available" || true)
  EXIT_ERRORS=$(echo "$ERROR_DATA" | grep -c "ExitError" || true)

  if (( KV_FAILURES > 0 )); then
    printf "  ${RED}%-28s %d${NC}\n" "KV cache full events:" "$KV_FAILURES"
  else
    printf "  ${GREEN}%-28s %d${NC}\n" "KV cache full events:" "$KV_FAILURES"
  fi

  if (( CTX_EXCEEDED > 0 )); then
    printf "  ${RED}%-28s %d${NC}\n" "Context exceeded errors:" "$CTX_EXCEEDED"
  else
    printf "  ${GREEN}%-28s %d${NC}\n" "Context exceeded errors:" "$CTX_EXCEEDED"
  fi

  if (( EXIT_ERRORS > 0 )); then
    printf "  ${YELLOW}%-28s %d${NC}\n" "Model exit errors:" "$EXIT_ERRORS"
  else
    printf "  %-28s %d\n" "Model exit errors:" "$EXIT_ERRORS"
  fi
else
  echo -e "  ${GREEN}No errors found${NC}"
fi

# ---------- Context Window Usage ----------

echo ""
echo -e "${BOLD}── Context Window Usage ──${NC}"

if [[ -n "$CONTEXT_DATA" ]]; then
  # Parse: "new prompt, n_ctx_slot = NNNN, n_keep = 0, task.n_tokens = NNNN"
  CTX_PAIRS=$(echo "$CONTEXT_DATA" \
    | sed -n 's/.*n_ctx_slot = \([0-9]*\).*task\.n_tokens = \([0-9]*\)/\1,\2/p')

  if [[ -n "$CTX_PAIRS" ]]; then
    CTX_SLOT=$(echo "$CTX_PAIRS" | head -1 | cut -d',' -f1)
    TOKEN_VALUES=$(echo "$CTX_PAIRS" | cut -d',' -f2)
    REQ_COUNT=$(echo "$TOKEN_VALUES" | wc -l)
    MIN_TOK=$(echo "$TOKEN_VALUES" | sort -n | head -1)
    MAX_TOK=$(echo "$TOKEN_VALUES" | sort -n | tail -1)
    AVG_TOK=$(echo "$TOKEN_VALUES" | awk '{sum+=$1} END {printf "%.0f", sum/NR}')
    MAX_PCT=$(echo "$MAX_TOK $CTX_SLOT" | awk '{printf "%.1f", ($1/$2)*100}')
    AVG_PCT=$(echo "$AVG_TOK $CTX_SLOT" | awk '{printf "%.1f", ($1/$2)*100}')

    printf "  %-28s %s tokens\n" "Context per slot:" "$CTX_SLOT"
    printf "  %-28s %d\n" "Requests sampled:" "$REQ_COUNT"
    printf "  %-28s %s tokens\n" "Min prompt size:" "$MIN_TOK"
    printf "  %-28s %s tokens (%s%% of slot)\n" "Avg prompt size:" "$AVG_TOK" "$AVG_PCT"
    printf "  %-28s %s tokens (%s%% of slot)\n" "Max prompt size:" "$MAX_TOK" "$MAX_PCT"

    # Distribution buckets
    echo ""
    echo "  Token usage distribution:"
    echo "$TOKEN_VALUES" | awk '
      { total++
        if ($1 < 8192) b1++
        else if ($1 < 32768) b2++
        else if ($1 < 65536) b3++
        else if ($1 < 131072) b4++
        else b5++
      }
      END {
        printf "    < 8K:    %4d  (%5.1f%%)\n", b1+0, (b1+0)/total*100
        printf "    8-32K:   %4d  (%5.1f%%)\n", b2+0, (b2+0)/total*100
        printf "    32-64K:  %4d  (%5.1f%%)\n", b3+0, (b3+0)/total*100
        printf "    64-128K: %4d  (%5.1f%%)\n", b4+0, (b4+0)/total*100
        printf "    > 128K:  %4d  (%5.1f%%)\n", b5+0, (b5+0)/total*100
      }'
  fi
else
  echo "  No context data found"
fi

# ---------- Throughput ----------

echo ""
echo -e "${BOLD}── Throughput ──${NC}"

if [[ -n "$TIMING_DATA" ]]; then
  # Generation speed: "eval time = XXXX.XX ms / NNN tokens (XX.XX ms per token, XX.XX tokens per second)"
  GEN_SPEEDS=$(echo "$TIMING_DATA" | grep "eval time =" | grep -v "prompt eval" \
    | sed -n 's/.* \([0-9.]*\) tokens per second.*/\1/p')

  if [[ -n "$GEN_SPEEDS" ]]; then
    GEN_COUNT=$(echo "$GEN_SPEEDS" | wc -l)
    GEN_MIN=$(echo "$GEN_SPEEDS" | sort -n | head -1)
    GEN_MAX=$(echo "$GEN_SPEEDS" | sort -n | tail -1)
    GEN_AVG=$(echo "$GEN_SPEEDS" | awk '{sum+=$1} END {printf "%.1f", sum/NR}')

    printf "  ${BOLD}Generation:${NC}\n"
    printf "    %-26s %s tok/s\n" "Min:" "$GEN_MIN"
    printf "    %-26s %s tok/s\n" "Avg:" "$GEN_AVG"
    printf "    %-26s %s tok/s\n" "Max:" "$GEN_MAX"
    printf "    %-26s %d\n" "Samples:" "$GEN_COUNT"
  fi

  # Prompt eval speed
  PROMPT_SPEEDS=$(echo "$TIMING_DATA" | grep "prompt eval time" \
    | sed -n 's/.* \([0-9.]*\) tokens per second.*/\1/p')

  if [[ -n "$PROMPT_SPEEDS" ]]; then
    PE_COUNT=$(echo "$PROMPT_SPEEDS" | wc -l)
    PE_MIN=$(echo "$PROMPT_SPEEDS" | sort -n | head -1)
    PE_MAX=$(echo "$PROMPT_SPEEDS" | sort -n | tail -1)
    PE_AVG=$(echo "$PROMPT_SPEEDS" | awk '{sum+=$1} END {printf "%.1f", sum/NR}')

    echo ""
    printf "  ${BOLD}Prompt eval:${NC}\n"
    printf "    %-26s %s tok/s\n" "Min:" "$PE_MIN"
    printf "    %-26s %s tok/s\n" "Avg:" "$PE_AVG"
    printf "    %-26s %s tok/s\n" "Max:" "$PE_MAX"
    printf "    %-26s %d\n" "Samples:" "$PE_COUNT"
  fi
else
  echo "  No timing data found"
fi

# ---------- Cache Efficiency ----------

echo ""
echo -e "${BOLD}── Cache Efficiency ──${NC}"

if [[ -n "$PROMPT_DATA" ]]; then
  # "prompt processing done, n_tokens = NNNN, batch.n_tokens = NNN"
  BATCH_SIZES=$(echo "$PROMPT_DATA" | sed -n 's/.*batch\.n_tokens = \([0-9]*\).*/\1/p')

  if [[ -n "$BATCH_SIZES" ]]; then
    BATCH_COUNT=$(echo "$BATCH_SIZES" | wc -l)
    FULL_EVALS=$(echo "$BATCH_SIZES" | awk '$1 >= 512' | wc -l)
    CACHE_HITS=$(echo "$BATCH_SIZES" | awk '$1 < 512' | wc -l)
    HIT_RATE=$(echo "$CACHE_HITS $BATCH_COUNT" | awk '{printf "%.1f", ($1/$2)*100}')
    AVG_BATCH=$(echo "$BATCH_SIZES" | awk '{sum+=$1} END {printf "%.0f", sum/NR}')

    printf "  %-28s %d\n" "Total prompt evals:" "$BATCH_COUNT"
    printf "  %-28s %d (batch < 512 tokens)\n" "Cache hits:" "$CACHE_HITS"
    printf "  %-28s %d (batch >= 512 tokens)\n" "Full re-evals:" "$FULL_EVALS"
    printf "  %-28s %s%%\n" "Cache hit rate:" "$HIT_RATE"
    printf "  %-28s %s tokens\n" "Avg new tokens per prompt:" "$AVG_BATCH"
  fi
else
  echo "  No prompt data found"
fi

# ---------- Model Swaps ----------

echo ""
echo -e "${BOLD}── Model Management ──${NC}"

if [[ -n "$SWAP_DATA" ]]; then
  SWAP_COUNT=$(echo "$SWAP_DATA" | wc -l)
  SWAP_MODELS=$(echo "$SWAP_DATA" | sed -n 's/.*<\([^>]*\)>.*/\1/p' | sort | uniq -c | sort -rn)
  printf "  %-28s %d\n" "Model unloads:" "$SWAP_COUNT"
  if [[ -n "$SWAP_MODELS" ]]; then
    echo "  By model:"
    echo "$SWAP_MODELS" | while read -r count name; do
      printf "    %-24s %d\n" "$name" "$count"
    done
  fi
else
  printf "  %-28s %d\n" "Model unloads:" 0
fi

echo ""
echo -e "${BOLD}═══════════════════════════════════════════════════${NC}"
