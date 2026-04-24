---
title: CriomOS cluster sema-ecosystem audit
date: 2026-04-24
status: complete
rfc: 040
---

Quick audit of the CriomOS cluster repos (newly canonical in sema-ecosystem workspace) to catch stale references to the sema stack.

## Summary

All four repos are **CLEAN** of major sema ecosystem contradictions. All CLAUDE.md shims are correct (one-liners). No references to deleted systems or renamed daemons. The only substantive observation: references to `lojix` in CriomOS reports are about lojix v1 fragilities (acknowledged and tracked), not architecture. horizon-rs design doc correctly frames `criome` as domain name (not a separate system), and the Nix guidelines docs use `sema` as a style-naming framework (not a product reference).

---

## Per-repo state

### `/home/li/git/CriomOS`

**Status:** CLEAN

CLAUDE.md is correct one-liner shim. README and AGENTS.md are clean — no sema ecosystem references. Architecture audit (reports/) contains discussions of lojix v1 production fragilities, which are acknowledged tactical gaps, not contradictions with the canonical architecture. All references to the horizon layer, horizon-rs, and lojix are accurate to the current canonical design.

The GUIDELINES.md and NIX_GUIDELINES.md files reference "Sema principles" and "Criome lineage" as *style frameworks*, not system names — this is correct usage. Confirms that Sema is the naming/architecture discipline, criome is the DNS domain scheme (`<node>.<cluster>.criome`). No blob framing, no stale daemon names, no references to `criome-store`, `lojix-archive`, or old aski language.

**Verdict:** CLEAN


### `/home/li/git/horizon-rs`

**Status:** CLEAN

CLAUDE.md is correct one-liner shim. README and AGENTS.md reference only internal scope (schema ownership, projection logic). DESIGN.md correctly defines `CriomeDomainName` as the derived domain (pattern: `<node>.<cluster>.criome`) and uses it consistently throughout. No stale references. The doc correctly treats horizon-rs as *lojix's dependency*, not a CriomOS input (per the 2026-04-24 architectural decision).

**Verdict:** CLEAN


### `/home/li/git/CriomOS-emacs`

**Status:** CLEAN

CLAUDE.md is correct one-liner shim. README describes the repo's scope cleanly (emacs distribution replacing legacy mkEmacs, consumed by CriomOS-home). AGENTS.md is correct. Emacs README has one mention of `forge` (the Magit Git tooling library), which is Emacs native and unrelated to sema ecosystem architecture.

**Verdict:** CLEAN


### `/home/li/git/CriomOS-home`

**Status:** CLEAN

CLAUDE.md is correct one-liner shim. README and AGENTS.md are clean. Emacs submodule README mentions `forge` (again, Magit library), no sema ecosystem references.

**Verdict:** CLEAN

---

## Summary findings

No stale passages found in any repo:
- No references to `criome-store` (renamed to lojix-store).
- No references to `lojix-archive` (deleted).
- No references to old aski language / askic.
- No incorrect daemon names (`lojix-stored`, `lojix-forged`, etc.).
- No blob framing for lojix-store (filesystem model is unstated, not wrong).
- No contradictions with sema-ecosystem integration (horizon-rs owns schema & projection, lojix owns orchestration, CriomOS is network-neutral platform).
- All CLAUDE.md files are correct one-line shims.

*End report 040.*
