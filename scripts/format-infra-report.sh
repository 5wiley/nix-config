#!/usr/bin/env bash
# Generate formatted infrastructure report from raw JSON

set -euo pipefail

INPUT="${1:-/dev/stdin}"
REPORT_FILE="/home/bcotton/nix-config/default/.local/share/opencode/tool-output/infra-report-$(date +%Y-%m-%d-%H-%M-%S).md"

# Parse and format the report
jq -r '
.meta as $meta |
def format_time: .[0] | tonumber / 1000000000 | strftime("%Y-%m-%d %H:%M %Z");

# Fleet Status
"## Infrastructure Log Report — Last 24 Hours\n**Generated**: \($meta.generated_at | split("T") | .[0])\n\n### Fleet Status\n" +
(if $meta.expected_hosts - ([.hosts_reporting.data.result[].metric.hostname]) | length) == 0 
  then "✅ All \($meta.expected_hosts | length) hosts actively reporting\n\n" + (.hosts_reporting.data.result | sort_by(.metric.hostname) | map("  - **\(.metric.hostname)**: \(.value[1]) log entries") | join("\n"))
  else "⚠️ Missing hosts: " + ([$meta.expected_hosts - [.hosts_reporting.data.result[].metric.hostname]] | join(", ")) + "\n\n"
end) +

# Auto-Upgrades
"### Auto-Upgrades\n" +
(if .auto_upgrades.data.result | length == 0 then "No auto-upgrades in last 24h\n\n"
else
  [.auto_upgrades.data.result | sort_by(.values[0][0])] | 
  map("\(.stream.hostname): Started \(.values[0][0] | format_time) → Completed \(.values[1][0] | format_time)") |
  join("\n") + "\n"
end) +

# Error Summary
"### Error Summary\n" +
"Hosts with syslog-priority errors (err/crit/alert/emerg):\n" +
(if .error_counts.data.result | length == 0 then "  None\n\n"
else
  [.error_counts.data.result | sort_by(.metric.hostname)] |
  map("  - **\(.metric.hostname)**: \(.value[1]) errors") |
  join("\n") + "\n"
end) +

# Top Error Units
"Top error-producing units:\n" +
(if .top_error_units.data.result | length == 0 then "  None\n\n"
else
  [.top_error_units.data.result | sort_by(-.value[1])] |
  map("  - **\(.metric.hostname)** (\(.metric.unit // "unknown")): \(.value[1])") |
  join("\n") + "\n"
end) +

# Error Lines
"### Recent Error Logs\n" +
(if .error_lines.data.result | length == 0 then "No critical errors found\n\n"
else
  [.error_lines.data.result | sort_by(.values[0][0])] |
  map("\n#### \(.stream.hostname) - \(.stream.unit // .stream.syslog_identifier // "unknown")\n" +
    (.values | map("  - \(.[0] | format_time): \(.[1])") | join("\n"))) |
  join("\n") + "\n"
end) +

# Service Failures
"### Service Failures\n" +
(if .service_failures.data.result | length == 0 then "No service failures\n\n"
else
  [.service_failures.data.result | sort_by(.stream.hostname)] |
  map("\n**\(.stream.hostname)** - \(.stream.unit):\n  " + (.values | map("  - \(.[0] | format_time)") | join("\n  "))) |
  join("\n") + "\n"
end) +

# UPS Status
"### UPS Status\n" +
(if .ups_status.data.result | length == 0 then "No UPS issues detected\n"
else
  "UPS issues detected:\n" + (.ups_status.data.result | map("  - \(.stream.hostname): \(.values[0][1])") | join("\n"))
end) +

# Restic Backups
"### Restic Backups (nas-01)\n" +
(if .restic_backups.data.result | length == 0 then "No backup logs found\n"
else
  [.restic_backups.data.result[] | select(.stream.hostname == "nas-01" and .stream.unit | startswith("restic-backups"))] |
  if length == 0 then "No backup activity\n"
  else
    "Recent backup activity:\n" + 
    (. | map("  - \(.values[0][0] | format_time): \(.values[0][1])") | join("\n"))
  end
end)

' "$INPUT" > "$REPORT_FILE"

echo "Report saved to: $REPORT_FILE"
cat "$REPORT_FILE"