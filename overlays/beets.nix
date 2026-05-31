{
  config,
  pkgs,
  lib,
  unstablePkgs,
  ...
}: self: super: let
  # Create a custom beets with all plugins via python3.pkgs.beets
  customPythonBeets =
    (super.python3.pkgs.beets.override {
      extraPatches = [
        # Bash completion fix for Nix
        # ./patches/bash-completion-always-print.patch
      ];
      pluginOverrides = {
        beets_id3extract = {
          enable = true;
          propagatedBuildInputs = [(pkgs.python3.pkgs.callPackage ../pkgs/beets_id3extract {})];
        };
        _typing = {
          enable = true;
          builtin = true;
          testPaths = [];
        };
      };
      extraNativeBuildInputs = with pkgs.python3Packages; [
        requests-mock
      ];
    })
    .overridePythonAttrs {
      src = pkgs.fetchFromGitHub {
        owner = "bcotton";
        repo = "beets";
        rev = "764539b3b6c550d15bd59f4a897fbb9706442e53";
        hash = "sha256-CIlhDLfldK+D8PLFPCwZj0s8ZjID5yAfGtlyBr3Iyv4=";
      };
      # Custom fork may not produce the _sphinx_design_static dir
      preInstallSphinx = ''
        rm -rf .sphinx/man/man/_sphinx_design_static
      '';
      # Custom fork has different plugin list than upstream; skip plugin list check
      doCheck = false;
    };
in {
  # Override beets at the top level to use the custom version
  beets = super.python3.pkgs.toPythonApplication customPythonBeets;
}
