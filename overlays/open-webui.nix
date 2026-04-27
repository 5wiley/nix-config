# open-webui 0.9.1 (nixpkgs-unstable rev 01fbdee, 2026-04-25) moved `pgvector`
# out of `dependencies` and into `optional-dependencies.postgres`. The NixOS
# module does not enable any extras, so the venv ships without pgvector and
# the service crashes at import when VECTOR_DB=pgvector is configured.
# See: forgejo issue #327.
{
  config,
  pkgs,
  lib,
  unstablePkgs,
  ...
}: final: prev: {
  open-webui = prev.open-webui.overridePythonAttrs (old: {
    dependencies = old.dependencies ++ prev.open-webui.optional-dependencies.postgres;
  });
}
