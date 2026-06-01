{
  lib,
  stdenv,
  makeWrapper,
  python3,
}:
stdenv.mkDerivation {
  pname = "hermes-webhook-tools";
  version = "1.0.0";

  src = ./.;

  nativeBuildInputs = [makeWrapper];

  dontBuild = true;

  installPhase = let
    python = python3.withPackages (ps: [ps.pyyaml]);
  in ''
    runHook preInstall

    mkdir -p $out/bin $out/share/hermes-webhook-tools
    cp configure-hermes-webhook.py $out/share/hermes-webhook-tools/configure-hermes-webhook.py

    makeWrapper ${python}/bin/python3 $out/bin/configure-hermes-webhook \
      --add-flags $out/share/hermes-webhook-tools/configure-hermes-webhook.py

    runHook postInstall
  '';

  meta = {
    description = "Hermes webhook configuration and Forgejo proxy utilities";
    license = lib.licenses.mit;
    platforms = lib.platforms.linux;
    maintainers = [];
  };
}
