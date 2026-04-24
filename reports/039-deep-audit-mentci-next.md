# 039 — deep audit: mentci-next workspace (reports, docs, ops files)

*Claude Opus 4.7 / 2026-04-24 · audit of mentci-next itself —
architecture doc, workspace manifest, every surviving report,
flake + devshell, PRIME.md, bd memories — against current
invariants. Scope: the workspace directory.*

---

## Summary

Clean overall. Two small sharpening opportunities in report 019;
no stale reports need deleting; architecture.md and the
workspace-manifest are aligned; bd memories are consistent with
current framing.

---

## Part 1 — Architecture + canonical docs

**`docs/architecture.md`** — clean. §1 thesis correctly states
both sema-is-the-truth and sema-holds-code-as-logic. §3 rewrites
from earlier this session for the lojix-store filesystem
framing. §4 repo layout is accurate. §8 rules set is consistent.
§9 reading order points at the correct surviving reports and
explicitly notes the deleted ones.

**`docs/workspace-manifest.md`** — clean. CANON rows include
lojix-store (with rename note) and the CriomOS cluster. RETIRED
and ARCHIVED sections are empty (disposition log notes the
rename/delete actions taken). OFF-SCOPE is a broad sweep.

**`AGENTS.md`** — correct. Pointer to architecture.md +
workspace-manifest.md; hard inclusion-exclusion rule; note about
the AGENTS.md/CLAUDE.md shim pattern.

**`CLAUDE.md`** (mentci-next) — correct one-line shim.

---

## Part 2 — Per-report verdicts

| Report | Verdict | Note |
|---|---|---|
| 004 sema-types-for-rust | KEEP | Foundational; correct. |
| 009 binds-and-patterns | KEEP | No stale refs. |
| 013 nexus-syntax | KEEP | Grammar canon; references to aski-v020 are explicitly historical precedent. |
| 014 serde-refactor-review | KEEP | Accurate state of nota-serde-core + nexus-serde refactor. |
| 016 tier-b-decisions | KEEP | Decision-staging document; questions superseded by 017 but the decision-journey value is intact. |
| 017 architecture-refinements | KEEP | Sharpened this session with the supersession note and lojix-store correction. |
| 019 lojix-as-pillar | **SHARPEN** | See below. Partial-supersession banner already at top, but the body at §2 line 80 still says "lojix-store (blobs, opaque)" — replace with "lojix-store (real files, hash-keyed)". Small edit, consistent with 032's verdict. |
| 020 lojix-single-daemon | KEEP | Establishes three-daemon topology. |
| 021 criomed-evaluates-lojixd-executes | KEEP | sema-is-the-truth framing. |
| 022 records-as-evaluation-prior-art | KEEP | Prior-art survey; framework-agnostic. |
| 026 sema-is-code-as-logic | KEEP | The canonical code-as-logic synthesis. |
| 027 adversarial-review-of-026 | KEEP | Open-questions list; still valid. |
| 028 doc-propagation-inventory | KEEP | Findings actioned this session. |
| 029 ra-chalk-polonius-structural-lessons | KEEP | Structural synthesis. |
| 030 lojix-transition-plan | KEEP | Phase A–G roadmap for lojix. |
| 031 uncertainties-and-open-questions | KEEP | Prioritised decision list. |
| 032 lojix-store-correction-audit | KEEP | Meta-report on the delete-and-rewrite pass. |
| 033 record-catalogue-and-cascade-consolidated | KEEP | Consolidates the content from deleted 023/024/025. |
| 034 sema-multi-category-framing | KEEP | Post-MVP category framing. |
| 035 bls-quorum-authz-as-records | KEEP | Post-MVP authorisation. |
| 036 world-model-as-sema-records | KEEP | Post-MVP exploratory. |
| 037 workspace-inclusion-and-archive-system | KEEP | Answered Li's Q-cluster; partially actioned (rename + delete + cluster adoption). |
| 040 criomos-cluster-audit | KEEP | Clean; documents the cluster as contamination-free. |

No deletions recommended. No banner-and-keep recommendations
(per Li's "delete wrong reports, don't banner" rule — banners
should only exist on reports that are *partially* wrong; any
such remaining is already in 019's top banner or 017's §3/§5
surgical notes).

---

## Part 3 — Operational files

- `flake.nix` — clean.
- `devshell.nix` — clean; linkedRepos mirrors the manifest.
- `.beads/PRIME.md` — clean; jj commit workflow updated
  earlier this session.

---

## Part 4 — bd memories

Search summary (from running `bd memories` against the
ecosystem):

- Current-truth memories present and consistent:
  - `sema-is-the-evaluation-per-li-2026-04`
  - `sema-holds-code-as-logic-not-text-li`
  - `lojix-store-is-a-content-addressed-filesystem-nix`
  - `engine-architecture-three-daemons`
  - `workspace-inclusion-rule-repos-in-docs-workspace-manifest`
  - `repo-operations-2026-04-24`
  - `lojix-repo-is-li-s-working-criomos-deploy`
- Superseded memories explicitly marked:
  - `engine-architecture-four-daemons` (SUPERSEDED landmark)
  - `criomed-has-an-incremental-evaluator` (SUPERSEDED landmark)

No stale memories found that conflict with current invariants.

---

## Part 5 — Recommended action batch

Single actionable item:

- **Sharpen report 019 §2 line 80**: "lojix-store (blobs,
  opaque)" → "lojix-store (real files, hash-keyed)".

Everything else is clean.

---

*End report 039.*
