---
name: restic-verify
description: Periodic verification of restic backups on nas-01. Use when asked to verify backups, validate restic, check backup health, or run the restic health report. Walks through service status, snapshot listing, repository check, cross-repo file comparison, orphan detection, metrics check, and a test restore.
allowed-tools: Bash, Read, Grep, Glob, Write, Edit
argument-hint: optional — "quick" (skip test restore + file diff) or "deep" (adds restic check --read-data)
---

# Restic Backup Verification Skill

End-to-end health check for the restic backup module on **nas-01** (`services.clubcotton.restic`). This skill assumes you are already running on nas-01. Most `restic` and `zfs` commands need root — **do not try to run them yourself**. Instead, present each command block to the user and ask them to paste the output back. Never route sudo commands through `tmux send-keys` as a workaround.

## Repositories

| Name | URL | Env file |
|---|---|---|
| `rsyncnet` | `sftp:de4729@de4729.rsync.net:restic-nas-01` | none |
| `b2` | `b2:nas-01-restic-backup` | `/run/agenix/restic-b2-env` |

Password file for both: `/run/agenix/restic-password`.

**Gotcha — sourcing the B2 env file:** `/run/agenix/restic-b2-env` contains `KEY=value` lines with **no `export`**, so a plain `source` won't propagate the vars to the `restic` subprocess. Always wrap with `set -a`:

```bash
sudo bash -c 'set -a; source /run/agenix/restic-b2-env; set +a; \
  RESTIC_REPOSITORY=b2:nas-01-restic-backup \
  RESTIC_PASSWORD_FILE=/run/agenix/restic-password \
  restic snapshots'
```

## Argument modes

- **(no arg)** — full run, steps 1–7
- **`quick`** — skip steps 4 (file diff) and 6 (test restore)
- **`deep`** — full run + step 8 (`restic check --read-data`, slow and — for b2 — expensive due to egress)

## How to work through the steps

1. Track progress with TaskCreate — one task per step. Mark `in_progress` when you start and `completed` when done.
2. For each step, present the command(s) to the user and ask them to run them and paste the output. Commands without sudo (e.g., `systemctl status`, `journalctl`, `curl http://localhost:9997/metrics`) you may run yourself.
3. Interpret the output against the pass criteria. Report PASS/FAIL as you go — don't batch everything to the end.
4. If anything fails, stop and report it before moving on so the user can decide whether to continue.

## Steps

### Step 1 — Service and timer status

These don't need sudo; run them directly.

```bash
systemctl status restic-backups-rsyncnet.timer restic-backups-b2.timer --no-pager
journalctl -u restic-backups-rsyncnet.service --since "3 days ago" -n 40 --no-pager
journalctl -u restic-backups-b2.service --since "3 days ago" -n 40 --no-pager
```

**Pass criteria:**
- Both timers `active (waiting)` with a reasonable next trigger
- Most recent service run ended with `Deactivated successfully` and `ZFS snapshot cleanup completed`
- No `Failed` states in the last 3 days

### Step 2 — List snapshots in each repo

Ask the user to run these and paste the tails:

```bash
sudo RESTIC_REPOSITORY="sftp:de4729@de4729.rsync.net:restic-nas-01" \
  RESTIC_PASSWORD_FILE=/run/agenix/restic-password \
  restic snapshots | tee /tmp/restic-rsyncnet-snaps.txt

sudo bash -c 'set -a; source /run/agenix/restic-b2-env; set +a; \
  RESTIC_REPOSITORY=b2:nas-01-restic-backup \
  RESTIC_PASSWORD_FILE=/run/agenix/restic-password \
  restic snapshots' | tee /tmp/restic-b2-snaps.txt
```

**Pass criteria:**
- Both repos return ~12 snapshots (retention: 7 daily + 4 weekly + 6 monthly + 1 yearly, deduped by identity)
- Latest snapshot in each is within the last 24h
- Latest snapshot includes all 5 configured paths: `backuppool/local/postgresql`, `mediapool/local/documents`, `mediapool/local/tomcotton/audio-library/SFX_Library/My_Exports`, `mediapool/local/tomcotton/data`, `rpool/local/lib`

You can read `/tmp/restic-{rsyncnet,b2}-snaps.txt` yourself afterward — the output files are world-readable.

### Step 3 — Repository integrity check

Metadata-only check (fast, ~1-2 min each). Ask the user to run:

```bash
sudo RESTIC_REPOSITORY="sftp:de4729@de4729.rsync.net:restic-nas-01" \
  RESTIC_PASSWORD_FILE=/run/agenix/restic-password \
  restic check

sudo bash -c 'set -a; source /run/agenix/restic-b2-env; set +a; \
  RESTIC_REPOSITORY=b2:nas-01-restic-backup \
  RESTIC_PASSWORD_FILE=/run/agenix/restic-password \
  restic check'
```

**Pass criteria:** Both repos print `no errors were found`.

### Step 4 — Cross-repo file list comparison (skip in quick mode)

Verify both backups cover the same file tree. The file lists are large (~90 MB, ~440k lines). Ask the user to run these; the output files are world-readable so you can diff them yourself afterward.

```bash
sudo RESTIC_REPOSITORY="sftp:de4729@de4729.rsync.net:restic-nas-01" \
  RESTIC_PASSWORD_FILE=/run/agenix/restic-password \
  restic ls latest > /tmp/restic-rsyncnet-files.txt

sudo bash -c 'set -a; source /run/agenix/restic-b2-env; set +a; \
  RESTIC_REPOSITORY=b2:nas-01-restic-backup \
  RESTIC_PASSWORD_FILE=/run/agenix/restic-password \
  restic ls latest' > /tmp/restic-b2-files.txt
```

Once both files exist, you can run the normalization and diff yourself (no sudo needed):

```bash
tail -n +2 /tmp/restic-rsyncnet-files.txt | \
  sed 's|^/mnt/\.restic-snapshots/rsyncnet|/mnt/SNAP|' | sort > /tmp/restic-rsyncnet-files-norm.txt
tail -n +2 /tmp/restic-b2-files.txt | \
  sed 's|^/mnt/\.restic-snapshots/b2|/mnt/SNAP|' | sort > /tmp/restic-b2-files-norm.txt
diff /tmp/restic-rsyncnet-files-norm.txt /tmp/restic-b2-files-norm.txt > /tmp/restic-files-diff.txt || true
wc -l /tmp/restic-files-diff.txt

# Categorize differences by top-level path
grep '^<' /tmp/restic-files-diff.txt | sed 's|^< /mnt/SNAP/||' | \
  awk -F/ '{print $1"/"$2"/"$3"/"$4"/"$5}' | sort | uniq -c | sort -rn
grep '^>' /tmp/restic-files-diff.txt | sed 's|^> /mnt/SNAP/||' | \
  awk -F/ '{print $1"/"$2"/"$3"/"$4"/"$5}' | sort | uniq -c | sort -rn
```

**Expected:** Some diff is always present because rsyncnet and b2 snapshots are taken at different times (~1–2h apart). The diffs should only fall into these "volatile state" categories:

- `rpool/local/lib/containers/storage/overlay/*/diff/var/www/wallabag/var/sessions/` — PHP session files
- `rpool/local/lib/loki/{wal,tsdb-cache,tsdb-index,compactor,ruler-wal}` — Loki write-ahead / rotating state
- `rpool/local/lib/mimir/{tsdb,compactor}` — Mimir rotating blocks
- `rpool/local/lib/incus/database/` — Incus raft database snapshots
- `rpool/local/lib/{radarr,lidarr,tempo,jellyfin}/...` — small rotating state/logs

**FAIL** if diffs appear under paths *not* on this list — especially anything under `mediapool/local/documents`, `mediapool/local/tomcotton/*`, or `backuppool/local/postgresql` — which would indicate actually-missing data in one repo.

### Step 5 — ZFS orphaned snapshot detection

`zfs list` does not need root, so you can run it yourself:

```bash
zfs list -t snapshot 2>&1 | grep restic
```

**Pass criteria:** Empty output (or only snapshots from an actively running backup).

**FAIL** if you see snapshots older than ~1 hour with names like `restic-rsyncnet-*` or `restic-b2-*`. These are orphans from an interrupted or misconfigured run. Also flag snapshots on datasets *not* in the current config (e.g., `backuppool/local/nas-01/*` from an old layout) — report and ask the user before any cleanup. Do **not** destroy snapshots yourself.

Current configured datasets (from `hosts/nixos/nas-01/restic.nix`): `rpool/local/lib`, `backuppool/local/postgresql`, `mediapool/local/documents`, `mediapool/local/tomcotton/data`, `mediapool/local/tomcotton/audio-library`.

### Step 6 — Test restore with hash verification (skip in quick mode)

Restore a small, stable file and compare SHA256 against the live copy. A good candidate is `/media/documents/wallabag/data/site-credentials-secret-key.txt` (136 bytes, unchanged since 2025-05-24).

Ask the user to run:

```bash
sudo rm -rf /tmp/restore-test
sudo mkdir -p /tmp/restore-test
sudo RESTIC_REPOSITORY="sftp:de4729@de4729.rsync.net:restic-nas-01" \
  RESTIC_PASSWORD_FILE=/run/agenix/restic-password \
  restic restore latest --target /tmp/restore-test \
  --include "/mnt/.restic-snapshots/rsyncnet/mediapool/local/documents/wallabag/data/site-credentials-secret-key.txt"

sudo sha256sum \
  /tmp/restore-test/mnt/.restic-snapshots/rsyncnet/mediapool/local/documents/wallabag/data/site-credentials-secret-key.txt \
  /media/documents/wallabag/data/site-credentials-secret-key.txt
```

**Pass criteria:** Both SHA256 values are identical.

If the candidate file has changed or been removed, pick another small stable file from `/media/documents/` and apply the same test. Avoid files under `/var/lib/` because they change frequently and because most are not readable without root.

### Step 7 — Prometheus metrics exporter

No sudo needed — run this yourself:

```bash
curl -sS http://localhost:9997/metrics | grep '^restic_'
```

**Pass criteria:**
- HTTP 200 (not 503)
- Both `rsyncnet` and `b2` appear with `restic_backup_success=1`
- `restic_snapshot_count` is ~12 for both
- `restic_latest_snapshot_timestamp` is within the last 24h
- `restic_total_size_bytes` is non-zero for both

**Known historical bugs to watch for** (fixed in a commit touching `clubcotton/services/restic/default.nix`):
1. **PrivateTmp mismatch** — if `/metrics` returns `503 "Metrics not yet available"`, check that the writer service (`restic-metrics.service`) and HTTP service (`restic-metrics-http.service`) share the same metrics file. They should both use `/run/restic-metrics/metrics.prom` via `RuntimeDirectory=restic-metrics`. Older revisions used `/tmp/restic_metrics.prom`, which broke because the HTTP service has `DynamicUser=yes` (implicit `PrivateTmp=yes`) while the writer did not.
2. **B2 env file sourcing** — if `restic_backup_success{repository="b2"}=0` despite backups actually working, the exporter is failing to source the env file. The generated `/nix/store/.../unit-script-restic-metrics-start` must contain `set -a` / `set +a` around `source /run/agenix/restic-b2-env`. Without this, the B2 vars are set in the sourcing shell but not exported to the `restic` subprocess.

### Step 8 (deep mode only) — Full data verification

Only run when invoked with `deep`. This downloads and verifies every pack in the repository. Very slow, and `b2` will incur egress charges (~170 GiB per run) — **explicitly warn the user about the cost** before they run the b2 variant.

Ask the user to run:

```bash
sudo RESTIC_REPOSITORY="sftp:de4729@de4729.rsync.net:restic-nas-01" \
  RESTIC_PASSWORD_FILE=/run/agenix/restic-password \
  restic check --read-data

# b2 — confirm with user before running (egress cost)
sudo bash -c 'set -a; source /run/agenix/restic-b2-env; set +a; \
  RESTIC_REPOSITORY=b2:nas-01-restic-backup \
  RESTIC_PASSWORD_FILE=/run/agenix/restic-password \
  restic check --read-data'
```

**Pass criteria:** `no errors were found` on both.

## Final report

Output a summary table:

| Check | Result |
|---|---|
| Timers active | PASS/FAIL |
| Last backup (rsyncnet) | PASS/FAIL — <date>, <size> |
| Last backup (b2) | PASS/FAIL — <date>, <size> |
| `restic check` (rsyncnet) | PASS/FAIL |
| `restic check` (b2) | PASS/FAIL |
| Cross-repo file diff | PASS/FAIL (volatile diffs only) / SKIPPED |
| Orphaned ZFS snapshots | PASS/FAIL |
| Test restore + hash | PASS/FAIL / SKIPPED |
| Metrics exporter | PASS/FAIL |
| `--read-data` (deep) | PASS/FAIL/SKIPPED |

List any issues found with enough context for the user to act. For orphaned ZFS snapshots, repository errors, or unexpected file-list diffs, do **not** self-remediate — report and wait for user instruction.

## Reference files

- Module: `clubcotton/services/restic/default.nix`
- Host config: `hosts/nixos/nas-01/restic.nix`
- Admin guide: `docs/RESTIC_ADMIN_GUIDE.md`
