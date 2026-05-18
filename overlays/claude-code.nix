{
  config,
  pkgs,
  lib,
  unstablePkgs,
  ...
}: final: prev: let
  stdenv = unstablePkgs.stdenvNoCC;
  baseUrl = "https://storage.googleapis.com/claude-code-dist-86c565f3-f756-42ad-8dfa-d59b1c096819/claude-code-releases";
  manifest = lib.importJSON ./claude-code-manifest.json;
  platformKey = "${stdenv.hostPlatform.node.platform}-${stdenv.hostPlatform.node.arch}";
  platformManifestEntry = manifest.platforms.${platformKey};
in {
  # Pin claude-code to a specific version.
  # To update: fetch new manifest.json from
  #   https://storage.googleapis.com/claude-code-dist-86c565f3-f756-42ad-8dfa-d59b1c096819/claude-code-releases/<version>/manifest.json
  # and save as overlays/claude-code-manifest.json
  claude-code = stdenv.mkDerivation (finalAttrs: {
    pname = "claude-code";
    inherit (manifest) version;

    src = unstablePkgs.fetchurl {
      url = "${baseUrl}/${finalAttrs.version}/${platformKey}/claude";
      sha256 = platformManifestEntry.checksum;
    };

    dontUnpack = true;
    dontBuild = true;
    __noChroot = stdenv.hostPlatform.isDarwin;
    dontStrip = true;

    nativeBuildInputs =
      [
        unstablePkgs.installShellFiles
        unstablePkgs.makeBinaryWrapper
      ]
      ++ lib.optionals stdenv.hostPlatform.isElf [unstablePkgs.autoPatchelfHook];

    strictDeps = true;

    installPhase = ''
      runHook preInstall

      install -Dm755 $src $out/bin/claude

      wrapProgram $out/bin/claude \
        --set DISABLE_AUTOUPDATER 1 \
        --set-default FORCE_AUTOUPDATE_PLUGINS 1 \
        --set DISABLE_INSTALLATION_CHECKS 1 \
        --set USE_BUILTIN_RIPGREP 0 \
        --prefix PATH : ${
        lib.makeBinPath (
          [
            unstablePkgs.procps
            unstablePkgs.ripgrep
          ]
          ++ lib.optionals stdenv.hostPlatform.isLinux [
            unstablePkgs.bubblewrap
            unstablePkgs.socat
          ]
        )
      }

      runHook postInstall
    '';

    meta = {
      description = "Agentic coding tool from Anthropic";
      homepage = "https://github.com/anthropics/claude-code";
      license = lib.licenses.unfree;
      mainProgram = "claude";
    };
  });
}
