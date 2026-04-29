# mentci

Workspace umbrella + meta-deploy aggregator for the
[criome](https://github.com/LiGoldragon/criome) sema-ecosystem.

Holds the dev shell, design corpus (`reports/`), agent rules
(`AGENTS.md`), workspace manifest (`docs/workspace-manifest.md`),
the symlink farm under `repos/`, integration tests under
`checks/`, and the nix-flake aggregation that composes the
ecosystem's daemons (criome, nexus, forge, arca-daemon) into
deployable NixOS services.

See [`ARCHITECTURE.md`](ARCHITECTURE.md) for the dev-environment
shape and [criome's
`ARCHITECTURE.md`](https://github.com/LiGoldragon/criome/blob/main/ARCHITECTURE.md)
for the project being built (REQUIRED READING for every agent
or human working in any sema-ecosystem repo).

`nix develop` opens the dev shell. `nix flake check` runs the
workspace's aggregated unit-test surface and the integration
scenarios under `checks/`.
