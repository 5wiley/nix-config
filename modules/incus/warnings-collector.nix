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
