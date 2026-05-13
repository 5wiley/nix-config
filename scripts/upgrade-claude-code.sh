#!/usr/bin/env bash
set -euo pipefail

# Upgrade claude-code to the latest binary release.
# Updates: overlays/claude-code-manifest.json

RED='\033[0;31m'
GREEN='\033[0;32m'
YELLOW='\033[1;33m'
BLUE='\033[0;34m'
NC='\033[0m'

BASE_URL="https://storage.googleapis.com/claude-code-dist-86c565f3-f756-42ad-8dfa-d59b1c096819/claude-code-releases"
MANIFEST_FILE="overlays/claude-code-manifest.json"
SCRIPT_DIR="$(cd "$(dirname "${BASH_SOURCE[0]}")" && pwd)"
REPO_ROOT="$(cd "$SCRIPT_DIR/.." && pwd)"

cd "$REPO_ROOT"

# Get current version from manifest
CURRENT_VERSION=$(python3 -c "import json; print(json.load(open('$MANIFEST_FILE'))['version'])")
echo -e "${BLUE}Current version: ${CURRENT_VERSION}${NC}"

# Get latest version from npm (the CDN doesn't have a "latest" manifest)
echo -e "${BLUE}==> Checking for latest claude-code version...${NC}"
LATEST_VERSION=$(npm view @anthropic-ai/claude-code version)
echo -e "${GREEN}Latest version: ${LATEST_VERSION}${NC}"

if [[ "$LATEST_VERSION" == "$CURRENT_VERSION" ]]; then
    echo -e "${GREEN}Already at latest version!${NC}"
    exit 0
fi

echo -e "${YELLOW}==> Updating to version ${LATEST_VERSION}...${NC}"

# Fetch the new manifest from CDN
echo -e "${BLUE}==> Fetching manifest for ${LATEST_VERSION}...${NC}"
MANIFEST_URL="${BASE_URL}/${LATEST_VERSION}/manifest.json"
HTTP_CODE=$(curl -s -w "%{http_code}" -o "$MANIFEST_FILE" "$MANIFEST_URL")
if [[ "$HTTP_CODE" != "200" ]]; then
    echo -e "${RED}==> Failed to fetch manifest (HTTP ${HTTP_CODE}). Version may not exist yet on CDN.${NC}"
    exit 1
fi
echo -e "${GREEN}Manifest downloaded${NC}"

# Build to verify
echo -e "${BLUE}==> Building to verify...${NC}"
if just build; then
    echo -e "${GREEN}==> Successfully upgraded claude-code from ${CURRENT_VERSION} to ${LATEST_VERSION}!${NC}"
    echo -e "${YELLOW}==> Don't forget to commit the changes:${NC}"
    echo -e "    git add ${MANIFEST_FILE}"
    echo -e "    git commit -m 'upgrade claude-code to ${LATEST_VERSION}'"
else
    echo -e "${RED}==> Build failed. Please check the errors above.${NC}"
    exit 1
fi
