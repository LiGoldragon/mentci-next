# 026 — sema holds code as logic, not text — corrected synthesis

*Claude Opus 4.7 / 2026-04-24 · Li's correction after first-pass
reports 023/024/025: "sema doesnt give a fuck about tokenstream;
it has a fully specified view of code. not text; logic!" This
report synthesises the whole architecture under the correct
framing. Supersedes the text-layer contamination in 023/024/025.*

---

## 1 · The fundamental invariant

**Sema holds code as fully-specified logic. Text is never a sema
input.** The records in sema are `Fn`, `Struct`, `Enum`, `Module`,
`Program`, `Expr`, `Statement`, `Pattern`, `Type`, `Signature`,
`TraitDecl`, `TraitImpl`, `ImplBlock` — already-parsed, already-
name-resolved, schema-bound structural records. There is no
`SourceRecord`; there is no `TokenStream`; there is no `Ast` as a
separate record kind.

This is the shape [report 004](004-sema-types-for-rust.md) always
assumed. Reports 023, 024, 025 drifted into a rust-analyzer-style
"source file as the input; cascade derivations cache the AST and
name resolution" framing. That's wrong. Sema is not a cache over
text. Sema is the origin — the canonical representation of code.
Text appears only when rsc projects records to `.rs` because
rustc needs bytes to read.

The flow is:

```
 sema (records)
     │
     │  rsc (records → .rs projector; lossy direction: records carry
     │       more than text; text can always be regenerated)
     ▼
 .rs text (on-disk scratch; ephemeral; emitted for rustc)
     │
     │  rustc
     ▼
 binary (into lojix-store)
```

Not the other direction. The engine does not parse text into sema.

---

## 2 · Implications for the three research rounds

### For report 022 (prior art) — still correct

The prior-art survey stands. The relevant prior art is actually
*Unison* far more than rust-analyzer: identity from the hash of
the logical structure, names as metadata. The datalog / DBSP /
differential-dataflow material applies directly — rules cascade
over logical records, no text anywhere. The Eve and Prolog
precedents (rules-as-records, clause-store semantics) survive
unchanged.

### For report 023 (rust-as-checker) — parts wrong, parts right

**Correct**:

- Part 1 (rustc phases) is accurate as background knowledge about
  what rustc does on text.
- Part 2 (precedents — rust-analyzer, chalk, polonius, gccrs) is
  accurate about what those projects do, and the reality check
  on "reimplementing rustc is a team-years project" stands.
- Part 5's hybrid recommendation ("rustc-as-derivation via
  lojixd; cache outcomes as records keyed by input-hash") is
  correct in direction but needs its inputs re-described.

**Wrong**: Part 3's record inventory listed `SourceRecord`,
`TokenStream`, `Ast`, `ItemTree` as records in sema. No such
records exist. The Rust-cascade records that *do* live in sema
are:

- **The code itself**, already in report 004's shape:
  `Module`, `Fn`, `Struct`, `Enum`, `Newtype`, `Const`, `TraitDecl`,
  `TraitImpl`, `Expr`, `Statement`, `Pattern`, `Type`,
  `Signature`, `Field`, `Variant`, `Method`, `Param`, `Origin`,
  `Visibility`, `Import`, `Program`.
- **Name resolution is not a phase** — records reference each
  other by content-hash IDs (`TypeId`, `StructId`, `FnId`, …).
  There are no "unresolved paths" because there is no text to
  have unresolved paths in. A reference is a hash; if the hash
  points at a record of the right kind, it's resolved; if it
  points at nothing, the reference is ill-formed and the
  mutation that introduced it gets rejected.
- **Semantic analyses as records** (the outputs of type-check,
  trait-solve, borrow-check):
  - `Obligation { site: ExprId, goal: TraitRef, status: Ok |
    Unsatisfied | Ambiguous }`
  - `TypeAssignment { expr: ExprId, ty: TypeId }` (if we
    materialise body typing; optional — may just be a derived
    view)
  - `CoherenceCheck { crate: OpusId, overlaps: Vec<…> }`
  - `BorrowFacts { body: FnId, loans, moves, regions }`
  - `BorrowResult { body: FnId, conflicts: Vec<…> }`
  - `Diagnostic { opus, site: RecordRef, message, level }`
  - `CompilesCleanly { opus, sema_rev, toolchain_pin }`

Critical: `Diagnostic.site` points at a **record ID**, not a
source-span. Line/col numbers don't exist in sema. If a user's
tool wants to show the error with source highlighting, rsc
projects to text AND emits a span table (record-id → line/col);
the tool joins those. rsc owns that translation; sema does not.

Part 4's cascade model is right in spirit — incremental
invalidation, firewalls — but the "edit a function body" scenario
must be re-narrated: the user doesn't edit text, they mutate a
record. A `(Mutate (Fn resolve_pattern { body: <new-body-record>
}))` comes in over nexus; criomed asserts the new `Fn` record;
the current-state pointer for that `FnId`'s name swings; the
cascade re-derives analyses that reference that `FnId`.

### For report 024 (self-hosting walkthrough) — wrong from Step 4 on

**Correct**: Parts 1's loader-in-criomed framing, genesis schema
records, rules-as-records, proc-macro-as-effect, restart story
(Part 3), chicken-and-egg honesty (Part 4).

**Wrong**: the whole "ingest source files as SourceRecords, let
the cascade derive TokenStream → Ast → ItemTree" narrative. That
isn't how code gets into sema.

**The actual bootstrap path for getting the engine's own source
into sema** (one-shot, at cold start):

1. A dedicated *ingester tool* (part of nexus-cli, or a sibling
   binary — not criomed's concern) walks the workspace's `.rs`
   files.
2. For each file, it uses `syn` (or `rustc_parse`) to parse the
   text to a Rust AST in the tool's memory.
3. It translates that AST to nexus-schema records
   (`Fn`, `Struct`, ...), resolving names to content-hash IDs
   during the translation — this is where "name resolution"
   happens *once*, at ingest, by the tool, not as a cascade in
   sema.
4. It emits those records as a long stream of `Assert` verbs to
   criomed over nexus.
5. The tool exits. Text is discarded. Sema now holds the code
   as logic.

After this one-shot, the engine *never parses text again* unless
a user brings in code from outside (at which point the same tool
runs). Editing happens by mutating records, typically via nexus
syntax that maps 1-1 to records (the nexus grammar is designed
precisely for this).

The warm-edit narrative becomes: user (or LLM) sends `(Mutate
(Fn resolve_pattern { body: (Block …)}))`. The `body` field is a
fully-formed expression-tree record, not a text body. Criomed
asserts, the cascade re-derives analyses (Obligation, TypeAssignment,
BorrowResult) for the changed `FnId`, the opus-level
CompilesCleanly may flip, subscribers see a stream event.

### For report 025 (schema inventory) — mostly correct, one contamination

**Correct**: Parts 1 (schema-of-schema), 2 (rules-as-records —
but premises should embed `PatternExpr` that matches *logical
records*, not source-site patterns), 4 (Revision / Assertion /
Commit), 5 (subscriptions), 6 (plans / outcomes), 7 (capabilities),
8 (non-Rust worlds — blobs, file attachments), 9 (ranking).

**Contamination**: Part 3 described `ModulePath` as
`{ segments, resolved: DefId }` where segments come from "every
path site in source". There are no path sites in source because
source doesn't exist in sema. `ModulePath` is just a convenience
index: `{ logical_segments: Vec<Name> → target: RecordId }`,
used for human-legible lookups ("find `criomed::resolver::resolve_pattern`").
Paths are secondary; hash IDs are primary. The "Resolution"
record in 023 §3 ceases to exist: there's nothing to resolve.

---

## 3 · The corrected architecture, top-to-bottom

### Layer 0 · Text grammars (nota, nexus, nota-serde-core)

The *surface syntax* users type. When a user writes
`(Mutate (Fn resolve_pattern { body: (Block (Stmt …)) }))`,
nexusd lexes+parses this text into a `CriomeRequest::Mutate`
containing a fully-formed `Fn` record tree. **Text is a
transport**, not a store.

### Layer 1 · Schema (nexus-schema)

The **record-kind vocabulary**. This is the shape of sema's
content: `Fn`, `Struct`, `Expr`, `Type`, etc. Report 004
enumerates the Rust-data-definition slice; the method-body slice
(Part 4 of 004) is the next push. For the MVP checker, we also
need: `Obligation`, `CoherenceCheck`, `BorrowFacts`,
`BorrowResult`, `Diagnostic`, `CompilesCleanly`.

### Layer 2 · Contracts (criome-msg, lojix-msg)

`criome-msg` carries `CriomeRequest::Assert / Mutate / Retract /
Query / Compile` with record-tree payloads. `lojix-msg` carries
concrete execution verbs (RunCargo, RunNix, PutBlob, GetBlob,
MaterializeFiles). **Record trees flow over criome-msg as
logical structures**, not as parsed-text artefacts.

### Layer 3 · Storage

- **sema** (redb, owned by criomed): content-addressed logical
  records. Every record is rkyv-archived under its blake3. The
  identity of a `Fn` is the hash of its record, which transitively
  hashes its body, signature, name, visibility — and is
  equivalent up to name choice (a `Fn` with renamed parameters
  is the same record if the body is alpha-equivalent at the
  record level; alpha-renaming is by construction as long as
  parameter positions carry no identity).
- **lojix-store** (append-only blobs, owned by lojixd): opaque
  bytes. Compiled binaries. Scratch-workdir-materialised `.rs`
  files from rsc's projector if we choose to cache them (not
  needed; regenerable).

### Layer 4 · Daemons

- **nexusd** — text ↔ record translator. Parses user-typed
  nexus syntax into record trees; serialises replies.
- **criomed** — sema's engine. Applies mutations to records;
  cascades rules; dispatches plan records to lojixd.
- **lojixd** — the executor. Runs cargo (which eats .rs text
  projected by rsc from sema records); runs nix; writes blobs.

### Layer 5 · Projectors and clients

- **rsc** — records → Rust text. The *only* code path in the
  engine that produces text from records. Lojixd links it; when
  lojixd materialises a workdir for `RunCargo`, it calls rsc
  on the referenced opus's records to emit `.rs` files into the
  scratch dir.
- **nexus-cli** — the only text-facing client.
- **ingester** (bootstrap-only) — text → records. Runs once at
  cold start; may be invoked later for external-code ingest.

---

## 4 · The rust-validity question, correctly framed

Given the fundamental invariant (sema holds code as logic), the
"does this opus compile?" question becomes: **does the
nexus-schema-valid record graph, when projected by rsc to
well-formed `.rs`, satisfy rustc's type / trait / borrow rules?**

Several layers of answer, easiest to hardest:

### 4a · Schema validity (cheap, already required)

Criomed's schema layer already rejects mutations that violate
nexus-schema's shape (e.g., a `Fn.body` field being a non-Block
record). This gives us "well-formed Rust AST" for free.

### 4b · Reference validity (cheap, already structural)

Every reference in sema is a content-hash ID. If a `Fn.signature`
references `SignatureId(H)` and no record with hash H exists of
kind `Signature`, the mutation is rejected. So the classical
"unresolved import" / "cannot find type" errors don't exist in
sema — you can't assert a bad reference.

This is the first major gift of records-as-logic: **a whole
class of rustc errors vanishes** because sema's structural
invariants prevent them.

### 4c · Type validity (medium; where the real checker work is)

"Does every `Expr` have a coherent type assignment?" This is
Hindley-Milner over records. rust-analyzer's `hir-ty` is the
reference implementation. It's a tree walk with unification —
non-trivial but bounded. In sema's model, each step produces an
`Obligation` or `TypeAssignment` record; cascades propagate as
bodies change.

### 4d · Trait resolution (medium; chalk territory)

"Does every trait bound have a matching impl?" Chalk formalises
this as logic programming over records `(TraitImpl, WhereClause,
CoherenceRule)`. A direct fit for sema's rules-as-records
model — `Obligation` records are the goal language; `TraitImpl`
records and `blanket_impl` rules are the clauses.

### 4e · Borrow checking (hard; polonius territory)

"Does every borrow satisfy lifetime rules?" Polonius formalises
this as datalog over records `(loan_issued_at, loan_live_at,
path_moved_at)`. The MIR-level representation is specific; sema
would need MIR-shaped records (not just HIR-shaped). This is the
longest pole.

### 4f · Practical recommendation

For the MVP: **defer 4c–4e to rustc-as-derivation** (report 023
§5 proposal, now re-grounded). Specifically:

1. User mutates records in sema.
2. Criomed asserts the mutation; cascades 4a–4b automatically.
3. User (or an eager subscription) asks for compile validity.
4. Criomed looks up `CompilesCleanly(opus, input_closure_hash)`;
   cache miss →
5. Criomed emits `RunCargoPlan { opus, ... }` to lojixd.
6. Lojixd calls rsc to project opus's records to `.rs` in a
   scratch workdir; spawns `cargo check`.
7. Rustc emits JSON diagnostics. Each diagnostic carries a
   source-span.
8. Lojixd hands the JSON back to criomed along with rsc's span
   table (record-id ↔ line/col).
9. Criomed joins these: `Diagnostic { opus, site: RecordId, ... }`
   records, pointing at the offending record, not a line.
10. If zero error-level diagnostics: `CompilesCleanly` asserted.

Post-MVP, criomed grows a native type-check / trait-solve
subsystem that operates on sema records directly, producing
the same `Obligation` / `CompilesCleanly` / `Diagnostic` record
shapes. Rustc becomes an optional oracle for cross-checking.
Borrow-check stays with rustc the longest.

The native subsystem, when it exists, is **a subagent inside
criomed** — call it `semachk` or similar — that is itself
written in Rust (and eventually self-hosted). Its rules are
records in sema (the type inference rules, the trait solver
clauses) — so it is extensible at runtime without recompiling
criomed, per the records-as-rules thesis.

This is the "specialised sub-component in criomed" Li hinted
at. It lives inside criomed; it operates on logical records;
it reimplements the type/trait/borrow reasoning, not the parse
or name-res phases (those don't apply).

---

## 5 · What this means for self-hosting

The self-host loop becomes:

```
 user mutates records describing criomed's own code
   ↓ (criomed applies the mutation; cascades run)
 CompilesCleanly flips (via rustc-as-derivation in MVP)
   ↓ (user requests Compile)
 lojixd runs rsc(records) → .rs → cargo → new binary → lojix-store
   ↓ (user materialises binary to filesystem)
 user kills old criomed, starts new one
   ↓ (new criomed opens sema, reads its own codebase as records)
 LOOP CLOSES
```

The loop is tight because nothing ever round-trips through
text for its own sake. Rsc projects to text *only* when rustc
needs it. Edits don't parse.

---

## 6 · Correction hygiene

Applying to 023/024/025:

- **023**: add correction banner pointing here. Parts 1, 2, 4
  (framing) and 5 (hybrid proposal) stand with reframing. Part 3
  (records sema would need) replace with this report's §4 and
  §2 (the record kinds are the ones in nexus-schema; analyses
  are `Obligation`/`TypeAssignment`/`Diagnostic`; `SourceRecord`/
  `TokenStream`/`Ast` don't exist in sema).
- **024**: add correction banner. Part 1's loader + genesis is
  right; the "walks the workspace, PutBlobs source files,
  asserts SourceRecords" narrative is wrong — see this report
  §3 for the one-shot ingester tool. Part 2's warm-edit is
  wrong as written (no content_hash of text mutates); see §3
  for the records-mutate narrative. Part 3 restart story is
  right. Part 4 is right. Part 5's inventory: strike
  `SourceRecord`, `TokenStream`, `Ast`, `ItemTree`,
  `MacroExpansion` as sema records (macros expand at ingest
  time, not in sema — user-facing mutations never include
  macro invocations; those belong to text syntax, not logic).
- **025**: add correction banner. Part 3's `ModulePath` gets
  re-described as a name-index (`Vec<Name> → RecordId`), not a
  source-path resolution. Part 9's "Rust cascade records"
  bullet: replace `SourceRecord, Ast, ItemTree, ModuleGraph,
  TypeckResult` with `the record kinds from nexus-schema (report
  004) + Obligation + Diagnostic + CompilesCleanly`.

---

## 7 · Invariant to add to architecture.md §8

A new project-wide rule, to be inserted:

> **Sema holds code as logic, not text.** Record kinds in sema
> describe semantic structure (`Fn`, `Struct`, `Expr`, `Type`,
> …). Text is transport (nexus syntax → records via nexusd) or
> projection (records → `.rs` via rsc for rustc). Sema never
> contains source bytes, token streams, or abstract syntax
> trees as records. A whole class of rustc errors
> (`unresolved import`, `cannot find type in this scope`)
> doesn't exist in sema because references are content-hash IDs
> validated at mutation time.

---

## 8 · Open questions now sharper

Now-better-scoped open questions from the earlier rounds:

- **Q1 — Where does the ingester live?** It's a one-shot
  bootstrap tool, not a daemon. Candidates: sibling binary in
  `nexus-cli`, standalone crate, criomed's internal actor
  invoked only on a dedicated bootstrap request. Lean:
  standalone crate (call it `text-to-sema` or reuse an existing
  name) that nexus-cli drives.
- **Q2 — Does rsc emit a span table?** Yes — for `Diagnostic`
  records to reference logical sites, rsc must emit
  `(record_id → byte_range)` alongside the `.rs` text. This is
  a small extension to rsc's existing codegen.
- **Q3 — How much semantic reasoning do we do pre-MVP?** The
  recommendation: 4a (schema validity) and 4b (reference
  validity) are free because they're structural. 4c–4e defer
  to rustc. No semachk subsystem in MVP.
- **Q4 — Macros as sema records: yes or no?** Currently leaning
  **no** for user-authored records. Users write
  *already-expanded* nexus syntax ("write the records the macro
  would produce"). Macros exist only in text; the ingester may
  encounter them and must expand via `syn` + proc-macro-server
  before translating to records. Post-MVP, sema could hold
  `MacroInvocation` records that get expanded by a cascade rule
  calling lojixd, but MVP: no.
- **Q5 — Post-MVP semachk is itself written in Rust; how does
  it avoid chicken-and-egg?** Same way any Rust-written tool
  avoids it: the running criomed binary was compiled by the
  previous criomed (or the bootstrap criomed). The *compiled*
  semachk validates records for the *next* compile. Records
  drift ahead of checker capability only when the checker
  subsystem itself needs Rust features that don't yet exist as
  records — a rare case once the schema is complete.

---

*End report 026.*
