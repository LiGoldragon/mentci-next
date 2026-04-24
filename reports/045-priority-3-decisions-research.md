---
report: 045
title: "priority-3 lojix-transition decisions — research and recommendations"
author: "Claude Opus 4.7"
date: "2026-04-24"
supersedes: []
depends_on:
  - reports/020-lojix-single-daemon.md
  - reports/021-criomed-evaluates-lojixd-executes.md
  - reports/030-lojix-transition-plan.md
  - reports/031-uncertainties-and-open-questions.md
  - reports/033-record-catalogue-and-cascade-consolidated.md
  - reports/037-workspace-inclusion-and-archive-system.md
---

# 045 — priority-3 lojix-transition decisions: thin CLI home, lojixd transport, deploy-verb genericity, phase ordering vs criomed

*Claude Opus 4.7 / 2026-04-24 · deep research on the four P3
decisions from report 031. Report 030 provides the seven-phase
scaffold; this report lands a concrete lean per decision.
Audience: future session agents picking up lojix work after
Phase A who need to know what Phases B–G look like without
re-litigating the design.*

---

## Scope

Report 031 flagged four P3 items as "load-bearing for
lojix-transition but orthogonal to sema." They can be settled
independently of P0 (hash-vs-name) and P1 (edit UX), but they
couple to each other: transport shapes the thin-CLI's life, and
verb genericity shapes phase ordering.

Current state: `lojix` is a single `clap` binary that spawns a
`DeployCoordinator` actor routing one `DeployMsg::Run { request,
reply }` through four subactors (`ProposalReader`,
`HorizonProjector`, `HorizonArtifact`, `NixBuilder`). Report 030
Phase A freezes this; everything below is additive.

---

## P3.1 — Thin CLI's home

Where does the Phase-B `lojix-msg`-constructing binary live?

### Precedent

**nix's CLI evolution**: nix shipped six separate binaries
(`nix-build`, `nix-env`, `nix-shell`, `nix-store`,
`nix-instantiate`, `nix-copy-closure`) for a decade before the
unified `nix` command landed in 2017. That transition has still
not retired the legacy binaries — seven years in, both ship in
stable. Lesson: binary-name proliferation is cheap, but
*retiring* a binary once users have muscle memory is very
expensive. This pushes against premature repo-splits and against
early binary-renames (report 030 guardrail #4 already prohibits
renaming `lojix` without Li).

**git's structure**: ~150 commands dispatched via
`git <subcommand>` from a single source tree, installed as many
small `git-*` binaries on `$PATH`. One repo, many binaries.
Cargo's `[[bin]]` table is the direct analogue.

**kubectl + crictl + ctr**: Kubernetes ships `kubectl` as the
human CLI and `crictl`/`ctr` as lower-level break-glass clients
targeting the same daemon. Separate binaries, separate repos,
they coexist naturally. Report 030 Phase G anticipates exactly
this shape — criomed routes most deploys but lojix-cli persists
for break-glass.

### Cost comparison

**New repo** costs, under our workspace rules: `Cargo.toml` +
`flake.nix` + `rust-toolchain.toml`, Dolt + beads databases,
`mentci-next/repos/` symlink, manifest entry, GitHub repo,
`AGENTS.md` + `CLAUDE.md`, CI/flake green. That's a day of Li's
attention per repo, and agents cannot bootstrap the Dolt + beads
dance autonomously.

**Second binary inside `lojix/`**: one `Cargo.toml` edit, one
new file under `src/bin/`. No flake changes. No new symlink.
Essentially free.

### Per-phase recommendation

- **Phase B** (lojix-msg crate): the crate itself is a
  standalone library repo (consumers will include criomed,
  lojixd, and tests — it cannot nest inside `lojix/`). No CLI
  work yet. Hand-rolled round-trip tests inside
  `lojix-msg/tests/`.
- **Phase C** (lojixd scaffolds): create `lojixd/` as a new
  repo; it's a daemon, not a CLI. No thin-CLI yet;
  integration tests inside `lojixd/` construct `LojixMsg`
  envelopes in-process.
- **Phase D** (`--via-daemon` flag): add the flag to `lojix`'s
  existing clap tree. No new binary. The monolith grows a
  lojix-msg code path.
- **Phase E** (monolith thins): same binary, same name;
  internals morph from "actor pipeline" to "rkyv client."
- **Phase F** (name transition): the binary retains the name
  `lojix` — no rename. Muscle memory wins. The *repo* shape
  changes: `lojix/` becomes spec-only README; the clap tree +
  thin-client logic extracts to a dedicated `lojix-cli/` repo
  whose installed binary is still named `lojix`. Kubectl
  precedent.
- **Phase G** (criomed brokers): `nexus-cli (Deploy …)` is the
  standard path; `lojix` persists as break-glass.

**Lean**: (b) second binary inside `lojix/` for Phases B–E, then
(a) extract to a dedicated `lojix-cli/` at Phase F. Never fold
into `nexus-cli` — coexistence matches kubectl/crictl. This
**supersedes report 030 Q1's lean (a)** with the more specific
(b)-then-(a) phasing.

---

## P3.2 — lojixd transport details

### Criomed↔nexusd sets the precedent

Architecture.md §2: nexusd listens on a Unix socket (or stdio);
`criome-msg` is rkyv over a stream. `nexusd/src/main.rs`'s
module comment confirms: "Parses nexus messages over a Unix
socket (or stdio), forwards rkyv criome-messages to criomed."
The criomed↔nexusd wire is UDS + rkyv. Rule: **lojix-msg
matches.** Two daemon-to-daemon wires with the same transport
means one framing story, one reconnect pattern, one test
harness.

### rkyv framing

rkyv doesn't mandate framing — an `ArchivedT` is a contiguous
byte buffer. For stream transport you need a length prefix
(`rkyv-rpc` uses `u32`; the ractor cluster protocol uses
length-prefixed bincode; all rkyv ecosystem RPCs converge here).
A `u32` prefix is too small at the margin for plans carrying
hundreds of `(blake3, RelPath)` tuples; use `u64` and accept
four bytes overhead.

```
[8 bytes LE u64 frame_len] [frame_len bytes rkyv-archived payload]
```

Payload is a single envelope enum `LojixMsg { corr_id: u64,
body: LojixBody }`.

### Zero-copy preservation

rkyv's headline feature is zero-copy reads — a received byte
buffer *is* the archived value. To preserve this at the lojixd
boundary: `read_exact` the 8-byte prefix, allocate
`Vec<u8>` of exactly `frame_len`, `read_exact` into it, then
`archived_root::<LojixMsg>(&bytes[..])` on the slice. One
allocation per frame, zero deserialisation copy. Standard rkyv
streaming pattern.

### Reconnect semantics

Report 033 Part 2's claim: "in-flight plans become durable
records; restart-safety is re-dispatch plans with no outcome."
This means **the wire itself needs no durability guarantees** —
durability lives in sema. Concretely:

- **lojixd restart (criomed alive)**: criomed notices UDS read
  fails, reconnects with exponential backoff (100ms, 300ms,
  1s, 3s, cap 10s), re-dispatches outstanding plans. Duplicate
  dispatches are safe: plan-id is the sema record id; lojixd's
  handler is idempotent keyed by plan-id.
- **criomed restart (lojixd alive)**: lojixd notices write
  fails, accepts the new criomed's reconnect.
- **Both restart**: composes.

**Open sub-decision**: does lojixd persist outcomes locally
before ack? Lean yes — a small `plan-id → outcome` redb with
24-hour TTL. This gives restart-safe idempotency local to
lojixd (critical for `nixos-rebuild Switch` which is NOT
idempotent against re-invocation) without round-tripping
through sema, and it decouples lojixd from criomed's ack
latency.

### Heartbeat

For two-process local UDS, TCP-style heartbeat is overkill. EOF
or error signals peer-gone. Add a 30-second idle ping —
criomed sends `Ping`, lojixd replies `Pong { uptime_ms }` —
just to catch hung half-closed sockets, and to distinguish
"lojixd is busy on a long build" from "lojixd is dead."

### Alternatives, dismissed

- **TCP localhost**: UDS is strictly better (faster; uid-auth
  via peer credentials; no port allocation). TCP is only
  useful for cross-host deploys, and lojixd is same-host
  (nixos-rebuild-to-remote is a sub-operation inside local
  lojixd, not a remote lojixd).
- **gRPC over UDS (tonic)**: adds protobuf/IDL on top of the
  rkyv schemas we already hand-define in `lojix-msg`. No win.
  Streaming can be implemented directly with our framing.
- **Named pipes (Windows)**: we don't target Windows —
  nixos-rebuild is Linux-only by construction.
- **Shared-memory rings (iceoryx)**: rkyv already gets us
  zero-copy *within* a process; the cross-process memcpy at
  the UDS boundary is negligible for our message sizes.
  Premature optimisation.

### Recommendation

Transport: UDS at `$XDG_RUNTIME_DIR/lojixd.sock` (falls back to
`/run/user/<uid>/lojixd.sock`). Framing: 8-byte LE u64 length
prefix + rkyv-archived `LojixMsg` envelope. Reconnect:
exponential backoff with 100ms–10s cap; idempotent replay keyed
by plan-id; no wire-level durability. Heartbeat: 30-second idle
ping. Local outcome cache in lojixd: small redb, 24-hour TTL.
Direct match for what criomed↔nexusd should be.

---

## P3.3 — Deploy verbs: generic vs CriomOS-specific

Current `lojix` is unambiguously CriomOS-specific:
`--criomos github:LiGoldragon/CriomOS` is a default;
`NixInvocation::command()` in `src/build.rs` hard-codes
`nixosConfigurations.target.config.system.build.toplevel` as the
target attribute; `DeployRequest.criomos: FlakeRef` is a typed
field for the CriomOS flake specifically. Terminal-state lojixd
serves any nix-flake target.

### Verb-shape sufficiency

Report 033 Part 2 sketches `RunNixosRebuildPlan { flake_path,
action, overrides, target_host }`. Testing against the current
CriomOS shape:

- `flake_path` generalises `--criomos`.
- `action` maps the `BuildAction` enum.
- `overrides` subsumes `--override-input horizon <uri>` and
  `--override-input system <uri>` as a generic
  `Vec<(String, FlakeRef)>`.
- `target_host` is for remote SSH deploys (deferred).

The thing CriomOS does — pointing at
`#nixosConfigurations.target.config.system.build.toplevel` — is
not a CriomOS convention, it's standard NixOS. The attribute
name `target` *is* a CriomOS convention but can be a generic
fifth field:

```
RunNixosRebuildPlan {
  flake: FlakeRef,
  attr: String,                  // "target" for CriomOS; other for others
  action: NixosRebuildAction,
  overrides: Vec<(String, FlakeRef)>,
  target_host: Option<String>,   // None = localhost
}
```

Five fields, nothing CriomOS-specific. CriomOS knowledge (attr
= "target"; override inputs are `horizon` + `system`; default
flake url) lives in the thin CLI's defaults, not in the daemon.

### Horizon projection

Current `lojix` links `horizon-lib` in-process. Horizon is
generic to the "goldragon-style cluster proposal" concept — not
CriomOS-specific — but its public API uses `ClusterName`/
`NodeName` which are CriomOS's vocabulary. Horizon is a library,
stays a library; lojixd depends on it. The invocation becomes
its own plan kind:

```
RunHorizonProjectionPlan {
  proposal_source: StoreEntryRef,
  viewpoint: Viewpoint,
} → StoreEntryRef
```

`RunNixosRebuildPlan` is a separate plan kind. The current
monolith sequences them in-process; terminal lojixd sees two
plans, and *criomed* sequences them (the projection-output is an
override-input to the rebuild — a dependency criomed resolves).

### Multi-target deploy

**Shape A** (one plan per host): criomed produces N plan records
for an N-host cluster; lojixd handles each independently; partial
failures are visible as individual outcome records.

**Shape B** (one plan, list of hosts): `target_hosts: Vec<String>`;
lojixd fan-outs internally.

**Lean: Shape A.** Criomed already has per-host structure (each
host gets its own `NixosRebuildOutcome`); lojixd stays simple;
failure isolation is natural; N=1–10 makes plan-count a
non-issue.

### Per-host secrets

Three options: (1) sema holds encrypted secrets, criomed
decrypts at plan-time, plan carries plaintext on the trusted
UDS; (2) sema holds secrets encrypted with per-host pubkeys,
lojixd or target decrypts, criomed never sees plaintext
(agenix/sops-nix pattern); (3) out-of-band (env vars,
bind-mounts), plan references by name. **Lean**: (3) for MVP
(operationally fragile but simple), (2) post-MVP (report 035
establishes records-as-crypto-primitives as a roadmap item).

### Layer split

- **lojix-cli** (thin wrapper): default `--criomos` flag;
  default attr `target`; default override-input names
  (`horizon`, `system`); `--cluster`/`--node` shapes;
  nota-source loader. All CriomOS-shaped.
- **lojixd** (daemon): nothing CriomOS-specific. All fields
  generic.
- **lojix-msg** (contract): nothing CriomOS-specific. Fields
  are nix-level abstractions.

### Recommendation

Generic verb set in `lojix-msg`:

```
RunHorizonProjectionPlan   { proposal_source, viewpoint }
RunNixBuildPlan            { flake, attr, overrides, expected_nar_hash }
RunNixosRebuildPlan        { flake, attr, action, overrides, target_host }
RunCargoPlan               { workdir_entries, toolchain, args, env }
PutStoreEntryPlan          { bytes }
GetStorePathPlan           { blake3 }
MaterializeFilesPlan       { entries, target_dir }
DeleteStoreEntryPlan       { blake3 }
```

All CriomOS-specific defaults in `lojix-cli`. Secrets MVP-out-
of-band, post-MVP-encrypted-records.

---

## P3.4 — Phase ordering relative to criomed

### Criomed scaffolding cost

Criomed doesn't exist yet (report 037 manifest). Minimum
viable criomed (answers `Query` against a hardcoded sema loaded
from JSON seed) is weeks of work: redb setup + sema loader +
criome-msg handler + UDS listener. A *useful* criomed (cascade
engine, subscription delivery, lojixd-dispatch, semachk phases)
is months. Phase-B criomed work is gated on P0.1 (hash-ref vs
name-ref) at minimum — we need to know whether `nexus-schema`
references are `StructId(Hash)` or `Type::Named(TypeName)`
before defining record write-paths.

### Early- vs late-integration risk

**Can we define lojix-msg before criomed exists?** Yes —
lojix-msg verbs are concrete (per report 021): "run this cargo
invocation" with explicit `workdir`, `args`, `env`, `toolchain`
fields. They reference sema records only via opaque content-
hash handles (`StoreEntryRef(blake3)`). criomed's internal
dispatch is orthogonal — any reasonable design produces a
`RunCargoPlan` from internal plan records.

**Risk**: we might discover, when criomed is being written,
that we want lojix-msg to carry a sema revision id or a
subscription correlation handle. Retrofitting means wire
versioning.

**Mitigation**: include `sema_rev: Option<RecordId>` and
`corr_id: u64` in `LojixMsg` from day one. Cost nothing; future-
proof.

### Migration safety

Architecture.md's "no backward compat" invariant (line 423): we
can reshape freely. Phase-D `lojix --via-daemon` depends on
lojix-msg stability, so `lojix` and `lojixd` must update
together; both depend on `lojix-msg` as a path-dependency so
`cargo update -p lojix-msg` keeps them in sync.

### Critical path to self-hosting

```
(code in .rs)
  → ingester loads it into sema      [blocks on P0.3]
  → criomed runs against the sema    [blocks on P0.1 + P1.x]
  → criomed dispatches RunCargoPlan  [blocks on lojix-msg]
  → lojixd runs cargo, emits CompiledBinary
  → binary in lojix-store; CompiledBinary record in sema
  → user runs new criomed binary on the same sema
  → self-hosting closed
```

On the critical path: P0.1 (nexus-schema reference shape); P0.3
(ingester scope); criomed skeleton; lojixd skeleton; lojix-store
directory; `RunCargoPlan` round-trip.

Lojix Phases B + C + D are on the critical path *but
parallelisable* to criomed work:

- **Phase B** (lojix-msg crate) can be written today against
  existing lojix shapes, modulo `sema_rev`/`corr_id`
  future-proofing. Doesn't need criomed. Doesn't need P0.1.
- **Phase C** (lojixd skeleton) tests against a hand-written
  `LojixMsg`-sending client — no criomed needed.
- **Phase D** (`lojix --via-daemon`) exercises the full B+C
  stack with the `lojix` monolith as client. Validates
  lojix-msg *without* waiting on criomed.

Not parallelisable: Phase G (criomed-brokers-deploys) trivially
needs criomed. Integration with actual sema records (`Opus`
records driving compile) blocks on criomed *and* nexus-schema
stability.

### Decisive bottleneck

**Criomed existing + the ingester loading the workspace into
sema.** Neither is lojix-work; neither gets faster by waiting.
Lojix Phases B/C/D can land in parallel with criomed scaffolding
and *act as an early-integration test* for lojix-msg. When
criomed arrives, its lojix-msg client is already proven.

### Recommendation

Dependency graph for the next 3–6 months:

```
criomed track:
  P0.1 decision → nexus-schema stabilises
  P0.3 decision → ingester scope
  criomed skeleton (gated on nexus-schema)

lojix track (parallel, criomed-independent):
  Phase B: write lojix-msg crate           [now]
  Phase C: scaffold lojixd UDS listener    [after B review]
  Phase D: `lojix --via-daemon` flag       [after C]

converge:
  criomed dispatches RunCargo via lojix-msg
  first compile via daemon
  self-hosting closes

off the 3-6 month path:
  semachk phases, rules-as-records, edit UX,
  Arbor/prolly-trees, Phase F renames, Phase G
```

**Order of Li's attention** (scarce resource): P0.1 first;
P0.3 second; then parallelise. **Order of agent-session
attention** (can run without Li): Phase B immediately
(mechanical translation of existing types); Phase C + D after
Li reviews the verb set.

This **confirms and extends report 030 Q5's lean**: start Phase
B now; Phase C + D parallelise with criomed-skeleton work, not
after it.

---

## Cross-cutting

**Does P3.1 (CLI home) depend on P3.2 (transport)?** Weakly.
With UDS + rkyv (~200 lines of tokio framing), the thin-client
fits inside `lojix/src/bin/` until Phase F. If the transport
were exotic (gRPC, shmem), code bulk would argue for its own
repo. P3.1's lean survives P3.2's choice.

**Does P3.3 (generic vs CriomOS) push P3.4 (ordering)?**
Moderately. Generic verbs add roughly a week of design work to
Phase B vs a CriomOS-only shape, but the *verb shape* is the
only forward commitment — implementation can stay
CriomOS-default with generic fields defaulted. No months-scale
slip.

**Does P3.2 (transport) push P3.4 (ordering)?** Strongly
favourably. UDS + rkyv is implementable in Phase C without
criomed; the transport choice is what *enables* the criomed-
independent critical path. Had we picked gRPC-over-TCP, the
infrastructure push (tonic, protobuf compilation, TLS?) would
eat into Phase C's timeline.

---

## Summary of leans

| Decision | Lean | Key reasoning |
|---|---|---|
| P3.1 Thin CLI home | (b) second binary in `lojix/` for Phases B–E; (a) extract `lojix-cli/` at Phase F; binary retains name `lojix` | New-repo overhead is expensive; binary-rename breaks muscle memory; lojix-cli / nexus-cli coexistence matches kubectl/crictl |
| P3.2 lojixd transport | UDS at `$XDG_RUNTIME_DIR/lojixd.sock`; 8-byte LE length prefix + rkyv envelope; 30s idle ping; plan-id-keyed idempotent replay; lojixd local outcome redb with 24h TTL | Matches criomed↔nexusd precedent; preserves zero-copy; restart-safety via sema; no exotic deps |
| P3.3 Deploy verbs | Generic five-field `RunNixosRebuildPlan`; CriomOS knowledge in `lojix-cli` defaults; Shape-A per-host plans; horizon-projection as its own plan kind | Generic verbs cost ~1 week of design; implementation stays CriomOS-default; parallels nix daemon/wrapper separation |
| P3.4 Phase ordering | Phase B now; Phase C + D parallel to criomed skeleton; criomed blocks on P0.1, not on lojix; `lojix --via-daemon` validates lojix-msg before criomed depends on it | Critical path bottleneck is criomed + ingester, not lojix; lojix B–D are parallelisable and provide early-integration test |

The **decisive bottleneck for self-hosting** is criomed
existing and ingester scope being settled. Lojix transition
work is useful in parallel but not gating. The order of Li's
attention that unlocks the most work: P0.1 first, P0.3 second,
then parallelise lojix Phase B and criomed-skeleton. The order
of agent-session attention that progresses without blocking Li:
start Phase B (mechanical translation against existing types),
let Li review the verb set, scaffold Phase C + D when the
contract is approved.

---

*End report 045.*
