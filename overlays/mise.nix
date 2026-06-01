# mise pinned to 2026.5.18 — nixpkgs-unstable currently at 2026.5.12 (2026-05-20).
{
  config,
  pkgs,
  lib,
  unstablePkgs,
  ...
}: final: prev: {
  mise = prev.mise.overrideAttrs (old: rec {
    version = "2026.5.18";

    src = prev.fetchFromGitHub {
      owner = "jdx";
      repo = "mise";
      tag = "v${version}";
      hash = "sha256-tV+Oc0c7A/ML6MIUvkSivib3EJheu/Xp4xLNWYiM3r0=";
    };

    cargoDeps = prev.rustPlatform.fetchCargoVendor {
      inherit src;
      name = "mise-${version}-vendor";
      hash = "sha256-f3cdfkQ5gguwoENO+1gNRnt7/qOAv+OfAwxEPQvQX+Q=";
    };

    nativeCheckInputs = (old.nativeCheckInputs or []) ++ [prev.git];

    postPatch =
      (old.postPatch or "")
      + ''
        # Some CI/build filesystems reject creating arbitrary non-UTF-8 pathnames
        # with EILSEQ. Upstream's test is only checking that directory scanning
        # skips non-UTF-8 entries after they exist, so skip the test when the
        # fixture cannot be created on the builder filesystem.
        substituteInPlace src/shims.rs \
          --replace-fail 'fs::write(&non_utf8, "").unwrap();' 'if fs::write(&non_utf8, "").is_err() { return; }' \
          --replace-fail 'file::make_executable(&non_utf8).unwrap();' 'if file::make_executable(&non_utf8).is_err() { return; }'
      '';
  });
}
