{ pkgs, inputs, system, ... }@args:

# Step B — query (| Node @name |) against the sema state
# produced by step A. Captures the [(Node "User")] reply text;
# the state output is left in $out/state.redb in case future
# steps want to chain off this point too.

let
  step = import ./lib.nix {
    inherit pkgs;
    criome    = inputs.criome.packages.${system}.default;
    nexus     = inputs.nexus.packages.${system}.default;
    nexus-cli = inputs.nexus-cli.packages.${system}.default;
  };
  assertNode = import ./assert-node.nix args;
in
step {
  name       = "scenario-query-nodes";
  input      = ''(| Node @name |)'';
  priorState = assertNode;
}
