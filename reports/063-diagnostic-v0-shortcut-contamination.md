# 063 — diagnostic: where the v0-shortcut contamination entered 062

*Claude Opus 4.7 · forensic trace requested by Li 2026-04-25
after report/062 proposed (a) collapsing nexusd/criomed/lojixd
into one process for v0 [Q1, S1], and (b) "hand-built records"
as a v0 prototyping path [Q2(c), Q4(a), parallel-tracks
bullet]. Both violate canonical invariants. This report
identifies the contaminations, traces their source, and names
the broader pattern. Per Li's instruction it does not propose
fixes — Li will direct eradication.*

---

## 1 · The canonical rules being violated

### 1.1 · Records enter sema via nexus only

> "**The invariant**: there is no `.rs → records` path. Anywhere.
> Ever. … Sema is populated by **nexus messages only**; those
> messages arrive at nexusd, are parsed to rkyv record trees,
> and are asserted by criomed."
> — [reports/051 §0](051-self-hosting-under-nexus-only.md)

> "**Every edit is a request.** criomed validates; requests can
> be rejected; this is the hallucination wall."
> — [docs/architecture.md §10](../docs/architecture.md)

Records do not enter sema by being hand-written as rkyv
literals in any daemon's source, baked into a binary, fabricated
in test fixtures, or constructed by any code path that bypasses
criomed. The single exception is the **strictly-limited seed**
in criomed's binary, scoped explicitly per
[reports/051 §Q2](051-self-hosting-under-nexus-only.md):

- schema-of-schema records (the kinds describing the kinds)
- KindDecl registry for kinds known at boot
- seed rules (currently empty)
- reserved slot range `[0, 1024)`

That same section makes the exclusion explicit:

> "Decision: seed includes (i) schema-of-schema, (ii) the
> KindDecl / record-kind registry for every kind the system
> recognises at boot, (iii) seed rules (presently empty), (iv)
> nothing else. **The Opus of the engine itself is authored by
> Li via nexus; it is *not* in the seed.**"

`Opus`, `OpusDep`, `Fn`, `Const`, and every other user-authored
record-kind enter sema only through the nexus → nexusd →
criome-msg → criomed → sema path. No exceptions, including
bootstrap, including testing, including v0 walking-skeletons.

### 1.2 · Multi-process + multi-repo + contract-crate boundaries are the architecture

The canonical corpus commits at every level to separate
processes communicating via rkyv contracts:

- [architecture.md §4](../docs/architecture.md) — three daemons (nexusd, criomed, lojixd)
- [reports/030](030-lojix-transition-plan.md) — lojix monolith → lojixd transition through Phases A-G; **never** collapses them
- [reports/061 §1.5](061-intent-pattern-and-open-questions.md) — "two stores, three daemons, one language" ratified
- Contract crates (`criome-msg`, `lojix-msg`) are first-class

Li 2026-04-25: *"no constraints imposed by the multi-repos and
contracts repos means bullshit implementation."* The boundaries
enforce the architecture; collapsing them lets agents produce
code that conforms to the wrong shape.

---

## 2 · The contaminations in 062

### 2.1 · Hand-built records (Li-flagged)

| Location in 062 | Violating text |
|---|---|
| §3 Parallel tracks bullet | *"Authoring seed `Opus` + `OpusDep` as rkyv literals in criomed source."* |
| §8 Q4 option (a) | *"bake one seed Opus as an rkyv literal in criomed source"* |
| §8 Q2 option (c) | *"prototype rsc emission on hand-built records"* |
| §3 Step 11 (implicit) | The smoke-test loop needs an Opus, and the parallel-tracks bullet was the implied source |

All violate §1.1. `Opus` and `OpusDep` are user-authored kinds,
not seed kinds.

### 2.2 · Single-process collapse (Li-flagged)

| Location in 062 | Violating text |
|---|---|
| §6 Stubbing S1 | *"Collapse nexusd, criomed, lojixd into one process at v0 with three modules. No UDS, no rkyv-on-the-wire."* |
| §8 Q1 | *"Single-process collapse for v0 walking skeleton? … B is ~3× cheaper and closes the loop faster."* |
| §9 Summary | *"five stubs for v0 collapse the work further"* |

Treats process boundaries as deferrable mechanism. They are not
mechanism — they are the architecture.

---

## 3 · Where the contaminations came from

### 3.1 · The hand-built-records hallucination

**Source.** The Plan subagent I launched for the walking-skeleton
critical-path research returned this directly:

> *"Authoring the seed `Opus` + `OpusDep` records as rkyv
> literals in criomed source so step 11 has a target to compile."*
>
> *"Q-γ. The walking skeleton needs some `Opus` to compile.
> Two options: (a) bake one seed `Opus` into criomed source as
> an rkyv literal; (b) require the first `Assert` to construct
> it via nexus before `Compile` is callable."*
>
> *"(c) prototype rsc emission on hand-built records"*

**Why the agent produced it.**
- Standard software-engineering patterns: "test fixtures" and
  "seed data" are common database/testing concepts.
- The phrase *"baked-in seed table"* in
  [reports/051 §Q2](051-self-hosting-under-nexus-only.md) and
  [reports/033 Part 4](033-record-catalogue-and-cascade-consolidated.md)
  was extrapolated from "seed schema is baked" to "any seed can
  be baked" — the agent did not register that the seed scope is
  explicitly limited and that `Opus` is in the *excluded* list.
- The bootstrap problem ("the walking skeleton needs *some*
  Opus") was framed as chicken-and-egg, with hand-baking as the
  apparent shortcut.

**Why I echoed it.** I did not check the proposal against the
canonical corpus before propagating it. I did not re-read
[reports/051 §Q2 Tensions](051-self-hosting-under-nexus-only.md)
where the seed scope is explicitly limited. The agent's options
framing made (a) sound like a reasonable engineering tradeoff
rather than a violation.

### 3.2 · The single-process-collapse hallucination

**Source.** Same agent, stub D1:

> *"Collapse nexusd, criomed, lojixd into one process at v0
> with three modules. No UDS, no rkyv-on-the-wire — just
> in-process function calls behind the criome-msg and lojix-msg
> types (so the contracts are real even though the transport
> isn't)."*

The agent argued: *"the contracts in criome-msg/lojix-msg are
the real architecture, the transport is mechanism."*

**Why the agent produced it.** "Monolith-first, microservices-
later" is a near-universal piece of software-engineering folk
wisdom. The agent treated this project's multi-process commitment
as a deferrable feature rather than as a load-bearing
architectural choice.

**Why this is wrong.**
1. Contracts are not enforced by type definitions alone — they
   are enforced by the act of serialising across a real
   boundary. Type-checking happens; protocol violation does not
   show up until bytes are on the wire.
2. Repo separation is a review boundary; in-process modules
   erase it.
3. Process separation is a fault and security boundary;
   in-process modules erase it.
4. Capability tokens ([architecture.md §4](../docs/architecture.md))
   are checked at process boundaries; in-process tokens are
   theatre.
5. [reports/030](030-lojix-transition-plan.md) preserves
   process separation throughout 7 phases. v0 does not get a
   different rule.

**Why I echoed it.** Same as 3.1. The agent's framing
(cheap-to-collapse, expensive-to-restart-from-real-daemons)
sounded plausible. I did not check it against the canonical
corpus.

### 3.3 · The prompt I wrote enabled both

The Plan subagent prompt I wrote for 062 included these lines:

> *"Can any daemon be stubbed (start with criomed in-process
> rather than a separate daemon with UDS, for instance)?"*
>
> *"Order of attack: lock nexus-schema contracts first, or
> scaffold daemon shells first, or **prototype rsc emission
> first**?"*

The first line gave the agent explicit permission to propose
process collapse. The second line implies hand-built records,
since rsc's input *is* records and there's no other way to
prototype its emission without supplying records. The agent took
both hints. **Both contaminations originated in the prompt I
wrote, not just in the agent's response.** The agent did exactly
what was asked.

---

## 4 · The systemic pattern: "v0 shortcut as constraint-collapse"

Both contaminations share a shape: *propose to defer an
architectural invariant for v0, then "un-stub" later.* The
other proposed v0 stubs in 062 §6 follow the same pattern:

| Stub | Constraint collapsed | Invariant in canonical corpus |
|---|---|---|
| S1 | Process boundaries | Three-daemon architecture ([architecture.md §4](../docs/architecture.md)) |
| S2 | RPATH + timestamp determinism | Content-addressing reproducibility ([reports/061 §1.2](061-intent-pattern-and-open-questions.md)) |
| S3 | Rules and cascades | Sema-is-evaluation ([reports/061 §1.1](061-intent-pattern-and-open-questions.md)) |
| S4 | Mutate + Subscribe verbs | Edit UX + cross-criomed interaction ([reports/061 §3.4](061-intent-pattern-and-open-questions.md)) |
| S5 | Capability tokens | Hallucination wall + BLS-quorum future ([architecture.md §10](../docs/architecture.md)) |

The same shape recurs in §8 questions:

- Q1 (= S1 as a question) — Li-flagged
- Q4 (Opus baked vs asserted — false dichotomy; only asserted is correct) — Li-flagged
- Q5 (in-memory sema vs redb — collapses durability)
- Q6 (rules at v0 — = S3)
- Q8 (skip Mutate + Subscribe — = S4)
- Q10 (skip capability tokens — = S5)

I have **not** confirmed that Li would reject all of these the
same way. Li explicitly flagged the two contaminations in §2.
The other six questions and four stubs share the same shape and
*may* all be wrong-shaped under Li's correction.

---

## 5 · What is now uncertain

After Li's two flags, I cannot confidently assert:

- That any of the five v0 stubs in 062 §6 are correct.
- That any of the §8 questions framed as "skip X at v0?" are
  well-formed.
- That the "walking skeleton" concept itself is correct in its
  062 form. A correct walking skeleton may need to be the FULL
  architecture from day 1 — three real daemons, real UDS, real
  contracts, real capability tokens, real rules, real durable
  sema — and what's "minimum" is only the smallest payload
  flowing through it (one Const record, asserted via nexus).
- That the bootstrap problem ("we need some Opus to compile")
  has the resolution I assumed. The correct resolution is in
  [reports/051](051-self-hosting-under-nexus-only.md): seed
  schema + kind-registry only, then user authors Opus via nexus
  before Compile is callable. The walking skeleton's first
  command is `(Assert (Opus …))`, not a hand-baked path.

The Q3 framing (Const → Fn sequenced) is probably fine — the
choice of first record-kind is orthogonal to whether the
architecture is honoured.

---

## 6 · For Li

Two flagged contaminations identified, sourced, and explained.
The pattern (v0-shortcut-as-constraint-collapse) appears to
extend to at least six more questions and four more stubs in
062. Awaiting direction on:

(a) Whether the pattern indeed extends to all the §4-listed
v0-shortcuts, or whether some are legitimate.

(b) How to eradicate this class of contamination going forward
— what guardrail (architecture.md §10 addition, agent-prompt
template, bd memory, structural rule about "no `v0 stub`
proposals") blocks "v0 collapses constraint X" framings before
they reach a report.

(c) What to do with 062 itself: leave as a teaching artifact,
delete per the "delete wrong reports" rule, or rewrite under
the corrected framing once (a) and (b) land.

This report does not propose those fixes per Li's instruction:
*"show you how to eradicate it."*

---

*End report 063.*
