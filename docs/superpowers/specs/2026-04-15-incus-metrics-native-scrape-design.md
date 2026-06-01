# Incus metrics: migrate from textfile collector to native Prometheus scrape

**Date:** 2026-04-15
**Issue:** [#291](https://forgejo.bobtail-clownfish.ts.net/bcotton/nix-config/issues/291)
**Status:** Draft

## Context

`modules/incus/monitoring.nix` currently collects incus metrics via a bash script that runs every 15 seconds on every host importing `modules/incus`. The script:

1. Runs `incus query /1.0/metrics`.
2. Strips OpenMetrics-only features (`# EOF`, `_created` lines) the node-exporter textfile collector can't parse.
3. Computes a custom `incus_warnings{severity=...}` gauge by parsing `incus warning list --format csv`.
4. Atomically writes the result to `/var/lib/prometheus-node-exporter-text-files/incus.prom`.
5. Prometheus scrapes node-exporter, which re-exposes the file.

Problems:

- **Fragile.** Any upstream change in incus output or the textfile collector's tolerated subset of OpenMetrics silently produces malformed `.prom` files. Issue #287 recorded 458 parse errors in ~4 hours from an unresolved interaction that self-healed before root cause was found.
- **Wrong shape.** Incus already exposes a native Prometheus endpoint at `https://<host>:8443/1.0/metrics` with TLS client-cert auth. Textfile collectors are meant for metrics that can't be scraped directly (ZFS pool health, tool output), not for shoehorning a real scrape source through a file round-trip.
- **Cluster duplication.** Every cluster member runs its own collector, but `/1.0/metrics` returns cluster-wide data, so metrics get duplicated N× and only differentiated by node-exporter's `instance` label.
- **Hidden custom metric.** `incus_warnings` only exists because the bash script computes it. Migration needs to decide whether to keep it, replace it, or drop it.

## Goals

1. Eliminate the textfile-collector detour for incus metrics.
2. Single authoritative scrape source per incus deployment, not per cluster member.
3. Preserve every metric currently consumed by recording rules and alerts in `modules/prometheus/prometheus.rules.yaml`.
4. Zero alert regressions across the cutover.

## Non-goals

- Restructuring non-incus scrape jobs.
- Changing how recording rules or dashboards consume `incus_*` metrics.
- Adding new incus metrics beyond what the native endpoint provides (and whatever is required to preserve `incus_warnings`).
- Migrating the ZFS or AMD GPU textfile collectors, which remain valid uses of the pattern.

## Topology

- **Cluster:** nix-01, nix-02, nix-03, nas-01 — one incus cluster.
- **Standalone:** condo-01, natalya-01.
- **Testing:** incus-testing, nix-04 — not currently part of the scrape plan; their state is a loose end to resolve during implementation. They still import `modules/incus` and will have the textfile collector deleted along with everyone else.

Hosts currently importing `modules/incus` (all 8 — confirmed by grep): nas-01, nix-01, nix-02, nix-03, nix-04, condo-01, natalya-01, incus-testing. Every one of them gets the collector deletion deployed.

Three scrape targets total in the new world: one cluster member (nas-01), condo-01, natalya-01.

## Design

### Scrape configuration

Add a single `incus` scrape job in `modules/prometheus/default.nix`:

```nix
{
  job_name = "incus";
  scheme = "https";
  metrics_path = "/1.0/metrics";
  scrape_interval = "30s";
  scrape_timeout = "10s";
  tls_config = {
    cert_file = config.age.secrets.prometheus-incus-cert.path;
    key_file = config.age.secrets.prometheus-incus-key.path;
    insecure_skip_verify = true; # incus presents its own self-signed cert
  };
  static_configs = [
    { targets = ["nas-01.lan:8443"]; }
    { targets = ["condo-01.lan:8443"]; }
    { targets = ["natalya-01.lan:8443"]; }
  ];
  relabel_configs = [
    # Replace the default host:port instance label with a bare hostname,
    # so queries and dashboards can match on 'nas-01' not 'nas-01.lan:8443'.
    {
      source_labels = ["__address__"];
      regex = "([^.:]+)(\\..*)?:[0-9]+";
      target_label = "instance";
      replacement = "\${1}";
    }
  ];
}
```

Notes:

- One target per deployment. Native `/1.0/metrics` returns cluster-wide data, so scraping one cluster member is sufficient. If `nas-01` is down, the cluster's metrics go stale for that scrape cycle — acceptable given we already page on `up{job="incus"} == 0`.
- `insecure_skip_verify = true` skips verifying the *server* certificate (incus's self-signed TLS cert). Client authentication still uses the real client cert. If the server cert is ever rotated via a known CA, this can be tightened (see "Out of scope").
- `instance` ends up as `nas-01`, `condo-01`, `natalya-01`. This is a **breaking change** to the label value: the textfile-collector pipeline set `instance` to whichever cluster member's node-exporter happened to produce the metrics, so existing queries that filter on `instance=~"nix-0[1-4]"` will stop matching cluster data. See Risks.

### Secrets

Following the `new-postgres-db` skill pattern:

1. Declare in `secrets/secrets.nix`:

   ```nix
   "prometheus-incus-cert.age".publicKeys = users ++ systems;
   "prometheus-incus-key.age".publicKeys = users ++ systems;
   ```

2. Activate in `secrets/default.nix`, gated on the prometheus host:

   ```nix
   age.secrets.prometheus-incus-cert = lib.mkIf config.services.prometheus.enable {
     file = ./prometheus-incus-cert.age;
     owner = "prometheus";
     group = "prometheus";
   };
   age.secrets.prometheus-incus-key = lib.mkIf config.services.prometheus.enable {
     file = ./prometheus-incus-key.age;
     owner = "prometheus";
     group = "prometheus";
     mode = "0400";
   };
   ```

3. The user generates the keypair and trusts it on each incus deployment out-of-band. See "Secrets workflow" below.

### Deleting the textfile collector

- Delete `modules/incus/monitoring.nix` entirely.
- Remove `./monitoring.nix` from `modules/incus/default.nix`'s `imports`.
- Verify the tmpfiles rule for `/var/lib/prometheus-node-exporter-text-files` is not orphaned. The node-exporter textfile collector module itself may declare it, and other collectors (`modules/zfs/monitoring.nix`, amdgpu) may also declare it. Implementation step: grep for other declarations before removing the rule from the incus module. If incus's copy is the only one on any host (unlikely but possible for condo-01 or natalya-01 which may not run zfs collectors), add a dedicated tmpfiles rule to a module that always runs on those hosts, or simply let the node-exporter service create the dir.

### Alert and rule updates

`modules/prometheus/prometheus.rules.yaml`:

- **Remove** `IncusMetricsStale` (lines 1048–1054). It measured staleness of `node_textfile_mtime_seconds{file="incus.prom"}`, which no longer exists.
- **Add** `IncusScrapeDown`:

  ```yaml
  - alert: IncusScrapeDown
    expr: up{job="incus"} == 0
    for: 5m
    labels:
      severity: warning
    annotations:
      description: 'Incus metrics scrape for {{ $labels.instance }} has been down for 5 minutes'
  ```

- **Remove dead recording rules and alerts** (verified 2026-04-15): the per-instance metrics `incus_cpu_seconds_total`, `incus_memory_Active_bytes`, `incus_memory_MemTotal_bytes`, `incus_filesystem_avail_bytes`, `incus_filesystem_size_bytes` have **never been exposed** by `/1.0/metrics` — not via the native HTTPS endpoint and not via the unix socket that the textfile collector uses. The current `.prom` file on nas-01 confirms zero matches. Consequently:
  - Recording rules `incus:instance_cpu_usage_ratio`, `incus:instance_memory_usage_ratio`, `incus:instance_filesystem_usage_ratio` have always produced empty results. **Delete them.**
  - Alerts `IncusInstanceHighMemory`, `IncusInstanceHighCPU`, `IncusInstanceFilesystemFull` have never fired. **Delete them.**
- **Keep** `IncusDaemonRestarted` (`resets(incus_uptime_seconds[5m]) > 0`) — `incus_uptime_seconds` is present on the native endpoint.
- **Keep** `IncusWarningsPresent` (`incus_warnings{severity!="low"} > 0`) — fed by the minimal warnings collector (see below).

### The `incus_warnings` metric

**Resolved (2026-04-15):** Path 3. Native `/1.0/metrics` only exposes `incus_warnings_total` — a counter with no severity label. The textfile collector's custom `incus_warnings{severity=...}` gauge is the only source for per-severity breakdown.

**Decision:** Keep a minimal textfile collector (`modules/incus/warnings-collector.nix`) that writes *only* `incus_warnings{severity=...}`. Gated on `config.virtualisation.incus.enable`, deployed on all hosts that import `modules/incus` (simpler than trying to pick one per deployment).

## Secrets workflow (user-executed, out-of-band)

When the nix changes are ready, the implementer STOPs and gives the user this script:

```bash
# Generate an ECDSA keypair, self-signed, 10-year validity
openssl req -x509 -newkey ec:<(openssl ecparam -name prime256v1) \
  -nodes -days 3650 -subj '/CN=prometheus' \
  -keyout /tmp/prom-incus.key -out /tmp/prom-incus.crt

# Encrypt into the repo. agenix -e opens $EDITOR on the decrypted file —
# override EDITOR so it just drops the plaintext file in place, then
# agenix re-encrypts it. Do NOT pipe via stdin; agenix -e does not read stdin.
cd secrets
EDITOR="cp /tmp/prom-incus.crt" agenix -e prometheus-incus-cert.age
EDITOR="cp /tmp/prom-incus.key" agenix -e prometheus-incus-key.age
cd ..

# Trust on each incus deployment (run once per deployment).
# Verify the exact 'incus config trust add-certificate' flag set on the
# current incus version before running — newer versions accept --type client
# and a path argument; older versions may differ.
scp /tmp/prom-incus.crt nas-01:/tmp/
ssh nas-01 'incus config trust add-certificate /tmp/prom-incus.crt --name prometheus && rm /tmp/prom-incus.crt'
scp /tmp/prom-incus.crt condo-01:/tmp/
ssh condo-01 'incus config trust add-certificate /tmp/prom-incus.crt --name prometheus && rm /tmp/prom-incus.crt'
scp /tmp/prom-incus.crt natalya-01:/tmp/
ssh natalya-01 'incus config trust add-certificate /tmp/prom-incus.crt --name prometheus && rm /tmp/prom-incus.crt'

shred -u /tmp/prom-incus.key /tmp/prom-incus.crt
```

The implementer waits for the user to confirm completion before resuming the build.

## Implementation plan (high level)

1. **Verify native endpoint contents.** SSH to `nas-01`, run `curl --cert /path --key /path https://localhost:8443/1.0/metrics`. Catalog which metric names *and their label sets* exist. Cross-reference against every metric used in `prometheus.rules.yaml` lines 937–1049, paying particular attention to label names referenced in `sum by (...)` clauses (`name`, `project`, `instance`, `mountpoint`, `fstype`). If any label the recording rules group by is missing, either the rules need updating or that rule is broken under native scrape. Decide the `incus_warnings` path.
2. **Add secret declarations** to `secrets/secrets.nix`.
3. **Add secret activation** to `secrets/default.nix` (gated on `services.prometheus.enable`).
4. **STOP for secrets creation.** User generates keypair, encrypts via agenix, trusts on each deployment.
5. **Add the `incus` scrape job** to `modules/prometheus/default.nix`.
6. **Update alert rules.** Replace `IncusMetricsStale` with `IncusScrapeDown`. Apply any `incus_warnings` path chosen in step 1.
7. **Build and deploy `admin`.** Verify `up{job="incus"} == 1` for all three deployments. Confirm the metric names used by recording rules are present in Prometheus.
8. **Delete the textfile collector.** Remove `modules/incus/monitoring.nix` and the import line. If step 1 required a minimal warnings-only collector, add it at the same time.
9. **Deploy to every host that currently imports `modules/incus`.** Confirm no `incus.prom` file is being written any more, and that node-exporter doesn't complain.
10. **Verify alerts.** Force a scrape failure (stop the scrape target) to exercise `IncusScrapeDown`. Let the rest of the alerts ride on real conditions.
11. **Close issue #291.**

## Risks and mitigations

- **`instance` label semantics change.** Post-migration, `incus_*` metrics carry `instance` values `nas-01`/`condo-01`/`natalya-01`. Previously they carried whichever cluster member's node-exporter had produced the textfile — almost always one of nix-01..nix-04 or nas-01. Any saved Grafana query, dashboard variable, or ad-hoc alert filtering `instance=~"nix-0[1-4]"` on incus metrics will silently stop matching cluster data. Mitigation: grep `clubcotton/`, `modules/grafana/`, and any dashboard JSON in the repo for `instance=.*nix-0` in incus contexts before cutover; audit Grafana dashboards manually during verification (step 7).
- **Cluster target goes down.** Scraping a single cluster member means metrics for the whole cluster disappear if that one host is down. Mitigated by `IncusScrapeDown` firing within 5 minutes. Acceptable because (a) incus cluster outages are already paged elsewhere, (b) we're not making reliability worse than the textfile collector, which would also fail if the incus daemon on a host was down.
- **Metric shape change beyond `instance`.** The native endpoint may produce different label sets than the textfile-scraped version (missing `project`, added labels the collector was stripping, etc.). Mitigated by step 1's catalog of metric names *and label sets*, cross-referenced against the `sum by (...)` clauses in existing recording rules before the collector is deleted.
- **`incus_warnings` path unknown until implementation.** Mitigated by deciding at step 1 with a live check, and by having a fallback (minimal collector) that preserves the alert even in the worst case.
- **Self-signed server cert.** `insecure_skip_verify = true` skips server verification. Prometheus still authenticates with a strong client cert, but a MITM attacker on the internal network could observe scrape requests. Acceptable in this trust domain.
- **Gap window during cutover.** Between deploying the collector deletion and deploying the new scrape job, there is a window with no incus metrics. Mitigation: implementation plan orders deploy-admin-with-scrape *before* deploy-collector-deletion (steps 7 then 8/9), so the scrape is working before the old source is removed.

## Testing

No automated NixOS test. The migration's value comes from real behavior of a live `/1.0/metrics` endpoint, which a test host can't reproduce without running incus with real data. Verification is manual via Prometheus queries after each deploy.

## Out of scope (for explicit noting)

- Migrating ZFS or AMD GPU textfile collectors.
- Reworking the `modules/incus` import list to match the true cluster topology.
- Adding per-member metrics (currently we collapse to one `instance` label per deployment).
- Promoting `insecure_skip_verify = false` by installing the incus server CA on admin.
