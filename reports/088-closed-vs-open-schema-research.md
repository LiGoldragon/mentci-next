# 088 — Closed-vs-open schema: research synthesis

*Three parallel research streams (wire formats, database/event
systems, type-theory/language-design) — all converged on a
sharper answer than I had when starting. Companion to 087
(M0 plan with Q1 still open about typed→RawRecord conversion).*

User's expressed vision (2026-04-27): *"that is not what I
envisioned. To me, everything was totally pre-typed."*

This report situates that vision in the design space, then
sharpens what "totally pre-typed" should mean concretely.

---

## 1 · The spectrum

```
   FULLY CLOSED                                       FULLY OPEN
   ─────────────                                      ──────────
   TigerBeetle   ──┐
   Cap'n Proto   ──┤  closed enum at the binary;
   FlatBuffers   ──┤  schema change = recompile +
   rkyv          ──┤  redeploy every consumer
   borsh         ──┘
   Postgres      ────  closed catalog + queryable
                       information_schema (hybrid)
   GraphQL       ────  closed schema + __schema introspection
   Avro+Registry ────  closed-per-message; schema-by-ID;
                       compat rules at registry boundary
   Datomic       ────  closed type primitives; open attributes
                       as data; bitemporal schema-of-yesterday
   Protobuf+Any  ────  closed core + Any{type_url, bytes} valve
   EDN           ────  open via #tagged literals; preserve unknowns
   MongoDB       ────  per-document open (drifted toward typing)
   RDF/JSON-LD   ──┐
   CBOR untyped  ──┘  fully self-describing; no shared schema
```

Today's [`signal::value::RawRecord`](../repos/signal/src/value.rs)
sits at "EDN-shaped" — string kind_name + named field map.
The user's "totally pre-typed" vision is at the
TigerBeetle/Cap'n Proto end.

---

## 2 · The structural finding (all three agents converged)

> The systems that suffered most are the ones that picked a
> side and refused to admit the dual: pure-Mongo before
> validators (open without discipline), pure-typed event
> sourcing without upcasters (closed without escape hatch).
> The systems that thrived split the boundary cleanly:
> Datomic, Avro+Registry, Postgres+catalog. *That split is
> the design move worth importing.*

The recurring **"closed primitives + open content"** pattern:

- **Datomic.** Type primitives (`:db.type/string`,
  `:db.cardinality/many`, `:db.unique/identity`) are a small
  closed enum the engine knows exhaustively. Specific
  attributes (`:user/email`, `:order/items`) are records
  *in* the database — added by transactions, queryable
  bitemporally as data.
- **Postgres.** Type system closed. Catalog tables
  (`pg_class`, `pg_attribute`) are queryable SQL — schema
  IS data, but the *kinds* of things schemas can declare are
  fixed.
- **GraphQL.** Closed type system per server, exposed via
  `__schema` introspection.
- **Avro + Schema Registry.** Wire is typed against a
  schema; the schema is data with an ID; compat rules
  enforce evolution at registry-write time.

The pattern in one line: **the engine's structural vocabulary
is closed; the user-defined types it composes are data.**

---

## 3 · The Expression Problem (Wadler 1998 / Reynolds 1975)

The unavoidable triangle:

```
        STATIC EXHAUSTIVENESS
          (exhaustive match)
                  │
                  │
                  ●  ◄── closed Rust enum
                 / \
                /   \
               /     \
              /       \
             /         \
            ●           ●  ◄── open dynamic kinds
   row poly /            \
            /             \
           ──────────────────
   MODULAR SEPARATE        LATE EXTENSIBILITY
   COMPILATION             (add a kind without
                            touching consumers)
```

You can have any two; you give up the third. Closed enum
gets exhaustiveness + modular compilation, costs late
extensibility. Open dynamic gets late extensibility +
modular compilation, costs exhaustiveness. Type classes /
multimethods (CLOS, Julia) get exhaustiveness + late
extensibility, cost modular compilation (orphan-instance
problem; global method table coherence).

For a self-hosting engine where the consumer ecosystem is
controlled by one author and the build is one repo, the
"modular separate compilation" requirement is **soft**.
That weakens the case for the dynamic-kinds option a lot.

---

## 4 · Self-hosting closes the closure

The "openness because federation" argument vanishes for a
single-author system. But there is a stronger property: the
**closed enum IS the projection of schema-records by rsc**.
The loop:

```
  ┌─────────────────────────────────────────────────────┐
  │ Adding a new record kind                            │
  ├─────────────────────────────────────────────────────┤
  │                                                     │
  │  1. user asserts a KindDecl record into sema:       │
  │     (KindDecl "Hyperedge"                           │
  │       [(FieldDecl members [Slot])                   │
  │        (FieldDecl weight  Float)])                  │
  │                                                     │
  │  2. user issues a Compile request against the       │
  │     signal opus                                     │
  │                                                     │
  │  3. criome reads Opus + KindDecl records from sema  │
  │     dispatches RunNix to lojix                      │
  │                                                     │
  │  4. rsc projects KindDecl records → Rust source:    │
  │       pub struct Hyperedge {                        │
  │           pub members: Vec<Slot>,                   │
  │           pub weight: f64,                          │
  │       }                                             │
  │       pub enum KnownRecord {                        │
  │           Node(Node), Edge(Edge), Graph(Graph),     │
  │           Hyperedge(Hyperedge),  // ← new           │
  │       }                                             │
  │                                                     │
  │  5. nix builds new criome binary; new signal crate  │
  │     has the variant                                 │
  │                                                     │
  │  6. user runs the new binary; can now assert        │
  │     Hyperedge records                               │
  │                                                     │
  └─────────────────────────────────────────────────────┘
```

This is what the criome architecture already describes
([criome/ARCHITECTURE.md §7 "Compile + self-host loop"](../repos/criome/ARCHITECTURE.md))
applied specifically to *schema*. The closed enum isn't a
constraint — it's a projection of the KindDecl records that
already live in sema. Every build regenerates it.

Smalltalk-72, Self, image-based Lisp had the same property:
the metasystem is reachable. They could afford rigid type
systems because the schema editor (themselves) lives inside
the system. Here the schema editor is a record in sema.

**This means closed enum + KindDecl-as-data is not a hybrid
or compromise.** It's two views of the same schema: one for
the running binary's compiler-checked dispatch, one for
queryable / editable / bitemporal access. rsc is the
projection function between them.

---

## 5 · "Totally pre-typed" — the recommendation

The literature converges on **closed enum at the wire**,
with one synthesis layer: **schema-as-data records** that
DESCRIBE the closed kinds, queryable for tooling and
introspection but not load-bearing for runtime dispatch.

```rust
// signal/src/lib.rs — the closed wire enum

pub enum KnownRecord {
    Node(Node),
    Edge(Edge),
    Graph(Graph),
    // grow as kinds are added; this enum IS the schema
}

pub struct AssertOp { pub record: KnownRecord }
pub struct MutateOp {
    pub slot: Slot,
    pub new_record: KnownRecord,
    pub expected_rev: Option<Revision>,
}
// RetractOp unchanged (slot identifies)

// Reply::Records carries Vec<KnownRecord> — typed end-to-end.
```

**What dies:**

- [`signal::value::RawRecord`](../repos/signal/src/value.rs)
  + `RawValue` + `RawLiteral` + `FieldPath` + `RawSegment`
- [`signal::pattern::RawPattern`](../repos/signal/src/pattern.rs)
  + `RawListPattern` + `FieldConstraint`
- [`signal::query::RawOp`](../repos/signal/src/query.rs)
  + `RawProjection` + `RawProjField` (probably; see §6)
- The KindDecl-record genesis story — kinds are baked into
  signal::KnownRecord, not declared at runtime
- Q1 (typed→RawRecord conversion) — gone; daemon parses
  text → typed `Node` → wraps `KnownRecord::Node(node)`
  directly
- Q2 (schema-check rigour) — collapses; rkyv decode IS the
  validation. Wrong shape = decode error
- Q6 (reply rendering) — typed values render via
  nota-serde-core directly

**What replaces it:**

- A handful of typed kinds in [`signal/src/`](../repos/signal/src/)
  (Node, Edge, Graph today; KindDecl, ChangeLogEntry, Opus,
  etc. as the schema grows)
- The `KnownRecord` enum at the top of signal (or
  per-verb if we don't want the wrapping enum — see §6)
- For queries: per-kind typed patterns (see §6)

---

## 6 · A query is just another kind — and verbs are typed per-kind

Asserts: `(Node "User")` becomes `Node { name: "User" }`,
delivered as `AssertOp::Node(node)`.

Queries: `(| Node @name |)` is a *NodeQuery* record. Per
Li 2026-04-27 *("isn't that query just another kind?")* —
yes. The pattern/query isn't a meta-construct alongside
the kind; it's a first-class record kind paired with its
instance kind, generated from the same KindDecl by rsc.

```rust
// The KindDecl declares both shapes; rsc generates both:

pub struct Node {
    pub name: String,
}

pub struct NodeQuery {
    pub name: PatternField<String>,
}

pub enum PatternField<T> {
    Wildcard,            // _
    Bind(String),        // @name (capture into a bind)
    Match(T),            // literal value to match equality
}
```

Per-verb, per-kind. No wrapping `KnownRecord` enum exists
at all — each verb's payload type is itself an enum of
typed variants (perfect specificity, §10):

```rust
// signal/edit.rs
pub enum AssertOp {
    Node(Node),
    Edge(Edge),
    Graph(Graph),
    KindDecl(KindDecl),
}

pub enum MutateOp {
    Node    { slot: Slot, new: Node,     expected_rev: Option<Revision> },
    Edge    { slot: Slot, new: Edge,     expected_rev: Option<Revision> },
    Graph   { slot: Slot, new: Graph,    expected_rev: Option<Revision> },
    KindDecl{ slot: Slot, new: KindDecl, expected_rev: Option<Revision> },
}

pub struct RetractOp {           // unchanged — slot identifies; no per-kind variants
    pub slot: Slot,
    pub expected_rev: Option<Revision>,
}

// signal/query.rs
pub enum QueryOp {
    Node(NodeQuery),
    Edge(EdgeQuery),
    Graph(GraphQuery),
    KindDecl(KindDeclQuery),
}

// signal/reply.rs
pub enum Records {              // a query targets one kind; the reply is typed
    Node(Vec<Node>),
    Edge(Vec<Edge>),
    Graph(Vec<Graph>),
    KindDecl(Vec<KindDecl>),
}

// signal/edit.rs — atomic batches stay per-verb
pub struct AtomicBatch {
    pub ops: Vec<BatchOp>,
}

pub enum BatchOp {
    Assert(AssertOp),
    Mutate(MutateOp),
    Retract(RetractOp),
}
```

The grammar dispatches by delimiter and verb sigil:

```
( ... )      → AssertOp variant       e.g. AssertOp::Node(node)
(| ... |)    → QueryOp variant        e.g. QueryOp::Node(NodeQuery{…})
~( ... )     → MutateOp variant       e.g. MutateOp::Node{slot, new, …}
!slot        → RetractOp{slot, …}
```

Records reply is typed too: a Node query gets back
`Records::Node(Vec<Node>)`, not a heterogeneous list.
Consumers `match` on the reply type and know the element
shape without dispatch.

For M0 we hand-write 4 KindDecls (KindDecl + Node + Edge +
Graph) and 4 query kinds (paired). rsc generates them
post-M0.

---

## 7 · No `Unknown` escape hatch

Decision (Li 2026-04-27): no. The closed enum stays
exhaustively closed. Self-hosting + single-author + the §4
loop means version skew doesn't happen — rebuilds bring
the whole world forward together. The escape hatch would
add a noise variant to every match for zero benefit.

---

## 8 · What this changes in M0

The 087 plan (~560 LoC, with KindDecl genesis, RawRecord
reflect helper, dynamic schema-check) reduces to roughly:

| # | What | LoC |
|---|------|-----|
| 1 | sema redb store/get + slot counter | ~50 |
| 2 | criome validator: rkyv decode IS the schema check | ~10 |
| 3 | criome write: encode KnownRecord; sema.store | ~25 |
| 4 | criome UDS accept loop + dispatch on Request | ~80 |
| 5 | nexus daemon: text → typed → KnownRecord wrap | ~70 |
| 6 | nexus-cli text shuttle | ~30 |
| 7 | parser: LParenPipe / LBrace / LBracePipe deserializer paths; LParenPipe dispatches to the matching `*Query` variant | ~120 |
| 8 | KnownRecord enum (KindDecl + 3 instance kinds + 3 query kinds = 7 variants) | ~100 |
| 9 | bootstrap genesis.nexus seeding the 7 KindDecl records | ~30 |
|   | **Total** | **~495** |

Down from ~560 in 087. Genesis text file stays (now
seeding KindDecl records, not validation rules); the
typed→RawRecord reflect helper is gone; criome validator
is mostly rkyv decode.

---

## 9 · KindDecl is foundational, not deferred

Per §4 the closed enum is rsc's projection of `KindDecl`
records. So `KindDecl` is the canonical schema source; the
closed enum is the in-binary view.

```rust
// signal::schema  (canonical schema kind)
pub struct KindDecl {
    pub name: String,            // "Node"
    pub fields: Vec<FieldDecl>,
}
pub struct FieldDecl {
    pub name: String,            // "name"
    pub type_name: String,       // "String", "Slot", "Vec<Slot>", "RelationKind", …
    pub cardinality: Cardinality,
}
pub enum Cardinality { One, Many, Optional }
```

KindDecl is itself a `KnownRecord` variant. Bootstrapping:

```rust
pub enum KnownRecord {
    KindDecl(KindDecl),    // ← itself a kind, by KindDecl
    Node(Node),
    Edge(Edge),
    Graph(Graph),
}
```

The bootstrap KindDecls — the records describing Node /
Edge / Graph / KindDecl itself — are part of `genesis.nexus`
shipped with criome. First boot dispatches them through the
normal Assert path; sema gets seeded; subsequent kind
additions go through the §4 loop.

**M0 status:** rsc isn't ready, so the closed enum is
hand-written in [`../repos/signal/src/`](../repos/signal/src/)
rather than projected. genesis.nexus seeds the corresponding
KindDecl records so the schema-as-data view exists from
boot. **This is the bootstrap state — not the long-term
design.** When rsc lands (M2+), the loop closes: edit a
KindDecl record, recompile, the new variant is in the
binary.

---

## 10 · Decision

**Recommendation: adopt "totally pre-typed" as the user
described it, in the closed-enum-at-wire form.**

- Drop RawRecord, RawValue, RawLiteral, RawPattern from
  signal
- Add `signal::KnownRecord` closed enum (Node | Edge | Graph
  for M0; grows by editing signal)
- Per-kind typed patterns for queries
- No `Unknown` escape hatch
- Schema-as-data (KindDecl records) deferred to post-M0
  introspection

This eliminates Q1, Q2, Q6 from 087. M0 LoC drops from
~560 to ~465. The whole "typed→RawRecord reflection"
problem dissolves.

**Costs we take on:**

- Adding a kind = asserting a KindDecl + recompiling
  (M2+ via rsc; M0/M1 hand-edits Rust source). The loop
  is the same; rsc just automates step 4.
- Pattern types are per-kind verbose. rsc projection will
  generate them too once it lands.
- No federation story. Acceptable until external
  signal-speaking peers exist.

---

## 11 · Decision: per-verb variants, no wrapping enum

Per Li 2026-04-27. Each verb's payload type is itself a
closed enum of typed kinds — no shared `KnownRecord`
indirection. AssertOp is an enum of typed asserts;
MutateOp is an enum of typed mutates (each variant
carries `slot + new + expected_rev`); QueryOp is an enum
of typed queries; Records is an enum of typed result
sequences.

**Why per-verb wins:** different verbs need different
field shapes per kind. MutateOp::Node carries
`{slot, new: Node, expected_rev}`; an Assert just carries
`Node`. A wrapping `KnownRecord` would force MutateOp to
look like `{slot, new: KnownRecord, expected_rev}` — losing
the per-kind expected_rev semantics in the type system and
forcing a runtime match where the wire could have carried
specificity. Per-verb keeps every payload precisely the
shape it actually needs.

This is the **perfect specificity** principle — see §12.

---

## 12 · The principle, named — perfect specificity

The cumulative architecture point named explicitly:

> **Perfect specificity.** Every typed boundary in the
> system names exactly what flows through it. No
> wrapper enums that mix concerns; no string-tagged
> dynamic dispatch; no generic-record fallback. Each
> verb's payload type is the precise shape it operates
> on. KindDecl is itself a kind; the schema is data;
> the typed code is its projection.

This principle is what generates all the §1-§11 decisions:
- closed enum at the wire (no string-tagged dynamic)
- per-verb payload types (no wrapping `KnownRecord`)
- query-as-kind (no parallel pattern enum)
- no `Unknown` escape hatch (no generic fallback)
- typed Records reply per kind (no heterogeneous result list)

Documented as Invariant D in
[`../repos/criome/ARCHITECTURE.md`](../repos/criome/ARCHITECTURE.md)
§2 — and echoed in each subsystem's arch doc in its own
voice (signal, nexus, sema).

---

*End 088.*
