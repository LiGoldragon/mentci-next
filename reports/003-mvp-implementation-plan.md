# 003 — MVP implementation: self-hosting via the database

*Claude Opus 4.7 / 2026-04-23*

The MVP goal: **self-hosting**. The system's own source lives as
records in the database; the same binary that serves the daemon
is also what rsc compiles back out of the database into `.rs`
files, built into a new binary that can edit its own DB. When
the loop closes — editing the DB in nexus messages, rsc producing
a build that passes — the MVP is done.

This is "pseudo-sema": rkyv-typed Rust records are the canonical
form for now. Fully-specified sema bytes come later.

---

## 1. Components

Nine repos, one artifact each (per
[rust/style.md](../repos/tools-documentation/rust/style.md)
rule 1). See [report 007](007-nota-nexus-layer-split.md) for the
nota ↔ nexus layering rationale:

| Repo | Kind | Role |
|---|---|---|
| [`nota`](https://github.com/LiGoldragon/nota) | spec-only | Grammar spec for the data-layer format (JSON/TOML class) |
| [`nota-serde`](https://github.com/LiGoldragon/nota-serde) | library | `serde::Serializer` + `Deserializer` for nota syntax |
| [`nexus`](https://github.com/LiGoldragon/nexus) | spec-only | Messaging-layer grammar — superset of nota; adds sigils + pattern/constrain/shape delimiters |
| [`nexus-serde`](https://github.com/LiGoldragon/nexus-serde) | library | `serde::Serializer` + `Deserializer` for nexus — depends on nota-serde |
| [`nexus-schema`](https://github.com/LiGoldragon/nexus-schema) | library | Rust types that shape database records; ports per [report 004](004-sema-types-for-rust.md) |
| [`sema`](https://github.com/LiGoldragon/sema) | library | The database — redb wrapper + record codec + structural edit operations |
| [`nexusd`](https://github.com/LiGoldragon/nexusd) | binary | Daemon — receives nexus messages, applies edits, serves queries; ractor-based |
| [`nexus-cli`](https://github.com/LiGoldragon/nexus-cli) | binary | Thin client — sends nexus to the daemon, formats responses |
| [`rsc`](https://github.com/LiGoldragon/rsc) | binary | Records → `.rs` projector. Walks an opus, writes files to a temp directory, invokes cargo build |

---

## 2. Flow

```
agent (or nexus-cli)
  ↓ nexus text
nexusd              — ractor-hosted service; parses via nexus-serde
  ↓ structural op
sema                — applies to redb, returns records
  ↓ rkyv bytes
mmap B-tree

rsc                 — walks records, emits .rs files to temp dir
  ↓ cargo build
new binary          — reads its own DB, edits it, repeats
```

---

## 3. Opus — the DB-level compilation unit

A database can hold multiple opera (singular: opus). Each opus
compiles to one artifact — library or binary. An opus corresponds
to one Rust crate; rsc produces one `.rs` tree per opus.

Records inside an opus reference each other by content hash.
Records can be shared across opera (e.g., a `U32` Type record is
referenced from any opus that uses U32).

---

## 4. Milestones

### M1 — nota-serde, then nexus-serde

Serde Serializer + Deserializer over the nota syntax first
(4 delimiter pairs, 2 sigils, Pascal/camel/kebab identifiers,
literals). Canonical-form emission on the serialize side
(reserved for future signing / content-addressing).

Round-trip every example in the nota spec through
`nota_serde::to_string` → `from_str`.

nexus-serde extends nota-serde with the 3 additional delimiter
pairs (`(| |)`, `{| |}`, `{ }`) and 3 sigils (`~`, `@`, `!`).
Phased per [report 007 §6](007-nota-nexus-layer-split.md).

### M2 — nexus-schema types

Data-type layer is already landed. Remaining:

- Method-body layer: Param, TraitDecl, TraitImpl, Method, Signature,
  Statement, Expr, Body, Pattern, MatchArm.
- Self-hosting additions: FreeFn, InherentImpl, `&str`, slice `[T]`,
  `?` operator, pattern guards, where clauses, break/continue with
  labels, panic/Error.

rkyv derives for storage + serde derives for wire (both coexist).

### M3 — sema (library)

redb-backed storage layer. Open DB, create per-record-kind tables,
store/retrieve rkyv records keyed by their blake3 hash. Structural
edit operations: assert a new record; mutate a specific field at a
path; list records of a kind; fetch by hash.

### M4 — nexusd

Ractor-hosted daemon. Accepts nexus messages over Unix socket;
deserializes via nexus-serde; dispatches to sema operations;
serializes responses via nexus-serde.

### M5 — rsc

Opus → temp directory of `.rs` files → `cargo build`. One codegen
rule per variant in nexus-schema's enums. Fidelity target:
behaviorally equivalent binary, not byte-identical source.

### M6 — bootstrap

Populate the DB with the MVP's own source — each of the seven repos
becomes an opus in the database. Run rsc. Compare the output to
the hand-written source (equivalence, not identity). Build, run.

Self-hosting demonstrated when the rsc-output daemon edits its own
database to add a feature that the hand-written daemon didn't have,
and the subsequent rsc+build produces a binary with that feature.

---

## 5. Out of MVP scope

Moved to post-MVP because self-hosting doesn't need them:

- Access control / actor identity / signing / quorum policies.
- Datalog-style queries (observe / constrain / antijoin /
  aggregation).
- Runtime-user-defined types (everything in the DB is a
  compile-time-known nexus-schema type).
- Schema-evolution cascade.
- Multi-writer / networked coordination.
- Full Rust feature coverage beyond what self-hosting needs
  (async, unsafe, Rc/Arc, macros beyond derivation).
