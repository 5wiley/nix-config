{
  config,
  pkgs,
  unstablePkgs,
  inputs,
  ...
}: {
  config = {
    nixpkgs.config.permittedInsecurePackages = [
      "python3.12-ecdsa-0.19.1"
      # beets 2.5.1 marked insecure upstream (CVE-2026-42052, XSS).
      # We use a custom fork (overlays/beets.nix → bcotton/beets@aa265b4f) which inherits
      # the base version. This unblocks CI; revisit when upstream bumps beets or our fork
      # is confirmed to address the XSS issue. See #384.
      "python3.13-beets-2.5.1"
    ];

    # let home-manager override files, but back them up first
    home-manager.backupFileExtension = "home-manager-backup";

    environment.systemPackages = with pkgs; [
      inputs.agenix.packages."${pkgs.stdenv.hostPlatform.system}".default
      atuin
      ## unstable
      yt-dlp
      get_iplayer
      monaspace

      diffnav

      ## stable
      #  asciinema
      bat
      bat-extras.batman
      bat-extras.batgrep
      bat-extras.batdiff
      bat-extras.batwatch
      bat-extras.prettybat
      btop
      moor

      # K8s development tools
      ctlptl
      unstablePkgs.tilt
      kind

      coreutils
      coreutils-prefixed
      cue
      curl
      diffr # Modern Unix `diff`
      difftastic # Modern Unix `diff`
      dnsutils
      dua # Modern Unix `du`
      duf # Modern Unix `df`
      dust # Modern Unix `du`
      # direnv # programs.direnv
      #docker
      drill
      dust
      dua
      duf
      entr # Modern Unix `watch`
      eza
      #  ffmpeg
      #  fira-code
      #  fira-mono
      fd
      gh
      go_1_24
      glow
      go-migrate
      gron
      gnused
      gnumake
      #htop # programs.htop
      hub
      #  hugo
      #  ipmitool
      inxi
      jetbrains-mono # font
      just
      jq
      killall
      lazydocker
      lazygit
      lsof
      mage
      mc
      mkdocs
      mosh
      neofetch
      nil # nix lsp
      nmap

      # qmk
      qmk
      ripgrep
      redis
      stern
      #  skopeo
      #  smartmontools
      #  terraform
      tree
      ttyplot
      unzip
      watch
      watchexec
      wget
      wireguard-tools
      viddy
      vim
      vscode
      yq
      zsh
      zsh-syntax-highlighting

      # requires nixpkgs.config.allowUnfree = true;
      vscode-extensions.ms-vscode-remote.remote-ssh

      # lib.optionals boolean stdenv is darwin
      #mas # mac app store cli

      (pkgs.python3.withPackages (python-pkgs: [
        python-pkgs.libtmux
        python-pkgs.requests
        python-pkgs.pytest
        python-pkgs.pyserial
      ]))
    ];
  };
}
