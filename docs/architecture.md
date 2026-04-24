# Sema-ecosystem architecture

*Living document · last revision 2026-04-24 · canonical reference for the engine structure*

> **Status rule.** This file is the single source of truth for
> the engine's high-level shape. Reports in `../reports/` are
> decision-journey records; `docs/architecture.md` is the
> current-state description. If they disagree, this file wins —
> update reports or add a new report explaining the change, don't
> edit old reports in place.

---

## 1 · The engine in one paragraph

The sema ecosystem is a **records database** (`sema`, owned by
`criomed`) paired with a **content-addressed blob store**
(`lojix-store`, owned by `lojix-stored`), fronted by a **thin
nexus-text messenger** (`nexusd`) and served by a **compile
daemon** (`forged`). Humans and LLMs communicate in nexus text;
everything internal to the engine is rkyv. The MVP target is
**self-hosting**: the engine's own source lives as records in
sema; forged projects those records to Rust source and compiles
them; the resulting binary can re-edit its own records.

---

## 2 · The four daemons

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
     │ criomed │ guardian of sema-db; overlord of lojix-store.
     │         │ • owns the records database (sema, redb+rkyv+blake3)
     │         │ • runs pattern resolvers against sema_rev snapshots
     │         │ • fires subscriptions on commits
     │         │ • dispatches compile requests to forged
     │         │ • signs capability tokens forged uses to Put
     │         │   directly into lojix-store
     │         │ • tracks what's in lojix-store (so it can direct
     │         │   GC); never moves binary bytes itself
     └────┬────┴────────────────────┐
          │                         │
  rkyv (compile-msg)     rkyv (lojix-store-msg)
          ▼                         ▼
     ┌─────────┐               ┌──────────────┐
     │ forged  │───capability  │ lojix-stored │
     │         │──token────────►              │
     │         │               │              │
     │ compile │ blake3 → bytes│    blob      │
     │ daemon  │               │   guardian   │
     │         │ • pulls records from criomed (read)
     │         │ • calls rsc::project(…) → in-memory crate
     │         │ • invokes cargo/rustc
     │         │ • Puts binary directly to lojix-stored via token
     │         │ • replies { binary: Hash } to criomed
     └─────────┘
```

**Invariants**:
- Text crosses only at nexusd's boundary.
- No daemon-to-daemon call traverses criomed for bulk data —
  forged and lojix-stored can be connected directly via token.
- criomed never sees compiled binary bytes; it only records
  their hashes in sema.
- There is no `Launch` protocol message. Binaries are
  materialised to filesystem paths (nix-store style); you run
  them from a shell.

---

## 3 · The two stores

### sema — records database

- Owner: `criomed`
- Backend: `redb 4` + `rkyv 0.8` + `blake3 1.5`
- Holds: nexus-schema record types (Struct, Enum, Newtype,
  Const, Module, Program, Opus, Derivation, Origin, Type,
  GenericParam, TraitDecl, TraitImpl, plus any future kinds)
- Identity: every record keyed by `blake3(rkyv(record))`
- Tables: `records`, `opus_roots` (OpusName → ProgramId/ModuleId),
  `opus_history`, `meta` (schema version)
- Writes: single-writer via criomed's `SemaWriter` actor
  (redb's single-writer txn semantics)
- Reads: parallel through `SemaReaderPool`

### lojix-store — content-addressed blobs

- Owner: `lojix-stored`
- Backend: append-only file at `~/.lojix/store/store.bin`
  + rebuildable index `~/.lojix/store/store.idx`
- Holds: opaque bytes (compiled binaries from forged;
  user file attachments; anything that doesn't belong in
  sema's record tables)
- Identity: `blake3(bytes)` → bytes. No kind bytes; no type
  information in the store itself
- Writes: single-writer via `StoreWriter` actor
- Reads: parallel via mmap + `StoreReader` actors
- Access control: capability tokens signed by criomed

### Relationship

sema records reference lojix-store blobs by `ContentHash` fields.
A record like `CompiledBinary { opus: OpusId, bytes: ContentHash }`
points at the blob's hash in lojix-store. Resolution is:
"record says hash H; fetch H from lojix-stored." Criomed tracks
which hashes are live (reachable from sema records) and can
issue garbage-collect instructions to lojix-stored.

---

## 4 · Repo layout (18 code repos + tools-documentation)

```
Layer 0 — text grammars (spec + parsers)
  nota                 spec: 4 delim pairs, 2 sigils
  nota-serde-core      shared kernel: Lexer + Ser + De + Dialect knob
  nota-serde           public façade (Nota dialect default)
  nexus                spec: messaging superset of nota
  nexus-serde          public façade (Nexus dialect; Bind/Mutate/Negate)

Layer 1 — schema (rkyv lingua franca)
  nexus-schema         record types (Struct, Enum, Opus, Derivation…)
                       + RawPattern, PatternExpr, QueryOp, ShapeExpr
                       + Bind, Mutate<T>, Negate<T> (moved from nexus-serde)

Layer 2 — contract crates (one per daemon↔daemon relation)
  criome-msg           nexusd ↔ criomed
  compile-msg          criomed ↔ forged
  lojix-store-msg      criomed/forged ↔ lojix-stored

Layer 3 — storage
  sema                 records DB (redb + rkyv + blake3)
  lojix-store          blob store (append-only file + idx)

Layer 4 — daemons
  criomed              guardian of sema, overlord of lojix-store
  forged               compile daemon (rsc + cargo → binary)
  lojix-stored         blob guardian
  nexusd               text ↔ rkyv messenger

Layer 5 — clients + build helpers
  nexus-cli            flag-less CLI (accept msg, send, print reply)
  rsc                  pure library: records → ProjectedCrate (no I/O)
  lojix                compile-orchestration helpers (ractor patterns)
```

**Shelved**: `arbor` (prolly-tree versioning) — post-MVP.

---

## 5 · Key record types

Live in `nexus-schema`. All derive `rkyv::Archive` + `serde`.

### Opus (pure-Rust artifact)

Nix-like, extremely explicit. All build-affecting inputs are
fields; same Opus hash → same binary (within rustc determinism):

```rust
Opus {
    name: OpusName, version: SemVer,
    toolchain: RustToolchainPin,     // a DerivationId, not a channel enum
    root: ModuleId,                   // source projected from sema
    target: TargetTriple,             // "x86_64-unknown-linux-gnu"
    profile: CargoProfile,            // Dev | Release | ReleaseWithDebug
    outputs: Vec<OpusOutput>,         // Bin { name, entry } | Lib { name, crate_types }
    features: Vec<CargoFeatureName>,
    deps: Vec<OpusDep>,
    rustflags: Vec<String>,
    env: Vec<(EnvVarName, String)>,
}
```

No `RustEdition` enum — edition is a property of the toolchain
derivation.

### Derivation (non-pure escape hatch)

Wraps a nix call or flake output:

```rust
Derivation {
    name: DerivationName, system: TargetTriple,
    builder: DerivationBuilder,       // FlakeOutput | NixExpression
    inputs: Vec<DerivationInput>,
    outputs: Vec<DerivationOutput>,   // Out | Lib | Dev | Bin | …
    nar_hash: NarHashSri,             // "sha256-…" content address
}
```

### OpusDep

```rust
OpusDep::Opus       { target: OpusId, as_name, features, optional, kind }
OpusDep::Derivation { target: DerivationId, output, link_spec }
```

### RawPattern / PatternExpr (schema-bound)

Two shapes: **raw** (strings, wire format to nexusd) and **bound**
(IDs, wire format to criomed + internal to criomed).

Resolution happens inside criomed against a specific `sema_rev`.
Hallucinated field names are rejected at the resolver, before
the matcher ever runs.

```rust
// on the wire
RawPattern::Match { record: StructName, variant, atoms: Vec<RawAtom> }
// after criomed resolves
PatternExpr { sema_rev: Hash, root: Pattern }
Pattern::Match { record: RecordRef, atoms: Vec<BoundAtom> }
```

See [reports/017](../reports/017-architecture-refinements.md) §2
for full shape.

---

## 6 · Data flow

### Single query

```
 human nexus text
        ▼
  nexusd: lex + parse → RawPattern
        │ rkyv(CriomeRequest::Query { pattern: RawPattern })
        ▼
  criomed: resolver(RawPattern, sema_rev) → PatternExpr
        │ matcher runs against redb
        ▼
  rkyv(CriomeReply::Records)
        ▼
  nexusd: serialize records → nexus text
        ▼
 human
```

### Compile + self-host loop

```
 human: (Compile (Opus nexusd))
        ▼
 nexusd → criomed → forged (with capability token)
        │
        ▼ forged pulls records from criomed
        ▼ rsc::project(…) → in-memory crate
        ▼ cargo build
        ▼ Put binary bytes → lojix-stored (direct, via token)
        ▼ reply: { binary: Hash } → criomed
        ▼ criomed asserts `CompiledBinary { opus, binary }` in sema
        ▼ reply flows back to human
 human: materialise binary to path (nix-style), run from shell
        ▼ running binary connects back to nexusd, Asserts new records
        ▼ sema updated → next compile produces a different binary
        ▼ LOOP CLOSES
```

---

## 7 · Contract crates — protocol surface

Each crate is rkyv-only, minimal, per-relation versioned.

### criome-msg (nexusd ↔ criomed)

```rust
pub enum CriomeRequest {
    Lookup { hash: Hash },
    Scan { kind: u8, limit: Option<u32> },
    Query { pattern: RawPattern, limit: Option<u32> },
    Shape { pattern: RawPattern, shape: ShapeExpr },
    Validate { pattern: RawPattern },   // dry-run resolver
    Assert { record: AnyRecord },
    Retract { hash: Hash },
    Mutate { target: Hash, patch: Patch },
    Transaction(Vec<TxOp>),             // {|| ||}
    Subscribe { pattern: RawPattern },  // <| |>
    Unsubscribe { sub: SubId },
    Compile { opus: OpusId },           // dispatched to forged
    // NO `Launch` — binary execution is filesystem, not protocol
    Ping, Shutdown,
}
```

### compile-msg (criomed ↔ forged)

```rust
pub struct CompileRequest {
    opus: OpusId,
    sema_rev: Hash,
    store_token: LojixStoreToken,       // criomed-signed capability
    // … profile, target, cache_mode as needed
}

pub enum CompileReply {
    Ok { binary: Hash, wall_time_ms: u32, warnings: Vec<Diagnostic> },
    Err { stage: CompileStage, diagnostics: Vec<Diagnostic> },
}
```

### lojix-store-msg (store traffic, blob-only)

```rust
pub enum LojixStoreRequest {
    Put      { data: Vec<u8>, token: Option<LojixStoreToken> },   // one-shot
    PutBegin { total_len: u64, token: Option<LojixStoreToken> },  // streaming
    PutChunk { session: SessionId, bytes: Vec<u8> },
    PutCommit{ session: SessionId, expected: Option<Hash> },
    PutAbort { session: SessionId },
    Get      { hash: Hash },
    GetBegin { hash: Hash },
    Contains { hash: Hash },
    Stats,
}
```

No `kind` byte; lojix-store is a pure `blake3 → bytes` map.

---

## 8 · Grammar (nota ⊂ nexus)

Delimiter-family matrix (filled from [reports/013](../reports/013-nexus-syntax-proposal.md)):

```
                  bare   |         ||
   ( ) record     rec    pattern   optional-pattern
   { } composite  shape  constrain atomic-txn
   [ ] evaluate   str    multiline rule (Phase 2)
   < > flow       seq    stream    windowed (Phase 2)
```

All cells land in the lexer via nota-serde-core with
`Dialect::Nexus`. Text crosses nexusd; everything internal is
rkyv.

**Sigil budget** (never grows):

| Sigil | Role |
|---|---|
| `;;` | line comment |
| `#` | byte-literal prefix |
| `~` | mutate marker |
| `@` | bind marker |
| `!` | negate marker |
| `=` | bind-alias (narrow: only `@a=@b`) |

---

## 9 · Rules (for future sessions)

From bd memories:

- **No ETAs.** Do not estimate time to complete anything. Li
  doesn't trust Claude's time estimates. Describe work, don't
  schedule it.
- **No backward compat.** The engine is being born. Rename
  freely, move modules, drop types. Applies until Li declares a
  compatibility boundary.
- **Text only crosses nexusd.** Every internal daemon-to-daemon
  message is rkyv.
- **Schema is the documentation.** Patterns and types resolve
  against sema; hallucinated names are rejected early.
- **Criomed is the overlord.** Bulk bytes can flow directly
  forged↔lojix-stored via capability tokens, but criomed knows
  what exists in lojix-store and can GC it.
- **A binary is just a path.** No `Launch` message; materialise
  to filesystem like nix does.
- **Sigils as last resort.** New features land as delimiter-
  family slots (see §8) or new Pascal-named records, never new
  sigils.
- **One artifact per repo.** rust/style.md rule 1.

---

## 10 · What's still open

Tracked in [reports/016](../reports/016-tier-b-decisions.md) +
[reports/017](../reports/017-architecture-refinements.md):

- Precise shape of `TxOp` / `Patch` / `Delta` / `AnyRecord` in
  nexus-schema.
- Capability-token signing details (key rotation, revocation).
- Bootstrap loader home (currently leaning
  `criomed/src/bin/bootstrap.rs`).
- Cargo determinism strategy (shared target-dir for MVP;
  hermetic later).
- Subscription durability across criomed restart
  (lean re-subscribe).
- Streaming compile progress events (deferred).

---

## 11 · Reading order

For a new session getting up to speed:

1. **This file** — the canonical shape.
2. [`reports/017`](../reports/017-architecture-refinements.md)
   — latest clarifications (Opus/Derivation, schema-bound
   patterns, no-Launch, no-kind-bytes, tokens).
3. [`reports/013`](../reports/013-nexus-syntax-proposal.md)
   — delimiter-family matrix (syntax canon).
4. [`reports/015`](../reports/015-architecture-landscape.md)
   v4 — full architecture synthesis (some sections superseded
   by 017; §§5, 10, 13 partly moot).
5. [`reports/016`](../reports/016-tier-b-decisions.md) — open
   questions (Q1 moot, Q2/Q4/Q5/Q6/Q7/Q8 answered by 017).
6. `reports/014` — serde-refactor history.
7. `reports/004`, `reports/009-binds-and-patterns` — technical
   references.
8. `reports/001–003`, `005–012` — **deleted**; their content is
   in these living documents or has been superseded.

---

## 12 · Update policy

When architecture changes:
1. Update this file first.
2. Add a report (`reports/NNN-whatever.md`) describing the
   decision and why.
3. If a decision supersedes a previous one, update the
   paragraph here; don't edit the old report — it stays as a
   decision-journey record.

When in doubt, this file is canonical.

---

*End docs/architecture.md.*
