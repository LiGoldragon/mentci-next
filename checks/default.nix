{ pkgs, inputs, system, ... }:

# Workspace-level aggregator. Depends on every CANON crate's
# `checks.default`, so a single `nix flake check` from mentci
# builds and tests every crate in a sandboxed parallel pass.
#
# Updating one crate: `nix flake update <crate>` from this dir
# bumps just that input. The aggregator's content-addressed
# hash changes only when one of its dependencies changes.
#
# When a new CANON crate lands, add it as an input in
# `flake.nix` and append it here.
pkgs.linkFarm "mentci-workspace-checks" [
  { name = "nota-derive"; path = inputs.nota-derive.checks.${system}.default; }
  { name = "nota-codec";  path = inputs.nota-codec.checks.${system}.default; }
  { name = "signal";      path = inputs.signal.checks.${system}.default; }
  { name = "sema";        path = inputs.sema.checks.${system}.default; }
  { name = "criome";      path = inputs.criome.checks.${system}.default; }
  { name = "nexus";       path = inputs.nexus.checks.${system}.default; }
  { name = "nexus-cli";   path = inputs.nexus-cli.checks.${system}.default; }
]
