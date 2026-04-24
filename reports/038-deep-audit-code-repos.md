# 038 — deep audit: sema-ecosystem code repos

*Claude Opus 4.7 / 2026-04-24 · audit pass against canonical
architecture (docs/architecture.md, reports 026/033/037) and the
current invariants (sema holds code as logic; lojix-store is a
content-addressed filesystem; three daemons; AGENTS.md/CLAUDE.md
shim pattern). Scope: all CANON + TRANSITIONAL repos.*

---

## Summary

Ecosystem is largely clean. Four actionable items found; one is
a small code comment, one is a flake description, one is a
stale file, and one was a misread (Cargo edition = "2024" is
valid).

---

## Actionable findings

### 1. `lojix-store/flake.nix` line 2 — stale description

Currently reads:
```
description = "criome-store — append-only content-addressed rkyv store";
```

Three problems: name (`criome-store` is renamed), backend
(`append-only` is wrong under the filesystem model), and content
(`rkyv store` — lojix-store holds opaque bytes, not rkyv).

Replace with something like:
```
description = "lojix-store — content-addressed filesystem (nix-store analogue; holds real unix files)";
```

### 2. `lojix-store/source/store.aski` — delete entire file

Legacy aski-language schema describing the old kind-byte-
registry + byte-map design. Violates architecture on multiple
axes:
- Aski is no longer a language in the ecosystem (nexus-schema
  is the vocabulary home).
- Kind-byte typing is rejected per report 017 §3.
- The byte-map shape doesn't match the filesystem target.

AGENTS.md of this repo already flags the prototype as
seed-only; deleting this file matches that flag.

Action: `rm /home/li/git/lojix-store/source/store.aski`.

### 3. `nexusd/src/main.rs` line 6 — stale daemon name

Currently:
```rust
//! rkyv criome-messages to criomed, relays replies back as nexus
//! text. Stateless modulo in-flight request correlations — criomed
//! (guardian of sema-db) and lojix-stored (guardian of lojix-store)
//! hold the state.
```

`lojix-stored` is a superseded daemon name (report 020 folded
`forged` + `stored` into `lojixd`). Replace with `lojixd`.

### 4. (No change) Cargo `edition = "2024"` in lojix-store

Initial audit flagged this as invalid. Verified: `edition =
"2024"` is used across the workspace (e.g. `nota-serde-core`).
Rust 2024 edition stabilised in rustc 1.85. Keeping as-is.

---

## Verified clean

These repos have no stale contamination under current
architecture:

- **nota**, **nota-serde-core**, **nota-serde** — grammar stack.
- **nexus**, **nexus-serde**, **nexus-schema** — grammar +
  vocabulary.
- **sema** — records DB. (Note: `sema/reference/Vision.md`
  contains aspirational aski-era text; it's explicitly labelled
  as historical reference, and the repo's README calls it a
  vision doc. Non-actionable.)
- **nexus-cli**, **rsc** — clients. Scaffolds.
- **criome** — spec-only repo; AGENTS.md updated this session.
- **lojix** — TRANSITIONAL working deploy CLI; BEWARE banner
  in AGENTS.md; CLAUDE.md shim correct.

## Contamination scan — terms searched and findings

- `criome-store` naming — 1 instance (lojix-store/flake.nix);
  ready to fix.
- `blob` / `append-only file` / `hash→offset index` — 1
  instance (same flake.nix line); covered by #1.
- `SourceRecord` / `TokenStream` / `Ast` records — **0**.
- `lojix-stored` / `lojix-forged` / `forged`-as-daemon — 1
  instance (nexusd/src/main.rs); ready to fix.
- `aski` language references — only in sema/reference/Vision.md
  (historical) and lojix-store/source/store.aski (to delete).
- `PutBlob` / `GetBlob` / `ContainsBlob` / `DeleteBlob` — **0**
  in code repos. (Still present in deleted-reports history but
  those are gone.)
- `kind-byte` / kind-byte typing — 1 instance in
  lojix-store/source/store.aski (to delete).
- `Launch` as a protocol verb — **0**.
- References to deleted reports 015/018/023/024/025 — **0**.
- `AGENTS.md` / `CLAUDE.md` shim pattern — consistent across
  all repos where both files exist (this session's sweep).

---

## Non-blocking observations

- Several canonical repos (nota, nexus, nexus-schema,
  nota-serde-core, nota-serde, nexus-serde, nexus-cli, nexusd,
  rsc, sema) have **no** AGENTS.md or CLAUDE.md. For pure
  library/spec crates this is fine — mentci-next/AGENTS.md
  covers cross-project rules and each repo's README describes
  its role. Adding minimal AGENTS.md + shim is optional, pays
  off only if a repo grows agent-specific guidance.

---

*End report 038.*
