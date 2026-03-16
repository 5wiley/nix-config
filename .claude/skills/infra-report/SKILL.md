---
name: infra-report
description: Generate an infrastructure health report from Loki logs. Use when asked to check logs and create a report, generate a health report, summarize infrastructure status, or do a log review.
allowed-tools: Bash(curl *), Bash(jq *), Bash(date *), Bash(sleep *), Bash(yq *), Bash(cat *), Bash(./scripts/infra-report), Bash(./scripts/format-infra-report.sh), Bash(./scripts/infra-report.sh), Bash(./scripts/host-lookup.sh), Bash(ssh *)
argument-hint: time window (e.g., 'last 12 hours', 'default 24h', 'last 7 days')
---

# Infrastructure Health Report Skill

Generate a comprehensive infrastructure health report by querying Loki logs across all hosts.

## Overview

This skill runs a structured set of Loki queries to assess fleet health, then produces a formatted report covering auto-upgrades, backups, UPS status, errors, and service health.

## Loki Endpoint Detection

Always detect the working endpoint first:

```bash
LOKI=$(curl -sf --max-time 3 https://loki.bobtail-clownfish.ts.net/ready >/dev/null 2>&1 \
  && echo "https://loki.bobtail-clownfish.ts.net" \
  || echo "http://nas-01.lan:3100")
```

Use `$LOKI` as the base URL. If both fail, tell the user Loki appears down.

## Query Pattern

All queries use:
```bash
curl -sG "$LOKI/loki/api/v1/query_range" \
  --data-urlencode 'query=...' \
  --data-urlencode "start=$(date -d '<time>' +%s)" \
  --data-urlencode "end=$(date +%s)" \
  --data-urlencode 'limit=100' \
  --data-urlencode 'direction=backward' | jq ...
```

For metric (count) queries use `/loki/api/v1/query` with `time=$(date +%s)`.

## Time Window

Parse the user's requested time window. Default to 24 hours. Examples:
- "last 12 hours" -> `date -d '12 hours ago' +%s`
- "last 24 hours" -> `date -d '24 hours ago' +%s`
- "last 7 days" -> `date -d '7 days ago' +%s`

Use the variable `WINDOW` for the LogQL range (e.g., `[24h]`, `[12h]`, `[7d]`).

## Quick Start (Automated)

### Easiest: Formatted Markdown Report

```bash
just infra-report          # Last 24 hours (formatted)
just infra-report 12h      # Last 12 hours
just infra-report 7d       # Last 7 days
```

Or use the convenience wrapper:

```bash
./scripts/infra-report [time-window]  # e.g., ./scripts/infra-report 24h
```

### Get Raw JSON (for programmatic use)

```bash
just infra-report-data          # Last 24 hours (JSON)
just infra-report-data 12h      # Last 12 hours
./scripts/infra-report.sh --since=24h
```

The JSON output contains all query results keyed by section (`hosts_reporting`, `error_counts`, `auto_upgrades`, etc.) plus a `meta` object with `expected_hosts` and `generated_at`.

## Queries to Run

Run these in parallel where possible. Use `$PERIOD` for `--data-urlencode "start=..."` and `$WINDOW` for LogQL range selectors.

### 1. Hosts Actively Reporting (validates fleet coverage)

```logql
count by (hostname) (count_over_time({job="systemd-journal"}[1h]))
```

Format: list of hostnames. Flag any expected host NOT reporting.

Expected hosts (derive dynamically — do not hardcode):
```bash
./scripts/host-lookup.sh --log-hosts
```

### 2. Error Counts by Host

```logql
sum by (hostname) (count_over_time({job="systemd-journal", priority=~"err|crit|alert|emerg"}[$WINDOW]))
```

Format: table of hostname: count. Hosts with 0 errors won't appear.

### 3. Top Error-Producing Units

```logql
topk(15, sum by (hostname, unit) (count_over_time({job="systemd-journal", priority=~"err|crit|alert|emerg"}[$WINDOW])))
```

Format: table of hostname/unit: count.

### 4. Actual Error Log Lines (syslog priority)

```logql
{job="systemd-journal", priority=~"err|crit|alert|emerg"}
```

Format with:
```bash
jq -r '.data.result[] | .stream as $s | .values[] | "\(.[0] | tonumber / 1000000000 | strftime("%Y-%m-%d %H:%M:%S")) [\($s.hostname)] [\($s.unit // $s.syslog_identifier // "?")] \(.[1])"'
```

### 4b. Application-Level Errors (text-based)

Many services log errors in the log text without setting syslog priority metadata.
The `(?i)` flag makes this case-insensitive, catching `ERROR`, `Error`, `error`,
`level=error`, `[Error]`, etc.

```logql
topk(20, sum by (hostname, unit) (count_over_time({job="systemd-journal"} |~ "(?i)\\bERROR\\b" [$WINDOW])))
```

Then sample the top offenders (limit 5 each) to classify as genuine vs noisy:
```logql
{hostname="<host>", unit="<unit>"} |~ "(?i)\\bERROR\\b"
```

**Known noisy/cosmetic text-level errors to note but not flag as action items:**
- `immich-server.service`: "Input file contains unsupported image format" (thumbnailing unsupported formats)
- `garage.service`: "error 404 Not Found, Key not found" (normal S3 cache misses, logged at INFO level)
- `podman-pinchflat.service`: SQL queries containing column name "last_error" (false positive)
- `navidrome.service`: Subsonic API scanner warnings
- `borgmatic.service` / `restic-backups-*.service`: Scrape target timeouts or transient errors (normal when backups are not actively running — these services are periodic, not persistent)
- `prometheus-smartctl-exporter.service`: Transient "open: permission denied" on devices being scanned (timing issue during device enumeration, not a failure)
- `polkit.service`: PolicyKit authorization noise on multiple hosts (cosmetic)
- `grafana.service`: Dashboard query errors (cosmetic)
- `tsnsrv-*.service`: Tailscale proxy connection errors (transient, self-resolving)
- `unifi-poller.service`: 401 Unauthorized from UniFi controller (known issue #105)
- `tailscaled.service`: Connection retry errors (transient)

**Potentially significant text-level errors to flag:**
- `prometheus-smartctl-exporter.service`: SMART command failures (may indicate failing disk)
- `radarr.service` / `sonarr.service`: Import failures (path/permission issues)
- `forgejo-log-scraper.service`: Loki push failures
- `technitium-configure-dhcp.service`: DHCP reservation failures

### 5. Auto-Upgrade Outcomes

```logql
{unit="auto-upgrade.service"} |~ "completed successfully|FATAL|failed|started"
```

For any failures, do a follow-up query to get the full log for that host:
```logql
{hostname="<host>", unit="auto-upgrade.service"}
```

Look for specific failure patterns:
- `FAIL: tcp` / `FAIL: ping` / `FAIL: dns` / `FAIL: service` / `FAIL: extra health check script` - health check failures
- `FATAL: nixos-rebuild test failed` - activation failure
- `FATAL: Build failed` - nix build failure
- `incus: command not found` / `awk: command not found` - missing PATH packages
- `nixos-rebuild-switch-to-configuration.service was already loaded` - stale transient unit
- `waiting for the big garbage collector lock` / `running auto-GC to free` - GC lock contention during switch (disk too full)
- `start operation timed out. Terminating.` - service timeout killed the upgrade process

### 6. Restic Backup Outcomes (nas-01)

```logql
{hostname="nas-01"} |= "restic-backups" |~ "Finished|Failed|Starting"
```

Filter out non-restic noise: `grep -v "alertmanager\|grafana\|tsnsrv\|loki"`

Also check for lock contention:
```logql
{hostname="nas-01"} |= "already locked"
```

### 7. UPS Status

```logql
{unit="upsmon.service"} |~ "unavailable|connect failed|Communications restored"
```

No output = healthy. Any "unavailable" or "connect failed" messages indicate the UPS server is unreachable from that host.

### 8. Service Failures (systemd)

```logql
{job="systemd-journal"} |~ "Failed to start|entered failed state|Main process exited, code=exited, status=1"
```

Filter out noise: `grep -v "alertmanager\|grafana\|tsnsrv\|loki"`

### 9. OOM Kills and ZFS Issues

```logql
{job="systemd-journal"} |~ "Out of memory|oom-kill|Killed process|FAULTED|degraded"
```

Filter out benign DNS degradation from systemd-resolved (these are transient and expected).

### 10. Kernel Errors

```logql
{job="systemd-journal", transport="kernel", priority=~"err|crit|alert|emerg"}
```

### 11. SSH Auth Failures

```logql
{unit="sshd.service"} |~ "Failed|Invalid user"
```

### 12. Syncoid/ZFS Replication Errors

```logql
{job="systemd-journal"} |~ "syncoid" |~ "error|fail|CRITICAL"
```

### 13. Forgejo Actions Log Scraper Errors

```logql
{unit="forgejo-log-scraper.service"} |~ "ERROR"
```

Check for Loki push failures (HTTP 400/500), decompression errors, or other scraper issues.

### 14. Forgejo Actions CI Failures (if logs are available in Loki)

```logql
{job="forgejo-actions"} |~ "FAIL|ERROR|error"
```

Note: These logs are only available if the forgejo-log-scraper is working correctly.

### 15. Prometheus Alerts (firing)

Query the Prometheus alerts API directly:

```bash
curl -sf http://admin:9001/api/v1/alerts | jq -r '.data.alerts[] | "\(.labels.alertname)\t\(.labels.instance // "-")\t\(.labels.severity)\t\(.state)\t\(.activeAt)"'
```

This returns all currently firing alerts. Cross-reference with findings from the Loki queries.

**Known expected alerts:**
- `Watchdog` (severity: none) — always firing; dead man's switch for Alertmanager health. Ignore.

**Alerts that indicate real issues:**
- `HostDown` — a host is unreachable by Prometheus for >15 minutes
- `BlackboxProbeFailed` — an HTTP endpoint probe has been failing for >15 minutes
- `HostSystemdServiceCrashed` — a systemd service is in failed state
- `HostOomKillDetected` — OOM kill occurred
- `HostRaidDiskFailure` — RAID degradation
- `DnsResolutionFailed` — DNS resolution check failed
- `Tempo*` alerts — Tempo-specific issues (ingestion failures, WAL corruption, S3 errors, etc.)

Include firing alerts (excluding Watchdog) in the report under a **Prometheus Alerts** section, before the Errors section. For each alert, show: alert name, instance, severity, and how long it's been firing.

### 16. Disk / Nix Store Usage

Query Prometheus for filesystem usage across all hosts:

```bash
curl -sG http://admin:9001/api/v1/query \
  --data-urlencode 'query=100 - ((node_filesystem_avail_bytes{fstype!~"tmpfs|overlay|nsfs|squashfs"} / node_filesystem_size_bytes{fstype!~"tmpfs|overlay|nsfs|squashfs"}) * 100)' \
  --data-urlencode "time=$(date +%s)" \
  | jq -r '.data.result[] | "\(.metric.instance) \(.metric.mountpoint): \(.value[1] | tonumber | . * 10 | round / 10)% used"'
```

Flag any filesystem above 80% usage. Pay special attention to `/nix/store` and `/` on small-disk hosts (dns-01, admin).

### 17. Auto-Upgrade Duration

Extract start and completion timestamps from auto-upgrade logs to compute duration per host:

```logql
{unit="auto-upgrade.service"} |~ "Auto-upgrade started|completed successfully|FATAL"
```

Parse the timestamps to calculate duration. Flag upgrades taking >30 minutes — they may indicate build issues or slow downloads.

### 18. Loki Error Rate (from Prometheus)

Query the `loki_host_error_lines_1h` metric exposed by the loki-host-monitor textfile collector:

```bash
curl -sG http://admin:9001/api/v1/query \
  --data-urlencode 'query=loki_host_error_lines_1h' \
  --data-urlencode "time=$(date +%s)" \
  | jq -r '.data.result[] | "\(.metric.hostname): \(.value[1]) errors/hr"'
```

This provides a quick snapshot without querying Loki directly. Compare with error counts from query 2 for consistency.

## Report Format

Present findings as a structured report with these sections:

```markdown
## Infrastructure Log Report — Last <N> Hours/Days
**Period**: <start> – <end> <timezone>

### Fleet Status
All N hosts actively reporting: <list>
(or flag missing hosts)

### Auto-Upgrades
| Host | Time | Status | Notes |
|------|------|--------|-------|
Table with all hosts that ran upgrades. Bold **FAILED** for failures.
Include brief failure reason in Notes column.

For failures, add detail paragraphs below the table explaining:
- What check failed
- Root cause if determinable
- Cascade effects on other hosts/services

### Backups
| Backup | Started | Finished | Status |
|--------|---------|----------|--------|

### UPS
Brief status. "Healthy" if no issues, or detail any unavailability windows.

### Prometheus Alerts
| Alert | Instance | Severity | Firing Since | Notes |
|-------|----------|----------|--------------|-------|
Table of currently firing alerts (excluding Watchdog).
If no alerts are firing (besides Watchdog), note "No active alerts."

### Errors
| Host | Count | Details |
|------|-------|---------|
Only hosts with errors. Note if errors are cosmetic/expected.

### Disk Usage
| Host | Mountpoint | Used % | Notes |
|------|------------|--------|-------|
Only filesystems above 70%. Bold **>90%** entries.

### Other Checks
Bullet list of categories checked with "None" or brief findings:
- Prometheus alerts (firing, excluding Watchdog)
- OOM kills
- ZFS/disk issues
- Kernel errors
- SSH auth failures
- Podman container issues
- DNS degradation
- Syncoid replication errors
- Service failures
- Forgejo log scraper errors
- Forgejo CI failures
- Auto-upgrade durations (flag >30 min)
- Loki error rate per host

### Changes Since Last Report
Compare with the previous report (see Report Diffing below):
- **New**: Issues not present in previous report
- **Resolved**: Issues from previous report no longer appearing
- **Recurring**: Same issues persisting across reports

### Action Items
Numbered list of things that need attention, ordered by severity.
Only include genuine issues, not cosmetic/expected errors.
```

## Analysis Guidelines

When analyzing results:

1. **Distinguish expected from unexpected**: Podman cleanup errors during reboot, lxcfs failures during upgrade, and systemd-resolved DNS degradation are expected/cosmetic.

2. **Identify cascade failures**: A single root cause (e.g., dns-01 down) can cause failures across multiple hosts (DNS resolution, ping checks, cache checks). Always trace back to the root cause.

3. **Check for patterns**: If the same error repeats on a schedule, note the pattern. If errors cluster around a specific time, correlate with auto-upgrade or backup windows.

4. **Auto-upgrade health checks working correctly**: A health check that catches a real problem and rolls back is the system working as designed. Note it as "caught by health check" rather than a system failure.

5. **Known cosmetic errors to ignore**:
   - `imac-01`: `Failed to initialize graphics backend for OpenGL` (headless display)
   - Podman aardvark-dns cleanup errors during reboot
   - lxcfs.service failures during auto-upgrade reboots
   - systemd-resolved "Using degraded feature set" (transient DNS negotiation)

## Filing Action Items as Forgejo Issues

After presenting the report, create Forgejo issues for each genuine action item.

### Check for Duplicate Issues

Before creating, list existing open bug issues to avoid duplicates:

```bash
./scripts/forgejo.sh issue list --label=bug
```

### Create Issues

For each action item, create an issue with the `bug` label:

```bash
./scripts/forgejo.sh issue create \
  --title "<host>: <short description>" \
  --body "## Problem

<description of the error>

## Evidence

\`\`\`
<relevant log lines>
\`\`\`

## Action Required

<numbered steps>

## Source

Discovered via infra-report skill.

🤖 Generated with [Claude Code](https://claude.com/claude-code)" \
  --label bug
```

### Host Lookup

To resolve an IP address to a hostname:
```bash
./scripts/host-lookup.sh 192.168.5.49    # → octoprint (OctoPrint) - 192.168.5.49
./scripts/host-lookup.sh --list           # → all hosts with IPs
```

### Issue Guidelines

- **Title format**: `<hostname>: <short description>` (e.g., `nas-01: Radarr import failure`)
- **Label**: Use `bug` (ID 1) for issues found in logs
- **Do NOT create issues for**:
  - Cosmetic/expected errors (OpenGL, aardvark-dns, lxcfs, DNS degradation)
  - Issues already fixed in the same session (note "fix deployed" in the report instead)
  - Transient errors that occurred only during upgrade/reboot windows
- **DO create issues for**:
  - Hardware problems (SMART failures, disk errors)
  - Persistent service failures (stuck imports, repeated crashes)
  - Configuration bugs (missing PATH packages, wrong permissions)
  - Anything that generates >100 errors/day and isn't cosmetic

## Publishing the Report as a Forgejo Issue

After presenting the report to the user and filing any action item bugs, publish the full report as a Forgejo issue for the daily log archive.

### Steps

1. **Check for duplicate report** — avoid filing twice for the same day:
   ```bash
   ./scripts/forgejo.sh issue list --label=report --limit=5
   ```
   If a report for today's date already exists, skip creating a new one (or add a comment to the existing one with updated findings).

2. **Create the report issue**:
   ```bash
   ./scripts/forgejo.sh issue create \
     --title "Infra Report — YYYY-MM-DD" \
     --body "<full markdown report>" \
     --label report
   ```

   - **Title format**: `Infra Report — YYYY-MM-DD` (use today's date)
   - **Label**: `report`
   - **Body**: The complete markdown report (same content shown to the user), with these additions:
     - In the Action Items section, reference any bug issues filed with their `#NNN` numbers
     - Append a footer: `🤖 Generated with [Claude Code](https://claude.com/claude-code)`

3. **Report the issue URL** to the user so they can find it.

### Notes

- Reports are kept open by default as a browsable daily log
- Old reports can be bulk-closed periodically: `./scripts/forgejo.sh issue list --label=report` then close as needed
- The `report` label (blue, #0075ca) distinguishes these from bug issues in the issue tracker

## Report Diffing (Comparison with Previous Report)

After generating the current report, fetch the most recent previous report to identify trends.

### Fetch Previous Report

```bash
# Get the most recent report issues
./scripts/forgejo.sh issue list --label=report --limit=3
```

Pick the most recent report that is NOT today's date. Fetch its body via the Forgejo API:

```bash
# Resolve Forgejo config for API access
source ./scripts/lib/common.sh
resolve_forgejo_config

# Fetch the previous report body (replace NNN with issue number)
curl -sf -H "Authorization: token $TOKEN" \
  "${BASE_URL}/api/v1/repos/${REPO}/issues/NNN" | jq -r '.body'
```

### Comparison Points

When comparing with the previous report:
1. **New issues**: Errors/failures not present in previous report
2. **Resolved issues**: Problems from previous report no longer appearing
3. **Recurring issues**: Same errors persisting across reports (flag for investigation)
4. **Trend changes**: Error counts going up or down significantly

Include findings in the **Changes Since Last Report** section of the report output.

## SSH Access for Live Investigation

For deeper investigation of flagged issues, SSH into hosts:

```bash
ssh -o IdentitiesOnly=yes -i ~/.ssh/id_ed25519 bcotton@<hostname>.lan "<command>"
```

Useful for checking:
- `systemctl status <service>` — current service state
- `journalctl -u <service> --since '1 hour ago'` — recent logs not yet in Loki
- `df -h /nix/store` — current disk usage
- `nixos-rebuild list-generations | tail -5` — recent generations
