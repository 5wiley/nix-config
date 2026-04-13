{
  lib,
  stdenv,
  fetchFromGitHub,
  makeWrapper,
  python311,
  uv,
  bash,
  zlib,
  zstd,
  postgresql,
}: let
  # Libraries required at runtime by Python wheels (numpy, etc.) that expect
  # system-provided libs.
  runtimeLibs = lib.makeLibraryPath [
    stdenv.cc.cc.lib
    zlib
    zstd
  ];
in
  stdenv.mkDerivation rec {
    pname = "honcho";
    version = "3.0.5";

    src = fetchFromGitHub {
      owner = "bcotton";
      repo = "honcho";
      rev = "67f6000d6e0f9c0f888a9ae9f530a9e2033887d3";
      hash = "sha256-1YNB90MxjfYmAVN//tRu5qHFGqQxbRqsrFP8yjQpHP8=";
    };

    nativeBuildInputs = [makeWrapper];

    # Don't try to build — we use uv at runtime to create the venv
    dontBuild = true;
    dontFixup = true;

    installPhase = ''
      runHook preInstall

      # Install source
      mkdir -p $out/share/honcho
      cp -r . $out/share/honcho/

      # Create wrapper scripts that use uv for venv management
      mkdir -p $out/bin

      # API server
      cat > $out/bin/honcho-api <<'WRAPPER'
      #!@bash@/bin/bash
      set -euo pipefail
      HONCHO_HOME="''${HONCHO_STATE_DIR:-/var/lib/honcho}"
      SOURCE_DIR="@out@/share/honcho"
      export UV_PYTHON="@python@/bin/python3.11"
      export UV_PYTHON_DOWNLOADS=never
      export UV_PYTHON_PREFERENCE=only-system
      export LD_LIBRARY_PATH="@runtimeLibs@''${LD_LIBRARY_PATH:+:$LD_LIBRARY_PATH}"

      # Wipe broken venv (e.g. left over from a previous uv-downloaded python)
      if [ -f "$HONCHO_HOME/.venv/bin/python" ] && ! "$HONCHO_HOME/.venv/bin/python" --version >/dev/null 2>&1; then
        rm -rf "$HONCHO_HOME/.venv"
      fi

      # Create venv on first run (or if source changed)
      if [ ! -f "$HONCHO_HOME/.venv/pyvenv.cfg" ] || \
         [ "$SOURCE_DIR/uv.lock" -nt "$HONCHO_HOME/.venv/pyvenv.cfg" ]; then
        echo "Syncing Honcho Python environment..."
        cd "$SOURCE_DIR"
        UV_PROJECT_ENVIRONMENT="$HONCHO_HOME/.venv" @uv@ sync --frozen --no-group dev 2>&1
      fi

      export PYTHONPATH="$SOURCE_DIR''${PYTHONPATH:+:$PYTHONPATH}"
      cd "$HONCHO_HOME"
      exec "$HONCHO_HOME/.venv/bin/python" -m uvicorn src.main:app \
        --host "''${HONCHO_HOST:-0.0.0.0}" \
        --port "''${HONCHO_PORT:-8000}" \
        "$@"
      WRAPPER
      chmod +x $out/bin/honcho-api
      substituteInPlace $out/bin/honcho-api \
        --replace-quiet "@out@" "$out" \
        --replace-quiet "@uv@" "${uv}/bin/uv" \
        --replace-quiet "@bash@" "${bash}" \
        --replace-quiet "@python@" "${python311}" \
        --replace-quiet "@runtimeLibs@" "${runtimeLibs}"

      # Deriver worker
      cat > $out/bin/honcho-deriver <<'WRAPPER'
      #!@bash@/bin/bash
      set -euo pipefail
      HONCHO_HOME="''${HONCHO_STATE_DIR:-/var/lib/honcho}"
      SOURCE_DIR="@out@/share/honcho"
      export UV_PYTHON="@python@/bin/python3.11"
      export UV_PYTHON_DOWNLOADS=never
      export UV_PYTHON_PREFERENCE=only-system
      export LD_LIBRARY_PATH="@runtimeLibs@''${LD_LIBRARY_PATH:+:$LD_LIBRARY_PATH}"

      if [ -f "$HONCHO_HOME/.venv/bin/python" ] && ! "$HONCHO_HOME/.venv/bin/python" --version >/dev/null 2>&1; then
        rm -rf "$HONCHO_HOME/.venv"
      fi

      # Ensure venv exists
      if [ ! -f "$HONCHO_HOME/.venv/pyvenv.cfg" ]; then
        echo "Syncing Honcho Python environment..."
        cd "$SOURCE_DIR"
        UV_PROJECT_ENVIRONMENT="$HONCHO_HOME/.venv" @uv@ sync --frozen --no-group dev 2>&1
      fi

      export PYTHONPATH="$SOURCE_DIR''${PYTHONPATH:+:$PYTHONPATH}"
      cd "$HONCHO_HOME"
      exec "$HONCHO_HOME/.venv/bin/python" -m src.deriver "$@"
      WRAPPER
      chmod +x $out/bin/honcho-deriver
      substituteInPlace $out/bin/honcho-deriver \
        --replace-quiet "@out@" "$out" \
        --replace-quiet "@uv@" "${uv}/bin/uv" \
        --replace-quiet "@bash@" "${bash}" \
        --replace-quiet "@python@" "${python311}" \
        --replace-quiet "@runtimeLibs@" "${runtimeLibs}"

      # Database migrations
      cat > $out/bin/honcho-migrate <<'WRAPPER'
      #!@bash@/bin/bash
      set -euo pipefail
      HONCHO_HOME="''${HONCHO_STATE_DIR:-/var/lib/honcho}"
      SOURCE_DIR="@out@/share/honcho"
      export UV_PYTHON="@python@/bin/python3.11"
      export UV_PYTHON_DOWNLOADS=never
      export UV_PYTHON_PREFERENCE=only-system
      export LD_LIBRARY_PATH="@runtimeLibs@''${LD_LIBRARY_PATH:+:$LD_LIBRARY_PATH}"

      if [ -f "$HONCHO_HOME/.venv/bin/python" ] && ! "$HONCHO_HOME/.venv/bin/python" --version >/dev/null 2>&1; then
        rm -rf "$HONCHO_HOME/.venv"
      fi

      # Ensure venv exists
      if [ ! -f "$HONCHO_HOME/.venv/pyvenv.cfg" ]; then
        echo "Syncing Honcho Python environment..."
        cd "$SOURCE_DIR"
        UV_PROJECT_ENVIRONMENT="$HONCHO_HOME/.venv" @uv@ sync --frozen --no-group dev 2>&1
      fi

      cd "$SOURCE_DIR"
      exec "$HONCHO_HOME/.venv/bin/python" -m alembic upgrade head "$@"
      WRAPPER
      chmod +x $out/bin/honcho-migrate
      substituteInPlace $out/bin/honcho-migrate \
        --replace-quiet "@out@" "$out" \
        --replace-quiet "@uv@" "${uv}/bin/uv" \
        --replace-quiet "@bash@" "${bash}" \
        --replace-quiet "@python@" "${python311}" \
        --replace-quiet "@runtimeLibs@" "${runtimeLibs}"

      runHook postInstall
    '';

    meta = with lib; {
      description = "Infrastructure layer for AI agents with memory and social cognition";
      homepage = "https://github.com/plastic-labs/honcho";
      license = licenses.agpl3Plus;
      platforms = platforms.linux;
      mainProgram = "honcho-api";
    };
  }
