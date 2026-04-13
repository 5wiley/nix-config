{
  inputs,
  self,
  ...
}: {
  flake = let
    inherit (inputs) nixpkgs nixpkgs-unstable home-manager agenix nix-darwin disko disko-zfs tsnsrv vscode-server nixos-generators nix-builder-config musnix;
    inherit (nixpkgs) lib;

    # Package set generators
    genPkgs = system:
      import nixpkgs {
        inherit system;
        config.allowUnfree = true;
      };

    genUnstablePkgs = system:
      import nixpkgs-unstable {
        inherit system;
        config.allowUnfree = true;
      };

    # Common module builders
    mkModuleArgs = unstablePkgs: system: {
      _module.args = {
        inherit unstablePkgs;
        localPackages = self.legacyPackages.${system}.localPackages;
      };
    };

    mkHomeManagerConfig = unstablePkgs: system: hostName: usernames: {
      networking.hostName = hostName;
      home-manager.useGlobalPkgs = true;
      home-manager.useUserPackages = true;
      home-manager.users = builtins.listToAttrs (
        map (username: {
          name = username;
          value.imports = [
            ../home/${username}.nix
            inputs.workmux.homeManagerModules.default
          ];
        })
        usernames
      );
      home-manager.extraSpecialArgs = {
        inherit inputs unstablePkgs hostName nixosHosts;
        localPackages = self.legacyPackages.${system}.localPackages;
        workmuxPackage = inputs.workmux.packages.${system}.default;
        crushPackage = inputs.nix-ai-tools.packages.${system}.crush;
        worktrunkPackage = inputs.worktrunk.packages.${system}.default;
        qmdPackage = inputs.qmd.packages.${system}.default.overrideAttrs (old: {
          buildPhase = ''
            export HOME=$(mktemp -d)
            bun install
          '';
        });
        gwsPackage = inputs.gws.packages.${system}.gws;
        devenvPackage = inputs.devenv.packages.${system}.devenv;
      };
    };

    # External modules used across NixOS systems
    externalNixOSModules = [
      inputs.disko.nixosModules.disko
      inputs.disko-zfs.nixosModules.default
      inputs.tsnsrv.nixosModules.default
      inputs.vscode-server.nixosModules.default
      inputs.home-manager.nixosModules.home-manager
      inputs.agenix.nixosModules.default
      inputs.musnix.nixosModules.musnix
    ];

    # Internal modules
    internalModules = [
      ../clubcotton
      ../secrets
      nix-builder-config.nixosModules.client
    ];

    # Service modules for full NixOS systems
    serviceModules = [
      ../modules/code-server
      ../modules/postgresql
      ../modules/tailscale
      ../modules/zfs
      ../modules/auto-upgrade
    ];

    # Default host settings — per-host specs override these
    # Only include values that differ from defaults in individual host specs
    hostDefaults = {
      shouldScrapeMetrics = true;
      botHosts = ["nix-01" "nix-02" "nix-03"];
      stateVersion = null; # Must be overridden per host
      hostId = null; # Required for ZFS hosts
      useDHCP = false;
      timeZone = "America/Denver";
      zshEnable = true;
      opensshEnable = true;
      firewallEnable = true;
      tailscaleEnable = true;
      linuxBuilderEnable = false;
      desktopPackages = false;
      determinateNix = false;
    };

    # NixOS host specifications - single source of truth for all NixOS hosts
    # Adding a host here automatically includes it in nixosConfigurations, SSH RemoteForward,
    # and the homepage dashboard (if ip is specified and shouldMonitor is true)
    #
    # Required fields:
    #   system      - Architecture (e.g., "x86_64-linux")
    #   usernames   - List of user accounts to create
    #   stateVersion - NixOS version when host was first installed
    #
    # Optional fields:
    #   ip          - IP address for Glances monitoring (enables Glances and adds to homepage)
    #   displayName - Name shown on homepage (defaults to hostname)
    #   glancesPort - Port for Glances (defaults to 61208)
    #   icon        - Icon for homepage (defaults to "mdi-server")
    #   hostId      - ZFS host ID (required for ZFS hosts)
    #   desktopPackages - Include heavy desktop/media packages (default: false)
    #
    # Auto-derived fields:
    #   shouldMonitor - From shouldScrapeMetrics (controls homepage/Glances inclusion)
    #
    # All other fields from hostDefaults can be overridden per-host.
    nixosHostSpecs =
      builtins.mapAttrs (
        name: spec: let
          merged = hostDefaults // spec;
        in
          merged
          // {
            shouldMonitor = merged.shouldScrapeMetrics;
          }
      ) {
        admin = {
          system = "x86_64-linux";
          usernames = ["bcotton"];
          stateVersion = "23.11";
          ip = "192.168.5.98";
          displayName = "Admin";
        };
        condo-01 = {
          system = "x86_64-linux";
          usernames = ["bcotton"];
          stateVersion = "24.11";
          hostId = "3fa4e0cb";
          # No IP - different network, not on homepage
        };
        natalya-01 = {
          system = "x86_64-linux";
          usernames = ["bcotton"];
          stateVersion = "24.11";
          hostId = "8fb0eda8";
          # No IP - different network, not on homepage
        };
        nas-01 = {
          system = "x86_64-linux";
          usernames = ["bcotton" "tomcotton"];
          stateVersion = "24.11";
          hostId = "007f0200";
          ip = "192.168.5.42";
          displayName = "NAS-01";
          desktopPackages = true;
        };
        nix-01 = {
          system = "x86_64-linux";
          usernames = ["bcotton" "tomcotton" "larry" "natalya"];
          stateVersion = "23.11";
          hostId = "85c6dbc0";
          ip = "192.168.5.210";
          displayName = "Nix-01";
          desktopPackages = true;
        };
        nix-02 = {
          system = "x86_64-linux";
          usernames = ["bcotton" "tomcotton" "larry" "natalya"];
          stateVersion = "23.11";
          hostId = "038f8559";
          ip = "192.168.5.212";
          displayName = "Nix-02";
          desktopPackages = true;
        };
        nix-03 = {
          system = "x86_64-linux";
          usernames = ["bcotton" "tomcotton" "larry" "natalya"];
          stateVersion = "23.11";
          hostId = "007f0200";
          ip = "192.168.5.214";
          displayName = "Nix-03";
          desktopPackages = true;
        };
        nix-04 = {
          system = "x86_64-linux";
          usernames = ["bcotton" "tomcotton"];
          stateVersion = "24.11";
          hostId = "3fa4e0cb";
          ip = "192.168.5.54";
          displayName = "Nix-04";
          desktopPackages = true;
          shouldScrapeMetrics = false;
        };
        imac-01 = {
          system = "x86_64-linux";
          usernames = ["bcotton" "tomcotton"];
          stateVersion = "24.11";
          hostId = "238f8e1e";
          ip = "192.168.5.125";
          displayName = "iMac-01";
          desktopPackages = true;
        };
        imac-02 = {
          system = "x86_64-linux";
          usernames = ["bcotton" "tomcotton"];
          stateVersion = "24.11";
          hostId = "95c41ddc";
          ip = "192.168.5.153";
          displayName = "iMac-02";
          desktopPackages = true;
        };
        dns-01 = {
          system = "x86_64-linux";
          usernames = ["bcotton"];
          stateVersion = "23.11";
          ip = "192.168.5.220";
          displayName = "DNS-01";
        };
        octoprint = {
          system = "x86_64-linux";
          usernames = ["bcotton" "tomcotton"];
          stateVersion = "23.11";
          ip = "192.168.5.49";
          displayName = "OctoPrint";
        };
        frigate-host = {
          system = "x86_64-linux";
          usernames = ["bcotton"];
          stateVersion = "23.11";
          ip = "192.168.20.174";
          displayName = "Frigate";
        };
        nixbook-test = {
          system = "x86_64-linux";
          usernames = ["tomcotton"];
          shouldScrapeMetrics = false;
          # No IP - laptop with DHCP, not on homepage
        };
        incus-testing = {
          system = "x86_64-linux";
          usernames = ["bcotton"];
          stateVersion = "25.05";
          shouldScrapeMetrics = false;
          # No IP - Incus VM with DHCP, external access via Tailscale
        };
        freshrss = {
          system = "x86_64-linux";
          usernames = ["bcotton"];
          stateVersion = "25.05";
          shouldScrapeMetrics = false;
          # No IP - Incus container with DHCP, accessed via Tailscale/tsnsrv
        };
      };

    # Derive host list from specs - used for SSH RemoteForward configuration
    nixosHosts = builtins.attrNames nixosHostSpecs;

    # List of clubcotton service names to show on homepage
    # Homepage metadata is read from each service's homepage.* options
    # Adding a service here just requires it to have homepage.* options defined
    homepageServiceList = [
      # Arr Suite
      "radarr"
      "sonarr"
      "lidarr"
      "prowlarr"
      "jellyseerr"
      # Media
      "jellyfin"
      "navidrome"
      "immich"
      "calibre-web"
      # Downloads
      "sabnzbd"
      "pinchflat"
      # Content
      "paperless"
      "freshrss"
      "wallabag"
      "filebrowser"
      # Infrastructure
      "forgejo"
      "atuin"
      "open-webui"
      "harmonia"
    ];

    # Services without standard clubcotton modules (need manual config)
    # Includes: monitoring services, multi-instance services
    homepageManualServices = {
      # Monitoring (standard nixpkgs services, not clubcotton)
      grafana = {
        name = "Grafana";
        category = "Monitoring";
        icon = "grafana.svg";
        description = "Metrics dashboards";
        href = "https://grafana.bobtail-clownfish.ts.net";
      };
      prometheus = {
        name = "Prometheus";
        category = "Monitoring";
        icon = "prometheus.svg";
        description = "Metrics collection";
        href = "http://admin:9001";
      };
      # Multi-instance services (readarr uses instances, not standard options)
      readarr-epub = {
        name = "Readarr (Books)";
        category = "Arr";
        icon = "readarr.svg";
        description = "E-book collection manager";
        tailnetHostname = "readarr-epub";
      };
      readarr-audio = {
        name = "Readarr (Audio)";
        category = "Arr";
        icon = "readarr.svg";
        description = "Audiobook collection manager";
        tailnetHostname = "readarr-audio";
      };
      # Infrastructure (non-clubcotton services)
      technitium = {
        name = "Technitium";
        category = "Infrastructure";
        icon = "technitium-dns-server.svg";
        description = "DNS & DHCP server";
        href = "http://dns-01:5380";
      };
      frigate = {
        name = "Frigate";
        category = "Smart Home";
        icon = "frigate.svg";
        description = "NVR & object detection";
        href = "http://frigate-host:5000";
      };
    };

    # NixOS system builder (consolidated from nixosSystem and nixosMinimalSystem)
    nixosSystem = {
      hostName,
      hostSpec, # Merged hostDefaults // per-host spec
      minimal ? false, # Toggle for minimal vs full
    }: let
      inherit (hostSpec) system usernames;
      pkgs = genPkgs system;
      unstablePkgs = genUnstablePkgs system;

      # Common modules for all NixOS systems
      commonModules =
        [
          (mkModuleArgs unstablePkgs system)
          ../overlays.nix
        ]
        ++ externalNixOSModules
        ++ internalModules
        ++ [
          # Enable nix cache client on all NixOS systems
          # Settings come from nix-builder-config flake defaults
          {services.nix-builder.client.enable = true;}
          ../hosts/nixos/${hostName}
          (mkHomeManagerConfig unstablePkgs system hostName usernames)
        ];

      # Additional modules for full (non-minimal) systems
      fullModules =
        serviceModules
        ++ [
          ../hosts/common/common-packages.nix
          ../hosts/common/nixos-common.nix
        ]
        ++ (
          if hostSpec.desktopPackages
          then [../hosts/common/nixos-desktop-packages.nix]
          else []
        )
        ++ [
          # Enable tailscale from hostSpec
          {services.clubcotton.tailscale.enable = hostSpec.tailscaleEnable;}
          # Auto-enable Glances on hosts with an IP and monitoring enabled
          (let
            hasIp = hostSpec.ip or null != null;
            enableGlances = hasIp && hostSpec.shouldMonitor;
          in {
            services.glances.enable = enableGlances;
            services.glances.openFirewall = enableGlances;
          })
        ];

      # User modules
      userModules = [../users/groups.nix] ++ map (username: ../users/${username}.nix) usernames;
    in
      nixpkgs.lib.nixosSystem {
        specialArgs = {
          inherit self system inputs hostName hostSpec nixosHostSpecs homepageServiceList homepageManualServices;
        };
        modules =
          [{nixpkgs.hostPlatform = system;}]
          ++ commonModules
          ++ (
            if minimal
            then []
            else fullModules
          )
          ++ userModules;
      };

    # Darwin system builder
    darwinSystem = {
      system,
      hostName,
      username,
      determinateNix ? false,
    }: let
      pkgs = genPkgs system;
      unstablePkgs = genUnstablePkgs system;
      hostSpec =
        hostDefaults
        // {
          primaryUser = username;
          inherit determinateNix;
        };
    in
      nix-darwin.lib.darwinSystem {
        inherit system;
        specialArgs = {
          inherit self system inputs hostName hostSpec;
        };
        modules =
          [
            (mkModuleArgs unstablePkgs system)
            ../overlays.nix
            inputs.home-manager.darwinModules.home-manager
          ]
          # nix-builder-config sets nix.settings.substituters which conflicts with nix.enable = false
          ++ lib.optionals (!determinateNix) [
            nix-builder-config.darwinModules.client
            {services.nix-builder.client.enable = true;}
          ]
          ++ [
            ../hosts/darwin/${hostName}
            {
              networking.hostName = hostName;

              home-manager.useGlobalPkgs = true;
              home-manager.useUserPackages = true;
              home-manager.users.${username}.imports = [
                ../home/${username}.nix
                inputs.workmux.homeManagerModules.default
              ];
              home-manager.extraSpecialArgs = {
                inherit inputs unstablePkgs hostName nixosHosts;
                localPackages = self.legacyPackages.${system}.localPackages;
                workmuxPackage = inputs.workmux.packages.${system}.default;
                crushPackage = inputs.nix-ai-tools.packages.${system}.crush;
                worktrunkPackage = inputs.worktrunk.packages.${system}.default;
                qmdPackage = inputs.qmd.packages.${system}.default.overrideAttrs (old: {
                  buildPhase = ''
                    export HOME=$(mktemp -d)
                    bun install
                  '';
                });
                gwsPackage = inputs.gws.packages.${system}.gws;
                devenvPackage = inputs.devenv.packages.${system}.devenv;
              };
            }
            ../hosts/common/common-packages.nix
            ../hosts/common/darwin-common.nix
            ../users/${username}.nix
          ];
      };
  in {
    # Darwin configurations
    darwinConfigurations = {
      bobs-laptop = darwinSystem {
        system = "aarch64-darwin";
        hostName = "bobs-laptop";
        username = "bcotton";
      };
      toms-MBP = darwinSystem {
        system = "x86_64-darwin";
        hostName = "toms-MBP";
        username = "tomcotton";
      };
      toms-mini = darwinSystem {
        system = "aarch64-darwin";
        hostName = "toms-mini";
        username = "tomcotton";
      };
      bobs-imac = darwinSystem {
        system = "x86_64-darwin";
        hostName = "bobs-imac";
        username = "bcotton";
      };
      bobs-work-laptop = darwinSystem {
        system = "aarch64-darwin";
        hostName = "bobs-work-laptop";
        username = "bcotton";
        determinateNix = true;
      };
    };

    # NixOS configurations - generated from nixosHostSpecs
    nixosConfigurations =
      builtins.mapAttrs (
        hostName: hostSpec:
          nixosSystem {
            inherit hostName hostSpec;
          }
      )
      nixosHostSpecs;

    # Expose host specs for CLI tooling (nix eval .#nixosHostSpecs)
    inherit nixosHostSpecs;
  };
}
