# 117 — Implementation gap: where the code is vs where the design says it should be

*Research output: walking the design changes from this session
([reports/113](113-architecture-deep-map-2026-04-29.md) — current
state; [reports/114](114-mentci-stack-supervisor-draft-2026-04-30.md)
— supervisor; [reports/115](115-schema-derive-design-2026-04-30.md)
— schema derive; [reports/116](116-genesis-seed-as-design-graph-2026-04-30.md)
— genesis seed) against actual code, calling out the changes the
existing code needs and the missing pieces. §4 names the issues
that genuinely block "engine works end-to-end" — the things to
attend to first. Lifetime: until the items in §4 land in code or
get superseded by a later report.*

---

## 0 · TL;DR

Two halves to the gap:

```
   ┌── EXISTING CODE NEEDS CHANGES ──────────────────────────────┐
   │                                                             │
   │   • Slot becomes Slot<T> across signal + criome + mentci-lib │
   │   • mentci-lib::CompiledSchema gets a real impl              │
   │   • mentci-lib's WorkbenchState.principal stops being         │
   │     hard-coded Slot::from(0u64)                              │
   │   • mentci-egui adds handlers for 21 of 31 UserEvent variants │
   │   • mentci-lib commits wire NewEdge / Rename / Retract /     │
   │     Batch — currently NewNode only                           │
   │   • criome's Mutate / Retract / AtomicBatch leave the        │
   │     E0099 stubs                                              │
   │   • sema gains store_at_slot(slot, bytes) for genesis        │
   │   • criome's Subscribe push gains some throttling /          │
   │     deduplication                                             │
   │                                                             │
   └─────────────────────────────────────────────────────────────┘

   ┌── MISSING CRATES / FILES ───────────────────────────────────┐
   │                                                             │
   │   • process-manager — the supervisor (per reports/114)      │
   │   • signal-derive — schema-derive proc-macros (per 115)     │
   │   • signal-arca — writers ↔ arca-daemon wire (per           │
   │     criome ARCH §3.4); referenced by forge skeleton today   │
   │   • genesis.nexus — the design graph as text seed (per 116) │
   │   • mentci-keygen — one-shot binary for the user BLS key    │
   │     (per 114 §10.1 Q8)                                      │
   │                                                             │
   └─────────────────────────────────────────────────────────────┘
```

Plus the longer-tail follow-ups: forge / arca-daemon / signal-forge
are skeleton-as-design today (todo!() bodies); their flesh comes
*after* the engine + workbench loop is exercised, not before.

§4 names the **5 highest-leverage issues** — the ones to attend to
first because they unblock everything downstream.

---

## 1 · The diff this session created, mapped to code

```
   What the design now says               What the code says today
   ──────────────────────────────────     ─────────────────────────────────

   Slot is phantom-typed Slot<T>          signal/src/slot.rs:21 — bare
   (reports/115 §2.1)                     pub struct Slot(u64)

   Schema descriptors live in a new       no signal-derive crate exists;
   signal-derive crate, emitted via       nota-derive emits NotaRecord /
   #[derive(Schema)] on every record       NotaEnum / NexusVerb /
   kind (reports/115)                     NexusPattern / NotaTransparent only

   mentci-lib reads schema from the       mentci-lib/src/schema.rs —
   compile-time catalog                    CompiledSchema methods are todo!()

   Genesis seed = the project's own       no genesis.nexus file exists;
   design as a flow-graph                  mentci-lib's handshake example
   (reports/116)                          inlines toy seed records

   process-manager supervises the          no process-manager crate exists;
   stack (reports/114)                    daemons start manually (criome-
                                          daemon &; nexus-daemon &; cargo
                                          run mentci-egui)

   Two signing keys: criome's              criome has no key bootstrap;
   capability-signing key + per-user       mentci-egui hard-codes
   BLS key (reports/114 §10.1 Q8)          Slot::from(0u64) as the
                                          principal; AuthProof::Single-
                                          Operator is the only real path

   Visuals-not-code rule for design        all reports prior to this session
   reports (AGENTS.md)                    have implementation code blocks
                                          (don't backfill at once; touch
                                          + fix as the rule says)

   Wrong-noun trap awareness               (no code consequence; doc-only)
```

Everything below is the consequence of these design moves rippling
through the codebase.

---

## 2 · Existing code that needs changing

### 2.1 The Slot phantom-typing migration

```
   ┌── files that change ──────────────────────────────────────────┐
   │                                                                │
   │  signal/src/slot.rs                                            │
   │    Slot(u64) → Slot<T>(u64, PhantomData<fn() -> T>)            │
   │    NotaTransparent derive renders as bare u64 (unchanged)      │
   │                                                                │
   │  signal/src/flow.rs                                            │
   │    Edge.from / Edge.to : Slot → Slot<Node>                     │
   │    Graph.{nodes,edges,subgraphs} : Vec<Slot> → Vec<Slot<Kind>> │
   │                                                                │
   │  signal/src/{identity,tweaks,layout,style,…}.rs                │
   │    every Slot field gets a phantom kind                        │
   │                                                                │
   │  signal/src/reply.rs                                           │
   │    Records::Node(Vec<(Slot, Node)>) →                          │
   │      Records::Node(Vec<(Slot<Node>, Node)>)                    │
   │    (the kind parameter is now redundant with the variant —     │
   │     consistency check the type system gets for free)           │
   │                                                                │
   │  criome/src/reader.rs                                          │
   │    decode_kind<T>(tag) returns Vec<(Slot<T>, T)> instead of    │
   │      Vec<(Slot, T)>                                            │
   │    sema::Slot → signal::Slot<T> conversion is monomorphic per  │
   │      kind (each find_nodes / find_edges / find_graphs knows T) │
   │                                                                │
   │  mentci-lib/src/state.rs                                       │
   │    WorkbenchState.principal : Slot → Slot<Principal>           │
   │    ModelCache fields stay homogeneous-per-kind                 │
   │                                                                │
   │  mentci-lib/src/canvas/flow_graph.rs                           │
   │    RenderedEdge.from / .to → Slot<Node>                        │
   │                                                                │
   │  signal/tests/, criome/tests/, mentci-lib/tests/               │
   │    test fixtures use the typed forms                           │
   └────────────────────────────────────────────────────────────────┘
```

Mechanical, pervasive, non-trivial. Wire format does not change —
the phantom is compile-time only; rkyv archives one u64 per Slot
exactly as before. Anyone holding an old `sema.redb` can still
read it because the on-disk bytes are unchanged.

### 2.2 The CompiledSchema implementation

mentci-lib/src/schema.rs has the trait + a `CompiledSchema` ZST
struct + `todo!()` bodies. The answer is **signal-derive**, the
durable shape per [reports/115](115-schema-derive-design-2026-04-30.md):

```
   every signal record kind gets #[derive(Schema)]
       │
       ▼
   signal exposes pub const ALL_KINDS: &[KindDescriptor]
       │
       ▼
   mentci-lib's CompiledSchema impl walks ALL_KINDS
       │
       ▼
   constructor flow surfaces real per-kind palettes
```

Until signal-derive lands, the constructor flow's kind palette
stays on its hardcoded `["Node"]` placeholder. The flow that
needs it (drag-new-box / picker-narrowing) waits. Per
[`AGENTS.md` §"No stop-gaps"](../AGENTS.md): the durable shape
is the answer; a hand-written stop-gap is not.

### 2.3 The user-identity migration in mentci-egui

```
   today                                tomorrow

   src/main.rs:43:                       src/main.rs:
     signal::Slot::from(0u64)            mentci_lib::user_identity::
                                           load_or_mint(${XDG_DATA_HOME}/
                                                        mentci/principal.bls)
                                          → returns (Slot<Principal>, BlsKey)

   mentci-lib does not sign frames;     mentci-lib signs every Frame
   AuthProof::SingleOperator is the     auth_proof with the loaded BlsKey
   only path                            (signal::AuthProof::BlsSignature{
                                          signature, signer })
```

This is a real chunk of work: BLS keypair generation, file I/O
with chmod 0600, signing per Frame, key storage layout. The
SingleOperator path keeps working for dev / first-cut; the BLS
path lands when more than one user, or when the signing surface
is exercised by forge/arca.

### 2.4 mentci-egui handlers for the missing 21 gestures

```
   UserEvent variant            handler exists in mentci-egui/src/render/?
   ──────────────────────────   ─────────────────────────────────────────
   SelectGraph                  yes (graphs_nav)
   OpenNewNodeFlow              yes (canvas + button)
   ConstructorFieldChanged      yes (constructor modal)
   ConstructorCommit / Cancel   yes
   ToggleWirePane / Tweaks      yes (header)
   PauseWire / ResumeWire        yes (wire pane)
   ClearDiagnostics             yes (diagnostics pane)
   ReconnectCriome / Nexus      yes (header chip)

   SelectSlot                   no — no inspector click handler
   PinSlot / UnpinSlot          no
   BeginDragNewBox / Update /   no — no drag-to-create gesture
     DropDragNewBox
   BeginDragWire / Update /     no — no drag-wire gesture
     DropDragWire
   MoveNode                     no — no node-drag gesture
   PanCanvas / ZoomCanvas        no — canvas is static
   ScrubTime                    no — no time-anchored kinds yet
   BeginRename / CommitRename / no — no in-place rename
     CancelRename
   RequestRetract               no — no retract button
   JumpToDiagnosticTarget       no
   SetWireFilter                no
```

Bringing the workbench up to "everything you can do via the
constructor flow has a gesture in egui" is mostly mechanical —
each gesture is a small block in a render pane. The handlers
that depend on M1 verbs (Mutate / Retract / AtomicBatch) get to
sit behind those verbs; the rest can land anytime.

### 2.5 mentci-lib constructor commit bodies

```
   constructor flow            ships today?    blocked on
   ─────────────────────       ─────────────   ─────────────────────
   NewNode                     ✓ yes            —
   NewEdge                     ✓ yes (wire)     mentci-lib commit body
                                                 (the trivial one — Assert
                                                  works today; from/to/kind
                                                  are all on the flow already)
   Rename                      ✗ no             criome's Mutate (E0099 today)
   Retract                     ✗ no             criome's Retract (E0099 today)
   Batch                       ✗ no             criome's AtomicBatch (E0099)
```

NewEdge is an honest oversight — the data is on `NewEdgeFlow`
already; the commit body is a few lines.

### 2.6 criome's Subscribe push throttling

The current implementation (criome/src/engine.rs:93-101) re-runs
**every** subscription's full query after **every** Assert and
casts the entire result set to each subscribed connection.

```
   today (works at MVP volume; doesn't scale):

     Assert(Node "X")
       → push_subscriptions:
           sub₀ (Graph wildcard) — re-query all Graphs, push      ┐
           sub₁ (Node wildcard) — re-query all Nodes, push        ├ N times
           sub₂ (Edge wildcard) — re-query all Edges, push         ┘
                                  per Assert,
                                  per connected client

   shape that scales:
     • per-kind subscriptions only re-fire when that kind is touched
     • push delta (the changed slot) instead of full snapshot
     • mentci-lib's cache treats deltas + snapshots both correctly
```

Under the design seed (19 Nodes + 28 Edges) the workbench is fine
at full-snapshot pushes. Past the first hundred records the
bandwidth cost gets visible. Worth flagging now; not blocking on.

---

## 3 · Missing pieces (entire crates / files that don't exist)

| missing piece | designed in | what it unblocks |
|---|---|---|
| **process-manager** crate | [reports/114](114-mentci-stack-supervisor-draft-2026-04-30.md) | the entire engine running as one foreground unit; auto-seed on empty sema; respawn on crash |
| **signal-derive** crate | [reports/115](115-schema-derive-design-2026-04-30.md) | mentci-lib's CompiledSchema reads real kinds/fields instead of the hand-written stop-gap; constructor flow shows real palettes |
| **signal-arca** crate | [criome ARCH §3.4](../repos/criome/ARCHITECTURE.md#3--the-wire-protocol-family) | forge → arca-daemon `Deposit` / `ReleaseToken` verbs; today forge has placeholder bodies referring to a not-yet-existent crate |
| **genesis.nexus** file | [reports/116](116-genesis-seed-as-design-graph-2026-04-30.md) | the seed pipeline has something to seed; the workbench has something to paint on first run |
| **mentci-keygen** one-shot binary | [reports/114 §10.1 Q8](114-mentci-stack-supervisor-draft-2026-04-30.md#101--resolved-by-the-principles) | per-user BLS key minting (alternative: mentci-egui's bootstrap mints inline) |

---

## 4 · The biggest unaddressed issues

Four things, in priority order. Each blocks the engine running
end-to-end as the design now says it should.

### 4.1 process-manager doesn't exist

The first-cut scope is in [reports/114 §10.3](114-mentci-stack-supervisor-draft-2026-04-30.md#103--first-cut-scope).
Without it, "the engine running" requires manual coordination of
three terminals (criome-daemon, nexus-daemon, cargo run
mentci-egui). The seed pipeline doesn't run. The directory layout
(sockets / state / keys) is improvised per agent.

The crate's first cut is small: read a config, fork some
processes, wait, restart on crash, run the seed pipeline on an
empty sema. Beauty discipline says don't ship complexity (no
swap, no watch mode); ship the clean spine.

The seed pipeline itself becomes trivial after the slot-
reservation removal: `process-manager` checks if sema has any
records via `Query(Graph wildcard)`, and if empty, pipes the
contents of `genesis.nexus` through `nexus-cli`. Records get slots
0, 1, 2, ... in `genesis.nexus` order — no special sema API
needed.

### 4.2 The Slot<T> migration

This is large but mechanical. Its absence means signal-derive is
held up too — the macro can read `T` from `Slot<T>` mechanically;
without phantom typing, it can't infer the kind without an
annotation hack the workspace has rejected.

Order matters: phantom-type Slot first; then signal-derive can
land cleanly; then mentci-lib's CompiledSchema gets real palettes.

### 4.3 Per-user identity is unimplemented

mentci-egui's `Slot::from(0u64)` is a developer-time shortcut.
Every Frame mentci-lib emits has `principal_hint: Some(Slot(0))`
and `auth_proof: Some(AuthProof::SingleOperator)`. This works
because criome accepts `SingleOperator` (peer-cred at the OS
layer) and never validates the hint.

The right shape — per Li 2026-04-30 — is **mentci owns key
management**. mentci has an interface (in mentci-egui's UI;
optionally a `mentci-keygen` one-shot for non-GUI flows) for
creating + listing + selecting + retiring user keys. The
private bytes live somewhere mentci controls.

The further direction (Li, "not a hard design decision, just an
idea"): a separate **key daemon** that holds the private bytes
in protected memory and serves signature requests over UDS. Other
processes (mentci-egui, mentci-lib's frame builder) ask the key
daemon to sign; private bytes never leave the daemon. This pairs
naturally with hardware secure enclaves once those are usable
outside corporate-guarded contexts:

```
   today                      tomorrow (key daemon)
   ─────                      ──────────────────────

   mentci-egui                mentci-egui
       │                          │
       │ loads .bls file           │ asks for signature
       │ signs Frame inline        ▼
       │                      ┌──────────────────┐
       │                      │   key-daemon     │
       │                      │                  │
       │                      │  • private bytes │
       │                      │    in protected  │
       │                      │    memory / HW   │
       │                      │    enclave       │
       │                      │  • returns BLS   │
       │                      │    signature     │
       │                      │  • signed-Frame  │
       │                      │    flows on      │
       │                      └──────────────────┘
                                       │
                                       ▼
                                  mentci-egui
                                  attaches sig,
                                  sends Frame
```

For the first-cut "engine working" milestone, the SingleOperator
shortcut is fine. The mentci key-management interface lands as
the user-identity slice does; the key daemon lands when the
private-bytes-protection requirement bites.

### 4.4 Subscribe push has a real correctness foot-gun (lower priority)

Less acute than the others, but worth naming now: every
`Reply::Records` reply from criome arrives at mentci-lib's driver
as an `EngineEvent::QueryReplied`, regardless of whether it was a
one-shot Query response or a Subscribe push. The driver doesn't
distinguish; mentci-lib's cache does an `absorb` which **replaces
the entire cached vector** for that kind.

```
   today's cache.absorb behaviour:
     Records::Node(vec) → cache.nodes = vec      ← replace, not merge

   why this is OK at MVP volume:
     • every Subscribe push pushes the FULL list of matching records
     • absorb replaces the cache; cache is now in sync
     • net effect: cache is correct after every push

   why this becomes wrong as soon as Subscribe pushes deltas:
     • a delta-style push (just the new record) would arrive as
       Records::Node(vec![just_one]); absorb would replace the
       whole cache with the single new record, losing the rest
```

Until criome's push semantics are decided + sub-id tracking is
added in mentci-lib's driver, the snapshot-style push is the
working shape. Worth a comment in the code at both ends so this
doesn't get accidentally regressed.

---

## 5 · Sequence to "engine works end-to-end"

```
   ┌─────────────────────────────────────────────────────────────────┐
   │                                                                 │
   │  step 1   process-manager skeleton:    §4.1                     │
   │           config + spawn + readiness                            │
   │           probes + tear-down                                    │
   │                                                                 │
   │  step 2   genesis.nexus written        per reports/116          │
   │           in mentci/                                            │
   │                                                                 │
   │  step 3   process-manager seed step:   §4.1 + 114 §4.2          │
   │           empty-sema check → pipe                                │
   │           genesis.nexus through                                  │
   │           nexus-cli                                              │
   │                                                                 │
   │  step 4   `nix run .#up` spawns the    end-to-end first         │
   │           full stack; mentci-egui      working state            │
   │           paints the design graph                                │
   │                                                                 │
   ├──── above this line: the engine is working ────────────────────┤
   │                                                                 │
   │  step 5   Slot<T> migration            §4.2 (mechanical)        │
   │                                                                 │
   │  step 6   signal-derive crate +        §4.2 (after Slot<T>)     │
   │           mentci-lib's CompiledSchema                            │
   │           reads ALL_KINDS                                       │
   │                                                                 │
   │  step 7   NewEdge constructor commit   §2.5 (NewEdge only;       │
   │           body in mentci-lib            Rename/Retract/Batch     │
   │                                          wait on M1)            │
   │                                                                 │
   │  step 8   mentci-egui handlers for     §2.4 (the gestures        │
   │           drag-wire / move-node / pan   not gated by M1)        │
   │           / zoom                                                │
   │                                                                 │
   │  step 9   per-user identity            §4.3 (mentci's key-       │
   │           (SingleOperator → mentci-     management interface;   │
   │            held BLS keypair)            key daemon later)       │
   │                                                                 │
   ├──── below this line: M1 work ─────────────────────────────────-┤
   │                                                                 │
   │  step 10  criome Mutate / Retract /    unblocks Rename +        │
   │           AtomicBatch                  Retract + Batch flows    │
   │                                                                 │
   │  step 11  Subscribe push delta /        §4.4 (the foot-gun)     │
   │           sub-id tracking in the driver                         │
   │                                                                 │
   └─────────────────────────────────────────────────────────────────┘
```

Steps 1 → 4 land "engine working end-to-end with the design seed
visible." That's the milestone testing should target per Li
2026-04-30 ("let's start testing a working engine first").
Everything below is incremental.

---

## 6 · Open shapes — resolved during this round

**Q1 — sema slot reservation.** Removed. Per Li 2026-04-30: the
`SEED_RANGE_END = 1024` reservation was an agent's reach for
"nice structure" that didn't make anything more beautiful,
elegant, or correct. Beauty rule applied: removed it. sema's
counter now starts at 0; genesis records get slots 0, 1, 2, ...
in `genesis.nexus` order; no special sema API needed; the
seed-pipeline gap dissolves.

**Q2 — CompiledSchema stop-gap.** Withdrawn. Per Li 2026-04-30
+ [`AGENTS.md` §"No stop-gaps"](../AGENTS.md): proposing a
hand-written stop-gap to replace later violates INTENTION.md
("Not for 'iterate later'"). The right shape is signal-derive;
the constructor flow's real kind palette waits on that crate.
Building the stop-gap means writing throwaway code — what looks
like progress is regression measured against INTENTION's "right
shape now."

**Q3 — Per-user BLS keypair.** Mentci owns key management. An
interface in mentci (UI in mentci-egui; optionally a
`mentci-keygen` one-shot) for creating, listing, selecting, and
retiring user keys. The further direction — a separate key
daemon holding private bytes in protected memory / HW enclave,
serving signature requests over UDS — is sketched in §4.3 as the
shape that pairs with secure-hardware-enclave integration when
that surface becomes usable.

---

*End report 117.*
