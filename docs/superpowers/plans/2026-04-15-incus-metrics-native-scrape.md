# Incus Metrics Native Scrape Migration — Implementation Plan

> **For agentic workers:** REQUIRED: Use superpowers:subagent-driven-development (if subagents available) or superpowers:executing-plans to implement this plan. Steps use checkbox (`- [ ]`) syntax for tracking.

**Goal:** Replace the bash/textfile-collector pipeline in `modules/incus/monitoring.nix` with a direct Prometheus scrape of incus's native `/1.0/metrics` TLS endpoint.

**Architecture:** Three new Prometheus scrape targets (nas-01 for the cluster, condo-01, natalya-01) using TLS client-cert auth via agenix secrets. The textfile collector is deleted from all 8 hosts that import `modules/incus`. Alert rules are updated to match the new scrape topology.

**Tech Stack:** NixOS, Prometheus, agenix, incus TLS API

**Spec:** `docs/superpowers/specs/2026-04-15-incus-metrics-native-scrape-design.md`

---

## File Map

| File | Action | Responsibility |
|------|--------|---------------|
| `secrets/secrets.nix` | Modify (line ~71, alphabetical between `paperless-database-raw.age` and `pushover-key.age`) | Declare `prometheus-incus-cert.age` and `prometheus-incus-key.age` |
| `secrets/default.nix` | Modify (after line ~55) | Activate secrets, gated on `config.services.prometheus.enable` |
| `modules/prometheus/default.nix` | Modify (line ~299, before `++ scrapeConfigs.autogenScrapeConfigs`) | Add `incus` scrape job |
| `modules/prometheus/prometheus.rules.yaml` | Modify (lines 1048–1054) | Replace `IncusMetricsStale` with `IncusScrapeDown` |
| `modules/incus/monitoring.nix` | Delete | Remove entire textfile collector |
| `modules/incus/default.nix` | Modify (line 8) | Remove `./monitoring.nix` import |

Depending on the `incus_warnings` decision (Task 1), one additional file may be created:

| File | Action | Responsibility |
|------|--------|---------------|
| `modules/incus/warnings-collector.nix` | Create (if needed) | Minimal textfile collector for just `incus_warnings` gauge |

---

## Chunk 1: Reconnaissance and Secrets

### Task 1: Verify native endpoint metrics and label sets

**Files:** None modified — read-only investigation.

This task decides the `incus_warnings` path and validates that recording rules will survive the migration.

- [ ] **Step 1: Fetch native metrics from the cluster**

SSH to nas-01 and query the local incus API via the unix socket (no TLS needed for local socket):

```bash
ssh nas-01 'incus query /1.0/metrics' > /tmp/incus-native-metrics.txt
```

- [ ] **Step 2: Catalog metric names and label sets**

Extract every unique metric name and its label set:

```bash
grep -v '^#' /tmp/incus-native-metrics.txt | sed 's/{.*//' | sort -u > /tmp/incus-metric-names.txt
```

For each metric referenced in `modules/prometheus/prometheus.rules.yaml` lines 937–1049, confirm it exists in the native output. The metrics to check:

- `incus_cpu_seconds_total` — labels must include: `mode`, `name`, `project`
- `incus_memory_Active_bytes` — labels must include: `name`, `project`
- `incus_memory_MemTotal_bytes` — labels must include: `name`, `project`
- `incus_filesystem_avail_bytes` — labels must include: `mountpoint`, `fstype`
- `incus_filesystem_size_bytes` — labels must include: `mountpoint`, `fstype`
- `incus_uptime_seconds` — any labels
- `incus_warnings` — check if this exists natively (gauge, with `severity` label)

```bash
for m in incus_cpu_seconds_total incus_memory_Active_bytes incus_memory_MemTotal_bytes \
         incus_filesystem_avail_bytes incus_filesystem_size_bytes incus_uptime_seconds \
         incus_warnings; do
  echo "=== $m ==="
  grep "^${m}" /tmp/incus-native-metrics.txt | head -3
done
```

- [ ] **Step 3: Decide the `incus_warnings` path**

Based on step 2 output:
- **If `incus_warnings` exists as a gauge with `severity` label:** No extra work. Record this finding.
- **If it exists under a different name:** Record the real name; Task 5 will update the alert.
- **If it doesn't exist natively:** Task 7 will create `modules/incus/warnings-collector.nix`.

Document the decision in a commit message for traceability.

- [ ] **Step 4: Commit investigation results**

```bash
git commit --allow-empty -m "chore(incus-metrics): document native endpoint investigation

Metrics verified: [list which were found]
incus_warnings path: [1/2/3 per spec]
Label gaps: [none / list any]"
```

### Task 2: Add secret declarations

**Files:**
- Modify: `secrets/secrets.nix` (insert at ~line 86, alphabetical position between `"borg-passphrase.age"` and `"cloudflare-tunnel-token.age"`)

- [ ] **Step 1: Add declarations**

Insert these two lines in alphabetical position in `secrets/secrets.nix`:

```nix
  "prometheus-incus-cert.age".publicKeys = users ++ systems;
  "prometheus-incus-key.age".publicKeys = users ++ systems;
```

They go after the `"paperless-database-raw.age"` line (line 71) and before `"pushover-key.age"` (line 72), following alphabetical order of the `prometheus-` prefix.

- [ ] **Step 2: Verify the file parses**

```bash
nix eval --file secrets/secrets.nix --json | jq 'keys | map(select(startswith("prometheus")))' 
```

Expected: `["prometheus-incus-cert.age", "prometheus-incus-key.age"]`

- [ ] **Step 3: Commit**

```bash
git add secrets/secrets.nix
git commit -m "feat(secrets): declare prometheus-incus TLS client cert and key

For native scrape of incus /1.0/metrics endpoint.
Part of #291."
```

### Task 3: Add secret activation

**Files:**
- Modify: `secrets/default.nix` (insert after the `homeassistant-token` block, ~line 56)

- [ ] **Step 1: Add activation blocks**

Insert after the `age.secrets."homeassistant-token"` block (line 55) in `secrets/default.nix`:

```nix
  age.secrets."prometheus-incus-cert" = lib.mkIf config.services.prometheus.enable {
    file = ./prometheus-incus-cert.age;
    owner = "prometheus";
    group = "prometheus";
  };

  age.secrets."prometheus-incus-key" = lib.mkIf config.services.prometheus.enable {
    file = ./prometheus-incus-key.age;
    owner = "prometheus";
    group = "prometheus";
    mode = "0400";
  };
```

This follows the existing pattern for prometheus-owned secrets (`condo-ha-token`, `homeassistant-token`).

- [ ] **Step 2: Commit**

```bash
git add secrets/default.nix
git commit -m "feat(secrets): activate prometheus-incus TLS cert and key on admin

Gated on services.prometheus.enable, owned by prometheus:prometheus.
Part of #291."
```

### Task 4: STOP — User creates secrets

**Files:** None modified by the implementer.

**STOP HERE.** The `.age` files do not exist yet. The nix build will fail without them. Give the user these instructions:

```bash
# 1. Generate an ECDSA keypair, self-signed, 10-year validity
openssl req -x509 -newkey ec:<(openssl ecparam -name prime256v1) \
  -nodes -days 3650 -subj '/CN=prometheus' \
  -keyout /tmp/prom-incus.key -out /tmp/prom-incus.crt

# 2. Encrypt into the repo
cd secrets
EDITOR="cp /tmp/prom-incus.crt" agenix -e prometheus-incus-cert.age
EDITOR="cp /tmp/prom-incus.key" agenix -e prometheus-incus-key.age
cd ..

# 3. Trust on each incus deployment (run once per deployment)
scp /tmp/prom-incus.crt nas-01:/tmp/
ssh nas-01 'incus config trust add-certificate /tmp/prom-incus.crt --name prometheus && rm /tmp/prom-incus.crt'
scp /tmp/prom-incus.crt condo-01:/tmp/
ssh condo-01 'incus config trust add-certificate /tmp/prom-incus.crt --name prometheus && rm /tmp/prom-incus.crt'
scp /tmp/prom-incus.crt natalya-01:/tmp/
ssh natalya-01 'incus config trust add-certificate /tmp/prom-incus.crt --name prometheus && rm /tmp/prom-incus.crt'

# 4. Cleanup
shred -u /tmp/prom-incus.key /tmp/prom-incus.crt
```

- [ ] **Step 1: Present instructions to user and wait for confirmation**
- [ ] **Step 2: After user confirms, verify `.age` files exist**

```bash
ls -la secrets/prometheus-incus-cert.age secrets/prometheus-incus-key.age
```

- [ ] **Step 3: Stage and commit the `.age` files**

```bash
git add secrets/prometheus-incus-cert.age secrets/prometheus-incus-key.age
git commit -m "feat(secrets): add encrypted prometheus-incus TLS client cert and key

User-generated ECDSA cert trusted on nas-01, condo-01, natalya-01.
Part of #291."
```

---

## Chunk 2: Scrape Job and Alert Updates

### Task 5: Add the incus scrape job

**Files:**
- Modify: `modules/prometheus/default.nix` (insert before the `++ scrapeConfigs.autogenScrapeConfigs` line at line 300)

- [ ] **Step 1: Add the scrape job**

Insert this block at the end of the `scrapeConfigs` list, just before line 300 (`++ scrapeConfigs.autogenScrapeConfigs;`):

```nix
        {
          job_name = "incus";
          scheme = "https";
          metrics_path = "/1.0/metrics";
          scrape_interval = "30s";
          scrape_timeout = "10s";
          tls_config = {
            cert_file = config.age.secrets."prometheus-incus-cert".path;
            key_file = config.age.secrets."prometheus-incus-key".path;
            insecure_skip_verify = true;
          };
          static_configs = [
            {targets = ["nas-01.lan:8443"];}
            {targets = ["condo-01.lan:8443"];}
            {targets = ["natalya-01.lan:8443"];}
          ];
          relabel_configs = [
            {
              source_labels = ["__address__"];
              regex = "([^.:]+)(\\..*)?:[0-9]+";
              target_label = "instance";
              replacement = "\${1}";
            }
          ];
        }
```

Note: the `\${1}` is correct Nix escaping — it produces literal `${1}` in the generated YAML, which is valid Prometheus relabel replacement syntax.

- [ ] **Step 2: Verify syntax**

```bash
nix eval '.#nixosConfigurations.admin.config.services.prometheus.scrapeConfigs' --json 2>&1 | head -5
```

This should parse without errors. If it fails because the `.age` files aren't committed yet, verify manually that the nix syntax is correct (balanced braces, semicolons).

- [ ] **Step 3: Commit**

```bash
git add modules/prometheus/default.nix
git commit -m "feat(prometheus): add native incus metrics scrape job

Scrapes /1.0/metrics on nas-01 (cluster), condo-01, natalya-01
via TLS client cert auth. Replaces the textfile collector pipeline.
Part of #291."
```

### Task 6: Update alert rules

**Files:**
- Modify: `modules/prometheus/prometheus.rules.yaml` (lines 1048–1054)

- [ ] **Step 1: Replace IncusMetricsStale with IncusScrapeDown**

Find and replace lines 1048–1054 in `modules/prometheus/prometheus.rules.yaml`.

Remove:
```yaml
  - alert: IncusMetricsStale
    expr: (time() - node_textfile_mtime_seconds{file="incus.prom"}) > 60
    for: 5m
    labels:
      severity: warning
    annotations:
      description: 'Incus metrics collector on {{ $labels.instance }} has not updated for over 60 seconds'
```

Replace with:
```yaml
  - alert: IncusScrapeDown
    expr: up{job="incus"} == 0
    for: 5m
    labels:
      severity: warning
    annotations:
      description: 'Incus metrics scrape for {{ $labels.instance }} has been down for 5 minutes'
```

- [ ] **Step 2: Handle incus_warnings (conditional)**

**If Task 1 found `incus_warnings` natively with severity label:** No change needed to `IncusWarningsPresent` alert (line 984). Skip to step 3.

**If Task 1 found it under a different name:** Update line 984:
```yaml
  - alert: IncusWarningsPresent
    expr: <real_metric_name>{severity!="low"} > 0
```

**If Task 1 found no native warnings metric:** Leave `IncusWarningsPresent` unchanged (it will be fed by the minimal collector from Task 7).

- [ ] **Step 3: Commit**

```bash
git add modules/prometheus/prometheus.rules.yaml
git commit -m "feat(prometheus): replace IncusMetricsStale with IncusScrapeDown

The textfile staleness check is meaningless after migrating to native
scrape. Use up{job=\"incus\"} == 0 instead.
Part of #291."
```

### Task 7: Create minimal warnings collector (conditional)

**Files:**
- Create: `modules/incus/warnings-collector.nix` (only if Task 1 step 3 chose path 3)
- Modify: `modules/incus/default.nix` line 8 (add import, only if creating the file)

**Skip this entire task if Task 1 found `incus_warnings` natively.** Proceed to Task 8.

- [ ] **Step 1: Create `modules/incus/warnings-collector.nix`**

```nix
{
  config,
  lib,
  pkgs,
  ...
}: {
  systemd.services.incus-warnings-collector = lib.mkIf config.virtualisation.incus.enable {
    description = "Collect Incus warning counts for Prometheus";
    after = ["incus.service"];
    wants = ["incus.service"];
    serviceConfig = {
      Type = "oneshot";
      ExecStart = pkgs.writeShellScript "incus-warnings-collector" ''
        TEXTFILE_DIR="/var/lib/prometheus-node-exporter-text-files"
        TMP="$TEXTFILE_DIR/incus-warnings.prom.tmp"
        OUT="$TEXTFILE_DIR/incus-warnings.prom"

        WARN_CSV=$(${pkgs.incus}/bin/incus warning list --format csv 2>/dev/null || true)
        {
          echo '# HELP incus_warnings Active warnings by severity'
          echo '# TYPE incus_warnings gauge'
          for severity in low moderate severe; do
            COUNT=$(echo "$WARN_CSV" | ${pkgs.gnugrep}/bin/grep -ci ",''${severity}," || true)
            echo "incus_warnings{severity=\"$severity\"} $COUNT"
          done
        } > "$TMP"
        chmod 644 "$TMP"
        mv "$TMP" "$OUT"
      '';
      User = "root";
      Group = "root";
    };
  };

  systemd.timers.incus-warnings-collector = lib.mkIf config.virtualisation.incus.enable {
    description = "Collect Incus warning counts every 60 seconds";
    wantedBy = ["timers.target"];
    timerConfig = {
      OnCalendar = "*:*:00";
      Persistent = true;
    };
  };
}
```

- [ ] **Step 2: Update `modules/incus/default.nix` imports**

Replace the `./monitoring.nix` import with `./warnings-collector.nix`:

```nix
  imports = [
    ./warnings-collector.nix
  ];
```

(If Task 1 found warnings natively, `monitoring.nix` is removed with no replacement — that's handled in Task 8 instead.)

- [ ] **Step 3: Commit**

```bash
git add modules/incus/warnings-collector.nix modules/incus/default.nix
git commit -m "feat(incus): add minimal warnings-only textfile collector

Native /1.0/metrics does not expose incus_warnings as a gauge.
Keep a small collector for just this one metric.
Part of #291."
```

---

## Chunk 3: Collector Deletion and Verification

### Task 8: Delete the textfile collector

**Files:**
- Delete: `modules/incus/monitoring.nix`
- Modify: `modules/incus/default.nix` line 8 (remove `./monitoring.nix` import)

**If Task 7 was executed:** The import was already changed in Task 7 step 2. Only delete `monitoring.nix` here.

**If Task 7 was skipped (warnings found natively):** Both the import removal and file deletion happen here.

- [ ] **Step 1: Verify tmpfiles rule is not orphaned**

Check that other modules declare the textfile directory on every host that needs it:

```bash
grep -rn 'prometheus-node-exporter-text-files' modules/ --include="*.nix" | grep -v monitoring.nix
```

If this returns results from `modules/zfs/monitoring.nix` or similar, the directory is covered. If a host that imports `modules/incus` but not the zfs module would be orphaned, add a tmpfiles rule to the host or to a common module. (Per spec review, condo-01 and natalya-01 both import the zfs module, so this is likely safe.)

- [ ] **Step 2: Delete `modules/incus/monitoring.nix`**

```bash
rm modules/incus/monitoring.nix
```

- [ ] **Step 3: Update `modules/incus/default.nix`**

If Task 7 was **skipped** (no warnings collector needed), remove the `./monitoring.nix` import. The imports list becomes empty, so remove the entire `imports` block:

Change:
```nix
  imports = [
    ./monitoring.nix
  ];
```

To: (delete the three lines entirely — no `imports` block needed)

If Task 7 was **executed**, the import was already changed to `./warnings-collector.nix`. Only delete `monitoring.nix` — do not change `default.nix`.

- [ ] **Step 4: Verify build for admin (prometheus host)**

```bash
nix build '.#nixosConfigurations.admin.config.system.build.toplevel' --option builders ''
```

This must succeed. If it fails due to missing `.age` files, confirm Task 4 was completed.

- [ ] **Step 5: Verify build for one incus host**

```bash
nix build '.#nixosConfigurations.nas-01.config.system.build.toplevel' --option builders ''
```

This confirms the incus module still builds without the deleted monitoring module.

- [ ] **Step 6: Commit**

```bash
git add -u modules/incus/
git commit -m "feat(incus): delete textfile collector monitoring.nix

Native Prometheus scrape replaces the bash pipeline.
Closes the textfile-collector portion of #291."
```

### Task 9: Verify instance label impact

**Files:** None modified — read-only investigation.

- [ ] **Step 1: Search for dashboards or configs referencing incus instance labels**

```bash
grep -rn 'instance.*nix-0' modules/grafana/ clubcotton/ 2>/dev/null || echo "no matches"
grep -rn 'incus.*instance' modules/grafana/ clubcotton/ 2>/dev/null || echo "no matches"
```

If any Grafana dashboard JSON or provisioning config filters on `instance=~"nix-0.*"` for incus metrics, note them for manual update after deployment.

- [ ] **Step 2: Document any findings**

If there are matches, create a follow-up issue. If none, record "no instance label conflicts found" in the commit.

### Task 10: Deploy and verify

**Files:** None modified — operational steps.

Deploy order matters: admin first (new scrape), then incus hosts (collector deletion).

- [ ] **Step 1: Deploy admin**

```bash
just deploy admin
```

- [ ] **Step 2: Verify scrape targets are up**

Wait 60 seconds for the first scrape, then check in Prometheus:

```
up{job="incus"}
```

Expected: three results, all value `1`, with `instance` labels `nas-01`, `condo-01`, `natalya-01`.

If any target shows `0`, check:
- Is the incus daemon running on that host? (`ssh <host> systemctl status incus`)
- Was the client cert trusted? (`ssh <host> incus config trust list`)
- Is port 8443 reachable from admin? (`ssh admin curl -k https://<host>.lan:8443`)

- [ ] **Step 3: Verify recording rules produce values**

Query each recording rule in Prometheus:

```
incus:instance_cpu_usage_ratio
incus:instance_memory_usage_ratio
incus:instance_filesystem_usage_ratio
```

Each should return results. If any is empty, check whether the underlying metric names or labels differ from what the rules expect (cross-reference against Task 1 findings).

- [ ] **Step 4: Verify `IncusWarningsPresent` alert expression**

Query the raw expression:

```
incus_warnings{severity!="low"}
```

If this returns data (possibly all zeros), the alert pipeline is intact. If it returns no data and the native endpoint exposes warnings, check the metric name. If the minimal collector (Task 7) was deployed, verify it's running on the relevant hosts.

- [ ] **Step 5: Deploy incus hosts**

Deploy to all 8 hosts that import `modules/incus`. This removes the textfile collector service/timer:

```bash
just deploy-all
```

(Or deploy individually if `deploy-all` doesn't cover all 8.)

- [ ] **Step 6: Confirm textfile collector is gone**

On one cluster member:

```bash
ssh nas-01 'systemctl status incus-metrics-collector.timer' 2>&1
```

Expected: "Unit incus-metrics-collector.timer could not be found" (or inactive/not-found).

```bash
ssh nas-01 'ls /var/lib/prometheus-node-exporter-text-files/incus.prom' 2>&1
```

Expected: file still exists (stale) but is no longer being updated. It will be cleaned up on next tmpfiles sweep or manually.

- [ ] **Step 7: Commit any follow-up adjustments**

If any recording rules or alerts needed label adjustments during verification, commit those changes:

```bash
git add -u modules/prometheus/
git commit -m "fix(prometheus): adjust incus recording rules for native scrape labels

[describe specific label changes if any]
Part of #291."
```

### Task 11: Close out

- [ ] **Step 1: Close issue #291**

```bash
./scripts/forgejo.sh issue close 291 --comment "Migrated to native Prometheus scrape of incus /1.0/metrics. Textfile collector deleted."
```

- [ ] **Step 2: Push branch**

```bash
git push -u origin proper-incus-metrics
```
