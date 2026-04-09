{
  config,
  lib,
  pkgs,
  ...
}:
with lib; let
  cfg = config.services.clubcotton.postgresql;
in {
  options.services.clubcotton.postgresql = {
    honcho = {
      enable = mkEnableOption "Honcho database support";

      database = mkOption {
        type = types.str;
        default = "honcho";
        description = "Name of the Honcho database.";
      };

      user = mkOption {
        type = types.str;
        default = "honcho";
        description = "Name of the Honcho database user.";
      };

      passwordFile = mkOption {
        type = types.nullOr types.path;
        default = null;
        description = "Path to the user's password file.";
      };
    };
  };

  config = mkIf (cfg.enable && cfg.honcho.enable) {
    services.postgresql = {
      ensureDatabases = [cfg.honcho.database];
      ensureUsers = [
        {
          name = cfg.honcho.user;
          ensureDBOwnership = true;
          ensureClauses.login = true;
        }
      ];
      extensions = ps: [ps.pgvector];
    };

    services.clubcotton.postgresql.passwordFiles =
      optional (cfg.honcho.passwordFile != null) cfg.honcho.passwordFile;

    services.clubcotton.postgresql.postStartCommands = let
      psql = "${lib.getExe' config.services.postgresql.package "psql"} -p ${toString cfg.port}";
      sqlFile = pkgs.writeText "honcho-setup.sql" ''
        CREATE EXTENSION IF NOT EXISTS vector;

        ALTER SCHEMA public OWNER TO "${cfg.honcho.user}";
      '';
      passwordCmd = optionalString (cfg.honcho.passwordFile != null) ''
        ${psql} -tA <<'EOF'
          DO $$
          DECLARE password TEXT;
          BEGIN
            password := trim(both from replace(pg_read_file('${cfg.honcho.passwordFile}'), E'\n', '''));
            EXECUTE format('ALTER ROLE "${cfg.honcho.user}" WITH PASSWORD '''%s''';', password);
          END $$;
        EOF
      '';
    in [
      passwordCmd
      ''
        ${psql} -d "${cfg.honcho.database}" -f "${sqlFile}"
      ''
    ];
  };
}
