#!/usr/bin/env bash
# Import a GGUF model into Ollama on a remote host
#
# Assumes the GGUF is already at /models/ on the target host
# (use download-model.sh --host <host> to get it there first).
#
# Usage:
#   ./scripts/ollama-import-gguf.sh <gguf_filename> <ollama_name> [--host HOST]
#
# Examples:
#   # Import embedding model on nix-01
#   ./scripts/ollama-import-gguf.sh gte-Qwen2-1.5B-instruct-Q8_0.gguf gte-qwen2-1.5b --host nix-01
#
#   # Import on default host (nas-01)
#   ./scripts/ollama-import-gguf.sh some-model.gguf my-model

set -euo pipefail

MODEL_DIR="/models"
HOST="nas-01"

usage() {
  echo "Usage: $0 <gguf_filename> <ollama_name> [--host HOST]"
  echo ""
  echo "Arguments:"
  echo "  gguf_filename  Name of the .gguf file in /models/ on the target host"
  echo "  ollama_name    Name to register in Ollama (e.g., gte-qwen2-1.5b)"
  echo "  --host HOST    Target host (default: nas-01)"
  echo ""
  echo "Examples:"
  echo "  $0 gte-Qwen2-1.5B-instruct-Q8_0.gguf gte-qwen2-1.5b --host nix-01"
  exit 1
}

GGUF_FILE="${1:-}"
OLLAMA_NAME="${2:-}"

if [ -z "$GGUF_FILE" ] || [ -z "$OLLAMA_NAME" ]; then
  usage
fi

shift 2
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
    *)
      echo "Unknown argument: $1"
      usage
      ;;
  esac
done

GGUF_PATH="${MODEL_DIR}/${GGUF_FILE}"

echo "Host:       $HOST"
echo "GGUF:       $GGUF_PATH"
echo "Ollama name: $OLLAMA_NAME"
echo ""

# Check if model already exists
if ssh "${HOST}" "ollama list 2>/dev/null" | grep -q "${OLLAMA_NAME}"; then
  echo "Model '${OLLAMA_NAME}' already exists on ${HOST}:"
  ssh "${HOST}" "ollama list" | grep "${OLLAMA_NAME}"
  exit 0
fi

# Check GGUF exists
if ! ssh "${HOST}" "test -f '${GGUF_PATH}'"; then
  echo "Error: ${GGUF_PATH} not found on ${HOST}"
  echo ""
  echo "Download it first:"
  echo "  ./scripts/download-model.sh <repo_id> --host ${HOST}"
  exit 1
fi

# Create and import
echo "Importing into Ollama..."
ssh "${HOST}" "
  MODELFILE=\$(mktemp)
  echo 'FROM ${GGUF_PATH}' > \"\$MODELFILE\"
  ollama create '${OLLAMA_NAME}' -f \"\$MODELFILE\"
  rm -f \"\$MODELFILE\"
"

echo ""
echo "Done. Verify:"
ssh "${HOST}" "ollama list" | grep "${OLLAMA_NAME}" || echo "WARNING: model not found after import"
