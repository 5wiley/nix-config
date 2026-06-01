# Heavy desktop/media packages — only included on hosts with desktopPackages = true
{
  pkgs,
  inputs,
  ...
}: {
  environment.systemPackages = with pkgs; [
    alsa-utils
    libva-utils
    jellyfin-ffmpeg
    synergy
    qemu
    quickemu
    inputs.ghostty.packages."${pkgs.stdenv.hostPlatform.system}".default
  ];
}
