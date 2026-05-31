{
  config,
  lib,
  pkgs,
  ...
}:
with lib; let
  service = "karakeep";
  cfg = config.services.clubcotton.${service};
  clubcotton = config.clubcotton;
in {
  options.services.clubcotton.${service} = {
    enable = mkEnableOption "Karakeep self-hostable bookmark-everything app";

    package = mkOption {
      type = types.package;
      default = pkgs.karakeep;
      defaultText = literalExpression "pkgs.karakeep";
      description = "Karakeep package to use.";
    };

    port = mkOption {
      type = types.port;
      default = 3030;
      description = "Port for the Karakeep web service (forgejo already uses 3000 on nas-01).";
    };

    environmentFile = mkOption {
      type = types.nullOr types.path;
      default = null;
      description = ''
        Optional environment file for private keys (e.g., OPENAI_API_KEY for
        AI-based tagging). NEXTAUTH_SECRET and MEILI_MASTER_KEY are generated
        automatically by the upstream module on first start.
      '';
      example = "/run/agenix/karakeep.env";
    };

    extraEnvironment = mkOption {
      type = types.attrsOf types.str;
      default = {};
      description = "Extra environment variables forwarded to the karakeep services.";
      example = literalExpression ''
        {
          DISABLE_SIGNUPS = "true";
        }
      '';
    };

    browser.enable = mkOption {
      type = types.bool;
      default = true;
      description = "Run the chromium sidecar (needed for screenshots and full-page archives).";
    };

    meilisearch.enable = mkOption {
      type = types.bool;
      default = true;
      description = "Enable the bundled Meilisearch instance for full-text search.";
    };

    tailnetHostname = mkOption {
      type = types.str;
      default = "${service}";
      description = "Tailscale hostname for the service. Set to empty to disable tsnsrv exposure.";
    };

    openFirewall = mkOption {
      type = types.bool;
      default = false;
      description = "Whether to open the firewall port. Defaults to off; reach the app via tailnet.";
    };

    homepage.name = mkOption {
      type = types.str;
      default = "Karakeep";
    };
    homepage.description = mkOption {
      type = types.str;
      default = "Bookmark-everything app with AI tagging";
    };
    homepage.icon = mkOption {
      type = types.str;
      default = "karakeep.svg";
    };
    homepage.category = mkOption {
      type = types.str;
      default = "Content";
    };
  };

  config = mkIf cfg.enable {
    services.karakeep = {
      enable = true;
      package = cfg.package;
      environmentFile = cfg.environmentFile;
      browser.enable = cfg.browser.enable;
      meilisearch.enable = cfg.meilisearch.enable;
      extraEnvironment =
        {
          PORT = toString cfg.port;
          NEXTAUTH_URL = "https://${cfg.tailnetHostname}.bobtail-clownfish.ts.net";
          DISABLE_NEW_RELEASE_CHECK = "true";
        }
        // cfg.extraEnvironment;
    };

    services.tsnsrv = mkIf (cfg.tailnetHostname != "") {
      enable = true;
      defaults.authKeyPath = clubcotton.tailscaleAuthKeyPath;

      services."${cfg.tailnetHostname}" = {
        ephemeral = true;
        toURL = "http://127.0.0.1:${toString cfg.port}/";
      };
    };

    networking.firewall.allowedTCPPorts = mkIf cfg.openFirewall [cfg.port];
  };
}
