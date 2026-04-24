# 044 — Priority-2 decisions: diagnostics, semachk scope, version skew

*Claude Opus 4.7 / 2026-04-24 · deep research on the three
Priority-2 items from [reports/031](031-uncertainties-and-open-questions.md)
§P2.1–P2.3. These are ergonomics / post-MVP concerns — they
do not block self-hosting, but they shape the criomed↔rustc
seam, decide whether semachk ever becomes real, and govern
how we handle criomed/sema version drift once Li has records
he cares about. Named precedents only; no code.*

---

## P2.1 — Diagnostic spans: rustc JSON → sema record refs

### The actual rustc JSON diagnostic shape

Rustc's `--error-format=json` output is **stable in ad-hoc
convention, not by Rust's stability policy**. The schema has
held its current shape since 1.12 (2016); `rustfix`, `cargo`,
`rust-analyzer`, IntelliJ-Rust, and `bacon` all consume it
with hand-written parsers and survive toolchain bumps via
point-fixes. A diagnostic object carries:

- `message` — prose body; `code` — optional `{ code: "E0308",
  explanation }`; `level` — error / warning / note / help /
  failure-note / ICE.
- `spans: Vec<DiagnosticSpan>` — each with `file_name`,
  `byte_start/byte_end`, `line_start/end`, `column_start/end`,
  `is_primary`, `label`, `suggested_replacement`,
  `suggestion_applicability` (MachineApplicable /
  MaybeIncorrect / HasPlaceholders / Unspecified), and
  `expansion: Option<DiagnosticSpanMacroExpansion>` with
  `span`, `macro_decl_name`, `def_site_span`.
- `children` — recursive sub-diagnostics (`help:` / `note:` /
  `try this:`).
- `rendered` — optional pre-rendered ANSI string.

Key consequences. First, every diagnostic has 0..N primary +
0..N secondary spans + 0..N children + recursive expansions;
026's "each diagnostic carries *a* source-span" (singular) was
wrong, per 027 §4. Second, macro expansion is a *nested tree*
(`DiagnosticSpanMacroExpansion` recurses arbitrarily). Third,
suggestions are first-class rewrite tuples `(byte_range,
replacement_text)` that rustfix applies literally — and a
single suggestion may straddle record boundaries in our
projected `.rs`.

### rust-analyzer's translation strategy

r-a does *not* parse rustc JSON for its primary diagnostics;
`hir-ty` emits them natively. r-a *does* consume JSON for the
"check on save" path, via its `flycheck` crate + the
third-party `cargo_metadata::diagnostic::Diagnostic` type.
That path:

- maps `file_name + line/col` to r-a's `FileId + TextRange`
  using the VFS;
- discards `children` that only echo the parent;
- preserves `suggested_replacement` + `suggestion_applicability`
  for Code Actions;
- ignores `macro_decl_name` for well-behaved derives;
- does **not** cross-reference secondary spans with its symbol
  table — secondaries stay as raw range annotations because
  the UI model is "primary gutter icon, secondary inline
  labels in the editor."

Takeaway: **even the best editor treats rustc JSON as
mostly-opaque once the primary span is placed**, because the
secondary spans' semantic meaning is already in the prose.

### Mapping source-span → record-id

rsc emits `.rs` *and* a reverse-projection map, minimally
`RecordId → (file, byte_start, byte_end)`. Inverted via a
per-file sorted interval tree, that gives `(file, byte) →
RecordId`. The easy case — rustc primary span → containing
record — is direct. Four complications:

- **Macro-expanded spans.** Sema holds post-expansion records
  only (026 §Q4, 033 §5). At compile time rsc projects the
  expanded graph to `.rs`; there is no macro call site for
  rustc to point at. For the MVP's still-allowed literal
  `#[derive(…)]`, `expansion.macro_decl_name` names the
  derive; rsc's map traces back to the attached `Struct`/
  `Enum`. `site: StructId`. Good enough.
- **Auto-generated impl spans** (trait-object vtables, closure
  desugarings). Rustc marks these with internal `macro_decl_name`
  (`"_"`). rsc can tag the desugaring point; in the MVP, the
  diagnostic degrades gracefully to "closest enclosing record."
- **Proc-macro-expansion spans.** Analogous. The expansion
  output is stored as a derived sub-tree under the invoking
  `Expr`; rsc maps back to that sub-tree's root.
- **Suggestion spans crossing record boundaries.** Worst case:
  rustfix wants to insert `.await` between an expression and
  its method call. In rsc's projected `x . foo ( )` the byte
  range straddles `Expr::MethodCall`'s projection span. "Replace
  byte range with text → mutate which record?" requires rsc
  to own a reverse-parse path. Precedent: rust-analyzer's
  `ide-assists` hand-codes each assist per pattern. **Not MVP.**

### Three strategies — the decision

**(a) Opaque JSON blob.** `Diagnostic { rustc_json_payload:
StoreEntryRef, primary_site: RecordId, level, code, message }`.
Blob in lojix-store; record carries human-queried fields only;
clients that want the full diagnostic parse the blob. Simple;
zero schema churn; no queryability into secondary spans.

**(b) Structured translation.** Full JSON parsed into a
record tree (`Diagnostic`, `DiagnosticChild`, `DiagnosticSpan`,
`DiagnosticSuggestion`, `MacroExpansionFrame`). Every span →
`RecordId`. Maximal queryability. Rustc adds fields → our
parser breaks; the parser belongs at schema level, not at
code level, which is a whole subsystem.

**(c) Hybrid.** Primary span → `RecordId` structural. Level,
code, message, children-prose structural. Secondary spans +
suggestions + macro backtrace → opaque JSON sidecar. 80 % of
queries ("what records are unhealthy?", "error count per
opus?", "all errors in this Fn") work structurally; the other
20 % pull the blob.

**Recommendation: (c) hybrid.** Matches r-a `flycheck` in
practice. Matches `cargo fix`'s posture (reads JSON, applies
machine-applicable, ignores rest). Survives rustc JSON drift
because the blob is the source of truth and our structured
projection is a derived view. Post-MVP, promote blob fields
to structured one at a time as querying needs arise.

Record shapes (catalogue-level; full rkyv shape belongs in a
future record-catalogue report):

- **CompileDiagnostic** — `{ opus: OpusId, revision:
  RevisionId, level, code: Option<String>, primary_message:
  String, primary_site: RecordId, children_summary:
  Vec<String>, raw_rustc_json: StoreEntryRef, seen_at:
  Timestamp }`.
- **DiagnosticSuggestion** — emitted separately when
  `applicability = MachineApplicable` so a future
  `(ApplySuggestion diagId)` verb finds them without blob
  parsing. `{ diagnostic: DiagnosticId, applicability,
  summary: String, raw: StoreEntryRef }`.

### Macro expansion in practice

Because sema holds only post-expansion records, the MVP macro
problem reduces to: map `expansion.macro_decl_name` +
`def_site_span` back to the `Struct` / `Enum` / `Fn` the
expansion was attached to. rsc's reverse-projection map
already records "this span was generated by expanding X
derive on Y record"; the lookup is direct. Function-like proc
macros (post-MVP) store their expansion as a derived sub-tree;
rsc maps back to the sub-tree root. `macro_rules!`-inside-sema
is deferred entirely per 026 §Q4 — this one decision erases
most of the macro-trace pain.

### Cross-cut with P0.1 (hash vs name refs)

Diagnostic translation is robust under either regime. If refs
are dual-mode, `primary_site` can hold a `RecordId` or a
`QualifiedName` and resolve through criomed. If hash-only,
`primary_site` is strictly `RecordId` and rsc's map must emit
hashes. The diagnostic schema is stable; only rsc's map-key
form differs.

---

## P2.2 — semachk's real feasibility

### Precedents

**`hir-ty`** (rust-analyzer). Hindley-Milner inference, coercion
tables, auto-deref, method resolution; near-complete
re-implementation of chalk's trait solver via `chalk-solve` +
`chalk-ir` as libraries; closure inference; limited const-eval;
per-pair coherence check. Known gaps vs rustc: partial GATs;
no specialisation; limited const-generic const-eval; partial
TAIT; partial opaque types in trait position; conservative
variance; region variables without borrow-check; partial MIR
analyses (exhaustiveness, unused bindings). Honest scope:
`hir-ty` covers ~30-40 % of rustc's checker by code volume,
~90 % of code users typically write.

**`chalk-solve`**. Real library, on crates.io; depends on
`chalk-ir`. Interface: `Solver::solve_goal(Canonical<InEnvironment<Goal>>)
-> Solution`. To use outside a rustc frontend you must
implement `RustIrDatabase` supplying the clause set (impls,
where-clauses, adt defs); canonicalise goals before solving
(helpers in `chalk-solve::infer`); interpret `Solution`
(Unique / Ambiguous / NoSolution / Overflow). `RustIrDatabase`
is the biggest adapter surface. Sema feasibility: **high**,
in the sense that if our `TraitImpl`, `WhereClause`,
`AssocType`, `Goal` records mirror chalk-ir's term language,
the adapter is months, not years. 029 §Part 2 is canonical.

**`polonius-engine`**. A datalog runtime, not a borrow
checker — rustc's `rustc_borrowck` supplies the rules;
`polonius-engine` just runs datalog. Library on crates.io;
you bring your own input-fact extraction, which is a MIR
re-implementation worth a team-year on its own. Polonius has
well-known perf issues on large bodies (why NLL is still
rustc's default in 2026).

**`rustc_driver`**. The "embed rustc" entry point. Nightly-
only, unstable, version-locked; every consumer (clippy, miri,
r-a's proc-macro-srv, rustdoc) pins a specific nightly. Our
rustc-as-subprocess architecture avoids this entirely — we
depend on stable `cargo check --message-format=json`, not on
`rustc_driver`. That's the right call; pulling in
`rustc_driver` would force us onto a rolling nightly.

**`gccrs` / `mrustc`**. Alternative frontends; neither at
parity; named only to anchor the "building a Rust checker
from scratch is not a one-person project" scale claim.

### Cheap phases that come near-free under code-as-logic

- **(i) Schema validity.** Already done by criomed's mutation
  gate. Zero new code.
- **(ii) Reference validity.** Every `StructId` / `FnId` /
  `TypeId` in sema references a content-hash; if the referred
  record is missing or wrong-kind, the mutation is rejected.
  Near-free; required anyway.
- **(iii) Module graph + visibility.** Given `Module`,
  `Visibility`, `Import` records, can `Fn A::B::c` see `Fn
  X::Y::z`? Tree-walk with pub/pub(crate)/pub(super) rules;
  dataset entirely in sema. **Weeks, not months.**
- **(iv) Public-API signature equality.** Walk opus's `pub`
  items; hash signatures; compare across revisions. Standard
  `cargo-semver-checks` logic, easier under content-addressed
  records. **Weeks.** Every CI wants it.
- **(v) Orphan rules.** Walk `TraitImpl` records; check at
  least one of (Trait, Type) is local to the opus. Pure
  record query. **Weeks.**
- **(vi) Unused / unreachable item detection.** From
  `Program.root` walk reachability; flag un-referenced public
  items. Pure graph walk.
- **(vii) Trait solving** (chalk territory). `ProgramClause`
  generation, canonicaliser, `RustIrDatabase` adapter.
  **Months of focused work.** Delivers native "does this impl
  apply" without a rustc round-trip.
- **(viii) Body-level typeck** (`hir-ty` territory). **Months**
  even with adapter, with permanent gaps vs rustc (GATs,
  specialisation, const-eval).
- **(ix) Borrow check** (polonius territory). **Years**, maybe
  never.

### Decision framework

- **Option A — rustc-as-derivation forever.** Every check is
  a subprocess; seconds-to-minutes per query; criomed's
  "edit-is-evaluation" promise is hollow.
- **Option B — cheap phases native, expensive phases rustc.**
  Semachk owns (i)–(vi); rustc owns (vii)–(ix).
- **Option C — full parity.** Team-years; permanent lag;
  unjustifiable without a user community demanding it.

**Recommendation: B, with explicit phase roadmap.** Ship
(i)–(ii) as part of criomed's commit path (already required).
Ship (iii)–(vi) as the first semachk milestone — weeks each,
felt value, low divergence risk (textually specified in the
reference). Ship (vii) as the second milestone via
chalk-solve adapter. Pause and re-evaluate before (viii). Do
not pursue (ix).

**Divergence management.** Every native semachk phase has a
rustc-oracle test: run native + run rustc-as-derivation; if
verdicts disagree, record a bug with the offending record
graph as reproducer. This is chalk's existing test pattern
applied to sema.

### Does semachk's shape affect rustc-as-derivation?

Yes. First, `Diagnostic.primary_site` is `RecordId` under both
regimes — we should not structure the rustc path around
"external byte-range spans"; semachk emits record-native
diagnostics from day one and the two streams merge into a
single `Diagnostic` kind differing only by `source: Rustc |
SemachkPhaseN`. Second, `CompilesCleanly`'s cache-key must be
stable across oracles — the proposition is the same whatever
ran it.

---

## P2.3 — Version skew between criomed and sema

Criomed v2 opens a sema written by v1. What fails; how?

### Precedents

**Datomic.** Schema *is* data — `:db/ident`, `:db/valueType`,
`:db/cardinality` are attributes in the same log as user data.
Migrations are **add-only**: add attributes, add composite
indexes, no downtime. You **cannot** remove, rename, or
retype. Renames are "install new, dual-write, retro-transact
old → new, stop dual-writing." Type changes: "new attribute,
migrate, retire old." No schema version number; the schema
is the current state; backward-compat held by never changing
existing attributes' semantics.

**PostgreSQL.** Detection by `server_version_num` +
`CREATE EXTENSION ... VERSION` + `pg_class` rows. Up-migration
is explicit: `pg_upgrade` (binary-format) or SQL migrations
(logical); server refuses to start on a data dir from a
higher major. Minor/patch = binary-swap. Well-maintained
production DBs keep a `schema_migrations` table (Rails /
ActiveRecord, `refinery` in Rust); startup compares expected
vs applied and refuses if mismatched. "(a) hard error"
softened with "(b) up-migration via explicit operator
action."

**Unison codebase format.** Codebase is content-addressed by
construction — every definition named by its hash. The
*storage format* is explicitly versioned (V1/V2/V3), stored
in a `format-version` file; `ucm` refuses to open a higher-
versioned codebase with an older binary. Upgrade is one-way
explicit: `ucm pull; ucm upgrade <v>`. The *user-level schema*
(types) never needs migration — old definitions keep their
hashes, old code keeps working — only the format does.

**rkyv.** `Archive` produces a version-specific memory layout.
Adding/removing/reordering fields invalidates archived bytes.
rkyv provides `CheckBytes` validation but **no automatic
schema-migration path** — closest is "archive → deserialise →
mutate → re-archive." Schema evolution is explicitly not a
design goal. So rkyv gives us bit-exact validation for free
but is hard-error-by-default on layout change.

### Three strategies — weighed

**(a) Hard error.** criomed embeds `SCHEMA_VERSION` (hash of
all nexus-schema record-kind rkyv layouts, computed at
criomed build). On open, reads `sema/schema_version`
sentinel. Mismatch → refuse to start. Simple; zero migration
complexity; matches rkyv; matches architecture.md §8 "no
backward compat." Brittle once Li has a real workspace —
every layout change bricks every sema on the machine;
"re-ingest every `.rs`" is fine for a toy workspace, painful
later.

**(b) Up-migration.** criomed embeds a migration plan — an
ordered list of `Migration { from, to, steps }` records.
On open, if `stored != embedded`, run the chain. Each
`MigrationStep` is itself a record — assert new schema,
retract old, rewrite rule. Migration runs as a Revision:
observable, reversible (if steps are asserted-only). Real
upgrade path; user workspaces survive. Matches Datomic's
add-only philosophy + PostgreSQL's logical-migration pattern.
First migration bug = corrupt sema; fix is non-trivial.

**(c) Read-only fallback.** Mismatched sema opens read-only;
writes refused until `nexus-cli migrate`. That verb runs (b)'s
logic explicitly, atomically, with a user-visible commitment
moment. Combines (a)'s safety with (b)'s upgrade path. Matches
Unison's `ucm upgrade` UX. Requires criomed to carry both
old and new schemas simultaneously (must read old to migrate
it).

### Recommendation: (c) read-only fallback with migration records

**Rationale.** (a) is right for pre-MVP and the first solstice
milestone — zero code, and while Li is the only user on a
test workspace, re-ingest is cheap. The moment (1) Li wants
to keep a real workspace across upgrade, (2) a collaborator
joins, or (3) we publish a release — (a) becomes liability.
(b) is tempting but auto-migration failures are scary: first
time criomed rewrites 50000 records on open and crashes
halfway, debugging is a nightmare. (c) is the honest middle:
user owns the upgrade moment; migration is explicit; on
failure pre-migration sema is untouched.

**Record shapes for migrations.**

- **SchemaVersion** — `{ sema_version: u32, criomed_build_id:
  BuildId, created_at }`. One per sema; sentinel.
- **Migration** — `{ from: u32, to: u32, title: String, steps:
  Vec<MigrationStepId>, guard: MigrationGuard }`. `guard`
  is a pre-flight query that must succeed.
- **MigrationStep** — variant over `AssertSchemaRecord`,
  `RetractSchemaRecord`, `RewriteRule { source_pattern,
  target_pattern }`, `RenameAttribute { old, new }`,
  `DropAttribute`, `SetDefault { attr, value }`. Each
  content-hashed; chain from old → new is the transitive
  closure.
- **MigrationRun** — evidence record; `{ migration, started,
  finished, records_affected, outcome: Success | Failure {
  error } }`. Written at end; visible to subscribers.

The migration chain is itself a content-addressed sema
structure — auditable, reversible in principle (forward
Migrations must supply inverses).

**On open:**

1. Read `SchemaVersion`.
2. If `sema.version == criomed.version`, proceed.
3. Else: open read-only; log `RequiresMigration` via
   subscription channel.
4. User runs `nexus-cli migrate`; criomed computes path,
   runs as a single Revision, writes `MigrationRun`, updates
   sentinel.
5. Resume normal operation.

**Cross-cut with semachk.** Derived analyses — `ProgramClause`,
`TraitResolution`, `InferenceResult` — are **never migrated**.
Erase on upgrade; re-derive on demand. Only user-authored
records (`Fn`, `Struct`, `Module`, etc.) migrate. Narrows
migration surface dramatically.

**Cross-cut with rustc cache.** `CompilesCleanly(opus,
input_closure_hash)` is in the "derived and re-derivable"
category — erase on upgrade; next compile regenerates. Per
027 §9 the cache key composes `(opus_hash, schema_version,
rsc_version, toolchain_pin, semachk_version)`.

### Cross-cut with P0.1 (hash vs name refs)

Under pure content hashes, any schema change that alters a
record's canonical encoding invalidates every hash in the
closure. Adding a field to `Fn` means every containing
`Module` / `Program` / `OpusRoot` must re-hash and re-point.
That's the whole workspace. Schema migrations under hash-only
are effectively "re-hash everything" — tractable (Unison does
it) but measurable minutes on realistic workspaces.

Dual-mode is cheaper: rewrite only the affected attribute's
indexes; leave hashes of unaffected records alone. Datomic
pattern. **This pushes P0.1 slightly toward dual-mode** for
the long run. Daily name-resolution cost is manageable;
whole-sema re-hash per schema bump is architectural friction.
Not dispositive, but worth noting.

---

## Cross-cutting synthesis

**P2.1 ↔ P0.1.** Diagnostic translation works under either
ref regime; `primary_site` holds whichever form sema stores.
rsc's map emits the matching form. Per 026 §4f the map is
`RecordId`-keyed regardless — ref form is presentation, not
structural.

**P2.2 ↔ rustc-as-derivation.** Semachk's phase migration is
compatible with rustc-as-derivation throughout. Every native
phase's output record kind is shared with rustc's:
`Diagnostic`, `CompilesCleanly`, `TraitResolution`,
`InferenceResult`. The only difference is `source: Rustc |
SemachkPhaseN` on each record. **The records produced by
today's rustc path are exactly the records tomorrow's
semachk will produce** — no schema churn to add semachk
later. This is the single most important decision to nail
down now even though semachk is months-to-years away:
design analysis records for the post-semachk world, under
today's rustc-only regime.

**All three together.** Diagnostic shape (P2.1) + checker
identity (P2.2) + upgrade survival (P2.3) compose into one
coherent picture:

- **Diagnostic** carries `source: Rustc | SemachkPhaseN`,
  `primary_site: RecordId`, `raw_rustc_json:
  Option<StoreEntryRef>`.
- **Semachk phases** ship in (iii)→(vii) order; all phases
  emit the same record kinds.
- **Migration** erases derived records on upgrade; requires
  explicit `nexus-cli migrate` for user-authored changes;
  re-derivation regenerates diagnostics from whatever
  compiler / semachk is running now.

---

## Recommendations, short form

- **P2.1**: adopt **(c) hybrid** — primary span as `RecordId`,
  rest as opaque rustc-JSON blob in lojix-store.
  `CompileDiagnostic` + `DiagnosticSuggestion` land in
  nexus-schema. Macro expansion degrades to "closest
  enclosing record" attribution.
- **P2.2**: adopt **B** — native cheap phases, rustc-as-
  derivation for typeck/trait/borrow. Phase roadmap
  (i)–(ii) already-shipping → (iii) module+privacy → (iv)
  public-API check → (v) orphan rules → (vi) unused →
  **pause** → (vii) trait solving via chalk-solve adapter
  per 029. Every native phase has a rustc-oracle test.
- **P2.3**: adopt **(c) read-only fallback** with
  `SchemaVersion` sentinel + `Migration` + `MigrationStep`
  + `MigrationRun` records. Derived analyses erase on
  upgrade; user-authored records migrate explicitly.

---

*End report 044.*
