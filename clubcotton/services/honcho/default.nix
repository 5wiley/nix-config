{
  config,
  lib,
  pkgs,
  localPackages,
  ...
}:
with lib; let
  service = "honcho";
  cfg = config.services.clubcotton.${service};
  clubcotton = config.clubcotton;

  # Generate config.toml from module options
  configFile = pkgs.writeText "honcho-config.toml" ''
    [app]
    LOG_LEVEL = "${cfg.logLevel}"
    NAMESPACE = "${cfg.namespace}"

    [db]
    CONNECTION_URI = "will-be-overridden-by-env"

    [auth]
    USE_AUTH = ${boolToString cfg.auth.enable}
    ${optionalString (cfg.auth.jwtSecret != null) ''JWT_SECRET = "will-be-overridden-by-env"''}

    [llm]
    DEFAULT_MAX_TOKENS = 2500
    EMBEDDING_PROVIDER = "${cfg.llm.embeddingProvider}"
    EMBEDDING_MODEL = "${cfg.llm.embeddingModel}"
    OPENAI_COMPATIBLE_API_KEY = "not-needed"
    OPENAI_COMPATIBLE_BASE_URL = "${cfg.llm.embeddingBaseUrl}"
    VLLM_API_KEY = "not-needed"
    VLLM_BASE_URL = "${cfg.llm.chatBaseUrl}"

    [deriver]
    ENABLED = true
    WORKERS = ${toString cfg.deriver.workers}
    PROVIDER = "vllm"
    MODEL = "${cfg.llm.chatModel}"
    THINKING_BUDGET_TOKENS = 1
    MAX_OUTPUT_TOKENS = 4096
    MAX_INPUT_TOKENS = 23000
    FLUSH_ENABLED = ${boolToString cfg.deriver.flushEnabled}

    [peer_card]
    ENABLED = true

    [dialectic]
    MAX_OUTPUT_TOKENS = 8192
    MAX_INPUT_TOKENS = 32000
    HISTORY_TOKEN_LIMIT = 8192
    SESSION_HISTORY_MAX_TOKENS = 4096

    [dialectic.levels.minimal]
    PROVIDER = "vllm"
    MODEL = "${cfg.llm.chatModel}"
    THINKING_BUDGET_TOKENS = 0
    MAX_TOOL_ITERATIONS = 1
    MAX_OUTPUT_TOKENS = 250
    TOOL_CHOICE = "required"

    [dialectic.levels.low]
    PROVIDER = "vllm"
    MODEL = "${cfg.llm.chatModel}"
    THINKING_BUDGET_TOKENS = 0
    MAX_TOOL_ITERATIONS = 3
    TOOL_CHOICE = "required"

    [dialectic.levels.medium]
    PROVIDER = "vllm"
    MODEL = "${cfg.llm.chatModel}"
    THINKING_BUDGET_TOKENS = 0
    MAX_TOOL_ITERATIONS = 2

    [dialectic.levels.high]
    PROVIDER = "vllm"
    MODEL = "${cfg.llm.chatModel}"
    THINKING_BUDGET_TOKENS = 0
    MAX_TOOL_ITERATIONS = 4

    [dialectic.levels.max]
    PROVIDER = "vllm"
    MODEL = "${cfg.llm.chatModel}"
    THINKING_BUDGET_TOKENS = 0
    MAX_TOOL_ITERATIONS = 6

    [summary]
    ENABLED = true
    PROVIDER = "vllm"
    MODEL = "${cfg.llm.chatModel}"
    THINKING_BUDGET_TOKENS = 1
    MAX_TOKENS_SHORT = 1000
    MAX_TOKENS_LONG = 4000

    [dream]
    ENABLED = true
    PROVIDER = "vllm"
    MODEL = "${cfg.llm.chatModel}"
    THINKING_BUDGET_TOKENS = 1
    MAX_OUTPUT_TOKENS = 8192
    MAX_TOOL_ITERATIONS = 10
    HISTORY_TOKEN_LIMIT = 16384
    DEDUCTION_MODEL = "${cfg.llm.chatModel}"
    INDUCTION_MODEL = "${cfg.llm.chatModel}"

    [cache]
    ENABLED = ${boolToString cfg.cache.enable}
    ${optionalString cfg.cache.enable ''URL = "${cfg.cache.url}"''}

    [vector_store]
    TYPE = "pgvector"
    DIMENSIONS = ${toString cfg.llm.embeddingDimensions}
  '';

  # Common environment for both API and deriver
  commonEnv = {
    HONCHO_STATE_DIR = cfg.stateDir;
  };
in {
  options.services.clubcotton.${service} = {
    enable = mkEnableOption "Honcho AI memory server";

    package = mkOption {
      type = types.package;
      default = localPackages.honcho;
      description = "Honcho package to use.";
    };

    stateDir = mkOption {
      type = types.path;
      default = "/var/lib/honcho";
      description = "State directory for Honcho (venv, runtime data).";
    };

    port = mkOption {
      type = types.port;
      default = 8000;
      description = "Port for the Honcho API server.";
    };

    logLevel = mkOption {
      type = types.enum ["DEBUG" "INFO" "WARNING" "ERROR" "CRITICAL"];
      default = "INFO";
      description = "Log level for Honcho.";
    };

    namespace = mkOption {
      type = types.str;
      default = "honcho";
      description = "Namespace for Honcho resources.";
    };

    # Database — connection string comes from agenix secret
    databaseSecretFile = mkOption {
      type = types.path;
      default = config.age.secrets."honcho-database-raw".path;
      description = "Path to file containing DB_CONNECTION_URI=postgresql+psycopg://...";
    };

    # Authentication
    auth = {
      enable = mkOption {
        type = types.bool;
        default = false;
        description = "Enable JWT authentication.";
      };
      jwtSecret = mkOption {
        type = types.nullOr types.path;
        default = null;
        description = "Path to file containing JWT_SECRET.";
      };
    };

    # LLM configuration
    llm = {
      chatBaseUrl = mkOption {
        type = types.str;
        default = "http://nas-01:8090/v1";
        description = "Base URL for the chat/agent LLM (llama-swap, vLLM, etc).";
      };

      chatModel = mkOption {
        type = types.str;
        default = "gemma-4-26b-a4b-it-bf16";
        description = "Model name for chat/agent operations.";
      };

      embeddingProvider = mkOption {
        type = types.str;
        default = "openai";
        description = "Embedding provider type (openai, ollama, etc).";
      };

      embeddingBaseUrl = mkOption {
        type = types.str;
        default = "http://nix-01:11434/v1";
        description = "Base URL for the embedding model (Ollama, etc).";
      };

      embeddingModel = mkOption {
        type = types.str;
        default = "gte-qwen2-1.5b:latest";
        description = "Model name for embeddings.";
      };

      embeddingDimensions = mkOption {
        type = types.int;
        default = 1536;
        description = "Embedding vector dimensions (must match model output).";
      };
    };

    # Cache (Redis)
    cache = {
      enable = mkOption {
        type = types.bool;
        default = false;
        description = "Enable Redis cache.";
      };
      url = mkOption {
        type = types.str;
        default = "redis://localhost:6379/0";
        description = "Redis connection URL.";
      };
    };

    # Deriver settings
    deriver = {
      workers = mkOption {
        type = types.int;
        default = 1;
        description = "Number of deriver worker threads.";
      };
      flushEnabled = mkOption {
        type = types.bool;
        default = false;
        description = "Process work immediately instead of batching.";
      };
    };

    # Networking
    openFirewall = mkOption {
      type = types.bool;
      default = true;
      description = "Whether to open the firewall port.";
    };

    tailnetHostname = mkOption {
      type = types.nullOr types.str;
      default = "honcho";
      description = "Tailscale hostname to expose the service as.";
    };

    homepage.name = mkOption {
      type = types.str;
      default = "Honcho";
    };
    homepage.description = mkOption {
      type = types.str;
      default = "AI agent memory and social cognition";
    };
    homepage.icon = mkOption {
      type = types.str;
      default = "honcho.svg";
    };
    homepage.category = mkOption {
      type = types.str;
      default = "Infrastructure";
    };
  };

  config = mkIf cfg.enable {
    # Enable PostgreSQL with pgvector
    services.clubcotton.postgresql.honcho = {
      enable = true;
      passwordFile = config.age.secrets."honcho-database".path;
    };

    # Create service user
    users.users.honcho = {
      isSystemUser = true;
      group = "honcho";
      home = cfg.stateDir;
    };
    users.groups.honcho = {};

    # Create state directory and symlink config.toml (Honcho reads from cwd)
    systemd.tmpfiles.rules = [
      "d '${cfg.stateDir}' 0750 honcho honcho - -"
      "L+ '${cfg.stateDir}/config.toml' - - - - ${configFile}"
    ];

    # Database migrations (runs once before API starts, re-runnable via systemctl)
    systemd.services.honcho-migrate = {
      description = "Honcho Database Migrations";
      after = ["postgresql.service"];
      requires = ["postgresql.service"];

      environment = commonEnv;

      script = ''
        source ${cfg.databaseSecretFile}
        export DB_CONNECTION_URI="$CONNECTION_STRING"
        ${cfg.package}/bin/honcho-migrate
      '';

      serviceConfig = {
        Type = "oneshot";
        RemainAfterExit = true;
        User = "honcho";
        Group = "honcho";
        WorkingDirectory = cfg.stateDir;
        ReadWritePaths = [cfg.stateDir];
        ProtectSystem = "strict";
        ProtectHome = true;
        NoNewPrivileges = true;
        PrivateTmp = true;
      };
    };

    # API server
    systemd.services.honcho-api = {
      description = "Honcho API Server";
      after = ["honcho-migrate.service" "network.target"];
      requires = ["honcho-migrate.service"];
      wantedBy = ["multi-user.target"];

      environment = commonEnv;

      script = ''
        source ${cfg.databaseSecretFile}
        export DB_CONNECTION_URI="$CONNECTION_STRING"
        exec ${cfg.package}/bin/honcho-api --port ${toString cfg.port}
      '';

      serviceConfig = {
        Type = "simple";
        User = "honcho";
        Group = "honcho";
        WorkingDirectory = cfg.stateDir;

        Restart = "on-failure";
        RestartSec = 5;

        # Hardening
        ReadWritePaths = [cfg.stateDir];
        ProtectSystem = "strict";
        ProtectHome = true;
        NoNewPrivileges = true;
        PrivateTmp = true;
      };
    };

    # Deriver worker
    systemd.services.honcho-deriver = {
      description = "Honcho Deriver Worker";
      after = ["honcho-api.service"];
      requires = ["honcho-api.service"];
      wantedBy = ["multi-user.target"];

      environment = commonEnv;

      script = ''
        source ${cfg.databaseSecretFile}
        export DB_CONNECTION_URI="$CONNECTION_STRING"
        exec ${cfg.package}/bin/honcho-deriver
      '';

      serviceConfig = {
        Type = "simple";
        User = "honcho";
        Group = "honcho";
        WorkingDirectory = cfg.stateDir;

        Restart = "on-failure";
        RestartSec = 5;

        ReadWritePaths = [cfg.stateDir];
        ProtectSystem = "strict";
        ProtectHome = true;
        NoNewPrivileges = true;
        PrivateTmp = true;
      };
    };

    # Tailscale
    services.tsnsrv = mkIf (cfg.tailnetHostname != null && cfg.tailnetHostname != "") {
      enable = true;
      defaults.authKeyPath = clubcotton.tailscaleAuthKeyPath;
      services."${cfg.tailnetHostname}" = {
        ephemeral = true;
        toURL = "http://127.0.0.1:${toString cfg.port}/";
      };
    };

    # Firewall
    networking.firewall.allowedTCPPorts = mkIf cfg.openFirewall [cfg.port];
  };
}
