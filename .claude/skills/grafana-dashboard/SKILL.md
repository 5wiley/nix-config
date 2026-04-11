---
name: grafana-dashboard
description: Create or update Grafana dashboards using gcx. Use when asked to create a dashboard, add panels, update a Grafana dashboard, or visualize metrics.
allowed-tools: Bash(gcx *), Bash(cat *), Bash(sed *), Bash(jq *), Bash(curl *)
argument-hint: describe what to visualize (e.g., 'create a dashboard for node metrics')
---

# Grafana Dashboard Skill

Create and manage Grafana dashboards using the `gcx` CLI tool.

## Grafana Instance

- **URL:** `https://grafana.bobtail-clownfish.ts.net`
- **Auth:** Service account token (configured in `~/.config/gcx/config.yaml`)
- **Limitations:** The service account can **create** and **update** dashboards but **cannot delete** them. Deletions must be done manually in the Grafana UI.

## Available Datasources

| Name | Type | UID | URL |
|------|------|-----|-----|
| Prometheus | prometheus | `a9d7903c-3981-4738-b3e4-484f7d454d2e` | `http://localhost:9001` |
| Mimir | prometheus | `PAE45454D0EDB9216` | `http://nas-01.lan:9009/prometheus` |
| Loki | loki | `loki-datasource` | `http://nas-01.lan:3100` |
| Tempo | tempo | `tempo-datasource` | `http://nas-01.lan:3200` |

**Use Mimir** (`PAE45454D0EDB9216`) for most metrics — it receives data from both Prometheus remote-write and Loki recording rules.

## gcx Commands

```bash
# List dashboards
gcx dashboards list
gcx dashboards list --query "search term"

# Get a dashboard (YAML output)
gcx dashboards get <uid>

# Create a dashboard from YAML file
gcx dashboards create -f dashboard.yaml
gcx dashboards create -f dashboard.yaml --folder-name "Folder Name"

# Update a dashboard
gcx dashboards update <uid> -f dashboard.yaml
gcx dashboards update <uid> -f dashboard.yaml --folder-name "Folder Name"

# Upsert (create or update)
gcx dashboards create -f dashboard.yaml --upsert

# Folders
gcx folders list
gcx folders create --title "My Folder" --uid my-folder
```

## Dashboard YAML Format

```yaml
apiVersion: dashboard.grafana.app/v1beta1
kind: Dashboard
metadata:
  name: my-dashboard-uid    # becomes the dashboard UID
spec:
  title: My Dashboard
  tags:
    - tag1
    - tag2
  schemaVersion: 39
  timezone: browser
  refresh: 1m
  time:
    from: now-24h
    to: now
  panels:
    # panels array (see Panel Types below)
```

## Panel Types

### Time Series

```yaml
- type: timeseries
  title: Panel Title
  datasource: {type: prometheus, uid: PAE45454D0EDB9216}
  gridPos: {h: 8, w: 12, x: 0, y: 0}
  id: 1
  fieldConfig:
    defaults:
      unit: short          # short, bytes, percent, s, MiB, etc.
      color: {mode: palette-classic}
      custom:
        drawStyle: line     # line, bars, points
        lineWidth: 2
        fillOpacity: 15
        spanNulls: true     # connect across gaps (useful for sparse metrics)
        axisBorderShow: false
        axisPlacement: auto
        showPoints: auto
        scaleDistribution: {type: linear}
        stacking: {group: A, mode: none}   # mode: none, normal, percent
        thresholdsStyle: {mode: "off"}     # off, line, dashed, area
      thresholds:
        mode: absolute
        steps:
          - {color: green, value: 0}
          - {color: red, value: 80}
    overrides: []
  options:
    legend:
      calcs: [min, mean, max]   # values shown in legend table
      displayMode: table         # list, table, hidden
      placement: bottom
      showLegend: true
    tooltip: {mode: single, sort: none}   # single, multi
  targets:
    - expr: "metric_name{label=\"value\"}"
      legendFormat: "{{label}}"   # or fixed string
      range: true
      refId: A
```

### Stat Panel

```yaml
- type: stat
  title: Panel Title
  datasource: {type: prometheus, uid: PAE45454D0EDB9216}
  gridPos: {h: 5, w: 4, x: 0, y: 0}
  id: 2
  fieldConfig:
    defaults:
      unit: short
      color: {mode: thresholds}
      thresholds:
        mode: absolute
        steps:
          - {color: green, value: 0}
          - {color: red, value: 1}
    overrides: []
  options:
    reduceOptions: {calcs: [lastNotNull], fields: "", values: false}
    textMode: auto
    colorMode: value       # value, background, none
    graphMode: none         # none, area
  targets:
    - expr: "metric_name or vector(0)"
      legendFormat: ""
      range: false
      instant: true
      refId: A
```

### Gauge Panel

```yaml
- type: gauge
  title: Panel Title
  datasource: {type: prometheus, uid: PAE45454D0EDB9216}
  gridPos: {h: 5, w: 4, x: 0, y: 0}
  id: 3
  fieldConfig:
    defaults:
      unit: percent
      min: 0
      max: 100
      color: {mode: thresholds}
      thresholds:
        mode: absolute
        steps:
          - {color: red, value: 0}
          - {color: orange, value: 50}
          - {color: green, value: 80}
    overrides: []
  options:
    reduceOptions: {calcs: [lastNotNull], fields: "", values: false}
  targets:
    - expr: "metric_a / metric_b * 100"
      instant: true
      refId: A
```

### Row (section separator)

```yaml
- type: row
  title: Section Title
  gridPos: {h: 1, w: 24, x: 0, y: 0}
  id: 100
  collapsed: false
```

## Grid Layout

- Dashboard is **24 columns** wide
- Standard panel: `w: 12, h: 8` (half width)
- Full width: `w: 24, h: 8`
- Stat panel: `w: 4, h: 5` (fits 6 across)
- Row separators: `w: 24, h: 1`
- `x`: column position (0-23)
- `y`: row position (panels below rows use row_y + 1)

## Common Units

| Unit | Description |
|------|-------------|
| `short` | Auto-formatted number |
| `percent` | Percentage (0-100) |
| `bytes` | Bytes (auto-scaled to KiB/MiB/GiB) |
| `decbytes` | Bytes (auto-scaled to KB/MB/GB) |
| `s` | Seconds |
| `ms` | Milliseconds |
| `MiB` | Mebibytes |
| `celsius` | Temperature |
| `tok/s` | Custom (tokens per second) |

## Color Overrides

To set fixed colors per series:

```yaml
overrides:
  - matcher: {id: byName, options: "Series Name"}
    properties:
      - id: color
        value: {fixedColor: green, mode: fixed}
```

## Stacked Bar Charts

For metrics like cache hits vs misses:

```yaml
custom:
  drawStyle: bars
  fillOpacity: 80
  stacking: {group: A, mode: normal}
  showPoints: never
```

## Workflow

1. **Discover metrics:** Query Mimir for available metrics:
   ```bash
   curl -s 'http://nas-01.lan:9009/prometheus/api/v1/label/__name__/values' | jq -r '.data[]' | grep pattern
   ```

2. **Check metric labels:**
   ```bash
   curl -s 'http://nas-01.lan:9009/prometheus/api/v1/query?query=metric_name' | jq '.data.result[0].metric'
   ```

3. **Write dashboard YAML** to `/tmp/<name>-dashboard.yaml`

4. **Create dashboard:**
   ```bash
   gcx dashboards create -f /tmp/<name>-dashboard.yaml --folder-name "Folder Name"
   ```

5. **Update existing dashboard:**
   ```bash
   gcx dashboards get <uid> > /tmp/<uid>.yaml
   # edit the file
   gcx dashboards update <uid> -f /tmp/<uid>.yaml
   ```

## Existing Folders

Check current folders before creating:

```bash
gcx folders list
```

## Tips

- Always assign unique `id` values to each panel
- Use `spanNulls: true` for sparse metrics (like Loki recording rules)
- Use `or vector(0)` for error count stats to show 0 instead of "No data"
- Use `instant: true` and `range: false` for stat/gauge panels
- Use `range: true` for timeseries panels
- Put `$__range` in stat panel expressions to aggregate over the dashboard time range
- The `metadata.name` field becomes the dashboard UID — use lowercase with hyphens
- Use `--folder-name` on create/update to organize dashboards into folders
