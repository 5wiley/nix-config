#!/usr/bin/env bash
set -euo pipefail

# Upgrade beads to the latest release.
# Updates: flake.nix (beads input), home/bcotton.nix (version, vendorHash)

RED='\033[0;31m'
GREEN='\033[0;32m'
YELLOW='\033[1;33m'
BLUE='\033[0;34m'
NC='\033[0m'

SCRIPT_DIR="$(cd "$(dirname "${BASH_SOURCE[0]}")" && pwd)"
REPO_ROOT="$(cd "$SCRIPT_DIR/.." && pwd)"

cd "$REPO_ROOT"

# Portable sed in-place edit (works on both macOS and Linux)
sed_inplace() {
    local pattern="$1"
    local file="$2"
    local tmp="${file}.tmp"
    sed "$pattern" "$file" > "$tmp" && mv "$tmp" "$file"
}

echo -e "${BLUE}==> Checking for latest beads release...${NC}"
LATEST_TAG=$(curl -s https://api.github.com/repos/steveyegge/beads/releases/latest | grep '"tag_name"' | sed -E 's/.*"([^"]+)".*/\1/')
LATEST_COMMIT=$(curl -s https://api.github.com/repos/steveyegge/beads/git/ref/tags/$LATEST_TAG | grep '"sha"' | head -1 | sed -E 's/.*"sha": "([^"]+)".*/\1/')
echo -e "${GREEN}Latest release: ${LATEST_TAG} (${LATEST_COMMIT})${NC}"

# Get current version from flake.nix
CURRENT_TAG=$(sed -n 's/.*beads\/\([^"]*\)".*/\1/p' flake.nix | head -1)
echo -e "${BLUE}Current version: ${CURRENT_TAG}${NC}"

if [[ "$LATEST_TAG" == "$CURRENT_TAG" ]]; then
    echo -e "${GREEN}Already at latest version!${NC}"
    exit 0
fi

echo -e "${YELLOW}==> Upgrading to ${LATEST_TAG}...${NC}"

# Get current version number from home/bcotton.nix for vendorHash lookup
CURRENT_VERSION=$(grep -A 5 'pname = "beads"' home/bcotton.nix | grep 'version =' | sed -E 's/.*version = "([^"]+)".*/\1/')

# Step 1: Fetch vendor hash from npm (beads publishes Go modules to npm)
echo -e "${BLUE}==> Fetching vendor hash from npm...${NC}"
SOURCE_URL="https://registry.npmjs.org/@steveyegge/beads/-/beads-${LATEST_TAG#v}.tgz"
echo -e "${YELLOW}Fetching from: ${SOURCE_URL}${NC}"

# Try to fetch the vendor hash - beads publishes to npm as @steveyegge/beads
if curl -sL "$SOURCE_URL" > /dev/null 2>&1; then
    # Extract and compute vendor hash
    TMPDIR=$(mktemp -d)
    trap 'rm -rf "$TMPDIR"' EXIT
    curl -sL "$SOURCE_URL" | tar xz -C "$TMPDIR"
    
    # Vendor hash for Go modules is the hash of the vendor directory
    if [ -d "$TMPDIR/vendor" ]; then
        VENDOR_HASH=$(nix-prefetch-dir "$TMPDIR/vendor" 2>/dev/null | grep 'sha256' | sed -E 's/.*"value": "([^"]+)".*/\1/')
    else
        # If no vendor dir, hash the go.mod and go.sum
        echo -e "${YELLOW}No vendor directory found, hashing go.mod/go.sum...${NC}"
        VENDOR_HASH=$(nix-prefetch-dir "$TMPDIR" 2>/dev/null | grep 'sha256' | sed -E 's/.*"value": "([^"]+)".*/\1/')
    fi
    echo -e "${GREEN}Vendor hash: ${VENDOR_HASH}${NC}"
else
    echo -e "${YELLOW}npm package not found, using flake input hash approach...${NC}"
    # Fall back to using the flake lock file hash
    echo -e "${YELLOW}You may need to manually update the vendorHash in home/bcotton.nix${NC}"
    echo -e "${YELLOW}Run: nix-prefetch-url --unpack https://github.com/steveyegge/beads/archive/refs/tags/${LATEST_TAG}.tar.gz${NC}"
    exit 1
fi

# Step 2: Update flake.nix
echo -e "${BLUE}==> Updating flake.nix...${NC}"
sed_inplace 's|github:steveyegge/beads/[a-f0-9]*|github:steveyegge/beads/'"$LATEST_TAG"'|' flake.nix
sed_inplace 's|github:steveyegge/beads/v[0-9.]*|github:steveyegge/beads/'"$LATEST_TAG"'|' flake.nix
echo -e "${GREEN}Updated flake.nix to ${LATEST_TAG}${NC}"

# Step 3: Update home/bcotton.nix
echo -e "${BLUE}==> Updating home/bcotton.nix...${NC}"
sed_inplace "s/version = \"[^\"]*\";/version = \"${LATEST_TAG#v}\";/" home/bcotton.nix
# Note: beads uses Go modules, not vendoring, so we don't update vendorHash
echo -e "${GREEN}Updated home/bcotton.nix${NC}"

# Step 4: Build to verify
echo -e "${BLUE}==> Building to verify...${NC}"
if just build; then
    echo -e "${GREEN}==> Successfully upgraded beads from ${CURRENT_TAG} to ${LATEST_TAG}!${NC}"
    echo -e "${YELLOW}==> Commit the changes:${NC}"
    echo -e "    git add flake.nix home/bcotton.nix"
    echo -e "    git commit -m 'upgrade beads to ${LATEST_TAG}'"
else
    echo -e "${RED}==> Build failed. Please check the errors above.${NC}"
    exit 1
fi
