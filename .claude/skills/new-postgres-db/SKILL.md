---
name: new-postgres-db
description: Add a new PostgreSQL database to nas-01. Use when asked to create a new database, add database support for a service, or set up PostgreSQL for a new application.
argument-hint: service name (e.g., 'myapp')
---

# New PostgreSQL Database Setup

Guided workflow for adding a new PostgreSQL database to nas-01. This creates the Nix module, secrets, and host configuration following the established pattern.

## Prerequisites

- The `pg-scram-hash` tool must be available (`nix run .#pg-scram-hash` or installed)
- Access to `agenix` for secret creation
- The service name that needs a database

## Step 1: Gather Information

Ask the user for:

1. **Service name** (e.g., `myapp`) — used for database name, user name, file names
2. **Database name** (default: same as service name)
3. **Database user** (default: same as service name)
4. **PostgreSQL extensions needed?** (e.g., `pgvector`, `postgis`, `pg_trgm`) — most services need none
5. **Raw password consumer(s)** — who needs the raw (non-SCRAM) password? Can be one or more of:
   - A clubcotton service on nas-01 (e.g., `services.clubcotton.myapp`)
   - A regular user on any host (e.g., `bcotton` on `nix-01`)
   - An external application (not managed by nix)
   - Nobody yet (database-only setup, raw secret can be added later)

   For each consumer, collect:
   - **Owner user/group** for the secret file
   - **Guard condition** — what gates the secret's activation? Examples:
     - `config.services.clubcotton.<service>.enable` (clubcotton service)
     - `config.services.clubcotton.postgresql.<service>.enable` (gate on the DB itself)
     - `config.users.users ? bcotton` (regular user exists on host)
     - No guard / always available
   - **Host scope** — is this only needed on nas-01, or on other hosts too?
6. **Raw password format** — what format does the consumer expect?
   - Just the password (most common)
   - `DATABASE_URL=postgresql://user:pass@nas-01.lan:5432/db`
   - `DB_PASSWORD=<password>`
   - Other key=value format

## Step 2: Generate Password

Generate a random password for the database:

```bash
# Generate a 32-character random password
openssl rand -base64 32
```

Save this password — it's needed for both the SCRAM hash and the raw secret.

## Step 3: Create the Nix Module

Create `modules/postgresql/<service>.nix` following this template:

### Simple service (no extensions):

```nix
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
    <service> = {
      enable = mkEnableOption "<Service> database support";

      database = mkOption {
        type = types.str;
        default = "<service>";
        description = "Name of the <Service> database.";
      };

      user = mkOption {
        type = types.str;
        default = "<service>";
        description = "Name of the <Service> database user.";
      };

      passwordFile = mkOption {
        type = types.nullOr types.path;
        default = null;
        description = "Path to the user's password file.";
      };
    };
  };

  config = mkIf (cfg.enable && cfg.<service>.enable) {
    services.postgresql = {
      ensureDatabases = [cfg.<service>.database];
      ensureUsers = [
        {
          name = cfg.<service>.user;
          ensureDBOwnership = true;
          ensureClauses.login = true;
        }
      ];
    };

    services.clubcotton.postgresql.postStartCommands = let
      psql = "${lib.getExe' config.services.postgresql.package "psql"} -p ${toString cfg.port}";
      sqlFile = pkgs.writeText "<service>-setup.sql" ''
        ALTER SCHEMA public OWNER TO "${cfg.<service>.user}";
      '';
      passwordCmd = optionalString (cfg.<service>.passwordFile != null) ''
        ${psql} -tA <<'EOF'
          DO $$
          DECLARE password TEXT;
          BEGIN
            password := trim(both from replace(pg_read_file('${cfg.<service>.passwordFile}'), E'\n', '''));
            EXECUTE format('ALTER ROLE "${cfg.<service>.user}" WITH PASSWORD '''%s''';', password);
          END $$;
        EOF
      '';
    in [
      passwordCmd
      ''
        ${psql} -d "${cfg.<service>.database}" -f "${sqlFile}"
      ''
    ];
  };
}
```

### Service with extensions (add to the config block):

```nix
    # Add to services.postgresql.settings if shared_preload_libraries needed:
    services.postgresql.settings.shared_preload_libraries = "<extension>.so";

    # Add extensions to package:
    services.postgresql.extensions = ps: [ps.<extension>];

    # Create extensions in postStartCommands (add before the existing commands):
    services.clubcotton.postgresql.postStartCommands = let
      # ... (same as above, plus):
      extensionCmd = ''
        ${psql} -d "${cfg.<service>.database}" -c "CREATE EXTENSION IF NOT EXISTS <extension>;"
      '';
    in [
      passwordCmd
      extensionCmd
      ''
        ${psql} -d "${cfg.<service>.database}" -f "${sqlFile}"
      ''
    ];
```

## Step 4: Add Import to modules/postgresql/default.nix

Add `./<service>.nix` to the `imports` list in `modules/postgresql/default.nix`:

```nix
  imports = [
    ./atuin.nix
    ./forgejo.nix
    # ... existing imports ...
    ./<service>.nix  # <-- add in alphabetical order
  ];
```

## Step 5: Add Secret Declarations to secrets/secrets.nix

Add entries in alphabetical position. Always add the SCRAM secret. Add the raw secret if there is a consumer now.

```nix
  "<service>-database.age".publicKeys = users ++ systems;
  # Add only if raw password consumer(s) identified:
  "<service>-database-raw.age".publicKeys = users ++ systems;
```

## Step 6: Add Secret Activation to secrets/default.nix

### SCRAM hash secret (always — on nas-01 where PostgreSQL runs)

Gate on the postgresql sub-module. Owned by `postgres` so `pg_read_file()` works:

```nix
  age.secrets."<service>-database" = lib.mkIf config.services.clubcotton.postgresql.<service>.enable {
    file = ./<service>-database.age;
    owner = "postgres";
    group = "postgres";
  };
```

### Raw password secret(s) (per consumer)

The raw secret is a **consumer concern**, not a PostgreSQL concern. Gate and own it based on who needs it, not on the database module. Choose the appropriate pattern:

**Consumer is a clubcotton service on nas-01:**
```nix
  age.secrets."<service>-database-raw" = lib.mkIf config.services.clubcotton.<service>.enable {
    file = ./<service>-database-raw.age;
    owner = "<service>";
    group = "<service>";
  };
```

**Consumer is a regular user (any host):**
```nix
  age.secrets."<service>-database-raw" = lib.mkIf (config.users.users ? <username>) {
    file = ./<service>-database-raw.age;
    owner = "<username>";
    group = "users";
  };
```

**Consumer is the database itself (no service yet, gate on postgresql option):**
```nix
  age.secrets."<service>-database-raw" = lib.mkIf config.services.clubcotton.postgresql.<service>.enable {
    file = ./<service>-database-raw.age;
    owner = "<owner>";
    group = "<group>";
  };
```

**No consumer yet — skip the raw secret entirely.** It can be added later when the consumer is known.

**Multiple consumers on different hosts:** Create separate secrets with distinct names (e.g., `<service>-database-raw-bcotton`) if they need different owners or formats.

## Step 7: Enable on nas-01

Add to `hosts/nixos/nas-01/default.nix` inside the `services.clubcotton.postgresql` block:

```nix
    <service> = {
      enable = true;
      passwordFile = config.age.secrets."<service>-database".path;
    };
```

## Step 8: Create the Secrets (USER ACTION REQUIRED)

**STOP here and give the user these instructions.** The nix build will fail without the `.age` files.

Generate the password and SCRAM hash, then create the secrets:

```bash
# 1. Generate a random password
PASSWORD=$(openssl rand -base64 32)
echo "Save this password: $PASSWORD"

# 2. Create the SCRAM hash secret (for PostgreSQL authentication)
#    pg-scram-hash produces the SCRAM-SHA-256$... format PostgreSQL stores in pg_authid
nix run .#pg-scram-hash -- "$PASSWORD" | (cd secrets && agenix -e <service>-database.age)

# 3. Create the raw password secret (for the consuming service/user)
#    Format depends on the consumer — adjust as needed:
#
#    Plain password:
echo "$PASSWORD" | (cd secrets && agenix -e <service>-database-raw.age)
#
#    DATABASE_URL format:
echo "DATABASE_URL=postgresql://<service>:${PASSWORD}@nas-01.lan:5432/<service>" | (cd secrets && agenix -e <service>-database-raw.age)
#
#    KEY=value format:
echo "DB_PASSWORD=${PASSWORD}" | (cd secrets && agenix -e <service>-database-raw.age)
```

If no raw secret consumer was identified, skip step 3 — it can be created later.

## Step 9: Build and Verify

After the user confirms secrets are created:

```bash
git add modules/postgresql/<service>.nix secrets/<service>-database.age secrets/<service>-database-raw.age
just build nas-01
```

If the raw secret is consumed on another host, build that host too:

```bash
just build <other-host>
```

## Checklist

- [ ] Module created: `modules/postgresql/<service>.nix`
- [ ] Import added to `modules/postgresql/default.nix`
- [ ] Secret declarations in `secrets/secrets.nix` (SCRAM + raw if needed)
- [ ] Secret activation in `secrets/default.nix` (SCRAM always; raw per consumer)
- [ ] Enabled on nas-01 in `hosts/nixos/nas-01/default.nix`
- [ ] User created `.age` files with `agenix`
- [ ] Build succeeds (nas-01 + any consumer hosts)
