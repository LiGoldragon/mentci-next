{ pkgs, inputs, system, ... }@args:

# Workspace-level aggregator. Depends on every CANON crate's
# `checks.default` plus two end-to-end test suites:
#
#   - [`integration`](./integration.nix) — single-derivation
#     monolithic shuttle. Fast feedback loop for daemon-graph
#     iteration.
#
#   - [`scenario/chain`](../lib/scenario/chain.nix) — chained
#     derivations, each step its own content-addressed
#     derivation passing `state.redb` forward. Forces the
#     tests to be real: every dependency between steps is
#     visible in the Nix graph; failures localise to the step
#     that broke; intermediate state is reproducible.
#
# `nix flake check` from mentci runs the entire workspace plus
# both end-to-end suites in a single sandboxed parallel pass.

let
  integration   = import ./integration.nix args;
  scenarioChain = import ../lib/scenario/chain.nix args;
in
pkgs.linkFarm "mentci-workspace-checks" [
  { name = "nota-derive";    path = inputs.nota-derive.checks.${system}.default; }
  { name = "nota-codec";     path = inputs.nota-codec.checks.${system}.default; }
  { name = "signal";         path = inputs.signal.checks.${system}.default; }
  { name = "sema";           path = inputs.sema.checks.${system}.default; }
  { name = "criome";         path = inputs.criome.checks.${system}.default; }
  { name = "nexus";          path = inputs.nexus.checks.${system}.default; }
  { name = "nexus-cli";      path = inputs.nexus-cli.checks.${system}.default; }
  { name = "integration";    path = integration; }
  { name = "scenario-chain"; path = scenarioChain; }
]
