# 023 — sema as a Rust correctness checker (hypothesis review)

> **⚠ Framing correction — 2026-04-24**: Li: "sema doesnt give a
> fuck about tokenstream; it has a fully specified view of code.
> not text; logic!" This report's Part 3 lists `SourceRecord`,
> `TokenStream`, `Ast`, `ItemTree` as records in sema — those
> don't exist. Sema holds code as fully-specified logical
> records (`Fn`, `Struct`, `Expr`, `Type`, … per report 004),
> not as text-derived artefacts. A whole class of rustc errors
> (`unresolved import`, `cannot find type`) doesn't exist in
> sema because references are content-hash IDs, validated at
> mutation time.
>
> Parts 1 (rustc phases), 2 (precedents), and 5 (hybrid
> recommendation — rustc-as-derivation, cache outcomes) stand
> with reframing. Part 3's record inventory is replaced by
> [reports/026 §4 and §2](026-sema-is-code-as-logic.md). Part 4
> cascade model is right in spirit; the "edit a function body"
> scenario becomes "mutate a `Fn` record", not "mutate a
> SourceRecord". Diagnostics reference record IDs, not
> line/col spans (rsc emits a span table at projection time).

*Claude Opus 4.7 / 2026-04-24 · design-research synthesis in
response to Li's hypothesis "criomed could determine compile
validity without running rustc, as incremental cascades over sema
records".*

Scope: evaluate the claim. Inputs are rustc's architecture, the
rust-analyzer / chalk / polonius / mrustc / gccrs precedents, and
sema's existing records-as-truth model (reports 002, 004, 015,
021). Output is a reality-checked record-kind enumeration, a
cascade model, and an MVP recommendation.

---

## Part 1 — What rustc actually does (yes/no phases only)

Phases ordered roughly as rustc executes them. Starred phases are
load-bearing for the "compiles: yes/no" question; unstarred
phases are codegen and not our concern.

1. **Lexing*** — `&str` → token stream. Inputs: source bytes +
   edition. Derived: tokens with spans. Errors: unterminated
   strings, stray characters, shebang handling. Stateless.

2. **Parsing*** — tokens → AST. Inputs: tokens. Derived: AST
   nodes, attributes, macro-invocation sites. Errors: "expected
   `)` found `;`" and similar. Stateless per-file; cross-file
   only via `mod` declarations.

3. **Macro expansion / AST lowering*** — AST → expanded AST →
   HIR (High-level IR). Inputs: AST + macro definitions + proc
   macros + cfg attributes. Derived: fully-expanded item tree;
   HIR bodies with de-sugared control flow (`?`, for-loops,
   async). Errors: macro hygiene violations, `cfg_attr`
   conflicts, recursion-limit blowups. This phase is the first
   that is *not* local — proc macros are Turing-complete and
   require running arbitrary Rust code.

4. **Name resolution*** — resolve every path (`foo::Bar::baz`)
   to a `DefId`. Inputs: expanded item tree, imports, prelude.
   Derived: for every name-site, the `DefId` it binds to; the
   "import map" for each module; visibility check results.
   Errors: `unresolved import`, `cannot find type T in this
   scope`, privacy violations.

5. **HIR type collection / ty::collect*** — gather declared
   types (struct fields, fn signatures, trait signatures,
   associated types) into rustc's `ty::Ty` universe. Inputs:
   HIR + name resolution. Derived: a `ty::Ty` per `DefId` that
   has a type. Errors: malformed types, impossible where-clauses
   at the declaration site.

6. **Trait solving / obligation resolution*** — answer "does
   `T: Trait` hold?" Inputs: trait declarations, impl blocks,
   blanket impls, where-clauses, coherence rules. Derived: for
   every obligation raised during typeck, a resolution (yes /
   no / ambiguous). Errors: `the trait bound T: Foo is not
   satisfied`, overlapping impls, orphan-rule violations. Chalk
   reformulates this as datalog; stock rustc uses a bespoke
   solver.

7. **Type checking & inference*** — assign a `ty::Ty` to every
   expression, unify inference variables, run method resolution,
   resolve auto-deref / auto-ref, insert coercions. Inputs: HIR
   bodies + collected types + trait solver. Derived: a
   `TypeckResults` struct per body — expression types, method
   callees, adjustments, pattern bindings. Errors: `mismatched
   types`, `no method named X found`, `cannot infer type`.

8. **MIR construction & MIR type-check*** — HIR body →
   Mid-level IR (CFG of basic blocks). Inputs: HIR + typeck
   results. Derived: MIR body, a second type-check pass over
   MIR (catches things HIR typeck deferred), region-constraint
   sets. Errors: mostly internal, but constant evaluation
   failures surface here (`const { panic!() }`).

9. **Borrow checking*** — per-MIR-body region and borrow
   analysis. Inputs: MIR + region constraints. Derived:
   borrow-check results (conflicting-borrow facts, moves out of
   borrowed data). Errors: `cannot borrow X as mutable because
   it is also borrowed as immutable`, `X does not live long
   enough`. Polonius re-expresses this as datalog.

10. **Const-eval & misc late checks*** — evaluate `const fn`
    bodies, check `#[must_use]`, dead-code, lints. Inputs: MIR
    + typeck. Derived: const values, lint diagnostics. Many
    lints are errors when `deny`'d.

11. **Monomorphisation + codegen** — not our concern. lojixd
    runs rustc for the actual object code.

**Dividing line:** phases 1–10 determine yes/no. Phase 11 is
lojixd's. The checker we're speculating about must reproduce 1–10
(or cache their outputs) faithfully enough that agreement with
rustc is the contract.

---

## Part 2 — Precedents

### rust-analyzer + salsa

r-a is the strongest precedent: an entire Rust frontend built
around salsa's query-memoize-invalidate model. Keys to study:

- **Base DB layering.** r-a splits the frontend into
  `base-db` → `hir-expand` → `hir-def` → `hir-ty` → `ide`
  trait families. Each layer exposes salsa queries; downstream
  layers call them. Input queries (source text, crate graph,
  proc-macro server state) sit at the bottom; everything else
  is a *derived* query, which is exactly sema's "records are
  derivations" model in a different vocabulary.
- **Memoized queries.** `parse(file_id)`, `def_map(crate_id)`,
  `infer(function_id)`, `trait_impls_in_crate(crate_id)`,
  `generic_predicates_of(def_id)`, hundreds more. The unit of
  memoization is the query invocation keyed by inputs.
- **Granularity of invalidation.** salsa's "firewall" pattern
  is critical: when a source file changes, r-a re-parses *that
  file*, but `def_map` only re-runs if the set of visible items
  changed — changing a function body doesn't invalidate sibling
  modules' name resolution. Blogs of note: Aleksey Kladov
  ("matklad")'s "Explaining Rust-Analyzer" series, and Niko
  Matsakis's salsa-architecture posts.
- **Macros.** r-a has a proc-macro server (a sidecar process)
  that runs untrusted proc macros; token-tree inputs/outputs
  are salsa-keyed. It accepts that full correctness for proc
  macros requires running arbitrary code. `hir-expand` memoizes
  per-expansion.
- **Trait/type inference.** `hir-ty` implements a trimmed
  chalk-style trait solver and Hindley-Milner-ish inference
  directly. Not bit-identical to rustc but close enough for
  IDE use. Known gaps: some advanced GAT patterns, specialisation,
  const-generics edge cases.
- **What r-a doesn't do:** borrow checking (intentionally
  out-of-scope), full const eval, codegen. Errors shown in-IDE
  are typeck+trait-solve class; borrow-check errors are
  deferred to rustc.

### chalk

chalk re-expresses Rust's trait system as a logic-programming
problem: trait declarations become *program clauses*, obligations
become *goals*, solving is SLG resolution with coinduction for
well-formedness. Key facts:

- Rules encoded: implementations, where-clauses, blanket impls,
  associated types, projection equality, auto-traits,
  well-formedness ("if `S { x: T }` is well-formed then T is
  well-formed"), coherence, orphan rules.
- Datalog-flavoured but not pure datalog — it needs function
  symbols (type constructors) and unification, hence logic
  programming rather than plain Datalog.
- rustc integrated chalk as an experiment (`-Ztrait-solver=next`
  and successors) and is gradually moving pieces into the
  "next-gen trait solver"; the chalk-in-rustc milestone is still
  in progress as of late-2025 releases.

### polonius

Next-generation borrow checker. Expresses borrow-check as a
Datalog program (originally run on souffle, now on an in-tree
engine). Facts:

- **Input facts** (extracted from MIR): `loan_issued_at`,
  `loan_invalidated_at`, `var_defined_at`, `var_used_at`,
  `cfg_edge`, `path_moved_at_base`, plus region-liveness
  derivations.
- **Derived facts:** `loan_live_at`, `errors`, `subset`,
  `origin_live_on_entry`. The `errors` relation is the
  yes/no output.
- Performance-sensitive; the prototype was slower than NLL but
  a from-scratch engine + incremental tweaks brought it into
  range. Not yet the default in stable rustc.

### mrustc and gccrs

- **mrustc** — a Rust-to-C transpiler whose explicit goal is
  bootstrapping: accept already-typechecked Rust (it trusts the
  input), skip borrow-check, skip most trait-coherence checking,
  focus on translation. Used to bootstrap rustc without a prior
  Rust binary. Lesson: *if you assume the input is already
  valid*, you can skip most of phases 4–10. Worthless as a
  correctness checker; interesting as an existence proof that
  the translation step is separable.
- **gccrs** — a full GCC front-end. Re-implementing name
  resolution, typeck, trait solving, borrow-check from spec +
  rustc-behaviour observation. Public status through 2025:
  many partial phases landed, "compiles real crates end-to-end"
  is still a per-crate adventure, borrow-check is the furthest
  behind. Lesson: years of full-time work from a funded team
  and still incomplete. This is the most honest cost estimate
  we have.

### rustc as a library

`rustc_driver` + `rustc_interface` expose the phases as callable
APIs. Tools like clippy, miri, and rust-analyzer-with-rustc-hack
use them. Cost: tied to nightly, ABI changes constantly,
distribution requires rustc-private components. Feasible for a
hybrid where criomed drives rustc phases and stores the outputs
as records; *not* feasible for rolling a pure-criomed checker
via `rustc_driver` because the driver is all-or-nothing per
invocation.

---

## Part 3 — Records sema would need

Grouped by phase. "Deriving from" = inputs; "blast radius" =
what else must re-derive when this changes. All would be records
in sema under content-hash IDs (consistent with report 004's
shape). Many would be stored *per-opus* because rustc's unit of
compilation is the crate.

### Source & syntax layer

- **SourceRecord** `{ opus_id, path, content_hash, edition }` —
  input. No derivation. Blast radius: everything downstream in
  that file.
- **TokenStream** `{ source_id → tokens }` — derived from
  SourceRecord. Blast radius: Ast for that file.
- **Ast** `{ source_id → ast_nodes }` — derived from
  TokenStream. Blast radius: ItemTree, expansions.

### Expansion & module graph

- **CfgContext** `{ opus_id → active_cfg_predicates }` — input.
  Invalidating this is catastrophic (entire opus re-expands).
- **MacroDef** — record per macro definition (hash of the
  macro's body).
- **MacroExpansion** `{ invocation_site, macro_def_id, input_tt
  → output_tt }` — derived; heavy. Proc macros require actually
  running code; this record caches the *result* only.
- **ItemTree** `{ source_id → items }` — derived post-expansion.
- **ModuleGraph** `{ opus_id → Module tree }` — derived from
  ItemTrees + `mod` declarations.
- **CrateGraph** `{ workspace → Opus nodes + dep edges }` —
  input (comes from Cargo.toml equivalents).

### Name resolution

- **DefId** — stable identifier for every named item. Record
  kind = "the existence of this item in this module at this
  path".
- **ImportMap** `{ module_id → { name → DefId }}` — derived.
- **Resolution** `{ path_site → DefId | Error }` — derived;
  one per path occurrence in the source. Potentially millions.
- **VisibilityCheck** `{ (from_def, to_def) → allowed }` —
  derived.

### Types and traits

- **Ty** — the canonical sema analogue of `rustc_middle::ty::Ty`.
  Content-hashed; shared aggressively (the type `u32` is one
  record used everywhere). Report 004's `Type` is the
  prototype; it needs extensions for inference variables,
  projections, higher-ranked lifetimes, opaque types.
- **SigOf** `{ def_id → Signature }` — derived.
- **TraitDecl**, **TraitImpl** — roughly report 004's shapes,
  but with a crucial addition: **impl-selection indexing**
  (so "what impls of Clone exist for `Vec<T>`?" is a cheap
  query).
- **Obligation** `{ site, goal: TraitRef | Projection → status
  }` — derived during typeck. The *primary* yes/no bearer
  alongside UnifyResult.
- **Coherence/OrphanCheck** `{ crate_id → overlap_errors }` —
  derived, global per-opus.

### Expression typing

- **TypeckResult** `{ body_id → { expr → Ty, method_callee_map,
  adjustments, pattern_bindings }}` — derived per function body.
- **InferenceTrace** (debug only) — probably not materialised.

### MIR & borrow check

- **Mir** `{ body_id → MIR graph }` — derived.
- **BorrowFacts** `{ body_id → polonius input facts }` — derived
  from MIR.
- **BorrowResult** `{ body_id → { errors, conflicting_loans }}`
  — derived from BorrowFacts.
- **RegionConstraints** — intermediate, per body.

### Outcome

- **Diagnostic** `{ opus_id, span, message, level }` — the
  failures.
- **CompilesCleanly** `{ opus_id, sema_rev, rustc_edition }` —
  existence of this record ⇔ every obligation resolved, every
  expression typed, every borrow checked, zero Diagnostics at
  `error` level.

### Granularity commentary

The invalidation granularity matrix: changing a function body
should touch `Ast(that_file)`, `TypeckResult(that_body)`,
`Mir(that_body)`, `BorrowResult(that_body)`, and the opus-level
`CompilesCleanly` — but **not** `ModuleGraph`, sibling typeck
results, or most trait obligations (except those that typecheck
that body specifically raised). This is salsa's firewall pattern
and must be preserved in sema's cascade semantics or we recompute
too much.

---

## Part 4 — The cascade model

Li's frame: rules are records, cascades settle in sema. Walk-through
of "human edits a function body" scenario:

1. **Edit lands.** criomed receives `Mutate(SourceRecord{path=…,
   content_hash=NEW})`. The record's hash changes.
2. **Immediate invalidation.** The `Ast(old_hash)` record is
   superseded by a newly-computed `Ast(new_hash)`. Anything that
   pointed at `Ast(old_hash)` is now orphaned (still addressable,
   just no longer current). The current-state pointer for that
   file moves to the new hash.
3. **ItemTree check.** Re-derive `ItemTree` for the file. If its
   hash *didn't* change (common case: body edit, signatures
   unchanged), the cascade stops here for most of the opus. This
   is the salsa firewall in records form.
4. **Typeck body.** `TypeckResult(body_id)` re-derives, taking
   the *unchanged* `SigOf(that_fn)`, `SigOf(called_fns)`, and
   trait-impl indices. New obligations raised, resolved against
   the existing trait database. If resolution succeeds, produce
   a new TypeckResult record.
5. **MIR + borrow-check.** Same pattern, body-local.
6. **CompilesCleanly roll-up.** Derived rule: opus-level record
   exists iff the set of error-level Diagnostics for that opus
   is empty. Opus-level record's hash changes iff the set
   changes.
7. **Subscribers notified.** Anyone watching the opus's
   CompilesCleanly hash (editor, CI agent, a dependent opus
   that refuses to build on broken deps) gets a nexus-stream
   event.

**Final state** is exactly one of:
- `CompilesCleanly { opus_id, sema_rev }` exists — green light.
- A non-empty set of `Diagnostic` records — compile-no.

**Versus salsa's in-memory memo model:**

- *Persistence.* salsa's cache is process-lifetime; sema's is
  durable on disk under content hashes. Reopen a session — the
  TypeckResult for an unchanged body is still there, no rebuild.
- *Sharing.* Multiple criomed processes (or a future multi-host
  setup) share the same records. salsa doesn't distribute.
- *Inspectability.* Every intermediate is a queryable record;
  nexus can ask "show me every unresolved Obligation in opus X".
  salsa's intermediates are private.
- *Cost.* Writing every derived fact to disk is expensive.
  rust-analyzer explicitly chose in-memory for latency. sema
  bets that content-hash dedup + redb's mmap model keeps the
  cost tolerable at MVP scale.
- *What's novel:* cascades as first-class records rather than
  function calls. The *rule itself* is a record, so a new Rust
  edition could be a record that swaps the trait-solver rule
  set without recompiling criomed. Speculative; load-bearing if
  it works.

---

## Part 5 — Reality check

**The danger.** Reimplementing phases 4–10 to rustc-parity is a
multi-year project even with full-time funding. gccrs is the
data point. Every nightly rustc release ships behaviour changes
(trait-solver refinements, new lints-as-errors, edition diffs,
new stable features enabling new typeck paths). A pure-sema
checker would permanently trail rustc and produce a non-trivial
stream of "rustc says yes, sema says no" (or worse, vice versa)
bugs. Non-parity on borrow-check is catastrophic for user trust:
"it compiled in my editor but not on CI" is the worst IDE bug
class.

**The hybrid is clearly right for MVP and probably for v1.**
Concrete proposal:

1. Treat `rustc --emit=metadata -Zno-codegen` (or `cargo check`)
   as a **derivation** — an opaque function `source_records →
   {CompilesCleanly | Diagnostics}`.
2. lojixd runs rustc in check-mode on a materialised view of the
   source records.
3. criomed stores the outcome as records, keyed by
   `content_hash(all_inputs)`. Cache hit ⇒ no rustc run.
4. Diagnostics are parsed from rustc's JSON output and stored as
   `Diagnostic` records.
5. On any input change, the cache key changes; cache misses
   re-run rustc.

This gives us 90% of the user-visible benefit (incremental,
durable, shareable, subscribe-to-compile-status) without
re-implementing the checker.

**Where to extend beyond the opaque-rustc hybrid (incrementally,
only when ROI is clear):**

- **Parse** — cheap and rustc-parity-able via `syn` or
  `rustc_parse` as a library. Low-risk to implement inside
  criomed; high value (syntax errors caught without round-trip).
- **Module graph + name resolution (first pass, public API
  only).** Doable in weeks; unlocks "find references", rename
  preview, broken-import detection. rust-analyzer's `hir-def`
  is the existence proof.
- **Signature-level coherence** — "does an impl exist for this
  trait on this type?" without body typeck. Useful for
  dep-validity checks.
- **Body typeck** — much harder. Start shadowing r-a's
  `hir-ty` only when parity with rustc is less critical than
  feedback speed.
- **Borrow check** — don't. Keep calling rustc. Polonius isn't
  even stable inside rustc yet.

**MVP scope recommendation** (ordered):

1. **Syntactic well-formedness** — parse-level errors, stored
   as Diagnostic records. ~1–2 weeks.
2. **Module graph & public-API resolution** — ItemTree,
   ModuleGraph, ImportMap records. Use `syn` + custom
   resolver. Catches "did you break a public signature"
   without type-checking bodies. ~4–6 weeks.
3. **rustc-as-derivation** for everything else. Rustc runs in
   lojixd (already our model per report 021); its JSON output
   becomes Diagnostic records; its zero-error exit becomes a
   CompilesCleanly record. Cache key = content-hash of all
   SourceRecords + toolchain pin. ~2 weeks once lojixd runs
   cargo.
4. **Defer** body typeck, trait solving, borrow check — rustc
   owns them. Revisit per-phase only when (a) a concrete
   feature needs the intermediate records and (b) we can
   justify the parity-maintenance cost.

This is the less-ambitious version of the vision, and it's the
one that survives contact with rust-weekly release cadence.

---

## Summary

The hypothesis ("sema holds enough verification data to decide
compile-validity without rustc") is *eventually* coherent but
*immediately* uneconomic. rust-analyzer, chalk, and polonius
exist precisely because full parity is a team-years effort even
with dedicated funding. The pragmatic path is: rustc-as-derivation
for the authoritative yes/no, sema stores the derived records
(Diagnostic, CompilesCleanly) under content-hash cache keys, and
criomed only reimplements the cheapest phases (parse, module
graph, public-API resolution) where the ROI is clear. This
preserves the records-are-truth model without committing to a
second Rust frontend.

Open sub-questions for later reports:

- What's the record-level schema for Diagnostic that's forward-
  compatible with rustc's JSON shape shifts?
- Does criomed's cache key include the full toolchain derivation
  hash (yes, probably), and does that mean every toolchain bump
  is a full cache invalidation (yes, and that's acceptable —
  toolchain bumps are rare)?
- Is the hybrid compatible with self-hosting? (Yes — the
  bootstrap opus compiles via rustc-derivation; once criomed
  runs, subsequent opera use the same pipe.)
- When does "reimplement parse + name-res in criomed" pay for
  itself? (When nexus wants live feedback faster than rustc's
  per-invocation startup; realistic horizon: Phase-1, not
  Phase-0.)

---

*End report 023.*
