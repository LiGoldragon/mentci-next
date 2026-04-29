# INTENTION

*Li's intention document for the sema-ecosystem. Upstream of
`ARCHITECTURE.md` and `AGENTS.md`. Where those documents say **what**
the system is and **how** to work on it, this document says **why** —
and what is being optimised for at the deepest level.*

> Read this before any other doc. Every other doc is downstream of
> these intentions; if a downstream doc conflicts with this one, this
> one wins and the downstream doc is wrong.

---

## What we are building

A typed, content-addressed, validated substrate for **everything**
that today lives in fragmented untyped software:

- **criome** is the engine that owns and serves the typed substrate.
  It validates every change; it never hallucinates; it is the
  hallucination wall against which untyped text input breaks.
- **sema** is the substrate itself — the canonical, evaluated,
  content-addressed records that are the meaning of every concept the
  engine reasons about.
- **mentci** is meant to become the universal interaction surface for
  working with sema — eventually replacing today's stack of fragmented
  application UIs with one introspectable, typed surface that scales
  from "edit a record" to "operate the world's data."

Scope is **world-supersession**, not personal-scale. CriomOS + criome
aim to supersede proprietary operating systems and computing stacks
globally; mentci is intended to become the universal UI replacing
today's fragmented software interfaces. Framings like "personal-
scale," "craftsperson workshop," "self-hosted-self," "MVP," and
"shipping fast" underestimate the project and corrupt design choices
that should be made at the right scale.

---

## What we value, and what we explicitly do not

### Good design over production speed

> *"I am much more interested in a good design than in producing it
> quickly — criome and sema are meant to be eventually impossible to
> improve, so I value clarity, correctness, and introspection above
> production volume, speed, and time to market."*
>
> — Li, 2026-04-29

We hold these in priority order. When two of them conflict, the
earlier one wins:

1. **Clarity** — the design reads cleanly to a careful reader. The
   structure of the system is the documentation of itself.
2. **Correctness** — every typed boundary names exactly what flows
   through it; nothing accidental survives the type system.
3. **Introspection** — the engine reveals itself to the agents
   (humans and LLMs) that participate in its development. The UI is
   not a layer atop the engine; it is part of how the engine is
   *understood*, which is part of how it is *built*.
4. **Beauty** — beauty in the operative sense: not pretty, but
   right. Ugliness is evidence the underlying problem is unsolved.
   See [tools-documentation/programming/beauty.md](https://github.com/LiGoldragon/tools-documentation/blob/main/programming/beauty.md).

### What we do not optimise for

- **Implementation speed.** Agents must not frame work in terms of
  "weeks" or "months" or "time-to-implement" or "shipping
  velocity." Time-to-market thinking distorts which trade-offs look
  acceptable. Rejected.
- **Feature volume.** The number of features shipped per quarter is
  not a signal we care about and not a target we set.
- **MVP framings.** "Minimum viable" means "least we can get away
  with"; we are not optimising for the least, we are optimising for
  the right shape. Rejected as a framing for *design* — the word may
  appear when describing milestones in execution but it does not
  shape the design.
- **Backwards compatibility.** Until Li declares a compatibility
  boundary, nothing is owed to past versions. Rename, move,
  restructure, delete freely; the engine is being born, not
  maintained.
- **"Time to first useful result."** The right shape now is worth
  more than a wrong shape sooner. A working but malformed pipeline
  is worse than no pipeline; the malformed one will need to be
  un-built before the right shape can land, and unbuilding is
  expensive in a way no agent can predict ahead of time.

The deep claim: criome and sema are meant to be **eventually
impossible to improve**. That goal is reachable only if every step
toward it is taken with the long view. Steps taken with the short
view rule out the long view.

---

## How agents participate

### Introspection is first-class

Agents (humans and LLMs) cannot improve what they cannot see.
**criome's state must be renderable into mentci's UI**, not just
queryable as records. The UI surface is the *primary* tool for
agent participation in the engine's development — not a downstream
consumer of the engine, but a peer to it.

Practical consequence: rendering criome into mentci-UI is not a
post-MVP concern, it is *part of how the engine is designed*.
Agents looking at the engine via UI should be able to inspect every
record, every cascade, every subscription, every diagnostic — and
the design pressure that puts on the engine (introspectable state
shapes; no hidden derived data) is *welcome*. It produces a better
engine.

### Agents do not estimate

Agents working on the sema-ecosystem do not produce time estimates,
implementation-cost numbers, "weeks to ship," or scope-by-cost
trade-off tables. These corrupt design choices. The work is
described by *what it requires*, not by *how long it will take*.

When an agent is tempted to say "this would take N weeks" or "this
is too expensive for MVP," the agent should instead say: "this is
the work; here is what it requires."

### Agents propose; Li decides

Design questions surface in reports (in `mentci/reports/`), and Li
answers them. Agents do not pre-decide based on cost; agents
enumerate the design surface honestly and let Li pick the shape.

When an agent has a recommendation, the agent states the
recommendation **and the principle that motivates it** — not the
expedient that motivates it.

---

## Foundational invariants

These are the rules every component, every report, and every
decision must respect. Each has been earned by Li's correction of
an earlier wrong frame.

### On the engine

- **Sema is all we are concerned with.** Everything else exists to
  serve sema.
- **criome runs nothing.** criome receives, validates, persists to
  sema, communicates. It does not spawn subprocesses, write files
  outside sema, invoke external tools, or link code-emission
  libraries. Effect-bearing work lives in dedicated components.
- **The flow-graph IS the program.** A `Graph` record holding
  `Node` records linked by `Edge` records is the canonical
  representation of any computation. There is no separate
  "compilation unit" or "module" concept above the graph; the graph
  *is* the unit.
- **Signal is the messaging system.** Every wire in the
  sema-ecosystem is signal-shaped. Layered protocols
  (signal-forge, signal-arca) re-use signal's envelope/handshake/
  auth and add audience-scoped verbs.
- **Push, never pull.** Producers expose subscriptions; consumers
  subscribe. No polling fallback ever. Real-time consumers defer
  their real-time feature until subscribe ships rather than poll
  while waiting.
- **Sema is local; reality is subjective.** No global sema, no
  federated database, no single logical truth. Each criome holds a
  subjective view; instances communicate, agree, disagree, and
  negotiate to reach agreement.
- **Categories are intrinsic.** Code records and world-fact records
  cannot share a category — the separation is a fact of reality,
  not a schema choice.

### On the codebase

- **Beauty is the criterion.** If it isn't beautiful, it isn't
  done. Ugly code is evidence the underlying problem is unsolved.
- **Every reusable verb belongs to a noun.** Free functions are
  verbs without owners. Find the owner; if no owner exists, the
  model is incomplete.
- **Perfect specificity at every typed boundary.** No wrapper enums
  that mix concerns; no string-tagged dynamic dispatch; no generic-
  record fallback.
- **One capability, one crate, one repo.** Adding a feature
  defaults to a *new* crate, not editing an existing one. The
  burden of proof is on the contributor who wants to grow a crate.
- **Skeleton-as-design.** New design starts as compiled types +
  trait signatures + `todo!()`. rustc checks consistency; prose
  cannot drift.
- **All-rkyv except nexus text.** Pinned feature set
  workspace-wide (rkyv 0.8, std + bytecheck + little_endian +
  pointer_width_32 + unaligned).
- **Content-addressing is non-negotiable.** Record identity is the
  blake3 of canonical rkyv encoding.

### On process

- **Update canonical docs first, code second, reports third.** The
  golden documents (criome/ARCHITECTURE.md, this file) are the
  source of truth. Code follows. Reports record the journey only
  when the journey is worth carrying forward.
- **Don't negate the past architecture; remove it from existence.**
  Stating "we used to do X but now we do Y" leaves agents to
  rediscover X. State only Y.
- **Don't restate-to-refute.** Wrong framings live once, in
  criome/ARCHITECTURE.md §10 "Rejected framings." Reports do not
  re-introduce rejected frames in order to refute them.
- **Delete wrong reports; don't banner.** Banners invite agents to
  relitigate. The rollover discipline lives in `mentci/AGENTS.md`.
- **No ETAs.** Describe the work; do not schedule it.

### On agent participation

- **Render criome into mentci-UI.** Introspectability is part of
  the design, not a downstream concern. Decisions that compromise
  introspectability are rejected even when they would otherwise
  improve performance or simplicity.
- **Agents do not estimate.** No "weeks," no "months," no
  "implementation cost," no "this would be too expensive."
- **Agents do not pre-decide on cost.** Agents enumerate the design
  surface honestly. Li decides.
- **Agents recommend by principle, not by expedient.** When an
  agent recommends an option, the recommendation cites the
  invariant or value that motivates it.

---

## What rejection looks like

A list of framings that are wrong and will be rejected. When an
agent generates one of these, the agent should recognise it and
back out. New rejections live in
[criome/ARCHITECTURE.md §10.1](https://github.com/LiGoldragon/criome/blob/main/ARCHITECTURE.md);
this section names the *categories* of mistake the rejections share.

- **Time-to-market thinking.** "MVP," "ship fast," "minimum
  viable," "we can iterate later." Rejected.
- **Cost-first design.** "This option is cheaper, so we should
  pick it." The cost of producing a wrong shape exceeds any
  short-term saving. Rejected.
- **Personal-scale framings.** "Self-hosted-self," "craftsperson
  workshop," "single-user tool." Rejected. The scope is global.
- **Federation / global-database framings.** Sema is local;
  reality is subjective. Rejected.
- **Backwards-compatibility-by-default.** Rejected until Li
  declares a compat boundary.
- **Bannered-deprecated framings.** "We used to think X but now we
  think Y." Rejected. State Y.
- **Aski-as-input.** Aski is retired and not a design source.
  Rejected.
- **Bit-for-bit identity at self-hosting close.** Rejected; new
  rustc versions aren't byte-identical to predecessors either.

---

## Lifetime of this document

This document is **upstream** of `criome/ARCHITECTURE.md` and
`mentci/AGENTS.md`. It changes only when the deep intentions
change — which is rare. When it does change:

1. Li edits this file.
2. Li (or an agent acting under Li's instructions) propagates the
   consequences into `criome/ARCHITECTURE.md` (engine-level rules),
   `mentci/AGENTS.md` (process-level rules), and per-repo
   `ARCHITECTURE.md` files (component-level rules).
3. Existing reports inconsistent with the change are deleted, not
   bannered.

This document does not depend on any other; everything else
depends on it.

---

*End INTENTION.md.*
