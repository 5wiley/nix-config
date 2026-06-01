# Skip flaky psycopg test that fails non-deterministically in CI.
# test_stats_connect checks connection pool counts but is timing-sensitive
# (asserts 3 connections, sometimes sees 5). Upstream already marks some
# tests as "flakey" but missed this one.
{
  config,
  pkgs,
  lib,
  unstablePkgs,
  ...
}: final: prev: {
  pythonPackagesExtensions =
    prev.pythonPackagesExtensions
    ++ [
      (pyFinal: pyPrev: {
        psycopg = pyPrev.psycopg.overridePythonAttrs (old: {
          disabledTests = (old.disabledTests or []) ++ ["test_stats_connect"];
        });
      })
    ];
}
