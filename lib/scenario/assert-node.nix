{ pkgs, inputs, system, ... }:

# Step A — assert (Node "User") into a fresh sema database.
# Captures both the (Ok) reply text and the resulting sema
# state for the next step in the chain to consume.

let
  step = import ./lib.nix {
    inherit pkgs;
    criome    = inputs.criome.packages.${system}.default;
    nexus     = inputs.nexus.packages.${system}.default;
    nexus-cli = inputs.nexus-cli.packages.${system}.default;
  };
in
step {
  name  = "scenario-assert-node";
  input = ''(Node "User")'';
}
