{
  config,
  pkgs,
  lib,
  unstablePkgs,
  ...
}: final: prev: {
  # Pin claude-code to a specific version.
  # Update with: ./scripts/upgrade-claude-code.sh
  claude-code = unstablePkgs.buildNpmPackage (finalAttrs: {
    pname = "claude-code";
    version = "2.1.139";

    src = unstablePkgs.fetchzip {
      url = "https://registry.npmjs.org/@anthropic-ai/claude-code/-/claude-code-${finalAttrs.version}.tgz";
      hash = "sha256-iLKbL+QQuhbUs9zoy3oCcqvV2spsk5++LnsPpkbgVK8=";
    };

    npmDepsHash = "sha256-K0s9Hyj2GucChc5lDIr74nr85BL5kFQEw0kaQOoz1i0=";

    strictDeps = true;

    postPatch = ''
      cp ${./claude-code-package-lock.json} package-lock.json
    '';

    dontNpmBuild = true;

    env.AUTHORIZED = "1";

    postInstall = ''
      wrapProgram $out/bin/claude \
        --set DISABLE_AUTOUPDATER 1 \
        --set DISABLE_INSTALLATION_CHECKS 1 \
        --unset DEV \
        --prefix PATH : ${
        lib.makeBinPath (
          [unstablePkgs.procps]
          ++ lib.optionals unstablePkgs.stdenv.hostPlatform.isLinux [
            unstablePkgs.bubblewrap
            unstablePkgs.socat
          ]
        )
      }
    '';

    meta = {
      description = "Agentic coding tool from Anthropic";
      homepage = "https://github.com/anthropics/claude-code";
      license = lib.licenses.unfree;
      mainProgram = "claude";
    };
  });
}
