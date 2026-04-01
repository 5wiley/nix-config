{
  lib,
  python3,
}:
python3.pkgs.buildPythonApplication {
  pname = "pg-scram-hash";
  version = "1.0.0";
  format = "other";

  src = ./.;

  dontBuild = true;

  installPhase = ''
    mkdir -p $out/bin
    cp pg-scram-hash.py $out/bin/pg-scram-hash
    chmod +x $out/bin/pg-scram-hash
  '';

  meta = with lib; {
    description = "Generate PostgreSQL SCRAM-SHA-256 password hashes";
    license = licenses.mit;
    platforms = platforms.all;
  };
}
