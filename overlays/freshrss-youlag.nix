{
  lib,
  pkgs,
  ...
}: final: prev: {
  freshrss-extensions =
    prev.freshrss-extensions
    // {
      youlag = prev.buildFreshRssExtension rec {
        FreshRssExtUniqueId = "YouLag";
        pname = "youlag";
        version = "unstable-2024-05-22";
        src = prev.fetchFromGitHub {
          owner = "civilblur";
          repo = "youlag";
          rev = "bd66a19abd439b5f0b424e86b267176a6972614a";
          hash = "sha256-AAAAAAAAAAAAAAAAAAAAAAAAAAAAAAAAAAAAAAAAAAA="; # Placeholder, will be replaced
        };
        meta = {
          description = "FreshRSS extension to embed content from sites like YouTube, PeerTube, etc.";
          homepage = "https://github.com/civilblur/youlag";
          license = lib.licenses.agpl3Only;
          maintainers = [lib.maintainers.stunkymonkey];
        };
      };
    };
}
