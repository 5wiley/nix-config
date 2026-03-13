# This is imported as module, from the top-level flake
{
  config,
  pkgs,
  unstablePkgs,
  lib,
  inputs,
  hostSpec,
  ...
}: {
  imports = [../toms-darwin/default.nix];

  services.clubcotton.toms-darwin = {
    enable = true;
    useP11KitOverlay = false;
  };

  homebrew = {
    enable = true;
    # updates homebrew packages on activation,
    # can make darwin-rebuild much slower (otherwise i'd forget to do it ever though)
    onActivation.upgrade = true;

    taps = [];
    brews = ["lolcat"];
    casks = [];
    masApps = {};
  };
}
