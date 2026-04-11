# Pin tmux to master to fix copy-mode crash on macOS (Apple Silicon)
# Bug: double-free in grid_clear_lines when entering copy mode after long sessions
# Issue: https://github.com/tmux/tmux/issues/4962 (still open)
# Related (closed): https://github.com/tmux/tmux/issues/4777
#
# Rebuild against current master (31d77e29) to pick up 4b0ff07b
# ("When a cell is cleared after having been moved, we cannot reuse its
# extended data..."), the most plausible unshipped root cause of the
# macOS-only heap corruption.
#
# TODO: Remove this overlay when tmux 3.7 (or 3.6b) is released and lands in nixpkgs
{
  config,
  pkgs,
  lib,
  unstablePkgs,
}: final: prev: {
  tmux = prev.tmux.overrideAttrs (old: {
    version = "3.6a-unstable-2026-04-05";
    src = prev.fetchFromGitHub {
      owner = "tmux";
      repo = "tmux";
      rev = "31d77e29b6c9fbb07d032018da78db3a8a38d979";
      hash = "sha256-7Sc1KAVs0eSkTkbkGf/fN3ploC8ZOc4RgZPF+NoyGnQ=";
    };
  });
}
