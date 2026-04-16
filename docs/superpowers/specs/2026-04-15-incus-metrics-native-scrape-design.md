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

- **Cluster:** nix-01, nix-02, nix-03, nas-01 — one incus cluster. The `modules/incus` import list currently shows `nas-01`, `nix-03`, `nix-04`, `incus-testing`, which does not match this topology; discrepancy is flagged for resolution during implementation but does not affect the scrape design.
- **Standalone:** condo-01, natalya-01.

Three scrape targets total: one cluster member, condo-01, natalya-01.

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
    { targets = ["nas-01.lan:8443"]; labels = { deployment = "nix-cluster"; }; }
    { targets = ["condo-01.lan:8443"]; labels = { deployment = "condo-01"; }; }
    { targets = ["natalya-01.lan:8443"]; labels = { deployment = "natalya-01"; }; }
  ];
  metric_relabel_configs = [
    # Normalize the 'instance' label so cluster-wide metrics don't carry
    # whichever member happened to answer the scrape.
    {
      source_labels = ["deployment"];
      target_label = "instance";
    }
  ];
}
```

Notes:

- One target per deployment. Native `/1.0/metrics` returns cluster-wide data, so scraping one cluster member is sufficient. If `nas-01` is down, the cluster's metrics go stale for that scrape cycle — acceptable given we already page on `up{job="incus"} == 0`.
- `insecure_skip_verify = true` skips verifying the *server* certificate (incus's self-signed TLS cert). Client authentication still uses the real client cert. If the server cert is ever rotated via a known CA, this can be tightened.
- Using `metric_relabel_configs` to promote a `deployment` label to `instance` gives stable, predictable instance values that don't depend on which cluster member answered.

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
- The tmpfiles rule for `/var/lib/prometheus-node-exporter-text-files` does not need to be preserved — `modules/zfs/monitoring.nix` already declares it on the hosts that need it, and hosts without the zfs collector don't need the directory.

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
      description: 'Incus metrics scrape for deployment {{ $labels.deployment }} has been down for 5 minutes'
  ```

- **Leave unchanged** (subject to verification during implementation): recording rules `incus:instance_cpu_usage_ratio`, `incus:instance_memory_usage_ratio`, `incus:instance_filesystem_usage_ratio`; alerts `IncusInstanceHighMemory`, `IncusInstanceHighCPU`, `IncusInstanceFilesystemFull`, `IncusDaemonRestarted`, `IncusWarningsPresent`. All match on `incus_*` metric names that should still be present under native scrape. Verification step listed in "Implementation plan" below will confirm each metric still exists before deleting the collector.

### The `incus_warnings` metric

Decided at implementation time after inspecting the live `/1.0/metrics` output on the current incus version:

1. **Native exposes `incus_warnings` with severity label** → drop the bash-computed version, `IncusWarningsPresent` alert unchanged (it already matches by severity label).
2. **Native exposes `incus_warnings_total` with severity label** → add a recording rule `incus_warnings = incus_warnings_total`, keep `IncusWarningsPresent` unchanged.
3. **Native doesn't expose it or lacks severity** → keep a minimal textfile collector (a new 15-line `modules/incus/warnings-collector.nix`) that writes *only* `incus_warnings{severity=...}` and nothing else. This preserves the alert without reintroducing the full bash pipeline. The collector would be gated on `config.virtualisation.incus.enable` like the current one but with a much smaller blast radius.

## Secrets workflow (user-executed, out-of-band)

When the nix changes are ready, the implementer STOPs and gives the user this script:

```bash
# Generate an ECDSA keypair, self-signed, 10-year validity
openssl req -x509 -newkey ec:<(openssl ecparam -name prime256v1) \
  -nodes -days 3650 -subj '/CN=prometheus' \
  -keyout /tmp/prom-incus.key -out /tmp/prom-incus.crt

# Encrypt into the repo
(cd secrets && agenix -e prometheus-incus-cert.age) < /tmp/prom-incus.crt
(cd secrets && agenix -e prometheus-incus-key.age) < /tmp/prom-incus.key

# Trust on each incus deployment (run once per deployment)
cat /tmp/prom-incus.crt | ssh nas-01 'incus config trust add-certificate --name prometheus --type client -'
cat /tmp/prom-incus.crt | ssh condo-01 'incus config trust add-certificate --name prometheus --type client -'
cat /tmp/prom-incus.crt | ssh natalya-01 'incus config trust add-certificate --name prometheus --type client -'

shred -u /tmp/prom-incus.key /tmp/prom-incus.crt
```

The implementer waits for the user to confirm completion before resuming the build.

## Implementation plan (high level)

1. **Verify native endpoint contents.** SSH to `nas-01`, run `curl --cert /path --key /path https://localhost:8443/1.0/metrics`. Catalog which metric names exist. Cross-reference against every metric used in `prometheus.rules.yaml` lines 937–1049. Decide the `incus_warnings` path.
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

- **Cluster target goes down.** Scraping a single cluster member means metrics for the whole cluster disappear if that one host is down. Mitigated by `IncusScrapeDown` firing within 5 minutes. Acceptable because (a) incus cluster outages are already paged elsewhere, (b) we're not making reliability worse than the textfile collector, which would also fail if the incus daemon on a host was down.
- **Metric shape change.** The native endpoint may produce slightly different label sets than what flowed through the textfile collector (e.g., `project` labels that weren't in the scraped version, or missing labels the collector was adding). Mitigated by the verify-before-delete step (step 1 and step 7) — we compare the native output against what recording rules consume before removing the collector.
- **`incus_warnings` path unknown until implementation.** Mitigated by deciding at step 1 with a live check, and by having a fallback (minimal collector) that preserves the alert even in the worst case.
- **Self-signed server cert.** `insecure_skip_verify = true` skips server verification. Prometheus still authenticates with a strong client cert, but a MITM attacker on the internal network could observe scrape requests. Acceptable in this trust domain.

## Testing

No automated NixOS test. The migration's value comes from real behavior of a live `/1.0/metrics` endpoint, which a test host can't reproduce without running incus with real data. Verification is manual via Prometheus queries after each deploy.

## Out of scope (for explicit noting)

- Migrating ZFS or AMD GPU textfile collectors.
- Reworking the `modules/incus` import list to match the true cluster topology.
- Adding per-member metrics (currently we collapse to one `instance` label per deployment).
- Promoting `insecure_skip_verify = false` by installing the incus server CA on admin.
