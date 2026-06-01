#!/usr/bin/env bash
# Download a GGUF model from Hugging Face to a host
#
# Models are auto-discovered by llama-swap at service start,
# so no nix config changes are needed after downloading.
#
# Usage:
#   ./scripts/download-model.sh <repo_id> [quant_pattern] [--host HOST] [--dry-run]
#
# Examples:
#   # Download all GGUF files from a repo (default: nas-01)
#   ./scripts/download-model.sh bartowski/Meta-Llama-3.1-8B-Instruct-GGUF
#
#   # Download only Q4_K_M quantization
#   ./scripts/download-model.sh bartowski/Meta-Llama-3.1-8B-Instruct-GGUF Q4_K_M
#
#   # Download to a different host
#   ./scripts/download-model.sh second-state/gte-Qwen2-1.5B-instruct-GGUF Q8_0 --host nix-01
#
#   # Preview what would be downloaded
#   ./scripts/download-model.sh bartowski/Meta-Llama-3.1-8B-Instruct-GGUF Q4_K_M --dry-run

set -euo pipefail

MODEL_DIR="/models"
HOST="nas-01"

usage() {
  echo "Usage: $0 <repo_id> [quant_pattern] [--host HOST] [--dry-run]"
  echo ""
  echo "Arguments:"
  echo "  repo_id        HuggingFace repo (e.g., bartowski/Meta-Llama-3.1-8B-Instruct-GGUF)"
  echo "  quant_pattern  Quantization filter (e.g., Q4_K_M, Q5_K_M, Q8_0). Default: all .gguf files"
  echo "  --host HOST    Target host (default: nas-01)"
  echo "  --dry-run      Preview what would be downloaded without downloading"
  echo ""
  echo "Examples:"
  echo "  $0 bartowski/Meta-Llama-3.1-8B-Instruct-GGUF Q4_K_M"
  echo "  $0 second-state/gte-Qwen2-1.5B-instruct-GGUF Q8_0 --host nix-01"
  echo "  $0 bartowski/Qwen2.5-72B-Instruct-GGUF Q4_K_M --dry-run"
  exit 1
}

REPO_ID="${1:-}"
QUANT=""
DRY_RUN=""

if [ -z "$REPO_ID" ]; then
  usage
fi

# Parse arguments (skip first which is repo_id)
shift
while [ $# -gt 0 ]; do
  case "$1" in
    --host)
      HOST="${2:-}"
      if [ -z "$HOST" ]; then
        echo "Error: --host requires a value"
        exit 1
      fi
      shift 2
      ;;
    --dry-run)
      DRY_RUN="yes"
      shift
      ;;
    *)
      if [ -z "$QUANT" ]; then
        QUANT="$1"
      fi
      shift
      ;;
  esac
done

# Build include pattern
if [ -n "$QUANT" ]; then
  INCLUDE="*${QUANT}*.gguf"
else
  INCLUDE="*.gguf"
fi

echo "Repository: $REPO_ID"
echo "Pattern:    $INCLUDE"
echo "Target:     $HOST:$MODEL_DIR"
echo ""

if [ -n "$DRY_RUN" ]; then
  echo "Listing matching files from HuggingFace API..."
  FILES=$(curl -sf "https://huggingface.co/api/models/${REPO_ID}" \
    | jq -r '.siblings[].rfilename' \
    | grep -i '\.gguf$' || true)

  if [ -n "$QUANT" ]; then
    FILES=$(echo "$FILES" | grep -i "$QUANT" || true)
  fi

  if [ -z "$FILES" ]; then
    echo "No matching .gguf files found in $REPO_ID"
  else
    echo "$FILES"
  fi
  echo ""
  echo "(dry-run mode - no files downloaded)"
  exit 0
fi

# Run download on target host via SSH
echo "Downloading model files..."
ssh "root@${HOST}" "hf download '${REPO_ID}' --include '${INCLUDE}' --local-dir '${MODEL_DIR}'"

# Flatten any subdirectories — some repos (e.g., unsloth) nest GGUFs in quant subdirs
echo ""
echo "Moving any nested .gguf files to ${MODEL_DIR}..."
ssh "root@${HOST}" "find '${MODEL_DIR}' -mindepth 2 -name '*.gguf' -exec mv -v {} '${MODEL_DIR}/' \\; && find '${MODEL_DIR}' -mindepth 1 -maxdepth 1 -type d -empty -delete"

echo ""
echo "Download complete. Listing model files..."
echo ""

# List downloaded files
GGUF_FILES=$(ssh "root@${HOST}" "ls -1 ${MODEL_DIR}/*.gguf 2>/dev/null || true")

if [ -z "$GGUF_FILES" ]; then
  echo "WARNING: No .gguf files found in $MODEL_DIR"
  exit 1
fi

echo "$GGUF_FILES"
echo ""
echo "Models are auto-discovered by llama-swap. Restart the service to pick them up:"
echo "  ssh root@${HOST} systemctl restart llama-swap"
echo ""
echo "Then verify:"
echo "  curl -s http://${HOST}:8090/v1/models | jq '.data[].id'"
