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
    version = "2.1.86";

    src = unstablePkgs.fetchzip {
      url = "https://registry.npmjs.org/@anthropic-ai/claude-code/-/claude-code-${finalAttrs.version}.tgz";
      hash = "sha256-Bo2Uj0doMbOK0H8nSzRvwWTcVYsQuP2E9KCauqISzQk=";
    };

    npmDepsHash = "sha256-/DITdMUtHiBQXjerNB8Pom6OaM0LpE6pWbD8njPfVqw=";

    strictDeps = true;

    postPatch = ''
      cp ${./claude-code-package-lock.json} package-lock.json

      substituteInPlace cli.js \
            --replace-fail '#!/bin/sh' '#!/usr/bin/env sh'
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
