# 046 — decisions synthesis — P0 through P3 with recommendations + action plan

*Claude Opus 4.7 / 2026-04-24 · unified recommendations across
the 14 open decisions from report 031. Deep analysis lives in
042 (P0), 043 (P1), 044 (P2), 045 (P3); this report is the
navigable digest + ordered action plan.*

---

## TL;DR — the 14 leans

| # | Decision | Lean |
|---|---|---|
| P0.1 | Hash-refs vs name-refs | **Index-indirection**: records store slot-refs; index holds `slot → { current-hash, name, … }` |
| P0.2 | Mutually recursive functions | **Unison-style `FnGroup`** with member indices |
| P0.3 | Ingester scope | **`syn` + custom resolver** for MVP; r-a crates post-MVP |
| P1.1 | Edit UX | **Hybrid**: text round-trip default + `(Patch …)` verb family |
| P1.2 | Comments and docs | **`DocStr` as records** (mirrors `#[doc]`); non-doc comments lossy |
| P1.3 | Non-Rust workspace surface | **Per-surface catalogue**: Opus covers Rust; new record kinds for build.rs, lint config, doctests, file attachments |
| P1.4 | Cascade cost | **Swing-the-pointer** + salsa-style firewall caches; DBSP deferred |
| P1.5 | Rule safety | **Hard protection** (seed rules compiled-in, verify-on-startup) |
| P2.1 | Diagnostic spans | **Hybrid**: primary span → RecordId; secondaries + suggestions as opaque JSON |
| P2.2 | semachk feasibility | **Option B**: cheap phases first (parse-equivalent, name-res, module graph); body typeck via rustc forever |
| P2.3 | Version skew | **Read-only fallback** + explicit migration verb; rkyv bit-compat catches most drift |
| P3.1 | Thin CLI home | **Second binary in `lojix/`** during B-E; extract to `lojix-cli/` at Phase F |
| P3.2 | lojixd transport | **UDS + 8-byte LE length prefix + rkyv**; match nexusd↔criomed |
| P3.3 | Deploy verbs generic vs CriomOS | **Generic in lojix-msg**; CriomOS defaults in the thin CLI |
| P3.4 | Phase ordering | **Start Phase B now**; C+D parallel with criomed skeleton; G last |

Decisive bottleneck for self-hosting: criomed existing + P0.3
ingester. Lojix transition is parallelisable.

---

## P0 — Foundational (sema-holds-code-as-logic)

### P0.1 · Index-indirection reference model

**Problem**: `reports/026` claims references are content-hash
IDs, but live `nexus-schema` stores names (`Type::Named(…)`
etc). A pure hash-ref model has a worse problem than either
direction: **ripple-rehash**. Changing a record's content
changes its hash, which forces every referring record to
re-hash, which cascades through the workspace.

**Recommendation** (per Li's 2026-04-24 clarification): records
store **slot-refs**, not content hashes. Sema owns an **index
table** per slot: `slot → { current_content_hash, display_name,
… }`.

- **Content edit**: updates the slot's `current_content_hash`.
  Dependents carry stable slot-refs → their own content hash
  is unchanged → no rehash ripple. Cascades still fire
  (salsa-firewall-style) because the slot's current-hash
  changed; dependents re-derive via subscription on that slot.
- **Rename**: updates the slot's `display_name`. No record
  rewrites anywhere. rsc picks up the new name on next
  projection.
- **Storage**: stored records contain `slot-ref` at every
  reference site (no names, no bare hashes).
- **Authoring / query**: clients type names; criomed resolves
  name → slot at commit time via the index.

**Why it works**: the index is sema's "mutable identity layer"
on top of immutable content-addressed records. Record hashes
stay stable under content edits of referents; the index moves.
This is Datomic's `eid` pattern + Git's ref-table, unified.

**Decisions ratified 2026-04-24** (via Li's follow-up; full
analysis in reports/047–049; synthesis in
[reports/050](050-slot-index-refinement-synthesis.md)):

1. **Slot-id is `Slot(u64)`** — monotonic counter minted by
   criomed, freelist-reused, with a reserved seed range
   `[0, 1024)`. Post-MVP migration path to `Slot(Blake3)`
   birth-hash for federation.
2. **Scope is global** and names are **global too**. One name
   per slot, stored on `SlotBinding.display_name`; renames
   change it once and every opus's rsc projection picks up
   the new name. Per-opus `MemberEntry { slot, visibility,
   kind }` declares the slots an opus defines plus their
   visibility — but not a local name. No aliasing at MVP; if
   `use X as Y`-style per-site aliases ever become load-bearing,
   add an `AliasEntry` record kind then.
3. **History is per-kind change logs** (one redb table per
   record-kind; key `(Slot, seq)`). Global `rev_index`
   auxiliary table for cross-kind queries. Per-kind log is
   ground truth; `index::K` + `rev_index` are derivable views.
4. **Cascade trigger** is subscription on `Slot → dependents`;
   fires on `SlotBinding.content_hash` changes; coalesced at
   Revision commit.
5. **Enum mapping is rsc-generated per-opus**, not stored in
   sema. Composite display-names computed by the **ingester**
   (the `.rs`→records translator) at slot-creation.

**Migration**: refactor `nexus-schema` to kill
`Type::Named(TypeName)` etc.; add the slot-ref type; criomed
(when it scaffolds) owns the index table.

**Full analysis**: [reports/042](042-priority-0-decisions-research.md) §P0.1 (with updated-recommendation banner at top).

### P0.2 · Unison-style `FnGroup` for mutual recursion

**Problem**: Content-hashing requires no cycles. `f` calling
`g` calling `f` is a cycle.

**Recommendation**: Introduce a record kind `FnGroup { members:
Vec<FnMember> }`. References inside the group go via
`FnRef { group: FnGroupId, index: u16 }`. The group hashes as
a whole; individual members don't have independent hashes.
Signatures factor outside the group boundary so a body edit
doesn't change downstream `FnId` if signatures are stable
(rust-analyzer-style firewall).

**Rationale**: Unison does exactly this. Tarjan's SCC at
ingest-time produces groups. Single-member "SCCs" are groups
of size 1, keeping the model uniform. Trait impls with mutual
methods inside the impl naturally fall into a group. Type
recursion handles cleanly via `Box` (already a solved pattern).

**Migration**: ingester runs Tarjan per opus; emits `FnGroup`
records for every SCC (including singletons); reference sites
carry `FnRef`.

**Full analysis**: [reports/042](042-priority-0-decisions-research.md) §P0.2.

### P0.3 · `syn` + custom resolver for MVP

**Problem**: Ingester (text → sema records) is not a weekend
project; name resolution alone is half of rustc.

**Recommendation**: For MVP, write a `syn`-based ingester with
a custom minimal resolver. Scope: own workspace only;
no arbitrary external crates; restrict macros to `derive(…)`;
`std` + `core` live as `ExternCrate(opaque-hash)` refs with a
hand-curated well-known-name table.

**Rationale**:
- Bounds scope at ~2-3 team-months for the self-host subset.
- Keeps ingester "ours" — no dependency on rust-analyzer's
  fast-moving crates at the project's critical path.
- Post-MVP path: swap in r-a-backed ingester when "ingest
  arbitrary third-party crates" is the target. Ingester is an
  intentionally-swappable component.

**Rejected**: linking `ra_ap_*` crates now. Too much scope,
too much churn.

**Rejected**: shelling out to `rustc --emit=metadata`.
Nightly-locked ABI; fragile.

**Full analysis**: [reports/042](042-priority-0-decisions-research.md) §P0.3.

### Cross-cutting P0

P0.1 is the root. Adopting hash-refs forces the ingester
(P0.3) to canonicalise at ingest time (which is exactly what
Tarjan + resolver do together). P0.2 is mechanically folded
into P0.1's storage rules.

---

## P1 — MVP self-hosting

### P1.1 · Hybrid edit UX

**Problem**: A function body is hundreds of records; users
don't type them. What's the edit surface?

**Recommendation**: Hybrid model.
- **Primary human/LLM edit flow**: text round-trip through
  rsc. User sends `(Edit opus)` or equivalent; criomed
  projects to `.rs` in a scratch file; user edits in
  `$EDITOR`; re-ingest; commit.
- **Programmatic/agent flow**: `(Patch (At path...) <subtree>)`
  records batched inside the existing `{|| ||}` atomic-txn
  delimiter. Pascal-named, no new sigils.

**Rationale**:
- LLMs are overwhelmingly trained on `.rs` text. Forcing them
  to speak native nexus for edits is empirically a losing
  battle.
- Structured editors (Lamdu, Hazel, Unison's ucm, MPS) have a
  30-year track record of failing to displace text — precedent
  is unambiguous.
- Path-patch verbs cover the programmatic flow (migrations,
  targeted rewrites) without forcing humans through them.
- `{|| ||}` atomic-txn delimiter already carries the batching
  semantics.

**Accepted loss**: non-doc comments + exact whitespace don't
survive ingest-via-text. rsc canonicalises formatting. This is
the trade for using LLMs.

**Full analysis**: [reports/043](043-priority-1-decisions-research.md) §P1.1.

### P1.2 · `DocStr` record kind

**Problem**: If comments die on round-trip, Rust docs die too.

**Recommendation**: Introduce `DocStr` as a first-class record
kind; every documentable kind (Fn, Struct, Enum, Module,
Field, Variant, Method, Const, TraitDecl, TraitImpl,
Newtype, Program) gains an `Option<DocStrId>` field. rsc
projects to `#[doc("…")]` attributes (the canonical Rust
desugaring of `///`). Markdown is stored as raw text; no
Markdown AST parsed.

**Non-doc comments**: explicitly lossy. Regular `//` and `/* */`
don't round-trip. Sema is canonical; formatting is emitted by
rsc.

**Full analysis**: [reports/043](043-priority-1-decisions-research.md) §P1.2.

### P1.3 · Non-Rust workspace surface

**Problem**: Cargo.toml has many sections; flake.nix, tests,
build.rs, doctests, proc-macros all exist.

**Recommendation**: Per-surface catalogue.

| Surface | Home |
|---|---|
| `[package]` fields | Already Opus fields |
| `[dependencies]`, `[dev-dependencies]`, `[build-dependencies]` | OpusDep |
| `[workspace]` members | Opus root list |
| `[patch.crates-io]` | Derivation family |
| `[features]` | Opus.features |
| `[[bin]]`, `[[test]]`, `[[bench]]` | New `BuildTarget` record |
| `build.rs` | Sub-`Opus` with `kind = BuildScript` |
| build-script output | `BuildScriptOutcome` record |
| `#[cfg(...)]` expressions | `CfgExpr` record |
| `flake.nix` top level | Mostly covered by Derivation records; `flake.lock` is a derived outcome, not input |
| `rust-toolchain.toml` | Mostly already `RustToolchainPin` |
| `.gitignore` | `FileAttachment` blob |
| Unit tests (`#[test]`) | In-opus; BuildTarget covers compile flags |
| Integration tests (`tests/*.rs`) | Separate Opus per test target (mirrors Cargo) |
| Doctests | `DoctestTarget` derived record |
| Lint config | `LintConfig` record |
| Proc-macro crate flag | `Opus.kind = ProcMacro` |

**Deferred to post-MVP**: `Cargo.lock` (derived); `flake.lock`
(derived); generic `FileAttachment` for arbitrary files (just
blobs until a structured shape emerges).

**Full analysis**: [reports/043](043-priority-1-decisions-research.md) §P1.3.

### P1.4 · Index-swing + firewall cascades

**Problem**: Edits must not ripple-rehash; cascades must be
bounded.

**Recommendation**: Under P0.1's index-indirection model, the
cascade story simplifies:

- **Substrate**: the sema index. Every reference is a slot-ref;
  the index maps slot → current-content-hash. ANY edit (rename
  OR content) is an index update, not a record rewrite.
  Dependents keep their own content-hash unchanged.
- **Cascade trigger**: subscription on index entries. When a
  slot's current-hash changes, dependent analyses re-derive.
- **Firewall caches**: derived analyses (TypeAssignment,
  Obligation, CompilesCleanly per opus) are salsa-style keyed
  by `(input_closure_hash, rule_id)`. Invalidate only when the
  closure-hash changes. Steal rust-analyzer's query boundary
  catalogue wholesale.

**Guardrails**:
- Subscription coalescing at revision commit boundaries (not
  per-assertion). Edit produces one commit → one notify.
- Worst-case-cascade budget: reject mutations whose cascade
  exceeds a threshold; require explicit `(Batch …)` wrapping.

**Deferred**: Differential dataflow / DBSP. Stratified-datalog
with semi-naïve evaluation is the Phase-1+ upgrade for
O(workspace)-worst-case rules (coherence, trait solving).

**Full analysis**: [reports/043](043-priority-1-decisions-research.md) §P1.4.

### P1.5 · Hard rule protection

**Problem**: Can a user retract the rule that drives the
cascade?

**Recommendation**: Hard protection. Seed rules carry a
compiled-in `SEED_RULE_IDS` allowlist. The mutation verb
refuses `Retract` on any seed-id; `Mutate` on a seed-rule
fails the schema check because seed-rule records have a
write-locked bit. On criomed startup, verify all seed rules
are present in sema; missing ones are re-asserted from
compiled-in seeds.

**Migration to Phase-1**: when BLS-quorum (report 035) lands,
the compiled-in `SEED_RULE_IDS` allowlist gets replaced by a
`CapabilityPolicy` requiring a root-quorum signature to touch
seed rules.

**Full analysis**: [reports/043](043-priority-1-decisions-research.md) §P1.5.

### Cross-cutting P1

P1.3 + P1.2 + P1.1 interact: attachments sidestep comment
loss; only `.rs` bodies round-tripping via rsc have the
lossy-comment problem. `build.rs` is the one edge case
(`.rs` text + possibly non-doc comments that matter).

P1.4 × P0.3: ingester quality drives cascade cost. Imprecise
ingest diffs trigger firewall cache misses. Incentivises
careful record-granular ingest (which the `syn` approach
supports).

---

## P2 — Ergonomics / post-MVP

### P2.1 · Hybrid diagnostic spans

**Problem**: rustc diagnostics have primary + secondary +
suggestion + macro-backtrace compound spans.

**Recommendation**: Hybrid storage.
- `CompileDiagnostic { opus, primary_site: RecordId, message,
  level, children: Vec<DiagnosticChild> }` — structured for
  the primary site and labeled children.
- `DiagnosticSuggestion`, macro backtrace, secondary spans →
  `suggestion_blob: BlobRef` pointing at opaque rustc JSON
  in lojix-store.

**Rationale**:
- 80% of IDE and query needs hit the primary site. Making it
  a first-class RecordId is high-value.
- Secondaries + suggestions are low-query, high-detail; JSON
  is fine.
- Robust under rustc JSON schema shifts (blob survives).

**Macro-expansion**: since sema records are post-expansion
(per report 026 Q4 — proc-macros run during ingest, not in
sema), rustc-span-inside-macro rarely surfaces in practice.
When it does, the span table maps to the `MacroInvocation`
record.

**Full analysis**: [reports/044](044-priority-2-decisions-research.md) §P2.1.

### P2.2 · semachk — Option B (cheap phases only)

**Problem**: Is the native checker ever going to happen?

**Recommendation**: Option B — cheap phases in criomed; body
typeck / trait solving / borrow check via rustc-as-derivation
forever.

Ordered phases for native implementation:
- (iii) Reference validity — free under hash-ref storage (P0.1).
- (iv) Module graph + visibility — days of work; high value
  (find-references, rename-preview).
- (v) Public-API signature check — weeks; "did you break the
  API".
- (vi) Public-API unification — weeks-to-months.
- (vii) Body typeck — via chalk-solve adapter; months, with
  permanent parity gaps.
- (viii) Full trait solving — years-or-never.
- (ix) Borrow checking — never (polonius-via-rustc forever).

**Rationale**: Option A (rustc forever) sacrifices ergonomics
(latency, non-queryable intermediate records). Option C (full
parity) is years-of-work and always trails rustc nightly.
Option B ships the user-visible wins (instant find-references,
instant API-break detection) without the parity trap.

**Key design implication**: sema's analysis record kinds
(`TypeAssignment`, `Obligation`, `TraitResolution`) are
shared between rustc-source and eventual-semachk-source from
day one. A `source: Rustc | SemachkPhaseN` enum discriminates
lineage but the record shape is identical.

**Full analysis**: [reports/044](044-priority-2-decisions-research.md) §P2.2.

### P2.3 · Read-only fallback with migration verb

**Problem**: New criomed on old sema.

**Recommendation**: Read-only fallback.
- sema carries a `SchemaVersion` sentinel record.
- New criomed reads it; if its own-compiled schema version
  is newer, sema opens read-only; a user-dispatched
  `Migrate { target: hash }` verb applies pending migration
  records in order.
- Migrations are records themselves: `Migration { id, parent,
  steps }` with steps like `AssertSchemaRecord`,
  `RenameAttribute`, `RewriteRule`, etc.
- Derived analyses (TypeAssignment, CompilesCleanly,
  ProgramClause) never migrate — they erase on schema bump
  and re-derive on demand.

**Rationale**: Datomic's add-only schema shapes this well.
PostgreSQL's explicit `pg_upgrade` shape is the safety model.
Unison's explicit codebase-format versioning is the durability
lesson.

**Full analysis**: [reports/044](044-priority-2-decisions-research.md) §P2.3.

### Cross-cutting P2

P2.2 × rustc-as-derivation: the same record kinds serve both
paths. No schema churn when semachk Phase-N lands.

P2.3 × P0.1: if hash-only were the reference model,
workspace-rehash on schema change would be catastrophic.
Dual-mode (P0.1) mitigates — names survive schema change;
hashes re-derive.

---

## P3 — lojix transition

### P3.1 · Second binary in `lojix/` (B-E) → extract at Phase F

**Problem**: Where does the thin CLI that builds lojix-msg
envelopes live?

**Recommendation**: During Phases B-E (report 030), add
`src/bin/lojix-cli.rs` as a second binary in the existing
`lojix/` repo. Keep `lojix` (the deploy binary) running
unchanged. At Phase F, extract `lojix-cli/` to its own repo
only if it's grown a real surface.

**Rationale**:
- Avoid premature repo-splits. Cost of new repo: flake.nix,
  CI, beads, Dolt.
- Kubectl, nix-cli, git all went through "monolithic binary →
  one repo → many binaries" evolution.
- Keeps the transition-plan's "don't touch production code"
  invariant (report 030 §5 guardrail 4 — binary name in
  Li's muscle memory).

**Full analysis**: [reports/045](045-priority-3-decisions-research.md) §P3.1.

### P3.2 · UDS + length-prefixed rkyv

**Problem**: lojixd's transport.

**Recommendation**:
- Unix Domain Socket at `$XDG_RUNTIME_DIR/lojixd.sock`.
- Wire frame: 8-byte little-endian length prefix + rkyv-archived
  `LojixMsg` envelope.
- 30-second idle ping.
- Idempotent replay: every plan carries `plan_id` (hash);
  lojixd holds a local redb `plan_id → outcome` with 24-hour
  TTL; duplicate submissions return the cached outcome.
- Criomed restart: lojixd retains the per-plan outcome cache;
  criomed re-issues plans missing in sema outcomes; lojixd
  replies from cache without re-running.

**Rationale**:
- Matches nexusd↔criomed transport (consistent ecosystem).
- Preserves rkyv zero-copy.
- Restart safety is durable in sema (plans + outcomes are
  records) — the wire is only concerned with current call.
- Windows is out of scope (CriomOS-only MVP).

**Full analysis**: [reports/045](045-priority-3-decisions-research.md) §P3.2.

### P3.3 · Generic lojix-msg + CriomOS defaults in the thin CLI

**Problem**: Current lojix CLI is CriomOS-specific.

**Recommendation**: Generic verbs in lojix-msg.
- `RunNixosRebuildPlan { flake_ref, attr, action, overrides,
  target_host }`
- `RunHorizonProjectionPlan { proposal, cluster, node,
  outputs }`
- Per-host plans; multi-target deploy = N plans (Shape-A from
  045).
- Per-host secrets: out-of-band for MVP; encrypted records
  post-MVP.

Thin CLI (`lojix-cli`) supplies CriomOS defaults
(`--criomos github:LiGoldragon/CriomOS`, default target
patterns) as a convenience layer. The daemon is
project-agnostic.

**Rationale**: Matches how nix itself separates
`nixos-rebuild` (generic) from wrappers. Same pattern in
kubectl / helm / terraform.

**Full analysis**: [reports/045](045-priority-3-decisions-research.md) §P3.3.

### P3.4 · Phase B now; C+D parallel with criomed skeleton

**Problem**: How much of report 030 depends on criomed?

**Recommendation**:
- **Phase B now** (create `lojix-msg` crate with envelopes
  mirroring existing lojix in-process types plus `sema_rev`
  and `corr_id` for future-proofing). Doesn't depend on
  criomed.
- **Phase C + D in parallel** with criomed skeleton work —
  not after it. Scaffold `lojixd` daemon + `--via-daemon` flag
  in `lojix`; validate the lojix-msg shape before criomed
  commits to depending on it.
- **Phase E (migrate all actors, flip default)** waits for
  operational maturity.
- **Phase F (repo rename)** waits for Phase E stable.
- **Phase G (criomed routes deploys)** is the last piece and
  gates on criomed being usable end-to-end.

**Decisive critical-path bottleneck**: criomed existing +
P0.3 ingester scope. Lojix work is parallelisable with
criomed skeleton and does not drive self-hosting's clock.

**Full analysis**: [reports/045](045-priority-3-decisions-research.md) §P3.4.

### Cross-cutting P3

All four P3 decisions are loosely coupled. P3.2's UDS+rkyv
choice is what enables P3.4's "start Phase B before criomed
is ready" — if transport choice required criomed to be alive,
the phase ordering would compress.

---

## Decision dependency graph

```
                                    ┌─ P0.1 hash/name refs ──────────────┐
                                    │                                    │
                                    ├─ P0.2 SCC hashing (mechanical) ────┤
                                    │                                    │
                                    └─ P0.3 ingester (syn MVP) ──────────┤
                                                                         │
                                   ┌─ P1.1 edit UX (hybrid) ─────────────┤
                                   │                                     │
                                   ├─ P1.2 DocStr records ───────────────┤
                                   │                                     │
                                   ├─ P1.3 non-Rust surface ─────────────┤
                                   │                                     ▼
                                   ├─ P1.4 cascade (pointer+firewall) ── self-hosting
                                   │                                     ▲
                                   └─ P1.5 rule protection ──────────────┤
                                                                         │
             ┌─ P2.1 diagnostics (hybrid) ────┐                          │
             │                                │                          │
             ├─ P2.2 semachk (B: cheap first) ├── post-MVP ergonomics ───┘
             │                                │
             └─ P2.3 migration (read-only) ───┘

   P3.x lojix transition: parallel track; meets mainline at Phase G
```

**Critical path for self-hosting**: P0.1 → P0.2 + P0.3 → P1.4
+ P1.5 → criomed scaffolds. P1.1/P1.2/P1.3 harden the self-host
loop but a minimal path closes without all of them (hand-curated
records + rsc + cargo is sufficient for the first loop).

---

## Ordered action plan (no ETAs)

### Immediately unblocks implementation

1. **Apply P0.1 to `nexus-schema`**: replace `Type::Named` and
   siblings with `TypeId` (content-hash). Name-index tables
   appear in sema (when criomed scaffolds); schema crate emits
   no name-strings at reference sites.

2. **Apply P0.2 to `nexus-schema`**: add `FnGroup` record kind;
   references to fns go via `FnRef { group, index }`. Trait
   impls that contain mutually-recursive methods use the same
   mechanism.

3. **Kick off P0.3 ingester**: new crate (probably
   `sema-ingest` or similar under mentci-next's purview).
   Depends on nothing daemonic; only nexus-schema.

### Parallel tracks while P0 lands

4. **Start P3.1 Phase B**: new `lojix-msg` crate; mechanical
   copy of existing lojix in-process types + `sema_rev` +
   `corr_id`.

5. **P1.3 minimal set**: add `BuildTarget`, `DocStr`, `CfgExpr`
   record kinds to nexus-schema. These are low-cascade
   additions that self-hosting will need.

6. **P2.3 `SchemaVersion` sentinel**: add to nexus-schema now;
   cost is one record kind + one seed record.

### Gated on criomed scaffolding

7. **P1.4 implementation**: name-index tables, firewall-cache
   shape, subscription-coalescing.

8. **P1.5 seed-rule protection**: `SEED_RULE_IDS` allowlist
   + write-lock bits; verify-on-startup.

9. **P2.1 `CompileDiagnostic` / `DiagnosticSuggestion` records**:
   needed the first time rustc-as-derivation returns errors.

10. **P3.2 lojixd transport**: when Phase C of lojix work lands,
    the UDS + rkyv wire is ready.

### Deferred until post-MVP

11. **P2.2 semachk Option-B phases**: start with (iv)
    module-graph + visibility; each phase is a distinct
    crate.

12. **P1.1 `(Patch …)` verb family**: the programmatic edit
    path; humans/LLMs use text round-trip at MVP.

13. **P3.4 Phases E-G**: lojixd end-to-end cutover.

### Eventually

14. **Full Option-B semachk stack**: phases (v) through (vii)
    as ROI emerges.

---

## Open sub-questions flagged by this round

These came up during P0-P3 research but didn't resolve; they
deserve their own decisions in a later pass:

- **Snapshot identity vs opus identity** — is an "opus at
  sema_rev R" the same identity as an "opus with hash H where
  H reflects the workspace at R"? (Relevant to
  reproducible-build semantics; came up in P0.1 analysis.)
- **Schema-migration rollback** — if a `Migrate` verb fails
  mid-sequence, do we partial-apply, roll back, or halt? (P2.3
  implicit.)
- **Proc-macro hermeticity during ingest** — proc-macros are
  Turing-complete Rust running at ingest time. Sandbox?
  (P0.3 §edge-cases.)
- **DBSP/differential dataflow trigger threshold** — when does
  Phase-1+ cascade-engine upgrade pay off? (P1.4 deferred.)
- **`RunHorizonProjectionPlan` vs direct horizon-rs link** —
  should lojixd spawn a projection subprocess, or link
  horizon-rs in-process? (P3.3 marginal; leans in-process per
  existing lojix.)

---

## What this unlocks

With these 14 leans as decisions (subject to Li's review):

- **nexus-schema refactor** for hash-refs + FnGroup can start.
- **Ingester implementation** (`sema-ingest` crate) can begin.
- **`lojix-msg` crate** (Phase B of report 030) can begin in parallel.
- **Self-hosting clock** starts once criomed scaffolds +
  ingester parses its own source + sema holds enough records
  to reproduce the compile via rustc-as-derivation.

Detailed analysis for every decision is in reports
042/043/044/045. This report is the navigable index;
those reports are the book.

---

*End report 046.*
