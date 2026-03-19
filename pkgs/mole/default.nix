{
  lib,
  buildGoModule,
  fetchFromGitHub,
  makeWrapper,
  coreutils,
}: let
  version = "1.30.0";
  src = fetchFromGitHub {
    owner = "tw93";
    repo = "Mole";
    rev = "V${version}";
    hash = "sha256-uo/wPKObL5i6A0i/1hmOjXCzlJkkrFsmZHvLoHmM8Ro=";
  };
in
  buildGoModule {
    pname = "mole";
    inherit version src;

    vendorHash = "sha256-oepnMZcaTB9u3h6S0jcP4W0pqNkDDgETVqDdCL0jarM=";

    subPackages = [
      "cmd/analyze"
      "cmd/status"
    ];

    ldflags = [
      "-s"
      "-w"
    ];

    nativeBuildInputs = [makeWrapper];

    postBuild = ''
      # Rename Go binaries to match what the shell scripts expect
      mv $GOPATH/bin/analyze $GOPATH/bin/analyze-go 2>/dev/null || true
      mv $GOPATH/bin/status $GOPATH/bin/status-go 2>/dev/null || true
    '';

    postInstall = ''
      # Install the shell script infrastructure
      mkdir -p $out/libexec/mole/bin
      mkdir -p $out/libexec/mole/lib

      # Copy shell components
      cp -r $src/lib/* $out/libexec/mole/lib/
      cp $src/bin/*.sh $out/libexec/mole/bin/

      # Move Go binaries into the expected location
      mv $out/bin/analyze-go $out/libexec/mole/bin/analyze-go
      mv $out/bin/status-go $out/libexec/mole/bin/status-go

      # Install the main mole script, patching SCRIPT_DIR
      substitute $src/mole $out/libexec/mole/mole \
        --replace-fail 'SCRIPT_DIR="$(cd "$(dirname "''${BASH_SOURCE[0]}")" && pwd)"' \
                        "SCRIPT_DIR=\"$out/libexec/mole\""
      chmod +x $out/libexec/mole/mole

      # Make all shell scripts executable
      find $out/libexec/mole -name '*.sh' -exec chmod +x {} \;

      # Create bin wrappers
      makeWrapper $out/libexec/mole/mole $out/bin/mole \
        --prefix PATH : ${lib.makeBinPath [coreutils]}
      ln -s mole $out/bin/mo
    '';

    doCheck = false;

    meta = with lib; {
      description = "macOS system maintenance tool for cleaning, optimization, and monitoring";
      homepage = "https://github.com/tw93/Mole";
      license = licenses.mit;
      platforms = platforms.darwin;
      mainProgram = "mole";
    };
  }
