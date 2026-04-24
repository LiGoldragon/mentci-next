# 025 — sema schema inventory beyond Rust code

> **⚠ Framing correction — 2026-04-24**: Li: "sema doesnt give a
> fuck about tokenstream; it has a fully specified view of code.
> not text; logic!" Most of this report is correct (schema-of-
> schema, rules-as-records, revision/assertion, subscriptions,
> plans/outcomes, capabilities, non-Rust blobs, MVP ranking).
>
> **Contamination**: Part 3 described `ModulePath` as "every path
> site in source". There are no source sites — sema holds logical
> records; names are a secondary index `Vec<Name> → RecordId`.
> Part 9's "Rust cascade records" bullet listing `SourceRecord,
> Ast, ItemTree, ModuleGraph, TypeckResult` as MVP-essential is
> wrong — the Rust-side MVP records are the nexus-schema record
> kinds (report 004: `Fn`, `Struct`, `Expr`, `Type`, …) plus
> analyses (`Obligation`, `Diagnostic`, `CompilesCleanly`).
>
> See [reports/026 §3](026-sema-is-code-as-logic.md) for the
> corrected layer stack.

*Claude Opus 4.7 / 2026-04-24 · enumerates the non-Rust record
kinds sema must hold because sema IS the evaluated truth — schema,
rules, names, history, subscriptions, plans, caps, blobs — and
ranks them for the solstice MVP.*

Report 023 covered what sema holds about Rust source. This report
enumerates what else must live in sema for the engine to be the
engine — every record kind whose *absence* would force criomed to
hold state somewhere other than sema. Goal: coverage, not
specification. Each entry names a record, sketches intent, and
points at where the shape would land.

---

## Part 1 — Schema-of-schema: does sema hold its own schema?

Forced by the mutation path: for criomed to validate
`(Mutate (Foo { bar: 7 }))`, it must know what "Foo" is — kind,
fields, field types. Three options:

- **(A) Compiled in.** `nexus-schema` is baked into criomed.
  *Hallucination wall*: rock solid, static. *Self-modifiability*:
  none — new kinds require criomed recompile. *Bootstrap*:
  trivial. *Sync*: same binary = same schema by construction;
  upgrades are coordinated restarts.
- **(B) Records in sema.** Users `(Assert (StructSchema …))` at
  runtime. *Hallucination wall*: still solid, but the wall is
  itself data. *Self-modifiability*: full. *Bootstrap*:
  non-trivial — first-boot needs seed schemas as axioms; a
  meta-schema must validate StructSchema itself. *Sync*: peer
  A's new schema must replicate before B can use records of that
  kind.
- **(C) Hybrid.** A small core schema set (meta-schema + Opus +
  Rule + Revision) is compiled in; user-defined kinds layer on
  as `StructSchema` records. *Hallucination wall*: layered.
  *Self-modifiability*: high for user code, zero for meta-schema
  (correct tradeoff — meta-schema churn is rare). *Bootstrap*:
  moderate. *Sync*: meta by binary version; user by record
  replication.

**Recommendation**: (C). (A) is too brittle once rules are
records; (B) is research-grade. The core compiled set must cover:
meta-schema records (`StructSchema`, `EnumSchema`, `FieldSchema`,
`VariantSchema`, `TypeRef`, `TypeParam`); Opus / Derivation /
OpusDep (reports/017 §1); rule records (Part 2); Revision and
Assertion (Part 4); Subscription (Part 5); Plan / Outcome
(Part 6); CapabilityPolicy (Part 7); StoredBlob / FileAttachment
(Part 8). Anything else is user-asserted `StructSchema`.

---

## Part 2 — Rules-as-records

Per 022 §3–§4 and the `[|| ||]` family (013), rules are
stratified datalog with aggregation, stored as records. The
record shapes capture premise, head, bindings, stratum,
provenance.

- **`RulePremise`** — a pattern the rule matches. Variants:
  `Match` (single record kind with field atoms), `Join`
  (conjunction of Matches sharing variable names), `Negation`
  ("no record matching X"; stratification must put it on a
  lower stratum than its dependents), `Aggregation` (`Count`,
  `Sum`, `GroupBy` from 013's matrix — a premise returning a
  bound value computed from many records). **`RulePremise`
  embeds `PatternExpr`, not `RawPattern`** — rules live in sema
  where hallucinated names would poison the cascade. Resolution
  happens at rule-assertion time.
- **`RuleHead`** — a partial record with some fields bound to
  premise variables. Must be ground after substitution; no free
  variables escape. One rule, one head kind; multi-output
  scenarios become multiple rules sharing a premise (a
  performance hint for the engine).
- **`RuleBinding`** — not a separate record. Bindings are
  implicit in variable names shared between premise and head.
  Redundant to materialise.
- **`Rule`** (outer record) — `name`, `premise`, `head`,
  `stratum`, `materialization: Always | Lazy | Never`
  (022 §7; MVP = Always everywhere), optional preconditions.
- **`RuleStratum` / `StratificationPlan`** — a global property
  of the rule set, not per-rule. Options: store on each Rule
  (convenient, recompute on changes) or keep an opus-level
  `StratificationPlan`. The second is cleaner; MVP can do
  per-rule and migrate.
- **`DerivedFrom`** — every derived record carries a sidecar:
  `{ rule: Hash, bindings, inputs: Vec<Hash> }`. Enables
  "why is this record here" queries, cascade retraction (walk
  backwards when a premise record is retracted), rule debugging.
  Storage-expensive but critical per Eve's lesson (022 §6).

**Integration with `PatternExpr`**: because `RulePremise`
embeds it directly, `PatternExpr` must live in `nexus-schema`
(not only internal to criomed as 017 §2 had it). The raw-vs-
bound split stays: `RawPattern` is wire-only; `PatternExpr` is
stored/bound. Rules carry `asserted_at_rev: Hash` for
re-resolution after schema migrations.

---

## Part 3 — Identity, naming, and references

Records are blake3-hashed; users think in names. The mapping
lives in sema.

- **`OpusRoot`** — `{ opus_name → root_hash }`, already canonical
  per architecture.md §3. The git-refs table. Mutable named-ref,
  not content-hashed itself; updates are transactional.
- **`ModulePath`** — `{ segments, resolved: DefId }`, content-
  hashed, deduplicated. Potentially millions per opus (every
  path site in source). Input to report 023's name-resolution
  cascade.
- **`NameAlias`** — per-scope `{ scope, name, target }` for
  `use foo::Bar as Baz` and operator-kind imports inside rules.
- **Symbolic refs** (HEAD-like): `WorkingHead { opus →
  sema_rev_hash }`, `Bookmark { name → sema_rev_hash }` (user-
  set labels like `pre-migration` / `good-build`),
  `PendingMerge { opus → Vec<sema_rev_hash> }` (divergent
  histories, post-MVP). All named-ref table entries, not
  content-hashed.
- **`QueryScope`** — the ambient namespace a nexus query runs
  in: `{ opus, sema_rev, imported_schemas }`. Trivial in MVP
  (one opus, one scope). Real when multi-opus coexists.

---

## Part 4 — History, time, and revision

- **`Revision`** — every mutation produces a new state. Fields:
  `parent` (linear hash or `Vec<Hash>` if merges matter),
  `asserted: Vec<AssertionHash>`, `retracted: Vec<AssertionHash>`,
  `wall_time` (informational), `caused_by: MutationRequestHash`.
  The revision's hash is the state identifier.
- **`Commit`** — optional human annotation on a revision:
  `revision, author, message, parent_commit`. Picks out
  meaningful points; engine uses revisions internally.
- **`Assertion`** — the individual fact:
  `{ record, rev, asserter, op: Add | Retract }`. Datomic's
  datom with extra context. The assertion log is the audit
  trail; current-state is a derived materialisation.

**History vs current-state** (architecture.md §3): both are real
redb tables. Current-state is "apply assertion log up to
WorkingHead, filter retracted"; criomed's writer keeps it in
sync. A peer rebuilding from history regenerates current-state
deterministically.

**XTDB valid-time vs tx-time**: MVP has tx-time only — revision
hash IS tx-time. Valid-time (late-arriving truth) layers on via
an optional `ValidAt { record, valid_from, valid_to }` sidecar
when a domain needs it. Records remain tx-time primary. Per
022 §5: Unison-default, XTDB-optional.

---

## Part 5 — Subscriptions, streams, liveness

**Subscriptions MUST be records** to survive criomed restart.
In-memory-only is simpler but kills continuous-agent UX across
daemon restarts.

- **`SubscriptionIntent`** — `{ id, pattern: PatternExpr,
  consumer: ConsumerRef, cursor: RevisionHash, created_at_rev,
  delivery_mode: AtLeastOnce | AtMostOnce | ExactlyOnce }`. MVP
  = AtLeastOnce.
- **`ConsumerRef`** — can't hold a live socket. Two approaches:
  named consumer (clients reconnect and claim by name) or
  "durable intent, ephemeral active". The second is cleaner —
  intent is data; active delivery is runtime state.

**`<| |>` stream grammar**: stream *definitions* are records
(survive restart); stream *results* are wire-only by default
(discarded after delivery). Persistence is opt-in via a separate
`StreamLog` record kind for users who want replay. Backpressure
stays TCP/socket flow control at nexusd for MVP; storing
emissions creates a real storage decision better left to a
Phase-1 design.

---

## Part 6 — Pending work, plans, outcomes

Criomed reads plan records from sema; lojixd executes; outcomes
become records. The lifecycle is visible as data.

**Plan records** (one per concrete verb):
`RunCargoPlan { opus_id, workdir_spec, args, env, fetch_files }`,
`RunNixPlan { flake_ref, attr_path, overrides, out_name }`,
`RunNixosRebuildPlan { flake_ref, target_host, switch_or_boot }`,
`PutBlobPlan`, `GetBlobPlan`, `MaterializeFilesPlan`,
`DeleteBlobPlan { hash, reason }` (GC). Each is a record; hash
is identity; identical plans dedupe.

**`PendingExecution`** — "plan P is currently running under
executor E". Fields: `plan, started_at, executor_id,
lease_expires_at`. Unusual because content may change. Options:
treat as a runtime table (not content-hashed; sacrifices purity)
or assert-retract on each lease renewal (consistent, more churn).
**MVP probably skips it entirely** — crash recovery derives
in-flight state from "plans without outcomes" and re-dispatches.

**Outcome records** (1:1 with plans, success or failure):
`CompiledBinary { opus, plan, binary_hash, warnings, wall_ms }`,
`CompileDiagnostic { plan, span, message, level }` (0–N per plan),
`CompilesCleanly { opus, sema_rev, plan, toolchain_pin }`,
`NixBuildOutcome { plan, out_paths, nar_hashes, wall_ms }`,
`DeployOutcome { plan, target, activation_rev, wall_ms }`,
`BlobPutOutcome { plan, hash, byte_len, wall_ms }`,
`GcOutcome { plan, freed_bytes, reclaimed_hashes }`,
`FailureOutcome { plan, kind, stderr_hash, exit_code }`. **Rule:
if Outcome(plan=P) is absent and PendingExecution(plan=P) is
absent, the plan is orphaned and must be re-dispatched.** The
023 set (`RunCargoPlan`, `CompileDiagnostic`, `CompilesCleanly`)
is a subset; full MVP needs cargo + blob plans; nix-build and
deploy land later.

---

## Part 7 — Capabilities and authorisation

Lojix-store accepts puts authorised by criomed-signed tokens.

- **Per-token records** would be noisy — tokens are short-lived
  (minutes); storing each is storage waste.
- **Policy + ephemeral signature** is lighter. Records:
  `CapabilityPolicy { principal, permits: Set<Op>, quota,
  valid_from, valid_to }`, `PrincipalKey { principal, pubkey }`
  (associates principals with signing keys; criomed is root).
  Ephemeral tokens are on-wire objects — the signature criomed
  puts on a lojix-msg envelope — not stored records.
  Revocation = retract the policy.

**Interaction with single-writer**: lojixd has no sema
connection. Lojixd writes to lojix-store (owns the directory);
replies flow back through criomed, which writes the outcome
record. Sema's writer stays singular. **No records are written
by lojixd directly** — load-bearing invariant.

---

## Part 8 — Non-Rust worlds

- **`FileAttachment`** — user-supplied files referenced into
  the engine: `{ name, content_hash, mime_hint, source_record }`.
  Bytes live in lojix-store. Use cases: LLM uploads a diagram;
  test fixture references a binary input.
- **`BlobRef`** — a *field type*, not a standalone kind.
  `BlobRef = ContentHash` as a named newtype lets reachability
  analysis find lojix-store references structurally across all
  records.
- **`StoredBlob`** — sidecar metadata anchor:
  `{ hash, byte_len, stored_at, producer }`. Kept by criomed via
  lojixd outcomes. Useful for "list all binaries" debuggability
  and reachability GC.
- **EnvVar**: no separate record — already an `Opus.env` field
  tuple (017 §1). Part of Opus's identity hash.
- **ProcessOutcome**: covered by specific outcome records
  (CompiledBinary etc., each carrying `wall_ms, stderr_hash,
  exit_code`). A generic `ProcessRunOutcome` backs arbitrary
  exec for future use; not MVP.
- **`DerivationLock`** (NixFlakeLock-style):
  `{ drv_id, resolved_nar_hash, locked_at_rev }` captures
  "when we last resolved this derivation, it evaluated to this
  nar-hash". A `LockSet { opus, derivations: Map<DrvName,
  NarHash> }` per-opus aggregates. MVP trusts flake-ref hashes
  directly; the lock layer prevents surprise upgrades Phase-1+.

---

## Part 9 — Ranking for MVP

Solstice self-hosting is the only gate. One-sentence
justifications for the MVP-essential; Phase-1 and Phase-2 get
brief tags.

**MVP-essential** (self-hosting does not close without these):

- **Core schema records** (`StructSchema`, `EnumSchema`,
  `FieldSchema`, `TypeRef`, `VariantSchema`) — without them,
  every mutation is unvalidated and the hallucination wall is
  theatre.
- **Opus, Derivation, OpusDep** — no compile path without them
  (017).
- **Revision + Assertion** — cascades need transaction
  boundaries; no boundaries means no cascade semantics.
- **OpusRoot** — something has to name the current state.
- **Rule, RulePremise, RuleHead** — the thesis ("records are
  the evaluation") requires rules as records day one.
- **`PatternExpr` lifted into nexus-schema** — forced by rules-
  as-records; non-negotiable once Rule is MVP.
- **Rust cascade records** (023's minimal set: SourceRecord,
  Ast, ItemTree, ModuleGraph, TypeckResult, Diagnostic,
  CompilesCleanly) — self-hosting compiles need a cache story.
- **Plan + Outcome records** (RunCargoPlan, CompiledBinary,
  CompileDiagnostic, CompilesCleanly, BlobPutOutcome,
  FailureOutcome) — criomed→lojixd dispatch is the whole
  run-time loop.
- **BlobRef + StoredBlob** — lojix-store reachability can't
  happen without typed pointers.

**Phase-1** (valuable but cuttable for solstice):

- **DerivedFrom / RuleProvenance** — debuggability gold (022 §6);
  ship naïve recompute without it and add when rule debugging
  becomes a time-sink.
- **Durable SubscriptionIntent** — matters once agents run
  continuously across criomed restarts.
- **Stream-definition records** (`<| |>` stored; emissions
  wire-only) — nexus-ui uses this; MVP polls.
- **Commit** (on top of Revision) — human-readable labels;
  convenient not load-bearing.
- **CapabilityPolicy + PrincipalKey** — needed once there's
  more than one principal; MVP signs blindly.
- **ModulePath / NameAlias as general records** — 023 lists
  them for the Rust cascade; generalising is a Phase-1 step.
- **QueryScope** — trivial in single-opus MVP; real when multi-
  opus arrives.
- **NixBuildOutcome / RunNixPlan** — needed once derivations
  drive nix builds end-to-end.
- **MaterializeFilesPlan** — needed once lojixd must assemble
  workdirs from records rather than on-disk source.

**Phase-2+** (design space; not blocking):

- **XTDB valid-time** via `ValidAt` sidecars — no current need;
  door stays open.
- **Bookmark / PendingMerge** — branching history post-MVP.
- **Per-rule materialisation policy** — 022 §7 Phase-2.
- **StratificationPlan as a top-level record** — on-the-fly
  recompute suffices; explicit plan is optimisation.
- **PendingExecution** as a first-class record — crash
  recovery via "plans without outcomes" is enough.
- **StreamLog** (persisted emissions) — niche; wait for use case.
- **DerivationLock / LockSet** — until we hit a reproducibility
  bug, hashing flake refs is enough.
- **DeployOutcome / RunNixosRebuildPlan** — not on the self-host
  path.
- **GcOutcome** records — GC itself is Phase-1; recording
  outcomes Phase-2.
- **Excision** as an admin verb — Datomic's sharp-edge; design
  when GDPR or legal forces it.
- **ProcessRunOutcome (generic)** — specific outcomes cover MVP;
  generalise later.

The pattern: MVP carries just enough records to make the thesis
real (schema + rules + revisions + plans/outcomes + compile
cascade + blob refs); Phase-1 adds the niceties that turn the
engine from "works" to "debuggable and live"; Phase-2+ opens
the design space the thesis invited but doesn't urgently need.

---

*End report 025.*
