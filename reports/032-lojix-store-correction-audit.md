# 032 — lojix-store terminology audit across reports

*Claude Opus 4.7 / 2026-04-24 · audit of every mention of
`lojix-store` and related terms across surviving reports, after
Li's correction from "blob DB with append-only file + offset
index" to "content-addressed filesystem analogous to the
nix-store, holding real unix files with a separate index DB".*

---

## Corrected terminology

**WRONG (old) framing**:
- lojix-store is a "content-addressed blob store"
- backend = "append-only file + hash→offset index"
- contents = "opaque bytes"
- verbs = `PutBlob` / `GetBlob` / `ContainsBlob`
- daemon name = `lojix-stored`

**CORRECT (current) framing** (per docs/architecture.md §3):
- lojix-store is a **content-addressed filesystem**
- backend = hash-keyed directory of **real unix files and
  directory trees** (nix-store analogue) + a separate **index
  DB** (path mapping, reachability, GC)
- contents = actual files on disk; `exec` the hash path
  directly for compiled binaries
- verbs = `PutStoreEntry` / `GetStorePath` /
  `MaterializeFiles` / `DeleteStoreEntry`
- daemon name = `lojixd` (unified since report 020)

---

## Per-report verdicts

### 013 — nexus-syntax-proposal.md — KEEP

No mentions of lojix-store, blobs, or related terms. Grammar
report; framework-agnostic. No action.

### 015 — architecture-landscape.md (v4) — **DELETE**

Already done this session. Substantially superseded by reports
017, 020, 021, 026. The 10-research-pass methodology was
valuable as decision-journey but the architectural specifics
(four-daemon topology with separate `forged` + `lojix-stored`;
kind-byte registry; append-only blob store) are all wrong under
the current framing. Core useful claims live on in 017/020/021.

### 016 — tier-b-decisions.md — KEEP

Decision-staging doc framing Q1–Q20 as questions, not as
architectural truth. The "lojix-stored" and "kind-byte registry"
mentions are in the context of "what we need to decide," with
answers captured by report 017. Safe as a decision-journey
record.

### 017 — architecture-refinements.md — **SHARPEN**

Two editorial fixes:

- **§1 store-placement language**: current phrasing is
  mostly right; tighten to make explicit that lojixd hashes
  the artifact tree and places it into the lojix-store
  filesystem under a hash-keyed path + updates the index DB.
- **§3 kind-byte registry section**: reframe from "a concept
  we had to shelve" to "Li clarified: lojix-store is
  hash→files with no kind tags — type lives in the referring
  sema record, which makes sense given the store holds real
  files (typing file contents makes no sense)".

### 019 — lojix-as-pillar.md — **SHARPEN**

- **§2 store description**: "blob store (`lojix-store`, owned
  by `lojix-stored`)" → "content-addressed filesystem
  (`lojix-store`, owned by `lojixd`)".
- **§4 daemon table**: rows for `lojix-forged` and
  `lojix-stored` are superseded by report 020. Add a note at
  the top of §4/§5: "Report 020 consolidates forged + stored
  into `lojixd`. The table below is the pre-consolidation view,
  kept for decision-journey."

### 020 — lojix-single-daemon.md — KEEP (with optional micro-sharpen)

First report that correctly frames a single `lojixd` daemon.
§2 still says "Append-only file + rebuildable index +
reader library" — optional micro-edit to read "Content-
addressed filesystem directory (hash-keyed paths, real files)
+ separate index DB + reader library" for consistency with the
updated architecture.md §3. Not load-bearing; skipping is
fine.

### 021 — criomed-evaluates-lojixd-executes.md — KEEP

No load-bearing lojix-store claims. Mentions it only in
passing ("lojixd writes into lojix-store"). Safe.

### 022 — records-as-evaluation-prior-art.md — KEEP

Prior-art survey; no lojix-store backend claims. Safe.

### 026 — sema-is-code-as-logic.md — KEEP

Correct treatment of lojix-store (passing reference to "opaque
blobs" acceptable in the broader sema-vs-lojix-store split
discussion; the backend model isn't claimed). Safe.

### 027 — adversarial-review-of-026.md — KEEP

Red-team of 026. No lojix-store backend claims. Safe.

### 028 — doc-propagation-inventory.md — KEEP

Doc-hygiene inventory. Its findings about repo docs are still
accurate (and actioned this session). Safe.

### 029 — ra-chalk-polonius-structural-lessons.md — KEEP

Structural-lessons synthesis. No lojix-store specifics. Safe.

### 030 — lojix-transition-plan.md — KEEP

Transition plan correctly identifies lojixd as the eventual
owner of lojix-store. Terminology consistent. Safe.

### 031 — uncertainties-and-open-questions.md — KEEP

Session-close open-questions list. No lojix-store backend
claims. Safe.

---

## Consolidated action table

| Report | Verdict | Action |
|---|---|---|
| 013 | KEEP | — |
| 015 | **DELETE** | Done |
| 016 | KEEP | — |
| 017 | SHARPEN | §1 rewording; §3 reframe of kind-byte drop |
| 019 | SHARPEN | §2 wording; §4 daemon-table note |
| 020 | KEEP (optional micro-sharpen §2 phrasing) | — or trivial |
| 021 | KEEP | — |
| 022 | KEEP | — |
| 026 | KEEP | — |
| 027 | KEEP | — |
| 028 | KEEP | — |
| 029 | KEEP | — |
| 030 | KEEP | — |
| 031 | KEEP | — |

---

## Scope of remediation this session

- 023/024/025 already deleted (banner-marked wrong per earlier
  correction cycle; now covered by 026 + 033).
- 015 deleted (this audit).
- 017/019 sharpened (this audit's findings actioned).
- Sibling-repo doc fixes from earlier in the session
  (lojix/CLAUDE.md, nexusd/README.md, criome/CLAUDE.md,
  criome-store/CLAUDE.md, lojix-archive/CLAUDE.md) are
  revisited because some carried the "append-only + hash→offset
  index" / "blob DB" phrasing that this correction invalidates.

---

*End report 032.*
