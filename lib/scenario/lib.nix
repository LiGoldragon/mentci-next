{ pkgs, criome, nexus, nexus-cli }:

# Run one daemon-shuttle step and capture both the rendered
# reply text and the resulting sema database state. Returns a
# derivation whose `$out` contains:
#
#   $out/response.txt — the text reply from nexus-cli
#   $out/state.redb   — the sema database after the request,
#                       suitable for chaining into the next step
#
# Args:
#   name:       step name (used as derivation name)
#   input:      nexus text to send (one or more top-level forms)
#   priorState: optional derivation containing a prior
#               `state.redb` to seed sema. `null` = fresh empty
#               database.
#
# Each step runs in its own pure-build sandbox, so passing the
# `priorState` derivation is the *only* way state crosses
# between steps. This forces every dependency between steps to
# be visible in the Nix dependency graph.

{ name, input, priorState ? null }:

pkgs.runCommand name { } ''
  set -euo pipefail
  cd $TMPDIR

  ${pkgs.lib.optionalString (priorState != null)
    "install -m 644 ${priorState}/state.redb sema.redb"}

  criome_socket=$PWD/criome.sock
  nexus_socket=$PWD/nexus.sock

  cleanup() {
    kill ''${nexus_pid:-} ''${criome_pid:-} 2>/dev/null || true
    wait ''${nexus_pid:-} ''${criome_pid:-} 2>/dev/null || true
  }
  trap cleanup EXIT

  CRIOME_SOCKET=$criome_socket SEMA_PATH=$PWD/sema.redb \
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

  echo ${pkgs.lib.escapeShellArg input} | \
    NEXUS_SOCKET=$nexus_socket ${nexus-cli}/bin/nexus > response.txt

  # Stop daemons so sema's redb commits flush cleanly to disk
  # before we copy state.redb into $out.
  kill $nexus_pid 2>/dev/null || true
  wait $nexus_pid 2>/dev/null || true
  kill $criome_pid 2>/dev/null || true
  wait $criome_pid 2>/dev/null || true

  mkdir -p $out
  cp response.txt $out/response.txt
  cp sema.redb $out/state.redb
''
