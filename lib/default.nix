{ ... }:

# Blueprint auto-discovers `lib/` and expects a `default.nix`
# here. The actual scenario test helpers live in
# `lib/scenario/` and are imported directly by
# `../checks/default.nix`; this file just satisfies the
# blueprint contract by exporting an empty attrset.
{ }
