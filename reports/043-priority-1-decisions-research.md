---
title: Priority-1 MVP decisions — deep research
author: Claude Opus 4.7
date: 2026-04-24
status: research synthesis; decisions recommended, not ratified
feeds: reports/031 P1.1–P1.5; docs/architecture.md §5, §8
---

# 043 — Priority-1 MVP decisions — deep research

*Claude Opus 4.7 / 2026-04-24. Five load-bearing decisions from
report 031 §P1, worked to the depth where concrete record shapes
and migration paths are on the table. Problem → Options →
Tradeoffs → Recommendation → Migration → Open sub-questions.
Cross-cutting interactions at the end.*

> **⚠ P1.4 recommendation simplified 2026-04-24** per Li's P0.1
> clarification: the reference model is **index-indirection**
> (slot-refs in records; sema's index holds `slot → {current-hash,
> name}`). Under that model, the "swing the pointer" pattern
> isn't a name-specific trick — it applies to **every
> reference**. Content edits never rehash dependent records;
> cascades fire from index-entry changes. The firewall cache
> story below stands; the named-ref-swing substrate becomes the
> universal-slot-swing substrate. See reports/046 §P0.1 and 046
> §P1.4.

---

## P1.1 — Edit UX: how humans and LLMs mutate a 500-record body

### Problem

A function body is not one record; it is a cascade. The existing
`nexus-schema` module layer models `Fn`-like shapes as nested
`Expr` / `Statement` / `Pattern` / `Type` records; a mid-size
function expands to several hundred records. Report 026 frames
edits as `(Mutate (Fn resolve_pattern { body: (Block …) }))`
arriving over nexus; report 027 §3 shows no human will type the
right-hand side, and today's LLMs are not trained on nexus record
trees. The "sema is the truth" thesis rests on mutation happening
*at the record level*, yet the interface between that thesis and
a usable editor is the biggest day-one UX risk.

The engine needs a surface that (a) humans can write, (b) LLMs
can emit from their training distribution, (c) reaches any record
in the graph, (d) preserves sema's logical invariants.

### Options

**(a) Path-patch verbs in nexus grammar.** A Pascal-named
`(Patch <path-expr> <new-subtree>)` record, where path-expr is
itself a record — `(At (Fn resolve_pattern) body stmts 3 rhs)`.
No new sigil, no new delimiter; path-patch rides on existing
grammar slots, matching report 013 §3.3's "operators are records"
discipline. Batched patches compose via `{|| ||}` atomic
transactions for free.

**(b) Text round-trip via rsc.** User runs `nexus-cli edit`;
criomed projects the opus to a scratch workdir via rsc; `$EDITOR`
opens; on save, the ingester re-parses and streams delta verbs
back. Familiar tooling (LSP, rustfmt, clippy work over the
scratch) but comments and formatting evaporate per cycle unless
records carry them (P1.2).

**(c) Hybrid.** Path-patch for surgical edits (programmatic
callers, refactor tools); text round-trip for bulk rewrites.
Both surfaces are first-class.

### Tradeoffs

Path-patch preserves the invariant "every mutation is a logical
operation on records, stored verbatim as an `Assertion` in the
history log." Audit trails read naturally; rules-as-records
(P1.5) need mutations to be structural to fire correctly;
subscriptions (report 013 §3.5) deliver diffs most meaningfully
when commits are structural.

Text round-trip is the only option that works today with LLM
tooling. GPT-class models emit `.rs` because they have seen
billions of lines of it; they have never seen nexus record
trees. Structural editors — Lamdu, Hazel, MPS, Isomorf, Unison's
`ucm` — illustrate the adoption problem starkly: every one is
technically admirable and commercially marginal. Unison is the
closest precedent: a structural-mutation shell over a
content-addressed code store; five years in, its community
remains a research niche. "Structural editing is better" has
been tested repeatedly; the market answer has been "not enough
better to retrain on."

The hybrid covers both audiences but splits implementation
budget. The honest risk is that path-patch rots from disuse if
every real edit goes through text — its code path bit-rots
before it stabilises.

### Recommendation

**Adopt (c) with text round-trip as the primary developer flow
and path-patch as the primary programmatic flow.** Accept that
LLMs will edit text: they are the single largest source of
mutations in the Li-and-agents future the engine is being built
for, and fighting their training distribution is a losing bet.
Path-patch exists so criomed's own rules, cascades, and internal
refactors speak the structural language directly.

Grammar sketch (no new sigils, existing delimiter families):

- Path expression is a record: `(At <root-ref> <hop> …)`. Hops
  are `(Field <name>)`, `(Variant <name>)`, `(Index <n>)`,
  `(Key <pattern>)`. Root is `(OpusRoot <name>)` or a hash-ID.
- `(Patch <path-expr> <new-subtree>)` replaces the subtree;
  `(Insert <path-expr> <n> <el>)` and `(Remove <path-expr>)`
  handle list ops.
- Batched via `{|| (Patch …) (Patch …) ||}`.

### Migration

Phase 0 (MVP self-hosting): ship text round-trip only. The
ingester (report 031 P0.3) is already needed; edit is a thin
CLI wrapper over it. Path-patch record kinds (`nexus::mutate::*`)
exist in nexus-schema but grammar dispatch is not wired.
Structural commits from the text flow are valuable — the MVP
gets structural history for free even though the user edits
text.

Phase 1: wire path-patch grammar. First customers are criomed's
internal cascade rules and refactor tools. LLM tooling wanting
to skip the round-trip opts in.

### Open sub-questions

- **Path uniqueness under shared sub-expressions.** Under
  content-addressing, two paths may reach the same sub-record.
  Right answer is "patches apply to record-IDs; path
  expressions resolve to record-IDs before application,"
  collapsing ambiguity structurally.
- **Comment round-trip fidelity.** See P1.2. If records carry
  `Doc` but not general comments, text flow loses non-doc
  comments. Warn once; accept.
- **Partial-ingest failures.** If the ingester parses but one
  record fails schema validation, MVP rolls back the whole
  commit and surfaces the error; Phase-1 explores partial
  commits gated by `{# #}` (report 013 §3.4 reservation).

---

## P1.2 — Comments and doc-comments

### Problem

Report 026 says records hold code as logic; it says nothing about
comments. rsc projects records to `.rs`; if records don't carry
comments, projected text has no comments; if text round-trip is
the primary edit flow (P1.1), every cycle loses every comment.
Over a handful of self-host iterations, the codebase degrades
into undocumented ruins.

Rust's compiler handles this a specific way. Doc-comments (`///`
and `//!`) desugar at parse time into `#[doc("…")]` attributes
that ride through HIR and reach rustdoc. Non-doc comments (`//`
and `/* */`) are stripped by the lexer and never reach HIR;
rustfmt and rust-analyzer recover them from source text for
formatting and hover, but they are not part of the language's
semantic representation.

### Options

**(a) Doc-comments as records, other comments dropped.** Mirror
rustc's split. A `DocStr` record carries the text; non-doc
comments are lossy; rsc emits a single formatting style.

**(b) Full fidelity.** Every comment, every whitespace choice,
every blank line becomes a record. Projection is bit-identical.
Expensive: schema catalogue roughly doubles, dedup is
ineffective, history fills with trivia churn.

**(c) Dual-store: structural sema + trivia sidecar.** Records
hold logic; a companion file per opus (in lojix-store) holds
`(record-id → trivia-blob)` mappings. rsc re-inlays trivia on
projection. Complicated; feels like reinventing source maps.

### Tradeoffs

(b) is what a structural editor like Hazel would demand. The
cost is real: every whitespace choice a database record; dedup
ineffective; history log fills with meaning-free assertions.
Strictly worse than (a) unless the entire product is a
structural editor — which nexus is not.

(a) is what rustc does and what rust-analyzer approximates.
Doc-comments are load-bearing (API docs, rustdoc, IDE hover);
they deserve first-class record treatment. Non-doc comments
explain subtleties; if text round-trip drops one, the user
notices and rewrites it. Not ideal, not a disaster — matches
every compiler except bit-faithful structural editors.

(c) sounds elegant and is a trap. Every function edit mutates
trivia-blob IDs; lojix-store churns; no logic moved. (b) with
extra steps.

### Recommendation

**Adopt (a).** Concretely:

- `DocStr` record kind in `nexus-schema`, holding Markdown as an
  owned `String` (inline for small docs; promoted to a
  lojix-store `FileAttachment` via `StoreEntryRef` above a
  threshold — say 4 KiB — so identical large docs dedup).
  Identity is blake3 of canonical text.
- Add `Option<DocStrId>` to every documentable record kind:
  `Fn`, `Struct`, `Enum`, `Module`, `Field`, `Variant`,
  `Method`, `Const`, `TraitDecl`, `TraitImpl`, `Newtype`,
  `Program`. Not on `Expr` or `Statement` — Rust doesn't permit
  doc-comments there.
- rsc, projecting a populated `doc` field, emits
  `#[doc = "…"]` (equivalent to `///` per rustc). The ingester
  normalises both to `DocStr`.
- Non-doc comments are explicitly lossy. rsc emits none; the
  ingester drops `//` and `/* */` silently. Users see a
  one-line banner the first time they run edit mode
  ("non-doc comments drop on re-ingest; use `///` to persist
  commentary") and never again.
- Formatting is rsc-canonical: rustfmt defaults, no
  configuration surface. Re-ingest is formatting-idempotent.

### Migration

MVP ships `DocStr` on all documentable kinds. Schema addition
in `nexus-schema`, not a new crate — it belongs with the code
records it annotates. rsc gains an "emit docs" codegen rule.
The r-a-linked ingester (report 031 P0.3) already parses doc
attributes via `hir-def`; translation is mechanical.

Post-MVP, if "lost comments" complaints materialise, (c) is the
extension path: opt-in `Opus.preserve_trivia` attaches a
sidecar. Document the cost; don't enable by default.

### Open sub-questions

- **Markdown or plain text in `DocStr`?** Rust doc-comments are
  Markdown. Store as text; let rustdoc render. Parsed Markdown
  AST would force every consumer to link a Markdown parser —
  overkill.
- **Multi-line doc-comments — one `DocStr` or many?** One per
  documentable record; the ingester concatenates `///` lines
  with `\n` as rustc does internally.
- **Module-level `//!`.** Attaches to enclosing `Module`'s
  `doc` field.
- **`#[doc = include_str!("…")]`.** Macro invocation; ingester
  materialises the referenced file into `DocStr` text at
  ingest. The attachment path handles large docs naturally.

---

## P1.3 — Cargo.toml, flake.nix, and the non-Rust surface

### Problem

`Opus` covers the nix-like slice of Cargo.toml: toolchain pin,
features, target triples, inputs by content-hash. Real workspaces
contain far more. The surface to enumerate:

`Cargo.toml` (workspace): `[workspace]`, `[workspace.dependencies]`,
`[workspace.package]`, `[patch.*]`, `[profile.*]`, `[replace]`.
Per-crate: `[package]` metadata, `[lib]`/`[[bin]]`/`[[test]]`/
`[[bench]]`/`[[example]]`, `[dependencies]`, `[dev-dependencies]`,
`[build-dependencies]`, `[features]`, `[profile.release.package.*]`,
`[target.'cfg(…)'.dependencies]`, `[lints]`.
`Cargo.lock`, `flake.nix`, `flake.lock`, `rust-toolchain.toml`,
`.gitignore`, `.mailmap`, `build.rs`, `tests/`, `examples/`,
`benches/`, doctests, `README.md` / `CHANGELOG.md` / `LICENSE.*`,
non-text assets (fixtures, golden files), proc-macro crates.

### Enumeration and decision per surface

Buckets: **(a)** already a record via `Opus`/`OpusDep`/etc.;
**(b)** new record kind; **(c)** opaque attachment (blob in
lojix-store); **(d)** out-of-scope MVP.

| Surface | Bucket | Record kind |
|---|---|---|
| workspace `Cargo.toml` [workspace] | (a) | `Opus` + `WorkspaceInheritedDep` |
| `[patch.*]` | (b) | `PatchOverride` (new) |
| `[profile.*]` | (b) | `BuildProfile` (new) |
| `[package]` metadata | (a) | `Opus` (extend fields) |
| `[lib]`/`[[bin]]`/`[[test]]`/`[[bench]]`/`[[example]]` | (b) | `BuildTarget` (new) |
| `[dependencies]` et al. | (a) | `OpusDep` (+ `cfg_condition`) |
| `[features]` | (a) | on `Opus` |
| `[target.'cfg(…)'.*]` | (b) | `CfgExpr` (new) on `OpusDep` |
| `[lints]` | (b) | `LintConfig` (new) |
| `Cargo.lock` | (d) MVP / (b) post | derived; later `LockSnapshot` |
| `flake.nix` | (a) | `Derivation` + `FlakeRef` |
| `flake.lock` | (d) MVP / (b) post | derived; later `FlakeLockSnapshot` |
| `rust-toolchain.toml` | (a) | `RustToolchainPin` |
| `.gitignore`, `.mailmap`, `CODEOWNERS` | (c) | `FileAttachment` |
| `build.rs` | (b) | `BuildScriptOpus` + `BuildScriptOutcome` |
| unit tests `#[cfg(test)]` | (a) | `Fn` + `cfg_gate` |
| integration tests | (a) | separate `Opus`, kind `IntegrationTest` |
| doctests | (b) | `DoctestTarget` (new) attached to `DocStr` |
| proc-macro crates | (a) | `Opus.kind = ProcMacro` |
| README / CHANGELOG / LICENSE | (c) | `FileAttachment` |
| test fixtures, binary assets | (c) | `FileAttachment` |

### Tradeoffs and rationale

`Cargo.lock` and `flake.lock` are resolver outputs, not
user-authored — the ingester re-derives them at compile time
(cargo sees the manifest rsc projects and produces its own lock).
MVP treats them as out-of-scope for sema. Post-MVP they become
outcome records asserted alongside `CompiledBinary` for
reproducibility audits. `build.rs` as a separate `BuildScriptOpus`
mirrors cargo's own model (build scripts are separate binary
targets); its `BuildScriptOutcome` captures the emitted
`rustc-cfg` / `rustc-env` directives. Doctests are tiny `Fn`-like
records attached to their containing `DocStr`, plus a
`DoctestTarget` in `Opus.targets`; rsc regenerates both the
doc-comment (with fenced code intact) and the harness file cargo
expects. Integration tests are *separate crates* per cargo's
rules; each becomes its own `Opus` marked `IntegrationTest`. No
special-casing — integration tests are opera that happen to be
tests. Proc-macro is one flag (`Opus.kind = ProcMacro`); the
semantic consequences (build-dependencies-only, `#[proc_macro]`
fn items) are enforcement rules applied at assert time.

`FileAttachment` (gestured at in reports 025 §8 and 033,
formalised here) holds `{ path: String, store_entry:
StoreEntryRef, role: AttachmentRole }` where `role` is
`GitIgnore | License | Readme | AssetBlob | ConfigFile | …`.
rsc materialises attachments verbatim into the scratch workdir;
the ingester updates them when the file changes.

### Recommendation

MVP-ship `BuildTarget`, `BuildScriptOpus`, `BuildScriptOutcome`,
`CfgExpr`, `LintConfig`, `DoctestTarget`, and formalise
`FileAttachment`. Defer `PatchOverride` and `BuildProfile`
unless the self-host workspace needs them. `Cargo.lock` and
`flake.lock` stay derived — cargo and nix emit them during
`RunCargoPlan` / `RunNixPlan`; we do not model them as edits.

### Migration

MVP: the new kinds land in nexus-schema. rsc gains projection
rules for each. The r-a-linked ingester already knows Cargo;
wiring is mechanical. Post-MVP: parse `.nix` proper (currently
opaque strings on `Derivation`) when the cost of not parsing
becomes real.

### Open sub-questions

- **`CfgExpr` granularity.** Full Rust cfg is a tiny language
  (`all`/`any`/`not` + `feature =` / `target_os =` / etc.).
  ~200 lines of schema.
- **Workspace-level inheritance.** `{ workspace = true }` in
  per-crate deps: represent as `OpusDep.source: DepSource`
  enum.
- **Cargo's auto-discovery conventions** (`src/bin/foo.rs`
  auto-detects as a bin). Ingester applies at ingest, producing
  explicit `BuildTarget` records. Sema is explicit.

---

## P1.4 — Cascade cost and firewalls

### Problem

Sema cascades: one edit propagates. Rename `foo.bar` → `foo.baz`,
and every `FieldAccess` to that field in every body in every
crate must update. Without bounds, worst case is O(workspace)
per edit. Report 031 P1.4 leans toward "swing the current-state
pointer; leave old records addressable," but the pattern
interacts with hash-vs-name refs (P0.1) in ways unspecified.

### Options

**(a) Swing the current-state pointer.** Named-ref table entries
(`OpusRoot`, `Bookmark`, and — under dual-mode refs per P0.1 —
per-name current-hash entries) mutate. Records themselves are
immutable. An edit updates the table; readers following name-refs
see the new state; readers following hash-refs still see the
old. Cascade cost O(|directly-edited records|); analyses and
subscriptions re-fire on demand.

**(b) Eager rewrite of all referring records.** Change a field
name, rewrite every record whose content transitively mentions
it. Strictly O(workspace) per edit. Fights content-addressing.

**(c) Salsa-style firewalls + targeted invalidation.** Named-ref
swing as substrate; analyses cached by `(input-closure-hash,
rule-id)`. When the table swings, dependent closures' hashes
change and cache entries lazy-invalidate. Re-derivation is
on-read. Approximately what rust-analyzer's salsa does, with
blake3 keys replacing salsa's interned IDs.

**(d) Differential dataflow / DBSP.** Datalog deltas with
provenance tracking. Research-grade incrementality; Phase-2+
answer for rules-as-records (P1.5 overlap).

### Tradeoffs

(a) alone is what git does and it scales to the Linux kernel.
Problem: historical queries keep answering with the old state
(fine — old Revision analyses are valid for that Revision) but
*current-state* queries re-derive from scratch every read.
Analyses need a cache, so (a) alone isn't sufficient in practice.
It is the substrate; (c) rides on top.

(b) is the textbook bad choice. Content-addressing's whole point
is to avoid rewriting unchanged records. An edit that ripples
through every transitive referrer is exactly what git's
blob/tree model is designed to avoid via the tree-object
indirection. Sema already has that indirection (names →
current-hash); use it.

(c) is the engineering sweet spot and matches precedents. Salsa
in rust-analyzer uses firewalls at well-chosen boundaries:
item-tree, module graph, name resolution, macro expansion,
signature, body, type inference, method resolution, trait
resolution. Each is a separate query with its own input closure.
Change a body and only body-level analyses for that `Fn`
invalidate; signature-level analyses do not. We steal the
boundary catalogue wholesale — hardened vocabulary.

(d) is the post-MVP destination. Report 022 cited DBSP; its cost
model is right for a rules-as-records engine firing derivations
incrementally. Gap between (c) and (d): "caches invalidate at
named-ref-swing boundaries" vs "every rule fires only on the
delta, with provenance." semachk benefits from (d); MVP ships
(c).

### Cost patterns

**Cheap:** function-body edit (invalidates body-typeck and
borrow-facts for that `Fn` only; signature, coherence, callers
unaffected; salsa firewall at body boundary). New `Fn` in a
module (invalidates module item-tree and name-resolution for
that module). `DocStr` attach (no semantic invalidation; only
rsc projection cache).

**Medium:** signature change (invalidates typeck for the `Fn`
and every caller; bounded by reachability query "which
`CallExpr` records reference this `FnId`?"). New `trait impl`
(invalidates coherence for the trait — rustc does this
crate-globally; MVP delegates to rustc-as-derivation; post-MVP
semachk does it incrementally).

**Expensive:** field rename across the workspace. Under
hash-refs: no cascade (field referenced by `FieldId`, unchanged
by rename). Under name-refs: every `FieldAccess { base_type,
field_name }` must re-resolve; O(|accesses|). Under dual-mode:
criomed's name-resolution pass re-runs for the touched type;
`FieldAccess` records re-bind. **This is an argument for P0.1's
dual-mode lean — post-resolution references are hashes, so
post-resolution mutations of names are cheap.** Blanket impls
(`impl<T: Trait> Other for T`): classical worst case; every
`Other` obligation in the crate. Post-MVP this becomes a
datalog-delta under (d); MVP delegates.

### Guardrails

Three levels:

1. **Named-ref swing is always O(1).** The commit is bounded;
   cascades happen on subsequent reads. No reads, no
   re-derivation. Free under (a) + (c).
2. **Analysis cache invalidation is by key, not graph walk.**
   Re-derivation cost is bounded by the analysis's own
   complexity, not workspace size.
3. **Subscription fan-out coalesced at `Revision` boundaries.**
   Deliver at most one event per subscriber per Revision. Cheap;
   matches Datomic's tx-report queue model. Protects against
   DOS by rapid edits.

### Recommendation

**Adopt (a) + (c) for MVP.** Named-ref-swing is the commit
model; salsa-firewall-and-cache is the analysis model. Steal
rust-analyzer's firewall boundaries as the starting catalogue.
Budget: commit is O(1); analysis cost pay-on-read, keyed by
well-chosen firewall IDs.

Formalise the pattern: **every analysis record carries
`input_closure: Vec<RecordId>`**. Criomed caches by
`hash(input_closure) + rule_id`. When a record in the closure's
current-hash swings, the closure-hash changes and the cache
entry lazy-invalidates — next read triggers re-derivation.

### Migration

MVP: named-ref-swing + basic input-closure-hash cache.
Guardrail: subscription coalescing at Revision boundaries.

Phase-1: mechanically port rust-analyzer's query catalogue to
our record model. Substantial (dozens of queries) but each port
is small — we adopt the boundaries and rewrite each query to
take `RecordId`s instead of salsa-interned IDs.

Phase-2+: identify analyses whose re-derivation is O(workspace)
worst-case and port them to differential dataflow. Coherence
and trait solving are priority candidates — the only rustc
phases classically O(crate) even incrementally.

### Open sub-questions

- **Cache eviction policy.** LRU on read-time when self-host
  workspace grows large enough to need it.
- **Cross-opus cascade.** An edit in opus A invalidates opus
  B's analyses across boundaries. No new mechanism — "closure
  spans opera" — but closure sets grow for public APIs. Same
  cost class as rustc's crate-boundary checking.
- **Retract semantics.** When a user retracts a record, its
  analyses should retract too (not re-derive). Cache keys must
  distinguish "input changed" from "input no longer exists."

---

## P1.5 — Rules as records: bootstrap and edit safety

### Problem

The records-as-rules thesis says rules are records, editable and
retractable like any record. But: retract the rule driving
`CompileDiagnostic` derivation and compilation stops surfacing
errors. Retract the rule maintaining `OpusRoot` integrity and
history desyncs. Some rules must not be retractable without
careful protocol; the engine bricks otherwise.

### Options

**(a) Hard protection: seed rules immutable.** Criomed hardcodes
`const SEED_RULE_IDS: &[RecordId]` (computed at build time as
blake3 of seed rule records embedded in source). `criome-msg`
refuses `Mutate` / `Retract` targeting listed IDs. Seed changes
require rebuild + cold-start. User-authored rules are unprotected.

**(b) Soft: convention + warning.** Rules named `criomed://…`
are flagged; retracting emits a warning but succeeds. Zero
mechanism; pure discipline.

**(c) Verify-on-startup (Unison pattern).** On boot, criomed
reads compiled-in seed IDs, checks each is present in sema with
expected hash, re-asserts any missing or mismatched. Users
retract at their peril; next restart fixes. Durable
misconfiguration requires stopping the engine and out-of-band
editing.

**(d) BLS-quorum policy gating (report 035).** Sensitive rules
gated by `Policy` requiring a quorum signature for mutation.
Post-MVP; no BLS or policy infrastructure in MVP.

### Tradeoffs

(a) is the strongest guarantee but closes the "rules are
extensible" door for seed rules. Bugs in seed rules require
code-change + rebuild + cold-start. Acceptable because changing
a seed rule *is* a significant change — the friction matches
the weight of the operation.

(b) fails predictably: a well-meaning cleanup retracts seed
rules, bricks the instance. "Read the warning" isn't a security
model.

(c) is elegant for Unison because ucm is the only edit surface.
For criomed, (c) makes seed rules recoverable — a mistake is
forgiven at next restart — but silently overrules user Retract
at boot (surprising without telemetry) and doesn't protect
against runtime damage: rules retracted while criomed runs break
every cascade that depended on them until restart.

(d) is the right long-term answer but orthogonal to MVP. Report
035 specifies `Policy` records with `required_quorum`; a
seed-rule policy requires a maintainer quorum. Post-MVP, the
hardcoded immutable list goes away.

### Recommendation

**For MVP: adopt (a) with (c) as a safety net.** Concretely:

- Criomed's loader hardcodes `SEED_RULE_IDS` computed at build
  time by hashing the seed rule records embedded in source.
- `criome-msg` handlers check against the list on every
  `Mutate` / `Retract` targeting a rule-kind record. Listed IDs
  reject with `AuthorizationError { reason: SeedRuleImmutable }`.
- On boot, criomed verifies all seed rules are present in sema
  ("decompile and verify"). Missing or mismatched rules are
  re-asserted from compiled-in seeds; a warning-class
  `RuntimeDiagnostic` marks the discrepancy. Covers the "sema
  DB got corrupted or hand-edited" case that (a) alone can't
  handle.
- User-authored rules follow normal authorization; retractable
  freely.

### Migration

MVP: (a) + (c). The compiled-in rule-set's hash becomes part of
criomed's version identity. `RuntimeIdentity` records include
`seed_rule_set_hash`; operators can tell when the binary's seed
set has changed.

Phase-1 (once BLS from report 035 lands): migrate seed rules to
`Policy`-gated. Each gets a `Policy { resource_pattern:
exact-match on rule RecordId, allowed_ops: [Retract, Mutate],
required_quorum: criomed-maintainers }`. The hardcoded list is
retired; its replacement is `Policy` records themselves, gated
by a meta-policy. Verify-on-startup still runs, comparing
against `Policy` records rather than a compiled constant.

Phase-2 (rules-as-records fully first-class): seed rules become
ordinary user-authored rules whose *authorship* is the
maintainer quorum. No hardcoded list; the floor is defined by
the quorum allowed to change it. Endpoint of the
records-as-rules thesis — rules are fully data, protection is
fully policy.

### Open sub-questions

- **Rule-set version skew.** Criomed v2's seed set differs from
  v1's sema DB. (c)'s re-assert logic needs a policy: MVP
  re-asserts with a warning (version upgrade is the expected
  cause). Alternative: refuse to boot on mismatch, requiring
  operator confirmation.
- **What counts as a "rule" record?** MVP has few (most cascade
  is in Rust code). As rules-as-records expands, the protected
  list grows. The list should be generated from seed-emission
  code, not hand-maintained.
- **Cross-opus rules.** A user-authored rule in opus A affects
  records in opus B. Authorization is by author, not location;
  Phase-1 policy-gating handles naturally.

---

## Cross-cutting interactions

### P1.1 (edit UX) × P1.4 (cascade cost)

Text round-trip (P1.1 primary) produces commits that look like
"many records changed" to sema — the ingester computes a
record-level diff, potentially touching hundreds of records for
a one-line text edit. Under named-ref-swing (P1.4), the commit
is O(|diff|) regardless of text edit size, but *diff quality
directly determines cascade cost*. A naive ingester re-asserts
the whole `Fn` on any edit; a precise ingester diffs
sub-records and keeps hashes stable where structure is
unchanged.

rust-analyzer's HIR lowering has the right shape here —
deterministic HIR that diffs cleanly. The r-a-linked ingester
inherits this quality. Writing our own ingester would make
diff-quality an explicit engineering goal taking several
iterations to reach parity. Another argument for the r-a-linked
ingester (report 031 P0.3 lean).

Path-patch verbs (P1.1 secondary) are the ideal for cascade
cost: `(Patch (At (Fn …) body stmts 3 rhs) <expr>)` mutates
exactly one sub-record and re-hashes exactly the ancestor
chain. No diffing, no hash churn. Programmatic callers speaking
path-patch directly sidestep the ingester and get the cheapest
possible cascade.

### P1.3 (non-Rust surface) × P1.2 (comments) × P1.1 (edit UX)

Text round-trip (P1.1) projects structured records to `.rs` via
rsc. Non-Rust files (P1.3) as `FileAttachment` blobs aren't
projected — they're materialised verbatim from lojix-store into
the scratch workdir. The user sees the full workspace: `.rs`
from rsc, `.md` / `.toml` / `.nix` / etc. from attachments. On
re-ingest, the ingester splits: Rust through r-a, other files
through their parsers (Cargo.toml → P1.3 records), unmodelled
files update their attachment hash.

Comments (P1.2) fit cleanly. `.rs` round-trips preserve
doc-comments via `DocStr`; non-doc comments are lost.
`Cargo.toml` comments: cargo ignores them silently; MVP drops
them. `.md` files are attachments — content preserved
byte-for-byte, no rsc projection, no comment loss.

The one corner case is `build.rs` — it's Rust, so it
round-trips via rsc and loses non-doc comments.
`BuildScriptOpus` inherits the same `DocStr` behaviour as
regular opera; users document build scripts with `///` if they
care.

---

*End report 043.*
