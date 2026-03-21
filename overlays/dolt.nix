{
  config,
  pkgs,
  lib,
  unstablePkgs,
  ...
}: final: prev: {
  # Pin dolt to v1.84.0
  dolt = prev.buildGoModule {
    pname = "dolt";
    version = "1.84.0";

    src = prev.fetchFromGitHub {
      owner = "dolthub";
      repo = "dolt";
      tag = "v1.84.0";
      hash = "sha256-EEPNMR71KTpVSy1Heq5jWMIRAfq7ZxOu9FxD+Fk6G7U=";
    };

    modRoot = "./go";
    subPackages = ["cmd/dolt"];
    vendorHash = "sha256-KnifekukBs7pqklR/pxdgCiQAl+uHX2rgHEC2Vy9cCY=";
    proxyVendor = true;
    doCheck = false;

    nativeBuildInputs = [prev.pkg-config];
    buildInputs = [prev.icu];

    env.CGO_ENABLED = "1";

    meta = {
      description = "Relational database with version control and CLI a-la Git";
      mainProgram = "dolt";
      homepage = "https://github.com/dolthub/dolt";
      license = lib.licenses.asl20;
    };
  };
}
