{ pkgs, inputs, system, ... }:

# Quick-loop end-to-end test — single derivation that spawns
# both daemons in shared `$PWD`, pipes the demo text through
# nexus-cli, asserts the canonical replies, and tears down.
#
# Pairs with the [`scenario/`](./scenario/) chain. The chain
# isolates each step in its own content-addressed derivation
# (forces real per-step caching + per-step failure isolation);
# this file is the "everything in one bash script" cousin that
# stays useful for fast iteration on the daemon graph itself.
# Both ride together under `checks/default.nix`.

let
  criome    = inputs.criome.packages.${system}.default;
  nexus     = inputs.nexus.packages.${system}.default;
  nexus-cli = inputs.nexus-cli.packages.${system}.default;
in
pkgs.runCommand "mentci-integration" { } ''
  set -euo pipefail

  cd $TMPDIR
  criome_socket=$PWD/criome.sock
  sema_path=$PWD/sema.redb
  nexus_socket=$PWD/nexus.sock

  cleanup() {
    kill ''${nexus_pid:-} ''${criome_pid:-} 2>/dev/null || true
    wait 2>/dev/null || true
  }
  trap cleanup EXIT

  CRIOME_SOCKET=$criome_socket SEMA_PATH=$sema_path \
    ${criome}/bin/criome-daemon &
  criome_pid=$!
  for i in $(seq 1 50); do
    [ -S "$criome_socket" ] && break
    sleep 0.1
  done
  [ -S "$criome_socket" ] || { echo "criome-daemon failed to bind"; exit 1; }

  NEXUS_SOCKET=$nexus_socket CRIOME_SOCKET=$criome_socket \
    ${nexus}/bin/nexus-daemon &
  nexus_pid=$!
  for i in $(seq 1 50); do
    [ -S "$nexus_socket" ] && break
    sleep 0.1
  done
  [ -S "$nexus_socket" ] || { echo "nexus-daemon failed to bind"; exit 1; }

  assert_reply=$(echo '(Node "User")' | NEXUS_SOCKET=$nexus_socket ${nexus-cli}/bin/nexus)
  if [ "$assert_reply" != '(Ok)' ]; then
    echo "FAIL: expected '(Ok)', got: $assert_reply"
    exit 1
  fi

  query_reply=$(echo '(| Node @name |)' | NEXUS_SOCKET=$nexus_socket ${nexus-cli}/bin/nexus)
  if [ "$query_reply" != '[(Node "User")]' ]; then
    echo "FAIL: expected '[(Node \"User\")]', got: $query_reply"
    exit 1
  fi

  diagnostic_reply=$(echo '~(Node "User")' | NEXUS_SOCKET=$nexus_socket ${nexus-cli}/bin/nexus)
  case "$diagnostic_reply" in
    '(Diagnostic Error "E0099"'*) ;;
    *) echo "FAIL: expected '(Diagnostic Error \"E0099\" ...)', got: $diagnostic_reply"; exit 1 ;;
  esac

  echo "integration test passed: assert + query + diagnostic shuttle through criome-daemon + nexus-daemon + nexus-cli"
  touch $out
''
