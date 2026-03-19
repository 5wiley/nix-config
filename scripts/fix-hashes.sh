#!/usr/bin/env bash
set -euo pipefail

# fix-hashes.sh - Detect and fix stale fixed-output derivation hashes
# after a nix flake update. Intended for CI use in flake-update.yaml.
#
# Each entry in HASH_REGISTRY defines:
#   BUILD_EXPR|FILE|HASH_ATTR
#
# The script builds each expression. If it fails with a hash mismatch,
# it extracts the correct hash from Nix's error output and patches the file.
#
# Usage: scripts/fix-hashes.sh

SCRIPT_DIR="$(cd "$(dirname "${BASH_SOURCE[0]}")" && pwd)"
REPO_ROOT="$(cd "$SCRIPT_DIR/.." && pwd)"
cd "$REPO_ROOT"

FIXED=0
FAILED=0

# Registry of volatile hashes.
# Format: BUILD_EXPR|FILE|HASH_ATTR
#
# BUILD_EXPR: nix expression to build (triggers the hash check)
# FILE:       file containing the hardcoded hash (relative to repo root)
# HASH_ATTR:  the nix attribute name to grep for (e.g. npmDepsHash, vendorHash)
#
# To add a new entry, just append to this array.
HASH_REGISTRY=(
  # opencode: npmDepsHash drifts when nixpkgs-unstable updates bun/node
  ".#nixosConfigurations.admin.config.system.build.toplevel|home/bcotton.nix|npmDepsHash"
)

for entry in "${HASH_REGISTRY[@]}"; do
  IFS='|' read -r BUILD_EXPR FILE HASH_ATTR <<< "$entry"

  echo "==> Testing build: $BUILD_EXPR"
  echo "    Hash location: $FILE ($HASH_ATTR)"

  # Attempt the build, capture stderr+stdout
  BUILD_OUTPUT=""
  if BUILD_OUTPUT=$(nix build "$BUILD_EXPR" 2>&1); then
    echo "    OK — build succeeded, no hash fix needed"
    continue
  fi

  # Check if the failure is a hash mismatch
  if ! echo "$BUILD_OUTPUT" | grep -q "hash mismatch"; then
    echo "    FAIL — build failed but NOT a hash mismatch:"
    echo "$BUILD_OUTPUT" | tail -20
    FAILED=$((FAILED + 1))
    continue
  fi

  # Extract the correct hash from "got:    sha256-XXXX"
  NEW_HASH=$(echo "$BUILD_OUTPUT" | grep -oP 'got:\s+\Ksha256-[A-Za-z0-9+/=]+' | head -1)

  if [ -z "$NEW_HASH" ]; then
    echo "    FAIL — hash mismatch detected but could not extract new hash"
    echo "$BUILD_OUTPUT" | grep -i "hash\|got:\|specified:" | head -10
    FAILED=$((FAILED + 1))
    continue
  fi

  # Extract the old hash from the file
  OLD_HASH=$(grep "$HASH_ATTR" "$FILE" | grep -oP 'sha256-[A-Za-z0-9+/=]+' | head -1)

  if [ -z "$OLD_HASH" ]; then
    echo "    FAIL — could not find current $HASH_ATTR in $FILE"
    FAILED=$((FAILED + 1))
    continue
  fi

  if [ "$OLD_HASH" = "$NEW_HASH" ]; then
    echo "    FAIL — hash mismatch but extracted hash matches file (unexpected)"
    echo "$BUILD_OUTPUT" | tail -10
    FAILED=$((FAILED + 1))
    continue
  fi

  echo "    Hash mismatch detected:"
  echo "      old: $OLD_HASH"
  echo "      new: $NEW_HASH"

  # Replace the hash in the file
  sed -i "s|$OLD_HASH|$NEW_HASH|" "$FILE"

  echo "    FIXED — updated $HASH_ATTR in $FILE"
  FIXED=$((FIXED + 1))
done

echo ""
echo "==> Summary: $FIXED fixed, $FAILED failed"

if [ "$FAILED" -gt 0 ]; then
  exit 1
fi

exit 0
