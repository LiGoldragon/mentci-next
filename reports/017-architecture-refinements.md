# 017 — architecture refinements after Li's directions (2026-04-24)

*Claude Opus 4.7 / 2026-04-24 · follow-up to
[016](016-tier-b-decisions.md) after Li's corrections. Each
section supersedes the matching point in 015/016. For current
truth see [docs/architecture.md](../docs/architecture.md).*

Li's directions (abridged):
- **No ETAs.** Never estimate time. Done; not in this report.
- **No backward compat.** Engine is being born. Rename freely.
- **Q2 · Opus** — nix-like, extremely explicit; plus a new
  `Derivation` record for non-pure deps.
- **Q4 · PatternExpr** — schema-bound. Schema documents + blocks
  hallucinated field names.
- **Q5 · nexus-cli** — pipe-simple; no flags beyond `--version`.
- **Q6 · forge-actor↔lojix-store** — token approach. Criomed
  as overlord of lojix-store. (Under report 020, forged and
  lojix-stored are internal actors inside a single `lojixd`;
  the cross-daemon token flow becomes in-process.)
- **Q7 · Launch** — filesystem, not protocol. There is no
  `Launch` nexus message. A binary in lojix-store lives at a
  hash-derived filesystem path (nix-store analogue); you run
  it directly.
- **Q8 · kind-byte registry** — Li didn't follow the concept.
  Answer: drop it.

---

## §1 · Opus + Derivation — nix-like, explicit

Replaces 015 §5 and 016 Q2.

### Principle

Every input that affects the compiled binary bytes is captured
in the Opus record. Same Opus hash → same cargo invocation →
same binary (within rustc determinism limits). Vague enums like
`RustEdition` are gone; their role is played by toolchain
derivations.

### `Opus` — pure-rust artifact

Shape (rkyv-archived):

```rust
pub struct Opus {
    pub name:      OpusName,
    pub version:   SemVer,                       // (major, minor, patch, pre, build)
    pub toolchain: RustToolchainPin,             // derivation, not a channel enum
    pub root:      ModuleId,                     // source projected from sema-db
    pub target:    TargetTriple,                 // "x86_64-unknown-linux-gnu"
    pub profile:   CargoProfile,                 // Dev | Release | ReleaseWithDebug
    pub outputs:   Vec<OpusOutput>,              // explicit, multiple possible
    pub features:  Vec<CargoFeatureName>,        // plain strings, order-preserving
    pub deps:      Vec<OpusDep>,
    pub rustflags: Vec<String>,                  // CARGO_ENCODED_RUSTFLAGS equivalent
    pub env:       Vec<(EnvVarName, String)>,    // build-affecting env, part of hash
}

pub struct RustToolchainPin {
    pub derivation:    DerivationId,             // resolves to rustc+cargo closure
    pub rustc_version: String,                   // informational: "1.84.0"
    pub components:    Vec<String>,              // ["rustc","cargo","rust-std","clippy"]
}

pub enum OpusOutput {
    Bin { name: String, entry: ConstId },        // explicit entry
    Lib { name: String, crate_types: Vec<CrateType> },
}

pub enum CrateType { Rlib, Dylib, Cdylib, Staticlib, ProcMacro }
pub enum CargoProfile { Dev, Release, ReleaseWithDebug }
pub struct SemVer { major: u32, minor: u32, patch: u32, pre: String, build: String }
```

**What changed from 015 §5**:
- `RustEdition` deleted. Edition is a property of the toolchain
  derivation and the module sources, not a loose enum.
- `RustToolchain { channel: ToolchainChannel, components }` →
  `RustToolchainPin { derivation: DerivationId, … }`. A channel
  enum is vague; a derivation hash is concrete.
- `EmitKind` enum → `Vec<OpusOutput>`. A crate can emit a lib
  AND a bin; each carries its own name + (for bins) entry point.
- `FeatureFlag` newtype → plain `CargoFeatureName(String)`.
- Added `rustflags` and `env` fields — anything that changes
  build output bits belongs in the hash.

### `Derivation` — the non-pure escape hatch

Non-Rust inputs (system libs, tools, anything via nix):

```rust
pub struct Derivation {
    pub name:     DerivationName,
    pub system:   TargetTriple,                  // nix "x86_64-linux"
    pub builder:  DerivationBuilder,
    pub inputs:   Vec<DerivationInput>,          // refs to other Derivations
    pub outputs:  Vec<DerivationOutput>,         // named outputs (out, lib, dev, bin)
    pub nar_hash: NarHashSri,                    // sha256-…  content address
}

pub enum DerivationBuilder {
    /// Dominant form: `nix build <flake_url>#<attr_path>`
    FlakeOutput {
        flake_url: String,                       // "github:NixOS/nixpkgs/<rev>"
        attr_path: String,                       // "openssl" or "packages.<system>.openssl"
        overrides: Vec<FlakeOverride>,
    },
    /// Escape hatch, rare. Inline nix expression.
    NixExpression {
        expr:        String,
        expr_inputs: Vec<DerivationId>,
    },
}

pub struct FlakeOverride { input_name: String, target: OverrideTarget }
pub enum OverrideTarget {
    Flake(String),                               // "github:…/<rev>"
    LocalPath(String),                           // "path:/abs/…"
    Derivation(DerivationId),                    // recursive: built drv as input
}

pub enum DerivationOutput { Out, Lib, Dev, Bin, Doc, Man, Other(String) }
```

`NarHashSri` is lifted from lojix's existing type
([lojix/src/cluster.rs](../repos/lojix/src/cluster.rs)) — reuse,
don't reinvent.

### `OpusDep` — Opus | Derivation

```rust
pub enum OpusDep {
    Opus {
        target: OpusId, as_name: OpusName,
        features: Vec<CargoFeatureName>,
        optional: bool, kind: CargoDepKind,
    },
    Derivation {
        target: DerivationId,
        output: DerivationOutput,                // which multi-output to link
        link_spec: LinkSpec,
    },
}

pub enum CargoDepKind { Normal, Dev, Build }

pub struct LinkSpec {
    pub kind: LinkKind,
    pub env:  Vec<(EnvVarName, EnvValueTemplate)>,   // "${OUT}/lib" templating
    pub rustc_link: Vec<RustcLinkArg>,
}

pub enum LinkKind {
    BuildTool,                                       // headers only
    PkgConfig,                                       // discover via PKG_CONFIG_PATH
    Native { lib_name: String, static_: bool },
    Tool,                                            // binary on PATH
}

pub enum RustcLinkArg { L(String), LNative(String), Lib(String), StaticLib(String) }
pub struct EnvValueTemplate(pub String);             // "${OUT}/lib" etc.
```

`EnvValueTemplate` has a closed, small vocabulary: `${OUT}`,
`${LIB}`, `${DEV}`, `${BIN}`. forged expands these at build time
from the derivation's resolved nix store paths.

### Builder-env split

**In the Opus record** (part of identity):
- `toolchain` (rustc bytes), `rustflags`, `env`, `deps` (all
  inputs), `profile`, `target`, `features`, `outputs`.

**In forged's runtime** (ephemeral):
- Resolving `DerivationId` → nix store path (via `nix build
  --print-out-paths`, same call lojix does today).
- `PATH` assembly; `${OUT}` template expansion.
- Cache dirs (`CARGO_TARGET_DIR`, `CARGO_HOME`).
- Sandbox creation.

### Repo-level note

`Opus` and `Derivation` live in nexus-schema. New modules
`nexus-schema/src/opus.rs` and `nexus-schema/src/derivation.rs`.
`NarHashSri`, `FlakeRef`, `OverrideUri`, `TargetTriple` lift
from lojix into nexus-schema's `names.rs` so lojix depends on
nexus-schema, not the reverse.

---

## §2 · PatternExpr — schema-bound with RawPattern split

Replaces 015 §11 and 016 Q4.

### Principle

Two types. The **raw** form carries user-facing names and
appears only at the nexusd↔client boundary. The **bound** form
carries schema IDs and appears on criome-msg + inside criomed.
Resolution (raw → bound) happens in criomed against a specific
`sema_rev`. This is the GraphQL pattern (text → AST →
validated IR → execution) mapped onto the daemon split.

### Shape

```rust
// Raw — what the nexusd parser emits
pub enum RawPattern {
    Match {
        record:  StructName,                     // or TypeName for enum patterns
        variant: Option<VariantName>,
        atoms:   Vec<RawAtom>,
    },
    Optional(Box<RawPattern>),                   // (|| … ||)
    Negate(Box<RawPattern>),                     // !(| … |)
    Constrain(Vec<RawPattern>),                  // {| … |}
    Stream(Box<RawPattern>),                     // <| … |>
}

pub enum RawAtom {
    Bind(BindName),                              // @horizontal — fresh, not schema
    BindAlias { from: BindName, to: BindName },  // @a=@b
    Wildcard,                                    // _
    Literal(LiteralValue),
    Nested(Box<RawPattern>),                     // nested record
}

// Bound — what goes on criome-msg and inside criomed
pub struct PatternExpr {
    pub sema_rev: Hash,                          // resolved against this snapshot
    pub root: Pattern,
}

pub enum Pattern {
    Match  { record: RecordRef, atoms: Vec<BoundAtom> },
    Optional(Box<Pattern>),
    Negate(Box<Pattern>),
    Constrain(Vec<Pattern>),
    Stream(Box<Pattern>),
}

pub enum RecordRef {
    Struct(StructId),
    Variant { enum_id: EnumId, variant: u32 },   // variant index
}

pub enum BoundAtom {
    Bind     { name: BindName, field: FieldId },
    Alias    { from: BindName, to: BindName, field: FieldId },
    Wildcard { field: FieldId },
    Literal  { field: FieldId, value: LiteralValue },
    Nested   { field: FieldId, inner: Pattern },
}
```

`atoms.len() == record.fields.len()` is a post-resolver
invariant: every field is accounted for, even wildcards.

`FieldId = blake3(struct_hash ‖ field_index_u32)` — derived, not
stored as a top-level record. Zero overhead; no sema-schema
changes needed beyond adding the newtype.

### Resolution flow

```
  nexus text  "(| Point @horizontal @vertical |)"
      │
      ▼
  [nexusd parser] → RawPattern (strings)
      │
      │ rkyv(RawPattern) over criome-msg
      ▼
  [criomed resolver] ←─ sema_rev snapshot
      │  looks up Struct("Point") → { horizontal, vertical }
      │  "@horizontal" → FieldId(ab…); "@vertical" → FieldId(cd…)
      │  hallucinated field → Err(SchemaMismatch { unknown })
      ▼
  [criomed matcher] runs PatternExpr against sema records
```

**Hallucination wall = criomed's resolver.** Agent writes `(|
Point @fake |)`; resolver looks up Point in sema, finds no
`fake`, errors with candidates ("did you mean horizontal,
vertical?"). Pattern never reaches the matcher.

### Wire type on criome-msg

```rust
// criome-msg
pub enum CriomeRequest {
    Query { pattern: RawPattern, limit: Option<u32> },
    Assert { record: AnyRecord },
    Subscribe { pattern: RawPattern },
    // …
    Validate { pattern: RawPattern },            // dry-run resolver (tooling)
}
```

The wire carries `RawPattern`. `PatternExpr` stays internal to
criomed. This is a correction to 015 §8 (which had
`pattern: PatternExpr` on the wire).

### Migration

`nexus-serde::Bind(pub String)` → `nexus-schema::Bind(pub
BindName)`. `BindName` is a named newtype with grammar
validation (camelCase / kebab-case leader + `[a-z0-9_-]` body).
`FieldName` in `RawPattern` stays a string; gets resolved to
`FieldId` by criomed.

---

## §3 · kind-byte registry — drop it

Replaces 016 Q8.

> *Updated 2026-04-24 (post-lojix-store correction)*: Li
> clarified lojix-store is a **content-addressed filesystem**
> (nix-store analogue) — it holds real unix files and directory
> trees, with a separate index DB — not a packed blob file.
> The "drop the kind byte" conclusion survives (still no kind
> tags) but the phrasing below that treats lojix-store as a
> `blake3 → bytes` map is wrong on the backend. The `Put…` enum
> sketch here is superseded by `PutStoreEntry` /
> `GetStorePath` / `MaterializeFiles` / `DeleteStoreEntry`
> verbs (see report 033 Part 2 and architecture.md §3).

### Answer to "I don't understand your concept"

A kind byte was a 1-byte tag stored alongside each store entry
in a content-addressed store so that `scan(kind)` could be
done by byte-prefix lookup. It only mattered when **one store
held everything**.

### Why it's gone now

- sema is its own redb-backed DB. Records have their own tables;
  no kind byte needed.
- arbor is shelved; kinds 0xA0, 0xF0, 0xF1 vanish.
- lojix-store holds real files (compiled binary trees from
  lojixd forge actors, user attachments). Type is known through
  the referring sema record — a filesystem of bytes doesn't
  need typing any more than `/nix/store/` does.

### What lojix-store is (corrected)

A **content-addressed filesystem + index DB**. Hash-keyed
directory of real unix files/trees; separate index DB for
metadata and reachability. Type is known by the referring sema
record. A sema record carrying
`compiled_binary: StoreEntryRef` tells you the referent is a
binary tree; lojix-store doesn't need to care.

If we want "list all binaries" debuggability, the index DB
already answers it — no separate sidecar needed.

### What the `LojixStoreRequest` enum was going to look like (superseded)

The kind-drop intuition holds; the actual verb set is now in
report 033 Part 2 (`PutStoreEntry`, `GetStorePath`,
`MaterializeFiles`, `DeleteStoreEntry`, `ContainsStoreEntry`).
The `Put / PutBegin / PutChunk / PutCommit` streaming-session
shape is still relevant for large artifact trees; see the
streaming sub-question in 031 P3.

(Original enum sketch removed — superseded by 033 Part 2.)

---

## §4 · Launch is filesystem, not protocol

Replaces 015 §7 step (8-11), 015 §10 `CriomeRequest::Launch`,
015 §13 T2.

### The error

I had `CriomeRequest::Launch { binary: Hash, argv }` and was
debating between criomed-does-exec vs launcher-daemon.

### Correction

**A binary in lojix-store is a real file** living at a
hash-derived path in the content-addressed filesystem. To run
it: just `exec` the path. No materialisation step needed for
binaries that are already in the store (materialisation applies
when assembling a workdir from multiple store entries for a
build).

Nix analogue:
```
/nix/store/<hash>-name/bin/app
~/.nix-profile/bin/app           # symlink tree for PATH
```

Lojix equivalent (sketch — not a spec):
```
~/.lojix/store/<hash>/bin/<name>    # real file; directly executable
~/.lojix/bin/<opus-name>            # optional symlink tree
```

**There is no `Launch` nexus message.** The flow is:

1. `(Compile (Opus nexusd))` → criomed → lojixd → binary tree
   placed into lojix-store at its hash-derived path, store-
   entry hash returned in compile reply.
2. Criomed writes a `CompiledBinary { opus, hash }` record to
   sema (so "what's the current binary for opus X" is a sema
   query).
3. To run: `lojixd` resolves `hash → filesystem path` via its
   index DB (a trivial lookup); nexus-cli prints the path.
4. User types the path in a shell. Done. The binary is already
   on disk.

### What criomed does gain

Criomed is the **overlord** of lojix-store (per Li's Q6): it
tracks what store entries exist (via sema records), knows
what's safe to garbage-collect, and issues capability tokens
to lojixd's forge actors so they can place store entries
without bytes crossing criomed. But it does **not** launch
processes. That's a userland concern.

### CriomeRequest diff

Remove `Launch { binary, argv }`. Add (implicit in the flow):
- compile puts a `CompiledBinary` record in sema automatically
- materialize-to-path is a nexus-cli-level concern, not a
  protocol message

---

## §5 · forge actors ↔ lojix-store via capability token

Replaces 015 §13 T1, 016 Q6.

> *Updated 2026-04-24*: Under report 020, the forged and
> lojix-stored daemons fold into a single `lojixd`. The token
> flow below was designed for cross-daemon; when both actors
> live in the same process, the authorisation becomes an
> in-process capability check rather than a wire-format token.
> The pattern — criomed as overlord issuing a signed permit,
> lojixd-internal store writer verifying — survives.

When criomed dispatches a compile plan to lojixd, it includes
a short-lived **capability token** that authorises placing new
store entries for that compile. Lojixd's internal store-writer
actor validates and accepts; no bytes ever cross criomed.

**Criomed stays the overlord**: it signs tokens, tracks what
lojixd stored (via sema records), can revoke the per-principal
policy. Large binary trees skip criomed's process memory
entirely.

Sketch (updated for in-process authorisation):
```rust
// lojix-msg envelope
pub struct RunCargoPlan {
    // ...
    pub store_token: LojixStoreToken,  // short-lived capability
}

pub struct LojixStoreToken {
    pub issued_at:  UnixMillis,
    pub expires_at: UnixMillis,
    pub permits:    TokenPermits,      // { place: bool, read: bool, … }
    pub signature:  Signature,         // criomed's key over the above
}
```

Token verification is a simple check inside lojixd's store-
writer actor: criomed publishes a pubkey at startup; tokens
are signed; the actor verifies.

---

## §6 · nexus-cli is flag-less

Replaces 015 §5 (capstone) and 016 Q5.

### What nexus-cli is

A trivial CLI: accept a nexus message on stdin or as argv,
send to nexusd, print the response. Nothing else.

```
nexus-cli '(Compile (Opus nexusd))'
nexus-cli < message.nexus
nexus-cli --version
```

No subcommands. No flags (beyond `--version`). All functionality
is in the message.

### Consequence for capstone

The "add a subcommand to nexus-cli" capstone proposed in 015/016
doesn't work — nexus-cli has no subcommands to add. New
capstone proposal:

**"Assert a new Method body record that adds a new built-in
query operator, recompile, observe the new operator work."**

e.g. add a new `(Median @field)` aggregation to
`nexus-schema::query`. Process:

1. `(Assert (Method …))` — define `Median` impl for the
   aggregator.
2. `(Compile (Opus nexus-schema))` → new nexus-schema binary.
3. `(Compile (Opus criomed))` → new criomed using it.
4. Run `nexus-cli '(Query (| Order @amount |) (Median @amount))'`
   — succeeds against new criomed, fails against old.

Fully exercises the mutation→compile→loop close flow and
doesn't require CLI subcommands.

---

## §7 · No backward compat

Replaces several spots across reports. Saved as a bd memory.

The engine is still being born — nexus/criome/sema are not in
production, no external consumers exist, no stable API surface.
Refactor, rename types, move modules between crates, drop
helpers, reshape records freely. Don't invoke "backward
compatibility" or "existing consumers" as blockers.

This applies until Li explicitly declares a compatibility
boundary.

---

## §8 · Status of 015 / 016 after this report

Points in 015 §5, §7 step 8-11, §10 (Launch), §13 T1 + T2 are
now **superseded** by this report. The rest of 015 stands.

Points in 016 Q2, Q4, Q5 (capstone), Q6, Q7, Q8 are now
**resolved** by this report. Q1 (solstice) is moot — ETAs off
the table.

The canonical living doc is `docs/architecture.md`.

---

*End report 017.*
