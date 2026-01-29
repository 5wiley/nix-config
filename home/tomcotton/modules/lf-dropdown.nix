{
  pkgs,
  lib,
  config,
  ...
}: let
  cfg = config.programs.lf-dropdown;
in {
  options.programs.lf-dropdown = {
    enable = lib.mkEnableOption "lf dropdown integration";

    keybind = lib.mkOption {
      type = lib.types.str;
      default = "e";
      description = "Tmux keybinding (after prefix) to toggle lf dropdown (default: 'e' for explorer)";
    };

    width = lib.mkOption {
      type = lib.types.str;
      default = "80%";
      description = "Width of popup window (default: 80%)";
    };

    height = lib.mkOption {
      type = lib.types.str;
      default = "80%";
      description = "Height of popup window (default: 80%)";
    };
  };

  config = lib.mkIf cfg.enable {
    # Create toggle script
    home.file.".local/bin/lf-dropdown-toggle.sh" = {
      executable = true;
      text = ''
        #!/usr/bin/env bash
        # Toggle lf floating window in tmux

        # Store the current pane ID as the origin pane for LF to track
        ORIGIN_PANE_ID=$(tmux display-message -p '#{pane_id}')

        # Open lf in a centered floating popup
        # -E closes popup when lf exits
        # -w and -h set width/height
        # -d sets the starting directory
        tmux popup -E -w ${cfg.width} -h ${cfg.height} \
          -d '#{?pane_path,#{pane_path},#{pane_current_path}}' \
          "LF_ORIGIN_PANE=$ORIGIN_PANE_ID lf"
      '';
    };

    programs.tmux.extraConfig = lib.mkAfter ''
      # LF dropdown toggle: Prefix + ${cfg.keybind} (for explorer)
      bind-key ${cfg.keybind} run-shell ~/.local/bin/lf-dropdown-toggle.sh

      # Use pane_path when creating new panes (fallback to pane_current_path)
      bind v split-window -h -c '#{?pane_path,#{pane_path},#{pane_current_path}}'
      bind s split-window -v -c '#{?pane_path,#{pane_path},#{pane_current_path}}'
    '';
  };
}
