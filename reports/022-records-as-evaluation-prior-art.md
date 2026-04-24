# 022 — "records are the evaluation" — prior art survey

*Claude Opus 4.7 / 2026-04-24 · design-research companion to
reports/021's framing correction. Prior art for the claim that
sema is the evaluation, not a store that an evaluator sits above.*

## Part 1 — Datomic and its descendants

Datomic's ontology is **datoms** `(e, a, v, tx, op)` — an
append-only log of 5-tuples. The "database value" at any point
is a function of the log up to some `tx`. Two things matter for
us:

1. **Derived facts are not first-class.** Datomic has rules
   (datalog `:where` clauses, reusable via `(rule-name ...)`),
   but rules are query-time constructs. They live in the query,
   not in the log. You *can* store rules as datoms with a
   `:db.fn/...` attribute and retrieve them, but Datomic's
   engine does not cascade them — you write application code
   that reads rule-datoms and uses them in a query. So Datomic
   is emphatically *not* "records-are-the-evaluation"; it's
   "records are the facts; queries are the evaluation."
2. **No view materialisation.** Datomic is lazy. A `q` call
   walks indexes; there's no stored result set that keeps itself
   in sync. Rich Hickey's argument: the indexes already give you
   log-time queries, and materialised views are a source of bugs
   and coordination cost.
3. **Excision ≠ retraction.** Retraction is a normal datom with
   `op=false`; the history is preserved. Excision is the
   sharp-edged escape hatch that actually deletes from history
   (for GDPR-style hard-delete). For sema: retraction is the
   primitive; excision is the rare admin operation.

**XTDB (née Crux)** extends this with *bitemporality* —
`valid-time` alongside `transaction-time`. You assert "this
fact was true from T1 to T2, as known at tx=47." That buys you
*late-arriving truth* without rewriting history. Relevant to
sema: if we ever let external evidence drift a record's
effective time independent of when we wrote it, XTDB's dual
axis is the precedent to copy. Their engine still does
query-time evaluation — derived state is not stored.

**Lesson for sema**: Datomic gives us the fact-log substrate
and the decision-discipline around retraction-vs-excision. But
its evaluator sits above the store. If we go "records are the
evaluation," rules must be datoms *and* the engine must cascade
them — Datomic explicitly does not do the second part.

## Part 2 — Datalog with incremental evaluation

**Soufflé** compiles datalog to C++, uses semi-naïve evaluation
with stratified negation, and is the benchmark for bulk
analytics datalog (static analysis, especially Doop). Its model
of "a rule" is a Horn clause in a source file; rules are not
data at runtime. Incremental Soufflé exists (the *Elastic* work
by Scholz et al.) but it's research-grade — the common case is
batch.

**Differential Dataflow** (McSherry, Murray, Isard, Abadi, 2013)
is the theoretical backbone of streaming incremental
computation. Every collection carries a *timestamp lattice*;
every update is a `(data, time, diff)` triple; every operator
(`map`, `join`, `iterate`, `reduce`) has a rule for how
diffs compose. Crucially: **fixpoints are first-class** —
`iterate` is an operator, and differential dataflow's cleverness
is that iteration timestamps get a *product* with outer
timestamps so you can update iterated computations
incrementally. For us, this is the canonical reference for "how
do cascades settle" done right.

**DBSP** (Budiu, Chajed, McSherry et al., Feldera, VLDB 2023)
reframes the same idea as a *calculus over Z-sets* (multisets
where multiplicities can be negative). A streaming SQL query
becomes an expression in this calculus; the incremental version
is derived *mechanically* by differentiation. This is powerful
because the derivation is syntactic — if our rules are records
with a known grammar, we could in principle run the DBSP
transform on them to get their incremental forms.

**Ascent** (Sahebolamri, 2022) embeds datalog in Rust via a
proc-macro; you write rules in `ascent! { ... }` and get a
compiled datalog program with semi-naïve evaluation. Rules are
compile-time constructs. Fast for what it is, but opaque: the
rules compile into type-erased `Vec`-backed relations with
generated fixpoint loops. No runtime introspection.

**Crepe** is a smaller Rust proc-macro datalog with a similar
shape. Both Ascent and Crepe teach us the cost of "rules are
macros, not records": blazing compile-time codegen, zero
runtime reflection, and you can't `SELECT * FROM rules` because
there is no such table.

**Lesson for sema**: Differential dataflow and DBSP are our
theoretical foundation — they *prove* that a general, correct
incremental engine is possible, and they specify what its
operator algebra must close over. Ascent/Crepe tell us what we
*lose* by making rules macros instead of records — which is
exactly the thing we're opting back into. If rules are records,
we pay in runtime dispatch and a plan-compiler that turns
rule-records into differential-dataflow-like operators; we gain
introspection and live-editability.

## Part 3 — Salsa and friends

**Salsa** (Niko Matsakis, powering rust-analyzer) is
demand-driven memoisation. Queries are `#[salsa::tracked]` Rust
functions; the framework caches outputs and tracks dependencies
at the granularity of the function's *inputs*, not of the
individual reads inside it. On input change, dependent queries
are invalidated; they recompute lazily when next asked. This is
the "pull" model.

The conceptual gulf between Salsa and "records are the
evaluation": in Salsa, **the function bodies are Rust code**.
They're opaque to the framework except as black-box
dependency-tracking points. You can't ask Salsa "show me the
query definitions in this database" — they were compiled away
before the database existed. In sema-as-evaluation, the rule
body is a record tree; the engine plans it. You gain:

- **Introspection**: you can query your rules like any other
  records.
- **Sync-as-replication**: two peers running the same engine
  with the same rule-records compute the same cascades; you
  don't have to version-lock the binary.
- **Editability at rest**: a rule can be mutated mid-session
  and the cascade re-runs. In Salsa, changing a query means
  recompiling.

You lose:

- **Expressiveness**: Rust closures can do anything; a record
  grammar can only do what the grammar allows. Total functions,
  maybe a well-defined effect set — you're building a DSL.
- **Performance ceiling**: Salsa's queries run at Rust speed. A
  rule-interpreter runs at interpreter speed unless you JIT,
  which is a serious engineering programme.
- **Type safety**: Rust's typechecker verifies query
  composition. A rule-interpreter verifies at runtime against a
  schema.

**Adapton** (Hammer et al.) maintains a *demanded-computation
graph* where each node is a thunk; changes invalidate
suspensions lazily. It's closer to Salsa than to differential
dataflow — pull, not push. Notable because its dependency graph
*is* reified: you can inspect it. Relevant if sema ever wants
"why is this record here" queries.

**Imp** (Jamie Brandon, 2019–2021 blog series — "reflections
on a decade of datalog," "imp v3," "imp v4") is the closest
design cousin. Brandon's thesis: datalog is great for static
data but painful for UI because UI has many tiny stratified
computations with complex dependency graphs. His Imp
experiments try to make rules editable and observable. Worth
reading end-to-end; the v4 post ("against SQL", "bounded
minimally, correct-by-construction datalog") is the clearest
statement of the design tensions we'll hit.

## Part 4 — Self-referential, rules-are-data systems

**Prolog** is the ur-example. Clauses are data: `assert/1`
and `retract/1` mutate the clause store at runtime; a clause
can be a rule or a fact — the engine treats them uniformly. Our
"every rule is a record" inherits directly from Prolog's
database. The caveat Prolog teaches: **termination is
undecidable** in the general case. Prolog chose SLD resolution
with depth-first search and left the user to avoid infinite
loops. Datalog chose restrictions (no function symbols, bounded
domains) to get decidability. Sema will face the same fork.

**Eve** (Chris Granger, Corey Montella et al., 2016–2018) was
explicitly "everything is a record; rules and UI and state all
live in the same store." Their design notes (the eve-docs
repo, and Granger's blog posts) are the *most direct* precedent
for what Li is proposing. Eve failed commercially but the
design writings are a goldmine: they describe exactly the
trade-offs of making every computation observable as data
(slow; complicated reactivity; hard to debug when a rule
misfires in the middle of a chain). Read their "A Year of
Making Eve" retrospective.

**Dynamicland / Realtalk** (Bret Victor's Oakland lab) is
physical-first: pages of code are the program, seen by overhead
cameras. Realtalk is tuple-space semantics —
`(claim ...)`, `(wish ...)`, `(when ...)` — with pages
observing pages. Fits our thesis in spirit: no hidden state.
But Realtalk's rule bodies are Tcl, so rule-body introspection
has the same gap as Salsa. Semantics fit; representation doesn't.

**SKDB** (SkipLabs) is reactive SQLite; **Tyrol / Skip**
(Facebook, abandoned) was the original reactive-language from
the same team. Rules-as-data at runtime but compiled surface.

**DDlog** (VMware, Ryzhyk et al.) is differential-dataflow with
a datalog front-end; rules compile to Rust. Same trade as
Ascent: fast, non-introspectable.

**Materialize** is commercial differential dataflow with SQL on
top; views are first-class, maintained incrementally. Closest
commercial analogue to what sema-the-engine does for relational
data.

## Part 5 — Content-addressed state

**Unison** is the extreme case: every function is keyed by the
hash of its AST. There are no names in the store — names are
just a UI over the hash-graph. Rename is metadata, not code
change. This is *exactly* the model sema wants for rule
records: the rule's identity is its content-hash; editing a
rule produces a new hash; both versions coexist in the store
and you migrate references explicitly.

What Unison doesn't do: **run rules against a changing dataset
and cascade**. Unison is a language; its store holds code.
Sema wants Unison's storage model plus differential dataflow's
execution model.

**Noms** (Attic Labs, 2015-2018, archived) was "git for
structured data" — content-addressed Merkle-DAG store with
first-class history and diff. **Dolt** (DoltHub) is the
surviving heir, SQL-on-top-of-noms-ideas. Both give us the
storage layer: content-addressed nodes, structural sharing,
cheap snapshots, and merge-as-data-operation. Neither has an
evaluator; they're databases.

**IPFS / IPLD** generalises: any structured data with a hash
identifier and cross-hash links. Relevant as the *syntax of
references* but not as an engine.

**On the time question**: all these systems have history built
in via content-addressing. You can ask "what did the store look
like at hash H" for free. Sema inherits this. But we need to
answer: **does a record need an explicit time attribute?** The
Datomic/XTDB answer is yes for bitemporality; the Unison/git
answer is no because the hash already identifies the snapshot.
My read: sema should be **Unison-default, XTDB-optional** —
records have no intrinsic time, but we can always attach a
`TimeAt` record if a domain needs it. Time-as-record, not
time-as-column.

## Part 6 — What the thesis gives us and what it costs

### New-or-unusual

The combination is novel-ish: **content-addressed storage
(Unison) + rules-as-records (Prolog/Eve) + incremental cascade
(differential dataflow/DBSP) + one engine owns both the store
and the cascade (criomed)**. No single project I know hits all
four. Eve hit three (no content-addressing); Unison hits one
(no engine, no cascade); Datomic hits two (no rules-as-data,
no cascade).

### Pitfalls

1. **Non-termination.** Left-linear recursion in datalog
   terminates under semi-naïve evaluation. General Horn clauses
   don't. Stratified negation avoids paradoxes of the form
   `p :- not p`. Our options: (a) restrict the rule grammar to
   stratified-datalog-with-aggregation (the DBSP approach;
   sufficient for ~everything); (b) admit unrestricted rules
   and detect cycles at cascade time (Prolog's abyss); (c)
   bounded-step evaluation with explicit fixpoint markers. I
   recommend (a): lose a bit of power, keep termination.
2. **Materialisation bloat.** If every derivation is stored,
   the DB grows by the sum of all views. Differential dataflow
   chose full materialisation because indexes+arrangements
   *must* exist to support incremental update; it pays for this
   in memory. Lazy recomputation trades memory for latency.
   Salsa/Adapton are memory-efficient; materialised-view DBs
   are latency-efficient. Sema will likely want a
   **per-rule materialisation policy** — some derived records
   stored, others computed on query with memoisation.
3. **Debuggability when a rule misfires.** This is what Eve
   struggled with most. When record X appears in sema, *why*
   did it appear? The provenance answer requires the engine to
   retain derivation edges (which rule fired, with which
   bindings). Differential dataflow can be instrumented for
   this but it isn't free. Provenance is a first-class feature
   to design in, not retrofit.
4. **The "no evaluator above sema" claim.** Honestly: **the
   engine IS an evaluator; we just live inside sema's
   boundary.** The thesis is useful because it disciplines us:
   no state leaks out, every intermediate is a record, the
   store is the ground truth. But criomed is still a program
   that reads rule-records and computes cascade-records.
   Calling this "sema is the evaluation" is a *framing* that
   forces intermediate state into first-class records; it's
   not the claim that an evaluator is absent. That's fine — it
   just shouldn't be oversold in docs.

### Introspection payoff (vs Salsa)

- **"Why is this record here?"** provenance queries walk
  derivation-edge records; Salsa has backtraces but no stable
  provenance queryable from user code.
- **"What did the store look like at hash H?"** — free with
  content-addressing; Salsa has no notion.
- **Rule edits at runtime** — possible; Salsa requires
  recompilation.
- **Peer sync** — two sema nodes with the same rule-records
  converge; two Salsa-backed tools must ship the same binary.
- **Multi-surface consumers** — a web UI and a CLI can share
  the rule-records; Salsa's rules live in one process.

## Part 7 — Recommendations for sema

### Precedents to draw from, in order

1. **DBSP / Materialize** for the evaluation algebra. Our
   cascade engine should be provably incremental over a
   restricted rule grammar. Adopt Z-set semantics; let rules
   compile to DBSP-style operator DAGs internally even if
   they're stored as records.
2. **Unison** for the identity and history model. Records are
   content-addressed; rules are records; rule-edits are
   new hashes; references are hash-valued with optional name
   lookup.
3. **Datomic / XTDB** for the transaction semantics around
   retraction and optional bitemporality. Default to
   Unison-style history; allow `TimeAt` records for domains
   that need valid-time vs tx-time separation.
4. **Eve design notes** as the cautionary companion — every
   trade-off they hit, we'll hit.
5. **Differential dataflow papers** as the execution reference
   when we implement cascade, including provenance
   instrumentation.
6. **Prolog** for the clause-store semantics of "rules live
   beside facts and can be asserted/retracted," and for the
   termination lessons.

### Minimum viable design

Given solstice pressure (reports/013 Phase-0 ~58 days):

- **Rule grammar**: stratified datalog with aggregation,
  expressed as nexus records using the `[|| ||]` rule family
  (reports/013). No recursion through negation; no unbounded
  recursion; no ungrounded variables. If something doesn't fit,
  it's an effect for lojixd, not a rule.
- **Evaluation**: naïve re-compute on mutation for MVP. Full
  re-run of all rules that touch the changed record-kind. This
  is O(rules × records) per mutation — fine for thousands of
  records, terrible later. Ship it; replace with semi-naïve
  after Phase-0.
- **Materialisation policy**: all derived records stored by
  default. Lazy-mode is a Phase-1 optimisation. The "bloat"
  risk is small when the store is small; the debuggability
  win is large.
- **Provenance**: every derived record carries a
  `DerivedFrom { rule: Hash, bindings: [...] }` sidecar
  record. Free introspection; cheap to strip later if it
  becomes a cost centre.
- **Cycle / non-termination**: reject at rule-parse time by
  stratification check. Runtime step-budget as a safety net.
- **Excision**: explicit admin verb, not a normal
  mutation-path. Datomic's discipline.

### Where sema sits on the materialisation spectrum

**Phase-0**: pure materialisation, naïve recompute. Simple,
inspectable, correct, slow. Enough to prove the thesis.

**Phase-1**: semi-naïve incremental evaluation (DBSP / diff
dataflow), still full materialisation. Same storage shape, an
order of magnitude faster on updates. Makes sema pleasant.

**Phase-2**: per-rule materialisation policy (`materialize`,
`lazy`, `never`) with a query planner. Materialize's world.
Not needed for self-hosting.

The thesis survives all three. The precedents agree on the
staging.

---

*Sources named, not URL'd (per task): McSherry/Murray/Isard/
Abadi "Differential Dataflow" (CIDR 2013); Budiu et al. DBSP
(VLDB 2023); Sahebolamri "Ascent" (CC 2022); Matsakis et al.
Salsa docs; Hammer et al. Adapton papers; Brandon "Imp"
blog series 2019–2021; Granger et al. Eve design notes and
"A Year of Making Eve"; Hickey "The Value of Values" and
Datomic docs; Kleppmann/Ryzhyk DDlog papers; Ryzhyk et al.
"Differential Datalog"; Unison docs by Chiusano/Bjarnason;
Attic Labs Noms design docs; DoltHub Dolt docs;
SkipLabs/Reactive-Systems Skip papers; Bret Victor's
Dynamicland/Realtalk writings.*
