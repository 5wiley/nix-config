{
  lib,
  rustPlatform,
  fetchFromGitHub,
  pkg-config,
  openssl,
}:
rustPlatform.buildRustPackage {
  pname = "weave";
  version = "0.2.5";

  src = fetchFromGitHub {
    owner = "Ataraxy-Labs";
    repo = "weave";
    rev = "v0.2.5";
    hash = "sha256-00e4eaxJ8P0Fb6fL1hV6q1Vw+I4Fj6ZevZ5hmQYKBAA=";
  };

  cargoHash = "sha256-j4OUt5+24eiODZSWwRIWQjzAmzHMJY5269VOpxEs1zg=";

  nativeBuildInputs = [
    pkg-config
  ];

  buildInputs = [
    openssl
  ];

  # Build only the CLI and driver binaries
  cargoBuildFlags = [
    "--bin=weave"
    "--bin=weave-driver"
  ];

  # Tests require git repo context
  doCheck = false;

  meta = with lib; {
    description = "Entity-level semantic merge driver for Git using tree-sitter";
    homepage = "https://github.com/Ataraxy-Labs/weave";
    license = with licenses; [mit asl20];
    mainProgram = "weave";
  };
}
