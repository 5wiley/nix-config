#!/usr/bin/env bash
# Helper script to create a new host configuration
# Usage: ./create-host.sh <hostname> <type>
# Example: ./create-host.sh my-server nixos
# Example: ./create-host.sh my-mac darwin

set -e

HOSTNAME="$1"
TYPE="$2"

if [ -z "$HOSTNAME" ] || [ -z "$TYPE" ]; then
    echo "Usage: $0 <hostname> <type>"
    echo "  type: nixos or darwin"
    exit 1
fi

if [ "$TYPE" != "nixos" ] && [ "$TYPE" != "darwin" ]; then
    echo "Error: type must be 'nixos' or 'darwin'"
    exit 1
fi

HOST_DIR="hosts/$TYPE/$HOSTNAME"

if [ -d "$HOST_DIR" ]; then
    echo "Error: Host directory $HOST_DIR already exists"
    exit 1
fi

echo "Creating new $TYPE host: $HOSTNAME"
mkdir -p "$HOST_DIR"

# Create a basic default.nix
echo "Creating default.nix..."
if [ "$TYPE" = "nixos" ]; then
    cat > "$HOST_DIR/default.nix" << 'EOF'
{
  config,
  pkgs,
  lib,
  hostSpec,
  ...
}: let
  keys = import ../../common/keys.nix;
in {
  imports = [
    # Include the results of the hardware scan.
    # Run: nixos-generate-config --show-hardware-config > hardware-configuration.nix
    ./hardware-configuration.nix

    # Add your module imports here
    # ../../../modules/some-module
  ];

  # System configuration
  time.timeZone = hostSpec.timeZone;
  programs.zsh.enable = hostSpec.zshEnable;

  # Services (tailscale is enabled by default via hostSpec)
  services.openssh.enable = hostSpec.opensshEnable;
  networking.firewall.enable = hostSpec.firewallEnable;

  # Boot loader configuration
  boot.loader.systemd-boot.enable = true;
  boot.loader.efi.canTouchEfiVariables = true;

  users.users.root = {
    openssh.authorizedKeys.keys = keys.rootAuthorizedKeys;
  };

  # stateVersion is set via hostSpec in nixosHostSpecs
  system.stateVersion = hostSpec.stateVersion;
}
EOF
else
    cat > "$HOST_DIR/default.nix" << 'EOF'
{
  config,
  pkgs,
  lib,
  hostSpec,
  ...
}: {
  imports = [
    # Add your module imports here
  ];

  config = {
    system.primaryUser = hostSpec.primaryUser;
    users.users.${hostSpec.primaryUser}.home = "/Users/${hostSpec.primaryUser}";

    # Darwin-specific services go here

    system.stateVersion = 4;
  };
}
EOF
fi

echo "Host directory created at: $HOST_DIR"
echo ""
echo "Next steps:"
echo "1. Add your host to nixosHostSpecs in flake-modules/hosts.nix:"
if [ "$TYPE" = "nixos" ]; then
    echo "   $HOSTNAME = {"
    echo "     system = \"x86_64-linux\";"
    echo "     usernames = [\"username\"];"
    echo "     stateVersion = \"25.05\";"
    echo "     # ip = \"192.168.x.x\";  # Optional: for homepage/monitoring"
    echo "   };"
else
    echo "   Add to darwinConfigurations:"
    echo "   $HOSTNAME = darwinSystem {"
    echo "     system = \"aarch64-darwin\";"
    echo "     hostName = \"$HOSTNAME\";"
    echo "     username = \"username\";"
    echo "   };"
fi
echo ""
echo "2. Edit $HOST_DIR/default.nix to add host-specific configuration"
if [ "$TYPE" = "nixos" ]; then
    echo "3. Generate hardware config: nixos-generate-config --show-hardware-config > $HOST_DIR/hardware-configuration.nix"
fi
echo ""
echo "4. Build: nixos-rebuild switch --flake .#$HOSTNAME"
