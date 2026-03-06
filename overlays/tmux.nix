# Pin tmux to master to fix copy-mode crash on macOS (Apple Silicon)
# Bug: double-free in grid_clear_lines when entering copy mode after long sessions
# Upstream fix: https://github.com/tmux/tmux/commit/035a2f35d40628dcfe235179220fc0ede848a195
# Issue: https://github.com/tmux/tmux/issues/4777
# TODO: Remove this overlay when tmux 3.7 (or 3.6b) is released and lands in nixpkgs
{
  config,
  pkgs,
  lib,
  unstablePkgs,
}: final: prev: {
  tmux = prev.tmux.overrideAttrs (old: {
    version = "3.6a-unstable-2026-03-06";
    src = prev.fetchFromGitHub {
      owner = "tmux";
      repo = "tmux";
      rev = "d0caf0a322b469a4582294d302b818a8d2590e0f";
      hash = "sha256-420SIds0SXbvxvv2+jMrt0LI0I0DeW63/1nCF/U5wSM=";
    };
  });
}
