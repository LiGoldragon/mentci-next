# 041 — deep audit, final synthesis

*Claude Opus 4.7 / 2026-04-24 · closes the multi-round audit Li
requested: "run a deep audit on everything. remove/edit stale
docs. remove stale code. use agents freely. then create a final
report." Synthesises reports 038 + 039 + 040 + the actual edits
made.*

---

## TL;DR

Three parallel audits ran: code repos (038), mentci-next
workspace (039), CriomOS cluster (040). Four actionable items
surfaced; all applied. Workspace is now clean.

---

## What the audits found

### Report 038 — sema-ecosystem code repos

Four actionable findings; one misread corrected:

1. `lojix-store/flake.nix` had `criome-store — append-only
   content-addressed rkyv store` as description. Stale on
   three axes (name, backend, content).
2. `lojix-store/source/store.aski` was a legacy aski-language
   schema describing the old kind-byte + byte-map design.
3. `lojix-store/Cargo.toml` still depended on `arbor` (shelved)
   and lived alongside the deleted `source/` tree — dead
   config.
4. `nexusd/src/main.rs` doc comment referenced `lojix-stored`,
   a daemon name superseded in report 020.

(The audit also flagged `edition = "2024"` as invalid. Verified
false: 2024 edition is stable in rustc 1.85 and used
workspace-wide. No change.)

All other canonical code repos (nota/nexus grammar stack,
nexus-schema, sema, nexus-cli, rsc, criome, lojix) came up
clean. Contamination scan for 10 specific terms (SourceRecord,
TokenStream, Ast, PutBlob, blob, append-only file, kind-byte,
lojix-stored, Launch, aski-in-active-code) returned only the
items above.

### Report 039 — mentci-next workspace

One actionable finding:

5. Report 019 §2 line 80 still read "lojix-store (blobs,
   opaque)" — inconsistent with the nix-store-analogue framing
   landed in docs/architecture.md §3.

Everything else — architecture.md, workspace-manifest.md,
AGENTS.md/CLAUDE.md, devshell.nix, flake.nix, PRIME.md, every
surviving report, every bd memory — came up clean.

### Report 040 — CriomOS cluster

Zero actionable findings. All four repos (CriomOS, horizon-rs,
CriomOS-emacs, CriomOS-home) are clean. References to sema
ecosystem concepts are accurate or explicitly historical
context.

---

## Actions applied this session

| Action | Target | Result |
|---|---|---|
| Update description | `lojix-store/flake.nix` | Now describes the nix-store-analogue filesystem model. |
| Delete file | `lojix-store/source/store.aski` | Removed. |
| Delete dir | `lojix-store/source/` | Removed (empty after aski delete). |
| Clean deps | `lojix-store/Cargo.toml` | Empty `[dependencies]`; comment flags this as scaffold-only. |
| Remove | `lojix-store/Cargo.lock` | Gone (no deps to lock). |
| Fix doc comment | `nexusd/src/main.rs` | `lojix-stored` → `lojixd`, and "guardian of sema-db" tightened to "sema's engine". |
| Sharpen prose | `reports/019-lojix-as-pillar.md` §2 | "lojix-store (blobs, opaque)" → "lojix-store (real files, hash-keyed — a nix-store analogue)". |
| Reading-order | `docs/architecture.md` §9 | Added 034–036 and 037–040 rows. |
| Save | `reports/038`, `reports/039` | Written (Explore agents couldn't save them directly). |
| Memory | bd (`deep-audit-2026-04-24`) | Durable record of these audits + outcomes. |

---

## What remains clean (i.e. needed no action)

**Code**: nota, nota-serde-core, nota-serde, nexus, nexus-serde,
nexus-schema, sema, nexus-cli, rsc, criome, lojix. No stale
contamination.

**Docs**: docs/architecture.md, docs/workspace-manifest.md,
AGENTS.md, CLAUDE.md, .beads/PRIME.md, flake.nix, devshell.nix.

**Reports**: 004, 009, 013, 014, 016, 017, 020, 021, 022, 026,
027, 028, 029, 030, 031, 032, 033, 034, 035, 036, 037, 040.

**bd memories**: all current-truth memories consistent;
superseded ones explicitly marked.

**CriomOS cluster**: all four repos clean.

---

## What the audits confirmed

The last several sessions of corrections stuck:

- **sema holds code as logic** (not text). No SourceRecord /
  TokenStream / Ast in any live repo or document.
- **lojix-store is a content-addressed filesystem** (not a blob
  DB). No append-only-file framing, no PutBlob/GetBlob verbs,
  no kind-byte registry.
- **Three daemons** (nexusd / criomed / lojixd). No
  forged/lojix-stored dangling anywhere.
- **Rename and delete rather than banner** (per Li's rule). 015,
  023, 024, 025, 018 are gone. 019 carries a narrow
  partial-supersession banner + the sharpened §2; 017 carries
  surgical notes in §3 and §5. No other banners exist.
- **AGENTS.md/CLAUDE.md shim** across all touched repos. Canon
  sibling repos without either file are fine as-is (library
  scope doesn't yet need per-repo agent guidance).

---

## Remaining work (not this session)

These are pointers forward, not audit findings:

- **Li's P0–P3 decisions from report 031** — hash-vs-name refs,
  use-r-a-crates for ingest, edit-UX model, lojix-msg home.
- **Create CANON-MISSING repos** when needed: criomed,
  criome-msg, lojix-msg, lojixd. `devshell.nix` has their
  entries commented out as a reminder.
- **Physical ~/git/archive/** — not yet needed; RETIRED and
  ARCHIVED are empty.
- **Agent doc shims** for the 10 canonical repos currently
  without any AGENTS.md — optional; add when a repo grows
  agent-specific guidance.

---

## Numbers

- Audit reports produced: 3 (038, 039, 040).
- Actionable findings: 5.
- Files edited this session under audit: 5 (`flake.nix`,
  `Cargo.toml`, `nexusd/src/main.rs`, `reports/019-*.md`,
  `docs/architecture.md`).
- Files deleted: 2 (`store.aski`, `Cargo.lock`).
- Directories removed: 1 (`lojix-store/source/`).
- Clean reports carried over: 22.
- Clean repos: 14 canonical + 5 CriomOS cluster.
- Final synthesis report: this one (041).

---

*End report 041.*
