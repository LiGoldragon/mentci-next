# Sema-ecosystem architecture

*Living document · last revision 2026-04-24 · canonical reference for the engine's shape*

---

## Scope rule (READ FIRST)

This file is **high-level concepts only**. Three layers of
documentation, strictly separated:

| Where | What | Example |
|---|---|---|
| `docs/architecture.md` | **Prose + diagrams only.** No code. High-level shape, invariants, relationships, rules. | "criomed owns sema; lojix-stored owns lojix-store; text crosses only at nexusd" |
| `reports/NNN-*.md` | **Concrete shapes + decision records.** Type sketches, record definitions, message enums, research syntheses, historical context. | `Opus { … }` full rkyv sketch |
| the repos themselves | **Implementation.** Rust code, tests, flakes, Cargo.toml. | `nexus-schema/src/opus.rs` |

**If a doc-layer rule is violated**, rewrite: move type sketches
out of `docs/architecture.md` into a report; move runnable code
out of reports into the appropriate repo. This file stays slim
so it remains readable in one pass.

When architecture changes, update this file first, then write a
new report explaining the change. Don't edit old reports —
they're decision-journey records.

---

## 1 · The engine in one paragraph

The engine is a **runtime (criome)** hosting two pillars — a
**records database (sema)** and an **artifacts family (lojix,
Li's expanded-and-more-correct nix)**. Three daemons run it:
**nexusd** (the translator — nexus text ↔ rkyv), **criomed**
(the brain — owns sema, runs an incremental evaluator that
re-resolves dependent state on every record mutation, resolves
schema-bound patterns, dispatches concrete work to lojixd), and
**lojixd** (the hands — receives concrete "do this" plans and
executes: runs cargo/nix subprocesses, materialises files,
writes blobs into lojix-store, runs deploys). All the thinking
is criomed's; lojixd is a thin executor. `nexus` is the
communication skin spanning all of criome: text at the human
boundary, rkyv internally. The MVP target is **self-hosting**:
the engine's own source lives as records in sema; criomed
incrementally evaluates what to build; lojixd executes the
resulting plan to produce a Rust binary that can re-edit the
same records.

---

## 2 · The three daemons

```
     nexus text (humans, LLMs, nexus-cli)
        ▲ │
        │ ▼
     ┌─────────┐
     │ nexusd  │ messenger: text ↔ rkyv only; validates syntax +
     │         │ protocol version; forwards to criomed; serialises
     │         │ replies back to text. Stateless modulo in-flight
     │         │ correlations.
     └────┬────┘
          │ rkyv (criome-msg contract)
          ▼
     ┌─────────┐
     │ criomed │ the brain — guardian of sema; overlord of lojix.
     │         │ • owns the records database
     │         │ • runs an incremental evaluator — every mutation
     │         │   re-plans dependent derived state (compile
     │         │   plans, pattern bindings, dep closures)
     │         │ • resolves RawPattern → PatternExpr (hallucination
     │         │   wall)
     │         │ • fires subscriptions on commits
     │         │ • dispatches concrete plans to lojixd
     │         │ • signs capability tokens; tracks reachability for
     │         │   lojix-store GC
     │         │ • never touches binary bytes itself
     └────┬────┘
          │ rkyv (lojix-msg — concrete "do this" verbs)
          ▼
     ┌──────────┐   owns lojix-store directory
     │  lojixd  │   (lojix family; thin executor; no evaluation)
     │          │ internal actors:
     │          │   • CargoRunner (spawns cargo per RunCargo plan)
     │          │   • NixRunner (spawns nix/nixos-rebuild)
     │          │   • StoreWriter + StoreReaderPool (blob access)
     │          │   • FileMaterialiser (records → workdir)
     │          │ • receives concrete plans: RunCargo, RunNix,
     │          │   RunNixosRebuild, PutBlob, GetBlob, ...
     │          │ • executes; writes binary into lojix-store
     │          │   (in-process)
     │          │ • replies {output-hash, warnings, wall_ms}
     └──────────┘
```

**Invariants**:

- Text crosses only at nexusd's boundary.
- No daemon-to-daemon path routes bulk data through criomed —
  forged and lojix-stored are connected directly, authorised by
  a criomed-signed capability token.
- Criomed never sees compiled binary bytes; it only records
  their hashes in sema.
- There is no `Launch` protocol message. Binaries are
  materialised to filesystem paths (nix-store style); you run
  them from a shell.

---

## 3 · The two stores

### sema — records database

- **Owner**: criomed.
- **Backend**: content-addressed records, keyed by the blake3
  of their canonical rkyv encoding. Storage engine is an
  embedded redb.
- **Holds**: every structural record (Struct, Enum, Module,
  Program, Opus, Derivation, Type, Origin, traits, …).
- **Writes**: single-writer through criomed's internal writer
  actor.
- **Reads**: parallel, MVCC semantics from the storage engine.
- **Identity of a workspace opus** tracked in a name→root-hash
  table (git-refs analogue).

### lojix-store — content-addressed blobs

- **Owner**: lojix-stored.
- **Backend**: append-only file plus a rebuildable hash-to-
  offset index.
- **Holds**: opaque bytes only (compiled binaries; user file
  attachments referenced by sema records; anything too large or
  too unstructured to belong in sema).
- **No typing**. No kind bytes. The type of a blob is known
  only through the sema record that references its hash.
- **Access control**: capability tokens, signed by criomed.

### Relationship

Sema records carry content-hash fields that reference blobs in
lojix-store. "Record says hash H; fetch H from lojix-stored."
Criomed keeps a reachability view (what hashes are live) and
can direct garbage collection; it never handles the bytes
themselves.

---

## 4 · Repo layout

~16 code repos + 1 spec-only + `tools-documentation`. **[L]**
marks lojix-family members.

- **Layer 0 — text grammars** — nota (spec), nota-serde-core
  (shared lexer+ser+de kernel), nota-serde (façade), nexus
  (spec), nexus-serde (façade).
- **Layer 1 — schema vocabulary** — nexus-schema (may rename to
  `sema-schema` later): sema records (including Opus,
  Derivation, OpusDep, RustToolchainPin, NarHashSri, FlakeRef,
  OverrideUri, TargetTriple — these are user-written records,
  not a separate lojix schema), pattern types, query ops.
  (A separate `lojix-schema` crate was proposed in report 019
  but superseded by 021 once criomed's incremental evaluator
  took over build-spec resolution.)
- **Layer 2 — contract crates** — criome-msg (nexusd↔criomed),
  lojix-msg **[L]** (criomed↔lojixd; carries **concrete
  execution verbs** — RunCargo / RunNix / RunNixosRebuild /
  PutBlob / GetBlob / MaterializeFiles — not Opus references).
- **Layer 3 — storage** — sema (records DB, backs criomed),
  lojix-store **[L]** (blob directory + reader library — no
  daemon; writes via lojixd, reads via mmap).
- **Layer 4 — daemons** — nexusd (messenger), criomed (guardian),
  lojixd **[L]** (single lojix daemon — forge + store + deploy
  as internal actors).
- **Layer 5 — clients + build libs** — nexus-cli (flag-less
  CLI; the only text client), rsc (pure records-to-source
  library; lojixd links it).
- **Spec-only** — lojix **[L]** (README for the namespace;
  parallels `nexus` and `nota` spec repos).

**Lojix family membership** is a second axis orthogonal to
layer. A crate is lojix-family iff it participates in the
content-addressed typed build/store/deploy pipeline (Li's
"expanded nix"). Criteria: carries `NarHashSri`/`FlakeRef`/
artifact records, or drives nix/cargo, or stores opaque blobs,
or is the typed wire for any of those.

### The `lojix-*` namespace — Li's expanded nix

"lojix" is Li's play on nix — "my take on an expanded and more
correct nix." Broad scope: covers everything nix covers
(compile, store, deploy, derive). The prefix is an umbrella; a
crate carrying `lojix-*` participates in the artifacts pillar.

Three-pillar framing:

- **criome** — the runtime (nexusd, criomed, the daemon graph)
- **sema** — records, meaning, schemas, patterns
- **lojix** — artifacts, build, compile, store, deploy

criome ⊇ {sema, lojix}. nexus is the communication skin spanning
all of criome, not a fourth pillar.

**Two axes per daemon**:

| Daemon | Runtime | Family |
|---|---|---|
| `nexusd` | criome | criome (nexus skin) |
| `criomed` | criome | criome |
| `lojixd` | criome | lojix |

All daemons run at the criome-runtime layer; `lojixd` is also
a lojix-family member.

**Shelved**: `arbor` (prolly-tree versioning) — post-MVP.

Concrete record types, message enums, and the rename journey
live in [reports/019](../reports/019-lojix-as-pillar.md),
[reports/017](../reports/017-architecture-refinements.md), and
earlier. This file names the components; it does not define
their shapes.

---

## 5 · Key type families (named, not specified)

- **Opus** — pure-Rust artifact specification. User-written
  sema record. Nix-like and extremely explicit: toolchain
  pinned by derivation reference, outputs enumerated, features
  as plain strings, every build-affecting input a field so
  the record's hash captures the full closure. Lives in
  `nexus-schema`. criomed's incremental evaluator resolves it
  to a concrete RunCargo plan at edit time; lojixd never sees
  the Opus directly.
- **Derivation** — escape hatch for non-pure deps. Wraps a nix
  flake output (or inline nix expression) with a content-hash
  and named outputs. User-written sema record. Lives in
  `nexus-schema`.
- **OpusDep** — opus → {opus | derivation} link spec.
  User-written. Lives in `nexus-schema`.
- **RawPattern** — the wire form of a nexus pattern, carrying
  user-facing names (`StructName`, `FieldName`, `BindName`).
  Appears on criome-msg; never used inside criomed after
  resolution.
- **PatternExpr** — the resolved form, carrying schema IDs
  (`StructId`, `FieldId`). Pinned to a specific sema snapshot.
  Internal to criomed.
- **CriomeRequest / CriomeReply** — the nexusd↔criomed
  protocol verbs (lookup, query, assert, mutate, subscribe,
  compile, …).
- **lojix-msg verbs** — concrete execution instructions in the
  criomed→lojixd direction: RunCargo, RunNix, RunNixosRebuild,
  PutBlob (streaming variants for large payloads), GetBlob,
  ContainsBlob, MaterializeFiles, DeleteBlob (criomed-driven
  GC). Each reply is a result of that concrete operation. No
  `CompileRequest { opus: OpusId }` — that level of abstraction
  is criomed's internal concern.

Concrete field lists live in
[reports/017 §1, §2](../reports/017-architecture-refinements.md)
and subsequent reports. If a type below needs to grow, update
its report (or write a new one); don't inline the shape here.

---

## 6 · Data flow

### Single query

```
 human nexus text
        ▼
  nexusd: lex + parse → RawPattern
        │ rkyv criome-msg (Query { pattern })
        ▼
  criomed: resolver(RawPattern, sema_snapshot) → PatternExpr
        │ matcher runs against records
        ▼
  rkyv reply (Records)
        ▼
  nexusd: serialize → nexus text
        ▼
 human
```

### Compile + self-host loop (edit-time + run-time)

**Edit-time** (heavy work; incremental):
```
 human: (Mutate (Opus nexusd …))
        ▼
 nexusd → criomed
        ▼
 criomed:
   • writes new Opus record to sema
   • incremental evaluator fires:
     - resolves toolchain derivation hashes
     - plans cargo invocation (args, env, fetch list)
     - caches the concrete plan keyed by opus content hash
   • fires subscriptions
        ▼ (no lojixd involvement yet)
```

**Run-time** (thin work; one cargo invocation):
```
 human: (Compile nexusd)
        ▼
 nexusd → criomed
        ▼
 criomed: concrete plan is already cached; issue it
        ▼ rkyv RunCargo { workdir, args, env, fetch_files, … }
 lojixd:
   • materialises fetch_files from lojix-store into workdir
   • spawns cargo
   • hashes binary; writes into lojix-store (in-process)
   • replies { output-hash, warnings, wall_ms }
        ▼
 criomed asserts CompiledBinary record
        ▼
 reply flows back to human
```

**Self-host close**: human materialises the new binary to a
filesystem path, runs it; running binary connects to nexusd
and asserts new records; criomed incrementally re-plans; next
compile is different — LOOP CLOSES.

---

## 7 · Grammar shape

Nota is a strict subset of nexus. A single lexer (in
nota-serde-core) handles both, gated by a dialect knob. The
grammar is organised as a **delimiter-family matrix** (see
[reports/013](../reports/013-nexus-syntax-proposal.md)):

- Outer character picks the family — records `( )`, composites
  `{ }`, evaluation `[ ]`, flow `< >`.
- Pipe count inside picks the abstraction level — none for
  concrete, one for abstracted/pattern, two for
  committed/scoped.

**Sigil budget is closed.** Six total: `;;` (comment), `#`
(byte-literal prefix), `~` (mutate), `@` (bind), `!` (negate),
`=` (bind-alias, narrow use). New features land as delimiter-
matrix slots or Pascal-named records — **never new sigils**.

---

## 8 · Project-wide rules

Foundational rules observed across sessions.

- **No ETAs.** Don't estimate time to complete work. Describe
  the work; don't schedule it.
- **No backward compat.** The engine is being born. Rename,
  move, restructure freely. Applies until Li declares a
  compatibility boundary.
- **Text only crosses nexusd.** Every internal daemon-to-daemon
  message is rkyv.
- **Schema is the documentation.** Patterns and types resolve
  against sema; hallucinated names are rejected early.
- **criomed owns all evaluation.** lojixd is a worker — receives
  concrete "do this" plans. Schema resolution, build planning,
  toolchain pinning, dep-closure computation all happen in
  criomed's incremental evaluator (fires on every sema
  mutation). lojixd never sees an Opus record directly.
- **Criomed is the overlord** of lojix-store. Tracks
  reachability; signs tokens; directs GC.
- **A binary is just a path.** No `Launch` message;
  materialisation is filesystem.
- **Sigils as last resort.** New features land in the matrix
  or as records. The sigil budget is frozen.
- **One artifact per repo.** rust/style.md rule 1.
- **Content-addressing is non-negotiable.** Record identity is
  the blake3 of its canonical encoding. Don't add mutable
  fields that would break identity.

---

## 9 · Reading order for a new session

1. **This file** — the canonical shape.
2. [reports/021](../reports/021-criomed-evaluates-lojixd-executes.md)
   — **critical refinement**: criomed has an incremental
   evaluator; lojixd is a thin executor, not an evaluator.
   Supersedes 020 §6–§7 on where evaluation happens.
3. [reports/020](../reports/020-lojix-single-daemon.md) —
   lojix shape: one daemon (`lojixd`), one contract
   (`lojix-msg`), no lojix CLI. Supersedes 019 §5–§6.
4. [reports/019](../reports/019-lojix-as-pillar.md) — lojix as
   the artifacts pillar; broad-lojix framing; three-pillar
   model. §5–§6 superseded by 020; lojix-schema proposal
   superseded by 021.
5. [reports/017](../reports/017-architecture-refinements.md) —
   Opus/Derivation shapes, schema-bound patterns, no-Launch,
   no-kind-bytes, tokens. Opus/Derivation type-home reverts
   to nexus-schema per 021.
3. [reports/013](../reports/013-nexus-syntax-proposal.md) —
   delimiter-family matrix (grammar canon).
4. [reports/015](../reports/015-architecture-landscape.md) v4 —
   full architecture synthesis (parts superseded by 017 — read
   after 017 so you know what's current).
5. [reports/016](../reports/016-tier-b-decisions.md) — open
   questions (most answered by 017).
6. `reports/014` — serde-refactor history.
7. `reports/004`, `reports/009-binds-and-patterns` — technical
   references.

Older reports have been deleted to prevent context poisoning.

---

## 10 · Update policy

When architecture changes:

1. Update this file first. Keep it prose + diagrams only.
2. Write a new report (`reports/NNN-whatever.md`) describing
   the decision, the alternatives considered, and any concrete
   shapes (types, enums).
3. Update implementation in the affected repos.

If an old report is superseded, **don't edit it** — it stays
as a decision-journey record. The current shape is wherever
this file points.

---

*End docs/architecture.md.*
