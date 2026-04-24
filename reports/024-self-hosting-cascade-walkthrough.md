# 024 — the self-hosting loop, as records, step by step

> **⚠ Framing correction — 2026-04-24**: Li: "sema doesnt give a
> fuck about tokenstream; it has a fully specified view of code.
> not text; logic!" This report walks through bootstrap and
> warm-edit using `SourceRecord`, `TokenStream`, `Ast`,
> `ItemTree` records and a `SourceRecord → TokenStream → Ast →
> ItemTree` cascade. Those records don't exist. Sema holds
> code as fully-specified logical records (`Fn`, `Struct`,
> `Expr`, … per report 004); text never enters sema.
>
> **What survives**: Part 1's loader-in-criomed (step 1), genesis
> schema records (step 2), genesis rules (step 3). Part 3
> restart story is correct. Part 4 honest-awkwardness list
> (schema-of-schema, rules bootstrap, proc-macros,
> mid-cascade consistency, schema-crate chicken-and-egg) is
> correct. Part 2's warm-edit is wrong as written.
>
> **The corrected bootstrap path**: a one-shot ingester tool
> (outside criomed) parses workspace `.rs` via `syn`, translates
> the AST to nexus-schema records, streams `Assert` verbs to
> criomed, exits. After that, sema never parses text again.
> Editing happens by mutating records directly.
>
> **The corrected warm-edit**: user sends `(Mutate (Fn
> resolve_pattern { body: (Block …) }))`; criomed asserts the
> new `Fn` record; cascade re-derives `Obligation` / analyses
> that reference that `FnId`; `CompilesCleanly(opus)` flips via
> rustc-as-derivation. No text, no token stream, no AST record.
>
> See [reports/026 §3 and §5](026-sema-is-code-as-logic.md) for
> the corrected narrative. Part 5's inventory: strike
> `SourceRecord`, `TokenStream`, `Ast`, `ItemTree`,
> `MacroExpansion` as sema records.

*Claude Opus 4.7 / 2026-04-24 · concrete narrative timeline of
cold start, warm edit, and close-the-loop for the sema engine,
at record-kind granularity. Companion to reports 021
(criomed-evaluates), 022 (prior art), 023 (rustc-as-derivation).*

---

## Part 1 — Cold start: from nothing to a sema holding the engine's own source

**Starting state.** A freshly-created sema directory: a redb file
containing only the table catalogue (records, current-state
pointers, subscription registrations, pending work). Zero
application records. On disk alongside it: a `cargo build`-produced
`nexusd` / `criomed` / `lojixd`; the workspace source tree.
Neither binary has ever touched this sema.

**Step 1 — criomed starts.** Criomed opens the redb file, notices
the records table is empty, and enters a *bootstrap* path. This
is the one place in its life where it writes records without a
caller asking. Answering PRIME's open question: **the loader
lives in criomed**, as a small internal actor that materialises a
hardcoded set of genesis records on empty-sema detection, then
stands down.

**Step 2 — genesis records.** The first records to appear are
*schema records*, not source. Criomed's internal Rust types
(`Opus`, `Derivation`, `SourceRecord`, `Ast`, etc.) each get a
**KindDecl** record, plus a set of **FieldDecl** records per
struct-shaped kind. A **SchemaRoot** record pins the hash over
the whole kind registry and becomes the target every future
mutation validates against. These genesis KindDecls are the same
record kind as user-written KindDecls would be; they are
privileged only in that criomed hardcodes their content.

**Step 3 — genesis rules.** The loader then asserts the core
**Rule** records (`[|| ||]` family, per report 013) that the
cascade cannot function without: `SourceRecord → TokenStream`,
`TokenStream → Ast`, `Ast + CfgContext → ItemTree`, and so on
through report 023 §3's derivation chain. These are ordinary
content-addressed records; on future runs criomed reads them
from sema rather than re-asserting.

**Step 4 — ingesting the workspace source.** A bootstrap client
tool (part of nexus-cli) walks the workspace. For each file: it
`PutBlob`s the bytes to lojixd (returns a blob hash), then sends
`Assert(SourceRecord { opus_id, path, content_hash: blob_hash,
edition })` to criomed via nexusd. Bytes never pass through
criomed. This is a stream of ordinary criome-msg `Assert` verbs
— not a new daemon, not a criomed-internal batch.

**Step 5 — Opus graph.** The tool then asserts one **Opus** per
crate (referencing its SourceRecord hashes), **OpusDep** records
mirroring Cargo.toml's `[dependencies]`, and one
**RustToolchainPin**. Sema now holds the workspace declaratively.

**Step 6 — cascade settles.** Each SourceRecord assertion triggers
its downstream rule chain: `TokenStream`, `Ast`, `ItemTree` per
file; `ModuleGraph` per opus; public-API `Resolution` per path
site (per report 023's MVP: cheap phases in criomed; body typeck
defers to rustc-as-derivation). Each derived record carries a
**DerivedFrom** sidecar naming the firing rule and its bindings.

**Step 7 — first compile.** The user sends
`(Compile workspace-root-opus)`. Criomed finds no matching
**CompiledBinary** and emits a **RunCargoPlan** record:
`{ workdir, args, env, fetch_files: Vec<(Hash, RelPath)>,
toolchain_path, expected_outputs }`. Inputs to this derivation:
the Opus, transitive OpusDeps, the RustToolchainPin, the
CrateGraph, the SourceRecords. Criomed then dispatches this plan
to lojixd as a `RunCargo` lojix-msg verb. Lojixd materialises
`fetch_files` into the scratch workdir, spawns `cargo build
--release`, hashes the resulting binary, stores it in lojix-store,
replies `{ output_hash, warnings, wall_ms }`.

**Step 8 — the binary becomes a record.** Criomed asserts
**CompiledBinary** `{ opus_id, input_closure_hash, blob_hash,
toolchain_pin, produced_at_rev, wall_ms }`. The `input_closure_hash`
is a blake3 over (Opus + transitive OpusDeps + SourceRecords +
toolchain pin) — the cache key. The tie back to the producing
Opus: by `opus_id` for human lookup, by `input_closure_hash` for
cache identity, and via a **DerivedFrom** sidecar naming the
RunCargoPlan.

Sema now contains enough to reproduce the compile. The engine is
bootstrapped.

---

## Part 2 — Warm edit: a single function body changes

**Scenario.** User edits the body of `resolve_pattern` in
`criomed/src/resolver.rs`, signature unchanged. Nexus-cli hashes
the new text, `PutBlob`s it, sends
`(Mutate (SourceRecord path=… content_hash=H_new))`.

**Step 1 — mutation lands.** Criomed asserts a new SourceRecord
with `content_hash = H_new`; the name→current-hash table entry for
that path atomically swings to the new hash. The old SourceRecord
is not excised — it stays addressable (matters for "sema at rev R"
queries). Datomic framing: retract the current-pointer, not the
record.

**Step 2 — immediate cascade.** `SourceRecord → TokenStream`
fires for this file; new TokenStream record. `TokenStream → Ast`
fires; new Ast. `Ast → ItemTree` fires — and here the rust-analyzer
firewall engages (report 023 §4): **the new ItemTree's hash equals
the old one** (body-only edit doesn't change item signatures), so
the cascade stops propagating up. ModuleGraph does not re-derive.
ImportMap does not re-derive. Sibling files' TypeckResults do not
re-derive.

**Step 3 — body-local re-derivation.** The rule "ItemTree +
changed body → TypeckResult(body_id)" fires for exactly one body.
Inputs: unchanged `SigOf(resolve_pattern)`, unchanged `SigOf` of
callees, unchanged trait-impl index, changed body-`Ast`. Produces
a new TypeckResult. `Mir(body_id)` fires next; then
`BorrowResult(body_id)`. In the MVP these inner-phase rules are
stubs because body typeck defers to rustc — the TypeckResult
record exists but its contents are placeholders filled in by the
rustc-derivation outcome.

**Step 4 — what's firewalled.** Every other body's TypeckResult,
Mir, BorrowResult; every other module's import resolution; every
coherence check. Cascade cost is O(depth of derivation chain for
one body), not O(workspace). Payoff of granular rules.

**Step 5 — when does rustc run?** The cascade produces a new
**RunCargoPlan** at edit time (changed `input_closure_hash`,
because SourceRecord hash is a transitive input) — this is
criomed's incremental planning per report 021. But **rustc itself
does not run automatically**. The plan sits as a pending record.
Rustc runs only on explicit `(Compile …)` or when an eager
subscription exists on `CompilesCleanly(opus)`. Default is
on-demand; always-on-edit is ruinous at workspace scale.

**Step 6 — explicit compile.** User sends `(Compile criomed)`.
Criomed consults the current RunCargoPlan, finds no CompiledBinary
for this `input_closure_hash`, dispatches `RunCargo`. Lojixd runs
cargo, replies with a new `output_hash`.

**Step 7 — binary replacement.** A *new* CompiledBinary record is
asserted with the new `input_closure_hash` and `blob_hash`. The
old CompiledBinary is **not retracted** — it stays addressable.
The current-state pointer "latest binary of opus criomed" swings
to the new record. If the old blob is no longer reachable from any
live CompiledBinary, criomed's GC may later issue `DeleteBlob`.

**Step 8 — subscriptions fire.** Subscribers on
`CompilesCleanly(criomed)` or `CompiledBinary(criomed)` get a
`<|>` stream event (report 013). In the self-host loop: a watcher
tool in another terminal prints "criomed rebuilt at hash H".

---

## Part 3 — The close-the-loop moment

**Scenario.** User materialises the new criomed binary to disk,
kills the running one, starts the new one against the same sema.

**Step 1 — materialise.** `(MaterializeFiles target=/tmp/criomed-new
files=[(blob_hash, "criomed")])`. Criomed translates to a
lojix-msg `MaterializeFiles` verb; lojixd copies from lojix-store
to the path with the executable bit. Optionally, an audit
**Materialisation** record is asserted; can skip for MVP.

**Step 2 — kill the old criomed.** In-flight state: any uncommitted
mutation is lost (redb transaction drops); any in-flight `RunCargo`
sees its reply channel close at lojixd's end. SIGTERM flushes redb
cleanly; SIGKILL leans on redb's recovery on next open. Crucially,
**no durable sema state reflects criomed's process identity** —
SubscriptionRegistrations name nexusd-connection IDs, not PIDs.

**Step 3 — new criomed starts.** It opens the sema directory and
finds it non-empty: SchemaRoot, KindDecls, Rules, SourceRecords
(including the new `resolve_pattern` body), Opus graph, old
CompiledBinaries. The genesis loader detects SchemaRoot already
exists and skips. Warm start reads what cold start wrote.

**Step 4 — schema consistency check.** The new criomed validates:
does its compiled-in understanding of each kind match the KindDecl
records in sema? If the new binary changed `nexus-schema`, it may
not. MVP answer: mismatch → refuse to start with a clear error.
Post-MVP: migration records applied at open time. Self-host loops
that don't touch `nexus-schema` just work.

**Step 5 — re-establish ephemerals.** SubscriptionRegistration is
a durable record, but its `subscriber_id` is session-local. On
restart, dead registrations are GC'd lazily — next cascade
attempts delivery, finds the id unresolvable, retracts the
registration. Live subscribers are responsible for re-subscribing
with fresh `Subscribe` verbs. No other in-memory state needs
rebuilding: plans are records, rules are records, caches are
records.

**Step 6 — self-identification.** The new criomed asserts
**RuntimeIdentity** `{ daemon: "criomed", binary_hash: self.exe_hash,
started_at, pid }` on startup. `binary_hash` is the blake3 of
`/proc/self/exe`. Content-addressing dedups if the same binary has
run before. The current-state pointer "running criomed" updates to
this RuntimeIdentity.

**Loop closes.** Next mutation runs the cascade inside the *new*
criomed, which may behave differently — `resolve_pattern` is now
the new implementation. The engine has modified itself.

---

## Part 4 — Where this framework gets awkward

- **Sema schema as records.** The KindDecl+FieldDecl+SchemaRoot
  set *is* sema's schema. Bootstrapped by criomed's genesis loader
  on cold start, validated on every open, extensible by
  user-written KindDecls. MVP answer: **hardcode the core schema
  in criomed's source** (the genesis table); write once; divergence
  is a hard error with no migration path. Post-MVP: migration
  records, user-authored schema in nexus text. The load-bearing
  move is that once written, KindDecls are ordinary queryable
  records.

- **Rules: in sema from the start, or hardcoded?** Same shape.
  MVP answer: **genesis rules are hardcoded in criomed**, asserted
  by the bootstrap loader. The "first rule" is something trivial
  like `SourceRecord → TokenStream`. Once asserted, they're
  ordinary records — queryable, editable (cautiously), even
  retractable (foot-gun). User-authored rules arrive via nexus
  text like any other record. The honest framing: criomed-the-binary
  contains *code that writes genesis records into empty sema*; it
  does not contain a separate evaluator. This is the same seed
  every self-bootstrapping system has (Unison, Smalltalk, Lisp).

- **Proc-macros are Turing-complete Rust.** Criomed cannot run
  them — that would mean arbitrary user code inside the sema
  engine. MVP answer: **proc-macro expansion is lojixd's**. A
  **MacroExpansion** record is keyed by `(macro_def_hash,
  input_tt_hash)`; on miss, criomed dispatches a **RunProcMacro**
  lojix-msg verb; lojixd runs the macro in a sandboxed subprocess
  (rust-analyzer's proc-macro-server model); the output token tree
  becomes a blob, hash referenced by the new MacroExpansion record.
  Proc-macro expansion is an effect, same category as cargo-build.

- **IDE queries mid-cascade.** Consistency model: criomed serves
  reads at a **sema-revision** (monotonic counter, bumped on each
  committed mutation). Queries name a sema_rev (or implicitly
  "latest committed"). Redb's MVCC delivers this cheaply. A
  cascade-in-progress holds uncommitted derivations in a scratchpad
  invisible to readers at earlier revs; commit bumps the rev and
  new derivations become visible atomically. There is no partial
  cascade visible. Consequence: "find references to resolve_pattern"
  after an edit returns old references until the cascade settles,
  then new. Correct; no tearing.

- **Criomed's schema crate compiling itself.** Chicken-and-egg:
  `nexus-schema` is an opus in sema; compiling it yields a
  CompiledBinary whose bytes link into criomed; sema's schema
  validation depends on criomed understanding `nexus-schema`'s
  types. MVP answer: the running criomed's schema-understanding is
  the one baked in at build time. Editing `nexus-schema` records
  cascades and produces a new CompiledBinary, but sema continues
  validating against the *running* criomed until the user
  materialises-kills-restarts (Part 3). On restart the new criomed
  validates its compiled-in schema against sema's KindDecls; any
  mismatch is a hard error requiring record migration. Ugly but
  honest — it is the same constraint as changing a compiler's AST
  type: you must recompile and restart.

---

## Part 5 — Records inventory for the self-host loop

Every record kind that appeared above, one line each. Grouped by
phase; (\*) marks kinds unavoidable even if not explicitly named
in the walkthrough.

**Meta / bootstrap**
- **KindDecl** — declares a record kind (name, identity strategy).
- **FieldDecl** — declares a field of a KindDecl (name, type).
- **SchemaRoot** — current-schema pointer; hash over all KindDecls.
- **Rule** — a derivation rule in the `[|| ||]` rule family.
- **RuntimeIdentity** — "this daemon, this binary_hash, started at T, pid P".

**Source / syntax** (from report 023 §3)
- **SourceRecord** — `{ opus_id, path, content_hash, edition }`.
- **TokenStream** — tokens derived from a SourceRecord.
- **Ast** — AST derived from a TokenStream.
- **CfgContext** — active cfg predicates per opus.
- **MacroDef** — hash-keyed macro definition.
- **MacroExpansion** — `(macro_def, input_tt) → output_tt`.
- **ItemTree** — post-expansion items per file.
- **ModuleGraph** — module tree per opus.
- **CrateGraph** — opus nodes + dep edges per workspace.

**Name resolution** (MVP subset per report 023)
- **DefId** — stable identifier for a named item.
- **ImportMap** — `{ module_id → { name → DefId } }`.
- **Resolution** — `path_site → DefId | Error`.
- **VisibilityCheck** (\*) — `(from, to) → allowed`.

**Types / traits / bodies** (stubbed in MVP; filled by rustc-as-derivation)
- **Ty** (\*) — canonical type record.
- **SigOf** — `def_id → Signature`.
- **TraitDecl**, **TraitImpl** (\*) — trait system records.
- **Obligation** (\*) — typeck obligation + resolution.
- **TypeckResult** — per-body typeck outputs (stub in MVP).
- **Mir**, **BorrowFacts**, **BorrowResult** (\*) — deferred to rustc.

**Opus / build spec** (nexus-schema, per report 017/021)
- **Opus** — pure-Rust artifact spec.
- **OpusDep** — opus → {opus | derivation} link.
- **Derivation** (\*) — wraps a nix flake / inline expr.
- **RustToolchainPin** — toolchain identity.
- **NarHashSri / FlakeRef / OverrideUri / TargetTriple** (\*) — supporting newtypes.

**Plans and outcomes**
- **RunCargoPlan** — concrete cargo invocation derived from Opus+deps+toolchain.
- **CompiledBinary** — `{ opus_id, input_closure_hash, blob_hash, toolchain_pin, produced_at_rev, wall_ms }`.
- **Diagnostic** — error / warning parsed from rustc JSON.
- **CompilesCleanly** — opus-level roll-up; exists iff zero error Diagnostics.
- **Materialisation** (optional) — audit of a MaterializeFiles call.

**Engine bookkeeping**
- **DerivedFrom** — provenance sidecar: `{ record, rule, bindings }`.
- **SubscriptionRegistration** — durable subscription; subscriber_id is session-local.
- **CurrentStatePointer** — not a record but a redb-table row: name → hash, for "current schema", "latest binary of opus X", "running criomed".

Records not listed because they did not appear and are not
unavoidable at this stage: `RunNixosRebuild` outcomes, cross-opus
provenance aggregates, `TimeAt` bitemporality sidecars (deferred
per report 022 §5), post-MVP deploy records.

---

*End report 024.*
