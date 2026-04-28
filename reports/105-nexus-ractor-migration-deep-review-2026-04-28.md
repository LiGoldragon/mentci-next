# 105 — Deep review of the nexus-daemon ractor migration

*Static review of the migration committed at [nexus c30f303f](https://github.com/LiGoldragon/nexus/commit/c30f303f0b39dbf495a7a5a39b1db144574c25ba)
and [mentci flake.lock bump](../flake.lock).*

Verdict up front: the migration is structurally correct, follows the
[reports/103](103-ractor-migration-design-2026-04-28.md) plan as
amended by [reports/104 §8](104-handoff-after-criome-ractor-migration-2026-04-28.md),
preserves every pre-migration behavior, and fixes the detached-task
supervision blind spot. The end-to-end gate (mentci's `integration`
nix-check) is still building at time of writing; this review covers
static + per-crate-test correctness.

---

## 1 · Plan compliance

Each non-negotiable from reports/104 §8c–§8g, with the file that
encodes it:

| Plan item | Encoded by | OK |
|---|---|----|
| `ractor = { version = "0.15", features = ["async-trait"] }` | [`Cargo.toml:30`](../repos/nexus/Cargo.toml) | ✓ |
| `Error::ActorCall(String)` + `ActorSpawn(String)` | [`error.rs:38,42`](../repos/nexus/src/error.rs) | ✓ |
| Listener actor — UDS accept, `Accept` self-cast, `spawn_linked` per accept, `handle_supervisor_evt` log-and-continue | [`listener.rs`](../repos/nexus/src/listener.rs) | ✓ |
| Daemon root actor — empty `Message`, `pre_start` spawns Listener linked, `Daemon::start` façade | [`daemon.rs`](../repos/nexus/src/daemon.rs) | ✓ |
| Connection actor — single-message `Run` lifecycle (pre_start casts Run, handle does shuttle, `myself.stop()`) | [`connection.rs`](../repos/nexus/src/connection.rs) | ✓ |
| `main.rs` calls `Daemon::start().await` and awaits the join handle | [`main.rs`](../repos/nexus/src/main.rs) | ✓ |
| `pub mod listener` added; `Connection` re-export dropped | [`lib.rs`](../repos/nexus/src/lib.rs) | ✓ |
| Parser, Renderer, CriomeLink stay structs | unchanged | ✓ |
| `nexus-parse`, `nexus-render` one-shot binaries unchanged | unchanged | ✓ |
| Per-crate `nix flake check` passes | run | ✓ |

All seven of Li's [reports/103 §8](103-ractor-migration-design-2026-04-28.md)
answers honored: read-pool now (criome side); per-crate Connection
actors with diverging inner state; Daemon IS an actor; log-and-forget
on connection panic; one file per actor with bare-named
module-derived qualifier; migration before lojix is born;
verb-specific messages (Connection's single `Run` is M0's specificity
— additional message variants land as M1+ streaming and M2+
subscriptions arrive).

## 2 · Architectural-invariant compliance

**Invariant D — perfect specificity.** Connection decomposes Frame
before crossing the actor boundary into criome — but the
decomposition happens inside `CriomeLink::send`, which constructs a
typed `Frame { body: Body::Request(request) }` per typed `Request`.
The actor message itself (`Run`) doesn't carry the Frame. ✓

**Two messaging surfaces** (nexus ARCH §"Two messaging surfaces") —
client-facing nexus text + signal-rkyv to criome. Connection State
holds the `UnixStream` (text side) and `criome_socket_path` (signal
side, used to lazily open `CriomeLink`). The two surfaces meet only
inside `State::process`, which is exactly where the mechanical-
translation rule lives. ✓

**No state survives a request** (nexus ARCH §"Per-connection
state"). Connection actor stops after one Run; the State is dropped;
the `UnixStream` and (if opened) `CriomeLink` are torn down with it.
✓

**No correlation IDs; FIFO position** (signal ARCH §"Reply
protocol"). `State::process` reads requests sequentially and renders
replies sequentially via the same `Renderer` — order preserved by
loop structure. ✓

**Methods on types** (style.md §Methods). `shuttle` and `process`
live as methods on `State`, not as free functions. ✓

**Bare-named module-derived qualifier** (style.md §Actors discipline
per reports/103 §8 Q5). `listener::Listener`, `daemon::Daemon`,
`connection::Connection`. ✓

## 3 · Behavior preservation

The migration is a **re-housing**, not a rewrite. Per-connection
control flow:

```
old: Daemon::run() loop → tokio::spawn → Connection::shuttle()
       → Connection::process() → CriomeLink → write_all → close
new: Daemon (actor) → Listener (actor) loop Accept
       → spawn_linked Connection (actor) → handle Run
       → State::shuttle() → State::process() → CriomeLink
       → write_all → myself.stop(None)
```

The bodies of `shuttle` and `process` are byte-for-byte the
pre-migration code, lifted from `Connection::{shuttle, process}` to
`State::{shuttle, process}`. CriomeLink unchanged. Renderer
unchanged. Parser unchanged. Same edge cases (empty input, parse
error before any request, parse error mid-stream, criome handshake
failure, frame too large, write failure) all map through unchanged.

## 4 · Correctness improvements (vs pre-migration)

1. **Connection panics now visible.** A panicking `shuttle` body
   becomes `SupervisionEvent::ActorFailed`, logged by Listener's
   override. Pre-migration: a panicking detached `tokio::spawn` task
   silently disappeared from the runtime.
2. **Graceful shutdown via ractor stop()** instead of ad-hoc
   shutdown channels. Same gap as criome on SIGTERM handling, but
   the plumbing is in place when we add it.
3. **Typed actor protocol prepared for M1+/M2+.** `Message::Run`
   today; `Message::ReadNext` for streaming and
   `Message::SubscriptionUpdate(Reply)` for subscriptions land as
   additive variants without restructuring.

## 5 · Tests

| Test surface | Result |
|---|---|
| 11 parser tests (`tests/parser.rs`) | pass — Parser stays a struct |
| 9 renderer tests (`tests/renderer.rs`) | pass — Renderer stays a struct |
| `cargo check` clean | ✓ |
| Per-crate `nix flake check` (sandboxed) | ✓ |
| Workspace `nix flake check` — `integration` end-to-end (load-bearing gate per reports/103 §7.2) | **pending** |

**Gap, intentional:** no unit tests for the actor wiring itself.
Per criome's pattern (six sync tests against `engine::State`, none
against actors), the actor wiring is integration-tested. The
`mentci/checks/integration.nix` end-to-end test exercises three
sequential connections (assert / query / diagnostic) through both
daemons via `nexus-cli` — if it passes, the actor lifecycle is
correct end-to-end.

## 6 · Observations and small frictions

1. **`listener.rs` doc comment lacks the report link** that
   `criome/src/listener.rs:11-12` has (`per reports/103 §8 Q4`).
   This is a slight inconsistency. Per Li's "reports are ephemeral"
   doctrine, the right resolution is to **drop the link from
   criome's listener.rs** rather than add it to nexus's — code
   shouldn't depend on a report that may be deleted. Flagged as
   follow-up, not blocking.
2. **`socket_path` vs `listen_path`** — the field on `daemon::Arguments`
   and `listener::Arguments` was renamed `listen_path` →
   `socket_path` to match criome's convention. Pairs as
   `socket_path` (bind) + `criome_socket_path` (dial). Both names
   are full-English; the choice is consistency with criome.
3. **`process` takes `&Path`** instead of `&PathBuf` — minor
   idiomatic improvement. CriomeLink::open accepts `&Path`; the
   coercion from `&self.criome_socket_path` (PathBuf) is automatic.
4. **`E0030` and `E0031` renderer codes** added to
   `local_error_code` for ActorCall and ActorSpawn. These should
   not normally reach client-facing rendering (the actor system
   would have collapsed first), but exhaustive match requires
   them.

## 7 · Things deliberately divergent from criome's shape

These differences are correct per the design, not gaps:

- **Connection lifecycle is one-shot (`Run` → stop)** vs criome's
  long-running (`ReadNext` loop). Nexus M0 client framing is
  read-to-EOF-and-respond; the actor lifecycle matches.
- **No Engine actor in nexus.** Dispatch target on the criome side
  is `CriomeLink` (a struct, single-owner per request). Nexus has
  no analog of criome's "writes serialized through one mailbox"
  problem.
- **No Reader pool** — same reason; nexus doesn't own state.
- **Listener's State is simpler** — no `engine_ref`, no `readers`,
  no `reader_cursor`. Just `listener` + `criome_socket_path` to
  forward.
- **Connection's State is simpler** — no engine ref, no
  reader_cursor. Just `client` + `criome_socket_path`.

## 8 · Follow-ups (post-migration, not blocking)

- **`nexus/ARCHITECTURE.md` code map** still describes pre-migration
  nouns (`Daemon noun: bind, accept loop, spawn Connection per
  client` etc.). Update to reflect actor tree.
- **`criome/ARCHITECTURE.md` code map** also describes pre-migration
  shape (per reports/104 §10a). Same update; can land together.
- **`bd mentci-next-rgs`** to close once integration passes.
- **`reports/104` cleanup** — once the migration is fully verified
  and ARCH docs updated, 104's §8 (the migration plan) can be
  trimmed since the plan is executed; the lurking-dangers list
  stays useful.

## 9 · Verdict

Structurally correct. Plan executed faithfully. Old behavior
preserved bit-for-bit. Supervision blind-spot closed. Per-crate
tests green. Integration test pending — that's the load-bearing
gate; once it passes, the migration is verified end-to-end.

If the integration test passes: close `mentci-next-rgs`, update both
ARCHITECTURE.md code maps, optionally trim reports/103 (its design
is now expressed in code; only the lurking-dangers + Li's seven
answers retain ongoing value, both of which live in reports/104).

If the integration test fails: read `nix log <drv>` on the failing
derivation; the failure is almost certainly in the actor wiring or
a subtle race in the new code path, not in any of the unchanged
parts (Parser / Renderer / CriomeLink).
