# 067 — what to implement next: rung-1 lock proposal

*Claude Opus 4.7 · 2026-04-25 · synthesis of three parallel
research agents (open-questions inventory, design proposals,
code proposals) under the rung-by-rung framing established
in reports 064 and 065. Recommends a path: answer three
blocking Li decisions; then land rung-1 design as skeleton-
as-design code across five repos in parallel; then author
`genesis.nexus`; then smoke-test the loop. ~1500–2500 LoC.*

---

## 1 · Where we are

The framing is settled (reports 064-066 + bd memories +
architecture.md §10): bootstrap is rung-by-rung; records
enter sema only via nexus → nexusd → criome-msg → criomed;
multi-process from day one; **machina** is the code category
name; `criome-schema` is the crate-name candidate for
criomed's operational-state records; genesis-via-nexus is
the only seed-delivery path.

State of code: **nota-serde-core** (1620 LoC, complete),
**nexus-schema** (499 LoC types-only), **nexus-serde** /
**nota-serde** (façades, complete), **lojix-store** (430
LoC skeleton-as-design exemplar), **lojix** (820 LoC
production monolith — preserve), **horizon-rs** (1780 LoC
production), **CriomOS** running. **sema**, **rsc**,
**nexusd**, **nexus-cli** are all stubs. **criome-msg**,
**criome-schema**, **lojix-msg**, **criomed**, **lojixd**
are CANON-MISSING.

Rung 1's success criterion (per [reports/064 §2.2](repos/mentci-next/reports/064-bootstrap-as-iterative-competence.md)):
the user runs `nexus-cli '(Query (KindDecl :name "KindDecl"))'`
and receives back the seed `KindDecl`-of-`KindDecl` record.

---

## 2 · Three blocking Li decisions

Open-questions inventory across reports 061, 064, 065
identified 16 questions. Most are directional. Three are
**blocking** for the next concrete piece of work:

### Q-α · Seed delivery (was [reports/064 Q1](repos/mentci-next/reports/064-bootstrap-as-iterative-competence.md))

Two options canvased:
- (A) Seed records as rkyv data baked into criomed's
  binary; criomed asserts them at first boot through the
  validator pipeline.
- (C) Seed records as nexus text in a `genesis.nexus`
  file shipping with criomed; criomed dispatches the file
  to nexusd at first boot; everything goes through the
  normal request flow.

Li 2026-04-25 ratified the *principle* "bootstrap rung by
rung; populate via nexus messages." Option (A) violates
that principle by introducing a parallel input path. **(C)
is the only option consistent with Li's standing rules.**
This is effectively answered by the rung-by-rung rule, but
worth ratifying explicitly so the implementing agent
doesn't backslide.

### Q-β · Stage A kind set (was [reports/064 Q2](repos/mentci-next/reports/064-bootstrap-as-iterative-competence.md))

Beyond schema-of-schema (`KindDecl`, `FieldSpec`,
`TypeRef`), what's the minimum kind set for criomed to
validate "user asserts a new `KindDecl`" at Stage B?

Research-agent recommendation (~15 kinds for v0.0.1):

- **Schema-of-schema**: `KindDecl`, `FieldSpec`, `TypeRef`,
  `VariantDecl`, `CategoryDecl`
- **Slot/index**: `Slot`, `Revision`, `SlotBinding`,
  `SemaGenesis`
- **Audit**: `ChangeLogEntry` (one per write)
- **Authz (degenerate at rung 1)**: `Principal`, `Quorum`,
  `Policy`
- **Supporting literals**: `LiteralValue`, `PrimitiveType`,
  `CollectionKind`, `StabilityTag`, `FieldVisibility`,
  `ChangeOp`, `Op`

Explicitly **deferred** to later rungs: `Capability`,
`CapabilityToken`, `MutationProposal`, `ProposalSignature`,
`CommittedMutation`, `RuntimeIdentity`, `PrincipalKey`,
`Rule`, `RulePremise`, `RuleHead`, `Invariant`,
`DerivedFrom`, `Diagnostic` (yes — reply-only, not a sema
kind yet), `Outcome`, `CompilesCleanly`,
`CompileDiagnostic`, `SubscriptionIntent`, `Subscriber`,
`Pattern` (the kind), `Query` (the kind),
`ConstraintDecl::ForeignKey/Range/Regex`,
`RevisionRecord`, `AuditEntry`, `DiagnosticSuggestion`.

Li to confirm or revise the ~15-kind list.

### Q-γ · Genesis principal mechanism (was [reports/065 Q2](repos/mentci-next/reports/065-criome-schema-design.md))

During the genesis stream, before any `Principal` record
exists in sema, criomed needs a principal for permission-
check on each genesis assertion. Two options:

- (a) Hardcoded **bootstrap-principal-id** in criomed's
  binary, used for every assertion in the genesis stream.
  Retired the moment `SemaGenesis` lands.
- (b) **First-message-bypasses-permission-check** — the
  first message in `genesis.nexus` is `(Assert (Principal
  ...))`; subsequent messages claim that Principal.

(a) names the special case clearly and keeps the validator
state-free during genesis. (b) reduces specialness slightly
but introduces a "first-message-special" rule. Research-
agent lean: (a). Li to confirm or override.

---

## 3 · The rung-1 design lock (what to land as design)

Once Q-α, Q-β, Q-γ are answered, the design content lands
as **skeleton-as-design code** (per the architecture.md
rule: "compiler-checked types beat prose"). Five repos
become the design surface, each in parallel:

| Repo | What lands | Anchor |
|---|---|---|
| `criome-schema` (CREATE) | Rust struct/enum types for the ~15 v0.0.1 kinds | report/065 §3 subset |
| `criome-msg` (CREATE) | `Request::{Assert, Query, Retract}` + `Reply::{Ok, QueryHit, Rejected}` + `Frame { correlation_id, body }` | this report §3.1 |
| `criomed` (CREATE) | `main` boot loop; UDS listener; validator pipeline trait + 5 step-stubs; sema redb open; genesis dispatcher | this report §3.3 |
| `nexusd` (CREATE) | `main` UDS listener; nota-serde-core parser at Dialect::Nexus; criome-msg envelope build; criomed UDS client | this report §3.4 |
| `nexus-cli` (extend stub) | Argv/stdin parser; UDS client to nexusd; reply printer | small |

Plus one non-Rust artefact:

| File | What lands | Anchor |
|---|---|---|
| `criomed/genesis.nexus` | ~15-30 `(Assert ...)` lines in nexus text — declares the seed kinds, then the bootstrap Principal/Quorum/Policy, then the `SemaGenesis` marker | this report §3.2 |

### 3.1 · `criome-msg` v0.0.1 envelope shape (rkyv-archived)

```rust
pub struct Frame { pub correlation_id: u64, pub body: Body }
pub enum   Body  { Request(Request), Reply(Reply) }

pub enum Request {
    Assert  { record: RawRecord, principal_hint: Option<u64> },
    Query   { kind_name: String, field_eq: Vec<(String, LiteralValue)> },
    Retract { slot: Slot },
}

pub enum Reply {
    Ok       { slot: Slot, rev: Revision },
    QueryHit { records: Vec<RawRecord> },
    Rejected { code: String, message: String, site: Option<Slot> },
}

pub struct RawRecord {
    pub kind_name: String,
    pub fields: Vec<(String, RawValue)>,
}
pub enum RawValue {
    Lit(LiteralValue), SlotRef(u64), List(Vec<RawValue>), Record(Box<RawRecord>),
}
```

Wire: UDS + 4-byte BE length-prefixed rkyv frames. Three
verbs only at v0.0.1; `Mutate`, `Subscribe`, `Compile` are
deferred to later rungs.

### 3.2 · `genesis.nexus` content sketch

```nexus
;; 1. Categories
(Assert (CategoryDecl :slot 0 :name "criomed-state"
                      :stratum-max 1 :visibility SeedOnly))

;; 2. Schema-of-schema (each KindDecl describes a kind)
(Assert (KindDecl :slot 2 :name "KindDecl"     :category 0 ...))
(Assert (KindDecl :slot 3 :name "FieldSpec"    :category 0 ...))
(Assert (KindDecl :slot 4 :name "TypeRef"      :category 0 :is-sum true ...))
(Assert (KindDecl :slot 5 :name "CategoryDecl" :category 0 ...))
(Assert (KindDecl :slot 6 :name "VariantDecl"  :category 0 ...))

;; 3. Identity / index kinds
(Assert (KindDecl :slot 7 :name "SlotBinding"     :category 0 ...))
(Assert (KindDecl :slot 8 :name "ChangeLogEntry"  :category 0 ...))
(Assert (KindDecl :slot 9 :name "SemaGenesis"    :category 0 ...))

;; 4. Authz kinds (records exist; verification degenerate at rung 1)
(Assert (KindDecl :slot 10 :name "Principal"  :category 0 ...))
(Assert (KindDecl :slot 11 :name "Quorum"     :category 0 ...))
(Assert (KindDecl :slot 12 :name "Policy"     :category 0 ...))

;; 5. The bootstrap principal (Q-γ option (a) — id matches a hardcoded
;;    constant in criomed's binary used during the genesis stream)
(Assert (Principal :slot 100 :pubkey #x00 :display-name "bootstrap"
                   :valid-from-rev 0))
(Assert (Quorum    :slot 101 :members [100] :threshold 1
                   :display-name "bootstrap-quorum"))
(Assert (Policy    :slot 102 :resource-pattern :all
                   :allowed-ops [Assert Query Retract]
                   :required-quorum 101))

;; 6. Terminal marker — flips criomed to normal mode
(Assert (SemaGenesis :slot 1 :marker #xDEADBEEF :created-at 0
                     :criomed-version "0.0.1"))
```

This is the *fixed point*: every kind referenced by any
record above is declared above. ~15-25 records, not the
60-120 the earlier sketch in report/065 implied.

### 3.3 · Validator pipeline at rung 1 (criomed)

For each `Request::Assert { record: R, principal_hint: h }`:

1. **Decode.** rkyv-archived `Frame` → typed
   `Request::Assert {R, h}`. Reject malformed bytes with
   `Reply::Rejected{code:"E0000",..}`.
2. **Schema-check.** Look up `KindDecl` for `R.kind_name`.
   *First-boot specific:* if no in-sema KindDecl exists for
   that name yet, fall back to a built-in Rust dispatch
   table (the criome-schema Rust types). Reject `E0001
   SchemaViolation` if name unknown. For each declared
   `FieldSpec`: confirm `(name, value)` present in
   `R.fields`; confirm `value` is shape-compatible with
   declared `TypeRef`.
3. **Ref-check.** For each `RawValue::SlotRef(s)`, look up
   `s` in the in-memory `SlotBinding` map (populated as
   genesis records land in order); reject `E0002` if
   absent. genesis.nexus ordered so refs only point
   backward.
4. **Invariant-check.** No `Rule` records loaded → trivially
   passes.
5. **Permission-check.** principal id from `h` (or hardcoded
   bootstrap id during genesis stream) compared against
   `Policy` records. At rung 1: one Policy (slot 102)
   allows {Assert, Query, Retract} for the bootstrap
   quorum. Pass.
6. **Write.** Compute blake3 of canonical rkyv encoding.
   Allocate slot (genesis carries `:slot N` explicitly;
   user requests get fresh slots from counter ≥ 1024).
   One redb transaction: kind-table write, SlotBinding
   write, ChangeLogEntry append, revision counter
   increment.
7. **Reply** `Reply::Ok { slot, rev }`.
8. **Cascade.** No Rule records → no work.

For `Request::Query`: skip 2-7; iterate kind-table for
`kind_name`, filter by `field_eq`, return `Reply::QueryHit`.

Every step has a concrete mechanism. No hand-waves. The
"first-boot specifics" (built-in Rust types in step 2;
hardcoded bootstrap id in step 5) fall away naturally as
the genesis stream completes — both reduce to "look up
in-sema record" once those records exist.

### 3.4 · nexusd at rung 1

- Tokio runtime; UDS listener at well-known socket path.
- For each accepted text request: `nota_serde_core::parse(text,
  Dialect::Nexus)` → AST. Map top-level `(Assert/Query/Retract …)`
  forms to `criome-msg::Request` envelopes; reject any
  other top-level form with a syntax error.
- Open UDS client to criomed; send rkyv-archived `Frame`;
  await `Frame` reply; serialise reply back to nexus text.
- Stateless modulo in-flight `correlation_id`.

### 3.5 · Nexus syntax subset for rung 1

```
Top-level form:        ( <RequestVerb> <body> )
                        verb ∈ {Assert, Query, Retract}
Record construction:   ( <KindName> :field-name <value> ... )
                        keyword form only
Values:                literals (Int, UInt, Float, Bool, Str, Bytes via #),
                        Ident, list [ ... ], nested ( <Kind> ... )
Slot literal in body:  bare Int treated as Slot when FieldSpec.type_ref
                        is TypeRef::Named(<slot>)
Comment:               ;; to end of line
```

Excluded (lexer accepts them but rung-1 parser rejects):
`~`, `@`, `!`, `=`, `{ }`, `{| |}`, `[ ]` as pattern
form, `< >`, `<| |>`, `(|| ||)`, `{|| ||}`, positional
record construction.

---

## 4 · Sequencing

```
Step 0: Li answers Q-α + Q-β + Q-γ.

Step 1: criome-schema (CREATE; ~250-400 LoC types)
        ── lock the ~15 kinds; rkyv + serde derives.

Step 2 || Step 3 || Step 4 in parallel:
   Step 2: criome-msg (CREATE; ~150-250 LoC envelope types)
   Step 3: sema crate scaffold (~250-400 LoC redb tables;
            SemaWrite trait; ChangeLogEntry append; SlotBinding index)
   Step 4: nexus-cli (extend stub; ~100-150 LoC)

Step 5 || Step 6 in parallel:
   Step 5: criomed (CREATE; ~400-600 LoC: main, UDS listener,
            validator pipeline, genesis dispatcher)
   Step 6: nexusd (extend stub; ~300-500 LoC: UDS listener,
            parser, criomed client)

Step 7: Author criomed/genesis.nexus
        (~50-100 lines of nexus text per §3.2 sketch)

Step 8: Smoke test rung-1 success criterion.

Total LoC: ~1500-2500.
```

Steps 2-4 are CANON-MISSING crate creations or stub
extensions; they don't depend on each other beyond shared
type imports from criome-schema (Step 1). Steps 5-6 are
the daemons; both can land in parallel because their
contracts are nailed by Steps 1-2.

---

## 5 · What's NOT in rung 1 (loud rejection list)

To prevent constraint-collapse contamination, the things
explicitly **not** in rung 1:

- **No `Mutate` / `Subscribe` / `Compile` verbs.** Rung 2+.
- **No rules / cascades.** Stage D.
- **No capability tokens / BLS verification / multi-
  principal.** Stage E. (The records `Principal`, `Quorum`,
  `Policy` exist at rung 1 but only the degenerate
  single-bootstrap-principal flow runs.)
- **No `Diagnostic` as sema kind.** Rejection codes ride
  in `Reply::Rejected`'s `code: String` for now; sema-side
  Diagnostic kinds land at Stage B+.
- **No `Pattern` / `Query` as sema kinds.** Patterns are
  in-flight only via criome-msg `Request::Query`'s simple
  field-eq form.
- **No lojixd / lojix-msg / rsc bodies / lojix-store
  bodies.** Stage F. lojix-store stays as the skeleton-as-
  design exemplar; rsc stays a stub; lojixd is uncreated.
- **No machina-chk.** Stage H+.
- **No nexus-schema rename to machina-schema.** Defer
  ([reports/065 Q1](repos/mentci-next/reports/065-criome-schema-design.md)).
  When categories want their own crates, the rename is
  trivial; until then, current name is fine.
- **No federation, cross-criomed interaction primitives,
  world-fact records.** Post-MVP.

---

## 6 · Three concrete questions for Li

These are the Q-α/β/γ from §2, restated for clarity:

### Q1 · Confirm seed delivery is `genesis.nexus` (not baked-in)

Per the rung-by-rung rule and Li's standing correction
("we would just abandon the bottom-rung layer, nexus?")
this is effectively settled. Confirming explicitly stops
future agents from rediscovering the baked-in option.

### Q2 · Confirm or revise the ~15-kind v0.0.1 set

Listed in §2 Q-β. Two ways Li might revise: (a) trim
further (e.g., merge `Quorum` into `Policy.required_quorum
= List<Slot<Principal>>`, dropping a kind); (b) add (e.g.,
include `Diagnostic` from day one if you want
machine-readable rejection records right away).

### Q3 · Confirm hardcoded bootstrap-principal-id (option a)

Versus first-record-as-self bypass (option b). Research-
agent lean is (a) for cleanliness. Li override welcome.

---

## 7 · One observation

The shape of "what to implement next" is:

> *Three short Li answers, then ~2000 LoC of skeleton-as-
> design code across five repo creations + stubs, then a
> ~50-line nexus text file, then a smoke test.*

Almost all the design work is already done — across reports
064, 065, and the cross-cutting framing established in 061
+ architecture.md §10. The remaining design lives in the
type signatures of the five new crates, where rustc will
catch drift; not in more prose. After Q1-Q3, the agents
implementing have a concrete spec.

---

*End report 067.*
