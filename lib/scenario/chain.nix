{ pkgs, inputs, system, ... }@args:

# Final assertion derivation — runs after each step's reply
# text is content-addressed in its own derivation. Asserts the
# canonical text replies the demo from
# [reports/100 §5](../../reports/100-handoff-after-nota-codec-shipping-2026-04-27.md)
# expects. If any assertion fails, the failure points at the
# specific step's `response.txt` so debugging starts at the
# isolated boundary, not in the middle of an interleaved
# bash log.

let
  assertNode = import ./assert-node.nix args;
  queryNodes = import ./query-nodes.nix args;
in
pkgs.runCommand "scenario-chain" { } ''
  set -euo pipefail

  if ! grep -qE '^\(Ok\)$' ${assertNode}/response.txt; then
    echo "FAIL scenario-assert-node:"
    echo "  expected: (Ok)"
    echo "  got:      $(cat ${assertNode}/response.txt)"
    exit 1
  fi

  if ! grep -qE '^\[\(Node "User"\)\]$' ${queryNodes}/response.txt; then
    echo "FAIL scenario-query-nodes:"
    echo "  expected: [(Node \"User\")]"
    echo "  got:      $(cat ${queryNodes}/response.txt)"
    exit 1
  fi

  echo "scenario chain passed: assert + query round-trip with sema state preserved across derivation boundaries"
  touch $out
''
