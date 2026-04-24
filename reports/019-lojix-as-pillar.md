# 019 — lojix as the artifacts pillar of criome

> **⚠ Partial supersession — read before the body**
>
> - **Daemon topology** (this report's §5–§6 and the table that
>   lists `lojix-forged` + `lojix-stored` as separate daemons):
>   **superseded by report 020**. Both forge and store become
>   internal actors inside a single `lojixd`.
> - **`lojix-store` as "blob store"** (this report's §2–§3
>   framing): **superseded by docs/architecture.md §3 and
>   reports/032**. lojix-store is a **content-addressed
>   filesystem** (nix-store analogue) holding real unix files
>   and directory trees, with a separate index DB — not a
>   blob-packed file.
> - **What survives here**: the three-pillar framing
>   (criome ⊇ {sema, lojix}); lojix = "Li's expanded and more
>   correct nix"; lojix-family membership as a second axis
>   orthogonal to layer; the 11 nix problems lojix fixes; the
>   8 principles; wrap→replace migration phases; broad-lojix
>   thesis.

*Claude Opus 4.7 / 2026-04-24 · supersedes the deleted report 018.
Synthesis of three research passes (vision, topology, boundaries)
given two settled premises from Li: "forged is deeply linked with
lojix" and "lojix is my take on an expanded and more correct nix."*

## 1 · Premises (settled, not litigated here)

- **lojix is a namespace** — Li's expanded-and-more-correct
  nix. The prefix is load-bearing.
- **Broad lojix** — lojix covers everything nix covers: build,
  compile, store, deploy. `forged` is in the lojix family (nix
  has build built-in via `nix-build` / `rustPlatform.buildRustPackage`;
  lojix's equivalent is `lojix-forge`).
- **Three pillars**: **criome** ⊇ **{sema, lojix}**. sema =
  records/meaning/schema. lojix = artifacts/build/deploy/store.
  nexus = communication skin spanning all of criome.
- **No backward compatibility.** Rename freely.

## 2 · Thesis

**lojix is the artifacts pillar of criome** — the namespace that
does what nix does (everything build, everything store,
everything deploy) redesigned around sema's invariants: typed
records instead of stringly-typed eval language, blake3 content-
addressing as architectural spine rather than cache patch,
daemon-mediated capability tokens instead of filesystem-permission
handwaving. Where nix unifies-by-coincidence, lojix unifies-by-
design.

The current `lojix` CLI (horizon-projector + nixos-rebuild
driver) is **one facet** of the namespace, not its totality.
The broad lojix family includes forge (rust compile), store
(blobs), stored (blob daemon), deploy (the current CLI),
schema (typed records describing build specs), and whatever
else the expanded-nix vision grows to need.

## 3 · What lojix fixes in nix (condensed)

Detailed table was in the research pass. Key items:

- **Stringly-typed derivation language** → typed `Opus` /
  `Derivation` rkyv records
- **Unstable derivation hashes** → identity = blake3 of
  canonical rkyv encoding
- **Hallucinatable attribute paths** → schema-bound pattern
  resolution (criomed rejects unknown field names)
- **Vague channel pinning** → `RustToolchainPin` carries a
  `DerivationId` (hash), not a channel enum
- **Tool fragmentation** (`nix-build`, `nix-shell`,
  `nixos-rebuild`, …) → unified four-daemon architecture with
  rkyv contract crates
- **Filesystem-path authz** → capability tokens signed by
  criomed
- **Impure builds** → `env`/`rustflags` are fields of `Opus` so
  they enter the identity hash
- **Two parallel dep systems (Cargo + nix)** → `OpusDep::{Opus,
  Derivation}` unifies both
- **Build/store blob conflation in `/nix/store`** → sema
  (records, typed) and lojix-store (blobs, opaque) are peer
  stores with separate daemons

## 4 · Three-pillar architecture with two-axis framing

criome (runtime) contains sema and lojix; nexus is the skin.

```
                    ┌─── nexus (communication skin) ───┐
                    │                                  │
   ┌────────────────┼──────── criome (runtime) ────────┼───────┐
   │                │                                  │       │
   │                ▼                                  ▼       │
   │      ┌─────────────────────┐    ┌─────────────────────┐   │
   │      │      sema           │    │       lojix         │   │
   │      │                     │    │                     │   │
   │      │ records, meaning,   │    │ artifacts, build,   │   │
   │      │ schema, patterns    │    │ compile, store,     │   │
   │      │                     │    │ deploy              │   │
   │      └─────────────────────┘    └─────────────────────┘   │
   │                                                           │
   │  four daemons: nexusd · criomed · lojix-forged ·          │
   │                lojix-stored                               │
   └───────────────────────────────────────────────────────────┘

               (CriomOS: consumer of lojix, not a pillar member)
```

**Two-axis framing.** Every daemon has both a **runtime
identity** and a **family lineage**:

| Daemon | Runtime | Family |
|---|---|---|
| `nexusd` | criome | criome (nexus communication skin) |
| `criomed` | criome | criome |
| `lojix-forged` (currently `forged`) | criome | lojix |
| `lojix-stored` | criome | lojix |

All four run at the criome-runtime layer. Some are also lojix-
family crates. Not a contradiction — it's the structure.

## 5 · Concrete topology (renames and additions)

### Rename table

| Current | New | Why |
|---|---|---|
| `forged` (planned daemon) | **`lojix-forged`** | Family-prefix symmetry with `lojix-stored`; aligns with lojix = nix umbrella |
| `compile-msg` (planned) | **`lojix-forge-msg`** | Contract crate for the forge daemon |
| `criome-store` (exists, scaffold) | **`lojix-store`** *(already renamed per prior session)* | Namespace correction |
| `lojix` (current deploy CLI) | **`lojix-deploy`** | Family-prefix symmetry; disambiguates from umbrella |
| `rsc` | **`rsc`** *(stays)* | Pure records-to-source lib; not nix-scope |
| new | **`lojix-schema`** | New crate; see §6 |
| new | **`lojix-forge`** (lib) / **`lojix-forged`** (daemon bin) | Library + daemon split per rust/style one-artifact-per-repo |

### New `lojix-schema` crate

**Recommendation: create it.**

- Owns: `Opus`, `Derivation`, `OpusDep`, `RustToolchainPin`,
  `CargoProfile`, `OpusOutput`, `CrateType`, `LinkSpec`,
  `DerivationBuilder`, `FlakeOverride`, `EnvValueTemplate`,
  `NarHashSri`, `FlakeRef`, `OverrideUri`, `TargetTriple`.
- Dep direction: `lojix-schema` → `nexus-schema` (imports `Hash`,
  ID newtypes, etc.). `nexus-schema` does **not** depend on
  `lojix-schema`. No cycle.
- Conceptually clean: sema vocabulary in `nexus-schema`; lojix
  vocabulary in `lojix-schema`. Symmetric per the pillar split.

This supersedes the plan in [reports/017 §1](017-architecture-refinements.md)
that placed Opus/Derivation inside nexus-schema.

### `nexus-schema` → `sema-schema` rename (potential)

Observation: `nexus-schema` contains sema records (Struct, Enum,
Module, Program, Type, Origin, Names, Patterns, Query ops) — not
nexus *messages*. The name is a historical artifact from when
the project was smaller. A rename to `sema-schema` would clarify
that this crate owns the sema pillar's type vocabulary.

**Recommendation**: consider but defer. Mechanical rename, high
cognitive payoff, but touches every dependent crate. Ship after
the lojix-schema split settles.

### Layer structure (updated)

| Layer | Contents | Lojix family? |
|---|---|---|
| 0 — text grammars | nota, nota-serde-core, nota-serde, nexus, nexus-serde | no |
| 1 — schema vocabulary | **nexus-schema** (sema records + patterns), **lojix-schema** (Opus/Derivation + nix newtypes) | lojix-schema is family |
| 2 — contract crates | criome-msg, **lojix-forge-msg**, lojix-store-msg | forge + store msg are family |
| 3 — storage | sema, lojix-store | lojix-store is family |
| 4 — daemons | nexusd, criomed, **lojix-forged**, lojix-stored | forged + stored are family |
| 5 — clients / build libs | nexus-cli, rsc, **lojix-forge** (lib), **lojix-deploy** (lib + CLI) | forge + deploy are family |

Net delta:
- **New**: `lojix-schema`, `lojix-forge` (lib), `lojix-deploy`
- **Renamed**: `compile-msg` → `lojix-forge-msg`; `forged` →
  `lojix-forged`; current `lojix` → `lojix-deploy`
- **Unchanged**: rsc, sema, lojix-store (already renamed),
  lojix-store-msg, lojix-stored, nexus-schema (potentially →
  sema-schema later)
- Workspace grows to ~19 repos (was 18).

### Daemon graph

```
 nexus text → nexusd ──[criome-msg]── criomed ──┬──[lojix-forge-msg]── lojix-forged
                                                │                           │
                                                │                           │ capability token
                                                │                           ▼
                                                └──[lojix-store-msg]── lojix-stored
                                                            ▲
                                     (forged uses same lojix-store-msg wire)
```

Only `forged → lojix-forged` and `compile-msg → lojix-forge-msg`
change visually vs the prior diagram in
[docs/architecture.md §2](../docs/architecture.md).

## 6 · Boundary taxonomy (concise)

Full table in research pass. Headline rules:

- **sema owns** record types, pattern types, query op types,
  subscription semantics. Lives in nexus-schema (or future
  sema-schema).
- **lojix owns** artifact types (Opus, Derivation), blob store,
  build daemons, deploy tooling, nix newtypes. Lives in
  lojix-schema + lojix-* crates.
- **criome owns** the runtime (daemons, supervision, token
  signing, pattern resolver engine, subscription hub, nexus
  text grammar, capability-token concept). Lives in nexusd +
  criomed + criome-msg + the nota/nexus grammar repos.
- **nexus is a skin** — not a pillar. The text grammar + rkyv
  wire-format conventions span all of criome.
- **Bridge types** (dual citizens) are noted explicitly and kept
  in the natural home:
  - `Hash`, ID newtypes → nexus-schema (sema vocabulary, used
    everywhere)
  - `LojixStoreToken` → lojix-store-msg (lojix verifies,
    criomed signs)
  - `NarHashSri` et al. → lojix-schema (lojix owns)
  - `CompiledBinary` record → lojix-schema (lojix artifact
    pointer)
  - `Opus` / `Derivation` → lojix-schema

## 7 · Nix relationship — wrap now, replace later

Migration phases (paraphrased from Agent 1's vision pass):

- **Phase A (today)**: the current `lojix` CLI shells out to
  `nix` / `nixos-rebuild`. Pure wrapping.
- **Phase B (MVP self-hosting)**: `lojix-forged` ships. Pure-
  rust builds go directly to cargo (no nix). `Derivation`
  records still resolve via `nix build --print-out-paths` for
  system libs.
- **Phase C**: system-library builds land as first-class lojix
  derivations with non-nix backends. `FlakeOutput` becomes one
  of several `DerivationBuilder` variants.
- **Phase D** (long-term): nix no longer required. The lojix-
  built pipeline bootstraps itself; the expanded-nix vision is
  complete.

No ETAs; no promises; direction only.

## 8 · What lojix is NOT (guardrails for future sessions)

- **Not sema's territory.** sema owns records and meaning; lojix
  owns artifacts and build activities. The join is that `Opus`
  is a record (sema cares it IS a record; lojix cares what it
  means).
- **Not criomed's internal concern.** criomed dispatches lojix
  work; doesn't implement it. lojix-forged does the compiling.
- **Not the nexus grammar.** lojix uses delimiters and records
  like anyone else; it doesn't own the grammar.
- **Not a versioning system.** arbor (shelved) was versioning;
  lojix is byte-identity only.
- **Not a process launcher.** binary → path materialization is
  filesystem (userland); no Launch protocol.

## 9 · Open questions

These need Li input before the reshape lands.

**Q1 — Create `lojix-schema` now, or keep Opus/Derivation in
nexus-schema for MVP and split later?** Recommendation: create
now; the no-backward-compat rule makes the cost low and the
conceptual payoff is immediate.

**Q2 — Top-level `lojix` CLI**: (a) thin dispatcher
(`lojix forge …`, `lojix store …`, `lojix deploy …` — like
`cargo`); (b) drop entirely, users call `lojix-deploy`,
`lojix-forged` etc. directly. (a) has UX polish; (b) has no
bare-name ambiguity. Lean (b) — the namespace is clearer
without a root binary that competes with the umbrella concept.

**Q3 — `lojix-forge` lib + `lojix-forged` daemon-bin — one
repo or two?** Per rust/style.md "one artifact per repo": two.
Matches `nexus-serde` (lib) + `nexusd` (bin) precedent. But the
lib and daemon are tightly coupled; one-repo-with-[lib]+[[bin]]
is ergonomically simpler. Lean two-repos for consistency.

**Q4 — Future `sema-schema` rename of `nexus-schema`?** Clean
up once the lojix-schema split has landed and settled. Not
blocking now.

**Q5 — Does CriomOS become a criome-runtime host long-term?**
Currently CriomOS uses lojix (consumer, not pillar). If
CriomOS ever ships a nexusd as a system service, the direction
flips — lojix becomes a tool *inside* CriomOS. Not a decision
for this report, but worth watching.

---

## Summary of concrete recommendations

- **Adopt broad lojix** — forged and rsc are lojix-family
  (though rsc keeps its name as a pure library).
- **Create `lojix-schema`** — own `Opus`/`Derivation`/nix
  newtypes; depend on `nexus-schema` for `Hash` and ID
  newtypes.
- **Rename** `forged` → `lojix-forged`, `compile-msg` →
  `lojix-forge-msg`, current `lojix` CLI → `lojix-deploy`.
- **Add** `lojix-forge` library crate alongside `lojix-forged`
  daemon.
- **Preserve** two-axis framing: every daemon has a runtime
  identity (always criome) and a family lineage (criome, sema,
  or lojix).
- **Update** docs/architecture.md to reflect broad lojix +
  lojix-schema + rename table.

---

*End report 019.*
