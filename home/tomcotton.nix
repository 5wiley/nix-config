{
  config,
  pkgs,
  lib,
  unstablePkgs,
  ...
}: let
  # See https://haseebmajid.dev/posts/2023-07-10-setting-up-tmux-with-nix-home-manager/
  # tmux-window-name requires Python with libtmux
  tmux-window-name = let
    pythonWithLibtmux = pkgs.python312.withPackages (ps: [ps.libtmux]);
    unwrapped = pkgs.tmuxPlugins.mkTmuxPlugin {
      pluginName = "tmux-window-name";
      version = "head";
      src = pkgs.fetchFromGitHub {
        owner = "ofirgall";
        repo = "tmux-window-name";
        rev = "dc97a79ac35a9db67af558bb66b3a7ad41c924e7";
        sha256 = "sha256-o7ZzlXwzvbrZf/Uv0jHM+FiHjmBO0mI63pjeJwVJEhE=";
      };
    };
    wrapped = pkgs.runCommand "tmux-window-name-wrapped" {} ''
      cp -r ${unwrapped} $out
      chmod -R +w $out

      # Replace Python shebangs with the correct Python path
      for f in $(find $out -name "*.py"); do
        if [[ -f "$f" ]]; then
          sed -i '1s|^#!.*python.*|#!${pythonWithLibtmux}/bin/python|' "$f"
        fi
      done

      # Patch the main tmux script to skip pip check (we know libtmux is available)
      sed -i '/pip_list=/,/exit 0/d' $out/share/tmux-plugins/tmux-window-name/tmux_window_name.tmux
    '';
  in
    wrapped
    // {
      inherit (unwrapped) pname version meta;
      rtp = "${wrapped}/share/tmux-plugins/tmux-window-name/tmux_window_name.tmux";
      passthru = unwrapped.passthru or {};
    };
  tmux-fzf-head =
    pkgs.tmuxPlugins.mkTmuxPlugin
    {
      pluginName = "tmux-fzf";
      version = "head";
      rtpFilePath = "main.tmux";
      src = pkgs.fetchFromGitHub {
        owner = "sainnhe";
        repo = "tmux-fzf";
        rev = "6b31cbe454649736dcd6dc106bb973349560a949";
        sha256 = "sha256-RXoJ5jR3PLiu+iymsAI42PrdvZ8k83lDJGA7MQMpvPY=";
      };
    };
  tmux-nested =
    pkgs.tmuxPlugins.mkTmuxPlugin
    {
      pluginName = "tmux-nested";
      version = "target-style-config";
      src = pkgs.fetchFromGitHub {
        owner = "bcotton";
        repo = "tmux-nested";
        rev = "2878b1d05569a8e41c506e74756ddfac7b0ffebe";
        sha256 = "sha256-w0bKtbxrRZFxs2hekljI27IFzM1pe1HvAg31Z9ccs0U=";
      };
    };
  nixVsCodeServer = fetchTarball {
    url = "https://github.com/msteen/nixos-vscode-server/tarball/master";
    sha256 = "sha256:0xjal4zcbmdjdaspfkjbpx1680q7390wfzmj7iad04kp3pc9syf8";
  };

  rose-pine-hyprcursor = pkgs.fetchFromGitHub {
    owner = "ndom91";
    repo = "rose-pine-hyprcursor";
    rev = "4b02963d0baf0bee18725cf7c5762b3b3c1392f1";
    sha256 = "sha256-ouuA8LVBXzrbYwPW2vNjh7fC9H2UBud/1tUiIM5vPvM="; # Replace with the correct SHA256
  };
in {
  home.stateVersion = "25.05";

  imports = [
    "${nixVsCodeServer}/modules/vscode-server/home.nix"
    ./modules/atuin.nix
    ./tomcotton/modules/tmux-config.nix
    ./tomcotton/modules/lf-dropdown.nix
  ];

  programs.tmux-plugins.enable = true;
  programs.lf-dropdown.enable = true;

  programs.atuin-config = {
    # Create this in agenix
    # nixosKeyPath = "/run/agenix/tomcotton-atuin-key";
    darwinKeyPath = "~/.local/share/atuin/key";
  };

  # list of programs
  # https://mipmip.github.io/home-manager-option-search

  home.file."dotfiles" = {
    enable = true;
    recursive = true;
    source = ./tomcotton/config;
    target = "tmp/..";
  };
  home.file."dummy" = {
    enable = true;
    source = ./tomcotton/config/tmp/dummy;
    target = "tmp/dummy";
  };
  home.activation.installScripts = lib.hm.dag.entryAfter ["writeBoundary"] ''
    $DRY_RUN_CMD mkdir -p $HOME/bin
    $DRY_RUN_CMD cp -f ${./tomcotton/scripts}/* $HOME/bin/
    $DRY_RUN_CMD chmod 554 $HOME/bin/*.sh
  '';

  programs.direnv = {
    enable = true;
    nix-direnv.enable = true;
  };

  programs.fzf = {
    enable = true;
    enableZshIntegration = true;
    tmux.enableShellIntegration = true;
  };

  programs.git = {
    enable = true;
    userEmail = "thomaswileycotton@gmail.com";
    userName = "5wiley";
    extraConfig = {
      alias = {
        # br = "branch";
        # co = "checkout";
        # ci = "commit";
        # d = "diff";
        # dc = "diff --cached";
        # la = "config --get-regexp alias";
        lg = "log --color --graph --pretty=format:'%Cred%h%Creset -%C(yellow)%d%Creset %s %Cgreen(%cr)%C(bold blue)<%an>%Creset' --abbrev-commit";
        lga = "log --color --graph --pretty=format:'%Cred%h%Creset -%C(yellow)%d%Creset %s %Cgreen(%cr)%C(bold blue)<%an>%Creset' --abbrev-commit --all";
      };
      url = {
        "ssh://git@github.com/" = {
          insteadOf = "https://github.com/";
        };
      };
      init.defaultBranch = "main";
      pager.difftool = true;

      core = {
        whitespace = "trailing-space,space-before-tab";
        # pager = "difftastic";
      };
      # interactive.diffFilter = "difft";
      merge.conflictstyle = "diff3";
      diff = {
        # tool = "difftastic";
        colorMoved = "default";
      };
      # difftool."difftastic".cmd = "difft $LOCAL $REMOTE";
    };
    # difftastic = {
    #   enable = false;
    #   background = "dark";
    #   display = "side-by-side";
    # };
    includes = [
      {path = "${pkgs.delta}/share/themes.gitconfig";}
    ];
    # delta = {
    #   enable = true;
    #   options = {
    #     # decorations = {
    #     #   commit-decoration-style = "bold yellow box ul";
    #     #   file-decoration-style = "none";
    #     #   file-style = "bold yellow ul";
    #     # };
    #     # features = "mellow-barbet";
    #     features = "collared-trogon";
    #     # whitespace-error-style = "22 reverse";
    #     navigate = true;
    #     light = false;
    #     side-by-side = true;
    #   };
    # };
  };

  programs.htop = {
    enable = true;
    settings.show_program_path = true;
  };

  services.vscode-server.enable = true;
  services.vscode-server.installPath = "$HOME/.vscode-server";

  programs.vscode = {
    enable = true;
    # mutableExtensionsDir = true;
    # extensions = with pkgs.vscode-extensions; [
    #   asvetliakov.vscode-neovim
    #   # ms-vscode.cpptools
    #   bbenoist.nix
    #   ms-vscode.cpptools-extension-pack
    #   xaver.clang-format
    #   twxs.cmake
    #   ms-vscode.cmake-tools
    #   james-yu.latex-workshop
    #   ms-dotnettools.csharp
    #   ms-dotnettools.csdevkit
    #   saoudrizwan.claude-dev
    #   ms-dotnettools.vscode-dotnet-runtime
    #   mechatroner.rainbow-csv
    #   ms-python.vscode-pylance
    #   ms-python.python
    #   ms-python.debugpy
    #   antyos.openscad
    #   ms-vscode.makefile-tools
    #   valentjn.vscode-ltex
    #   vadimcn.vscode-lldb
    #   justusadam.language-haskell
    #   sainnhe.gruvbox-material
    #   mkhl.direnv
    #   # jdinhlife.gruvbox
    #   ] ++ pkgs.vscode-utils.extensionsFromVscodeMarketplace [
    #   {
    #     name = "chuck";
    #     publisher = "forrcaho";
    #     version = "1.0.1";
    #     sha256 = "sha256-gqcN7eam0YnBNQ2z7tA7Fo7PbXnJV0lX9TqcEbnMDL8=";
    #   }
    #   {
    #     name = "vscode-tidalcycles";
    #     publisher = "tidalcycles";
    #     version = "2.0.2";
    #     sha256 = "sha256-TfRLJZcMpoBJuXitbRmacbglJABZrMGtSNXAbjSfLaQ=";
    #   }
    #   {
    #     name = "cpptools";
    #     publisher = "ms-vscode";
    #     version = "1.27.7";
    #     sha256 = "sha256-/usZ8oaelNF2jdYWSKLEcFVPAxMk8T/7u3xR4t4NCjM=";
    #   }
    #   {
    #     name = "fzf-quick-open";
    #     publisher = "rlivings39";
    #     version = "0.5.1";
    #     sha256 = "sha256-xGcBl3mmyy+Zsn9OncDDbJViMxEgvsRjkzy89NPJpS8=";
    #   }
    # ];
    profiles.default = {
      userSettings = {
        # This property will be used to generate settings.json:
        # https://code.visualstudio.com/docs/getstarted/settings#_settingsjson
        "editor.formatOnSave" = true;
        "editor.fontSize" = 12;
        "editor.insertSpaces" = true;
        "editor.detectIndentation" = true;
        "files.autoSave" = "onFocusChange";
        # "extensions.autoCheckUpdates" = false;
        "extensions.autoUpdate" = false;
        "extensions.experimental.affinity" = {
          "asvetliakov.vscode-neovim" = 1;
        };
        "files.trimFinalNewlines" = true;
        "files.trimTrailingWhitespace" = true;
        # "editor.lineNumbers" = "relative";
        "[latex]" = {
          "editor.wordWrap" = "on";
        };
        "[markdown]" = {
          "editor.quickSuggestions" = {
            "other" = true;
            "comments" = true;
            "strings" = true;
          };
        };
        "files.associations" = {
          "*.tidal" = "haskell";
        };
        "tidalcycles.bootTidalPath" = "/Users/tomcotton/tidal-cycles/BootFiles/BootTidal.hs";
        "workbench.colorTheme" = "Default Dark Modern";
        "makefile.configureOnOpen" = true;

        # Custom Gruvbox Material theme matching Ghostty
        "workbench.colorCustomizations" = {
          "[Default Dark Modern]" = {
            "editor.background" = "#282828";
            "editor.foreground" = "#d4be98";
            "editorCursor.foreground" = "#d4be98";
            "editor.selectionBackground" = "#504945";
            "editor.selectionForeground" = "#d4be98";
            "editor.lineHighlightBackground" = "#32302f";
            "editorLineNumber.foreground" = "#7c6f64";
            "editorLineNumber.activeForeground" = "#d4be98";
            "sideBar.background" = "#282828";
            "sideBar.foreground" = "#d4be98";
            "sideBarSectionHeader.background" = "#32302f";
            "activityBar.background" = "#282828";
            "activityBar.foreground" = "#d4be98";
            "statusBar.background" = "#32302f";
            "statusBar.foreground" = "#d4be98";
            "statusBar.noFolderBackground" = "#32302f";
            "titleBar.activeBackground" = "#282828";
            "titleBar.activeForeground" = "#d4be98";
            "titleBar.inactiveBackground" = "#282828";
            "titleBar.inactiveForeground" = "#7c6f64";
            "terminal.background" = "#282828";
            "terminal.foreground" = "#d4be98";
            "terminal.ansiBlack" = "#282828";
            "terminal.ansiRed" = "#ea6962";
            "terminal.ansiGreen" = "#a9b665";
            "terminal.ansiYellow" = "#d8a657";
            "terminal.ansiBlue" = "#7daea3";
            "terminal.ansiMagenta" = "#d3869b";
            "terminal.ansiCyan" = "#89b482";
            "terminal.ansiWhite" = "#d4be98";
            "terminal.ansiBrightBlack" = "#7c6f64";
            "terminal.ansiBrightRed" = "#ea6962";
            "terminal.ansiBrightGreen" = "#a9b665";
            "terminal.ansiBrightYellow" = "#d8a657";
            "terminal.ansiBrightBlue" = "#7daea3";
            "terminal.ansiBrightMagenta" = "#d3869b";
            "terminal.ansiBrightCyan" = "#89b482";
            "terminal.ansiBrightWhite" = "#ddc7a1";
            "tab.activeBackground" = "#282828";
            "tab.inactiveBackground" = "#32302f";
            "tab.activeForeground" = "#d4be98";
            "tab.inactiveForeground" = "#7c6f64";
            "panel.background" = "#282828";
            "panel.border" = "#504945";
            "input.background" = "#32302f";
            "input.foreground" = "#d4be98";
            "input.border" = "#504945";
            "dropdown.background" = "#32302f";
            "dropdown.foreground" = "#d4be98";
            "list.activeSelectionBackground" = "#504945";
            "list.activeSelectionForeground" = "#d4be98";
            "list.hoverBackground" = "#32302f";
            "list.inactiveSelectionBackground" = "#32302f";
          };
        };
        "editor.tokenColorCustomizations" = {
          "[Default Dark Modern]" = {
            "textMateRules" = [
              {
                "scope" = ["comment" "punctuation.definition.comment"];
                "settings" = {
                  "foreground" = "#7c6f64";
                  "fontStyle" = "italic";
                };
              }
              {
                "scope" = ["string" "constant.other.symbol"];
                "settings" = {"foreground" = "#a9b665";};
              }
              {
                "scope" = ["constant.numeric" "constant.language" "constant.character"];
                "settings" = {"foreground" = "#d3869b";};
              }
              {
                "scope" = ["keyword" "storage.type" "storage.modifier"];
                "settings" = {"foreground" = "#ea6962";};
              }
              {
                "scope" = ["entity.name.function" "support.function"];
                "settings" = {"foreground" = "#a9b665";};
              }
              {
                "scope" = ["entity.name.class" "entity.name.type" "support.class"];
                "settings" = {"foreground" = "#d8a657";};
              }
              {
                "scope" = ["variable" "support.variable"];
                "settings" = {"foreground" = "#7daea3";};
              }
              {
                "scope" = ["entity.name.tag" "markup.heading"];
                "settings" = {"foreground" = "#7daea3";};
              }
              {
                "scope" = ["entity.other.attribute-name"];
                "settings" = {"foreground" = "#d8a657";};
              }
              {
                "scope" = ["support.type.property-name"];
                "settings" = {"foreground" = "#7daea3";};
              }
              {
                "scope" = ["markup.bold"];
                "settings" = {
                  "foreground" = "#ea6962";
                  "fontStyle" = "bold";
                };
              }
              {
                "scope" = ["markup.italic"];
                "settings" = {
                  "foreground" = "#d3869b";
                  "fontStyle" = "italic";
                };
              }
              {
                "scope" = ["markup.inline.raw"];
                "settings" = {"foreground" = "#89b482";};
              }
            ];
          };
        };
        # "gruvboxMaterial.darkPalette" = "original";
        # "gruvboxMaterial.darkWorkbench" = "original";
      };
      keybindings = [
        # See https://code.visualstudio.com/docs/getstarted/keybindings#_advanced-customization
        {
          key = "ctrl+t";
          command = "workbench.action.terminal.focus";
        }
        {
          key = "ctrl+t";
          command = "workbench.action.focusActiveEditorGroup";
          when = "terminalFocus";
        }
        # {
        #   key = "ctrl+alt+shift+cmd+[";
        #   command = "workbench.action.previousEditor";
        # }
        # {
        #   key = "ctrl+alt+shift+cmd+]";
        #   command = "workbench.action.nextEditor";
        # }
      ];
    };
  };

  xdg = {
    enable = true;
    configFile."containers/registries.conf" = {
      source = ./dot.config/containers/registries.conf;
    };
    configFile."atuin/config.toml" = {
      source = ./tomcotton/config/.config/atuin/config.toml;
    };
    configFile."ghostty/config" = {
      source = ./tomcotton/config/.config/ghostty/config;
    };
    configFile."sesh/sesh.toml" = {
      source = ./tomcotton/modules/sesh.toml;
    };
  };

  programs.zsh = {
    enable = true;
    autosuggestion.enable = true;
    enableCompletion = true;
    defaultKeymap = "emacs";
    autocd = true;

    cdpath = [
      "."
      ".."
      "../.."
      "~"
      "~/projects"
    ];

    dirHashes = {
      docs = "$HOME/Documents";
      vdocs = "/Volumes/Files_Tom/Documents";
      dl = "$HOME/Downloads";
    };

    # Environment variables
    envExtra = ''
      export DFT_DISPLAY=side-by-side
      export XDG_CONFIG_HOME="$HOME/.config"
      export LESS="-iMSx4 -FXR"
      export PAGER=less
      export FULLNAME='Thomas Wiley Cotton'
      export EDITOR=nvim
      export EMAIL=thomaswileycotton@gmail.com
      export GOPATH=$HOME/go
      export PATH=$GOPATH/bin:$PATH
      export PATH=$HOME/.local/bin:$PATH

      export EXA_COLORS="da=1;35"
      export BAT_THEME="Visual Studio Dark+"
      export TMPDIR=/tmp/

      export FZF_CTRL_R_OPTS="--reverse"
      export FZF_TMUX_OPTS="-p"

      export ZSH_AUTOSUGGEST_STRATEGY=(history completion)

      [ -e ~/.config/sensitive/.zshenv ] && \. ~/.config/sensitive/.zshenv   # Manual env variables not to be checked in
    '';

    oh-my-zsh = {
      enable = true;
      custom = "$HOME/.oh-my-zsh-custom";

      theme = "headline";
      # theme = "git-taculous";
      # theme = "agnoster-nix";

      extraConfig = ''
        zstyle :omz:plugins:ssh-agent identities id_ed25519
        if [[ `uname` == "Darwin" ]]; then
          zstyle :omz:plugins:ssh-agent ssh-add-args --apple-load-keychain
        fi
        source ${pkgs.zsh-syntax-highlighting}/share/zsh-syntax-highlighting/zsh-syntax-highlighting.zsh

        # Change working dir in shell to last dir in lf on exit (adapted from ranger).
        #
        # You need to either copy the content of this file to your shell rc file
        # (e.g. ~/.bashrc) or source this file directly:
        #
        #     LFCD="/path/to/lfcd.sh"
        #     if [ -f "$LFCD" ]; then
        #         source "$LFCD"
        #     fi
        #
        # You may also like to assign a key (Ctrl-O) to this command:
        #
        #     bind '"\C-o":"lfcd\C-m"'  # bash
        # bindkey -s '^o' 'lfcd\n'  # zsh
        #

        lfcd () {
            # `command` is needed in case `lfcd` is aliased to `lf`
            cd "$(command lf -print-last-dir "$@")"
        }

        if [[ "$CLAUDECODE" != "1" ]]; then
          eval "$(zoxide init zsh)"; alias cd="z"; alias cdi="zi"
        fi

        # Auto-attach to tmux in Ghostty
        if [[ -z "$TMUX" && "$TERM_PROGRAM" == "Ghostty" ]]; then
            tmux attach-session -t default 2>/dev/null || tmux new-session -s default
        fi

        # For some reason this was aliased to vi, seems regresive
        # unalias nvim

        # Set these in your shell (e.g., ~/.bashrc, ~/.zshrc)
        export ANTHROPIC_BASE_URL="https://openrouter.ai/api"
        export ANTHROPIC_AUTH_TOKEN="$OPENROUTER_API_KEY"
        export ANTHROPIC_API_KEY="" # Important: Must be explicitly empty

      '';
      plugins = [
        "brew"
        "bundler"
        "colorize"
        "dotenv"
        "fzf"
        "git"
        "gh"
        "kubectl"
        "kube-ps1"
        "ssh-agent"
        "sesh"
        # "tmux"  # Removed - managed by home-manager programs.tmux instead
      ];
    };

    shellAliases = {
      batj = "bat -l json";
      batly = "bat -l yaml";
      batmd = "bat -l md";
      dir = "exa -l --icons --no-user --group-directories-first  --time-style long-iso --color=always";
      ltr = "ll -snew";
      tree = "exa -Tl --color=always";
      # watch = "watch --color "; # Note the trailing space for alias expansion https://unix.stackexchange.com/questions/25327/watch-command-alias-expansion
      watch = "viddy ";
      # Automatically run `go test` for a package when files change.
      py3 = "python3";
      vi = "nvim";
    };

    initContent = ''
      tmux-window-name() {
        (${builtins.toString tmux-window-name}/share/tmux-plugins/tmux-window-name/scripts/rename_session_windows.py &)
      }
      if [[ $TERM_PROGRAM == "tmux" && `uname` == "Darwin" ]]; then
        add-zsh-hook chpwd tmux-window-name
      fi

      bindkey -e
      bindkey '^[[A' up-history
      bindkey '^[[B' down-history
      #bindkey -m
      bindkey '\M-\b' backward-delete-word
      bindkey -s "^Z" "^[Qls ^D^U^[G"
      bindkey -s "^X^F" "e "

      # Atun stuff
      # eval "$(atuin init zsh)"


      setopt autocd autopushd autoresume cdablevars correct correctall extendedglob globdots histignoredups longlistjobs mailwarning  notify pushdminus pushdsilent pushdtohome rcquotes recexact sunkeyboardhack menucomplete always_to_end hist_allow_clobber no_share_history
      unsetopt bgnice


      export PATH=$PATH:/Library/TeX/texbin

      function reload-hm () {
        echo "🔄 Reloading home-manager environment..."

        # Reload tmux config first (before exec replaces this shell)
        if [[ -n "$TMUX" ]]; then
          local tmux_conf="$HOME/.config/tmux/tmux.conf"
          if [[ -f "$tmux_conf" ]]; then
            tmux source-file "$tmux_conf"
            echo "  ✓ Reloaded tmux.conf"
          fi
        fi

        # Unset the guard so hm-session-vars.sh runs in the new shell
        unset __HM_SESS_VARS_SOURCED

        echo "  ✓ Starting fresh shell..."
        exec zsh
      }

    '';

    #initContent = (builtins.readFile ../mac-dot-zshrc);
  };

  programs.eza.enable = true;
  programs.home-manager.enable = true;
  programs.neovim.enable = true;
  programs.nix-index.enable = true;
  programs.zoxide = {
    enable = true;
    enableZshIntegration = false;
  };

  programs.neovim = {
    # https://nixos.wiki/wiki/Neovim
    plugins = [
      # (pkgs.vimPlugins.nvim-treesitter.withPlugins (p: [
      #   p.c
      #   p.cpp
      #   p.lua
      #   p.nix
      #   p.json
      #   p.python
      #   p.bash
      #   p.markdown
      #   p.markdown-inline
      #   p.latex
      # ]))
      pkgs.vimPlugins.LazyVim
    ];
  };

  programs.ssh = {
    enable = true;
    extraConfig = ''
      Host *
        StrictHostKeyChecking no
        ForwardAgent yes

      Host github.com
        Hostname ssh.github.com
        Port 443
    '';
    matchBlocks = {
    };
  };

  home.packages = with pkgs;
    [
      # unstablePkgs.ghostty
      (pkgs.python311.withPackages (ppkgs: [
        ppkgs.numpy
        ppkgs.libtmux
      ]))
      ffmpeg
      rsync
      rhash
      # restic  # Temporarily disabled - rclone build failing on x86_64-darwin
      lf
      vimv
      subversion
      devenv
      arduino-cli
      sesh
      git-lfs
      # hugo
      # claude-code
      # python3Packages.libtmux
      # kubernetes-helm
      # kubectx
      # kubectl
      #   ## unstable
      #   unstablePkgs.yt-dlp
      #   unstablePkgs.terraform

      #   ## stable
      #   ansible
      #   asciinema
      #   bitwarden-cli
      #   coreutils
      #   # direnv # programs.direnv
      #   #docker
      #   drill
      #   du-dust
      #   dua
      #   duf
      #   esptool
      #   ffmpeg
      #   fd
      #   #fzf # programs.fzf
      #   #git # programs.git
      gh
      #   go
      #   gnused
      #   #htop # programs.htop
      #   hub
      #   hugo
      #   ipmitool
      #   jetbrains-mono # font
      #   just
      #   jq
      #   mas # mac app store cli
      #   mc
      #   mosh
      #   neofetch
      #    nmap
      # (python311.withPackages(ps: with ps; [ libtmux ]))
      #   ripgrep
      #   skopeo
      #   smartmontools
      #   tree
      #   unzip
      #   watch
      #   wget
      #   wireguard-tools
    ]
    ++ lib.optionals stdenv.isDarwin [
      # macOS-only: tmux clipboard integration
      reattach-to-user-namespace
    ];
}
