{
  config,
  pkgs,
  lib,
  unstablePkgs,
  crushPackage,
  fjPackage,
  gwsPackage,
  localPackages,
  inputs,
  ...
}: {
  imports = [
    inputs.nix-openclaw.homeManagerModules.openclaw
    inputs.nix-index-database.homeModules.default
  ];

  home.stateVersion = "24.05";

  programs.home-manager.enable = true;

  # Ensure systemd user services have coreutils in PATH
  systemd.user.sessionVariables = {
    PATH = "/run/current-system/sw/bin:/bin";
  };

  # Add pnpm local bin to user's shell PATH
  home.sessionPath = [
    "/home/larry/node_modules/.bin"
    "/home/larry/.local/bin"
  ];

  # ─────────────────────────────────────────────────────────────
  # Shell: zsh with starship prompt
  # ─────────────────────────────────────────────────────────────
  programs.zsh = {
    enable = true;
    autosuggestion.enable = true;
    enableCompletion = true;

    shellAliases = {
      # Modern replacements
      ls = "eza --icons";
      ll = "eza -la --icons --git";
      lt = "eza --tree --icons";
      cat = "bat";
      grep = "rg";
      find = "fd";

      # Git shortcuts
      gs = "git status";
      gst = "git status";
      gd = "git diff";
      gdc = "git diff --cached";
      gl = "git log --oneline -20";
      gco = "git checkout";

      # Nix
      nix-options = "xdg-open https://search.nixos.org/options";

      # Navigation
      ".." = "cd ..";
      "..." = "cd ../..";

      # Forgejo - use `tea login default forgejo` to set default, --login is a subcommand flag

      # Safety
      rm = "rm -i";
      mv = "mv -i";
      cp = "cp -i";
    };

    initContent = ''
      # Starship prompt
      eval "$(starship init zsh)"

      # Wire up completions for aliased commands.
      # Use `compdef _func cmd` (not `compdef cmd=other`) — the alias form
      # requires the target's completion to be pre-registered, which doesn't
      # happen for autoloaded completion functions until first use.
      compdef _eza ls ll lt
      compdef _bat cat
      compdef _rg grep
      compdef _fd find

      # Better history
      setopt HIST_IGNORE_DUPS
      setopt HIST_IGNORE_SPACE
      setopt SHARE_HISTORY

      # Ensure systemd user session env vars are set
      export XDG_RUNTIME_DIR="/run/user/$(id -u)"
      export DBUS_SESSION_BUS_ADDRESS="unix:path=$XDG_RUNTIME_DIR/bus"

      # tea completion if available (source the file directly to avoid "Fetching" output)
      [[ -f ~/.config/tea/autocomplete.zsh ]] && PROG=tea _CLI_ZSH_AUTOCOMPLETE_HACK=1 source ~/.config/tea/autocomplete.zsh
      # pnpm
      export PNPM_HOME="/home/larry/.local/share/pnpm"
      case ":$PATH:" in
        *":$PNPM_HOME:"*) ;;
        *) export PATH="$PNPM_HOME:$PATH" ;;
      esac
      # pnpm end

    '';
  };

  programs.starship = {
    enable = true;
    settings = {
      add_newline = true;
      character = {
        success_symbol = "[🎭](bold green)";
        error_symbol = "[🎭](bold red)";
      };
      directory = {
        truncation_length = 3;
        fish_style_pwd_dir_length = 1;
      };
      git_branch = {
        symbol = " ";
      };
      git_status = {
        conflicted = "⚔️ ";
        ahead = "⬆️ ";
        behind = "⬇️ ";
        diverged = "↕️ ";
        modified = "📝";
        staged = "✅";
        untracked = "❓";
      };
      nix_shell = {
        symbol = "❄️ ";
      };
    };
  };

  # ─────────────────────────────────────────────────────────────
  # Git configuration
  # ─────────────────────────────────────────────────────────────
  programs.git = {
    enable = true;
    settings = {
      user = {
        name = "Larry";
        email = "larry@nix-02";
      };
      init.defaultBranch = "main";
      push.autoSetupRemote = true;
      pull.rebase = true;

      alias = {
        br = "branch";
        co = "checkout";
        ci = "commit";
        st = "status";
        lg = "log --color --graph --pretty=format:'%Cred%h%Creset -%C(yellow)%d%Creset %s %Cgreen(%cr)%C(bold blue)<%an>%Creset' --abbrev-commit";
        lga = "log --color --graph --pretty=format:'%Cred%h%Creset -%C(yellow)%d%Creset %s %Cgreen(%cr)%C(bold blue)<%an>%Creset' --abbrev-commit --all";
      };

      core.whitespace = "trailing-space,space-before-tab";
      merge.conflictstyle = "diff3";
      diff.colorMoved = "default";
    };
  };

  # Delta for beautiful diffs
  programs.delta = {
    enable = true;
    enableGitIntegration = true;
    options = {
      navigate = true;
      light = false;
      side-by-side = true;
      line-numbers = true;
    };
  };

  # ─────────────────────────────────────────────────────────────
  # Other useful programs
  # ─────────────────────────────────────────────────────────────
  programs.bat = {
    enable = true;
    config = {
      theme = "TwoDark";
    };
  };

  programs.codex = {
    enable = true;
    package = unstablePkgs.codex;
  };

  programs.fzf = {
    enable = true;
    enableZshIntegration = true;
  };

  # Nix workflow tools from
  # https://iampavel.dev/blog/best-nixos-tools
  # nix-index-database supplies a prebuilt index for nix-locate and comma.
  programs.nix-index-database.comma.enable = true;
  programs.nix-index = {
    enable = true;
    enableZshIntegration = true;
  };

  programs.direnv = {
    enable = true;
    enableZshIntegration = true;
    nix-direnv.enable = true;
  };

  programs.tmux = {
    enable = true;
    terminal = "screen-256color";
    historyLimit = 10000;
    keyMode = "vi";
    prefix = "C-a";

    extraConfig = ''
      # Better splits
      bind | split-window -h -c "#{pane_current_path}"
      bind - split-window -v -c "#{pane_current_path}"

      # Easy reload
      bind r source-file ~/.tmux.conf \; display "Reloaded!"

      # Mouse support
      set -g mouse on

      # Status bar
      set -g status-style 'bg=#1e1e2e fg=#cdd6f4'
      set -g status-left '#[fg=#89b4fa]🎭 #S '
      set -g status-right '#[fg=#a6adc8]%H:%M'
    '';
  };

  # ─────────────────────────────────────────────────────────────
  # Packages
  # ─────────────────────────────────────────────────────────────
  home.packages = with pkgs; [
    # Modern CLI tools
    eza # better ls
    bat # better cat
    ripgrep # better grep
    fd # better find
    jq # JSON processor
    yq # YAML processor
    htop # process viewer
    bottom # fancy htop
    procs # better ps

    # Git tools
    delta # beautiful diffs
    git-absorb # automatic fixup commits
    lazygit # git UI

    # Forgejo/Git workflow
    tea # Gitea/Forgejo CLI
    fjPackage # Forgejo CLI (gh clone)
    gwsPackage # git workspace manager
    bws # Bitwarden Secrets Manager CLI

    # Development
    tldr # simplified man pages
    direnv # per-directory environments
    pnpm
    nodejs_24
    claude-code # Anthropic's Claude Code CLI
    crushPackage # AI coding agent
    uv
    python311

    # Nix tools
    nil # nix LSP
    alejandra # nix formatter
    nh
    nix-init
    nurl
    smfh
    statix

    # Cloud
    google-cloud-sdk

    # Playwright
    localPackages.playwright-cli

    # Fun
    cowsay
    lolcat
  ];
}
