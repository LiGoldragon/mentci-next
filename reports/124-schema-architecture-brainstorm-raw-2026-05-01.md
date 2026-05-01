# 124 — Schema architecture brainstorm (raw, undecided)

*Raw notes from the architectural session 2026-04-30 → 2026-05-01,
captured before things got polished. Decisions are NOT made;
this is the live exploration. Lifetime: until the localization-
store ownership lands, then fold into [reports/122](122-schema-bootstrap-architecture-2026-04-30.md)
or the relevant ARCHITECTURE.md and delete.*

---

## 0 · The originating question

Nexus turns signal records into text. Mentci-egui will turn
signal records into pixels containing text (widgets carry
labels, dropdowns carry variant names, slot pickers carry the
target's display name). Both share the work of projecting
structured records into something humans read.

Where's the duplication; where isn't it; and is there a deeper
unification?

---

## 1 · The path the brainstorm walked

Stages, in order. Each one corrected something in the prior.

- *Three-shapes proposal* (single-derive / shared-Shape / reflective-codec).
  Missed the point.
- **Both are text-projectors of signal.** Nexus produces flat text;
  mentci-egui produces text wrapped in spatial+interactive widgets.
  The text content overwhelmingly overlaps. The walking-of-record-
  structure is the same; the rendering differs.
- **Mentci-egui isn't a codec.** Codecs are symmetric (parse =
  inverse of render, round-trip property holds). Mentci-egui is
  *renderer + editor*: records → pixels (one-way), gestures →
  Mutate verbs (the other way, through user intent, not via
  parsing pixels).
- **The shape walk is broader than codec.** Codecs use it
  (symmetric); renderers use it (one-way); editors use it (route
  gestures back to fields); validators use it (type-check
  incoming records). Many consumers, one structural-walk pattern.
- **Two descriptions per kind.** Numerical (structural; fields,
  types, slot relations; language-agnostic) and linguistic
  (per-language display names; project-specific). Sema sees only
  numerical refs. Strings live in a separate localization store.
- **The inversion.** Declaring types as Rust source creates
  tension because Rust source isn't the right home for "what
  numerical id does this kind have" or "what's the localization."
  Capnp resolves via `.capnp` files. **Our resolution: the engine
  itself is the type-declaration system.** Records describe kinds;
  prism projects records to Rust source; rustc compiles; new
  binary reads the same sema. Same dog-fooding loop as criome
  (records → prism → Rust → binary), applied to schema.
- **The slot-id problem.** Author writes records in text. Records
  cross-reference each other by Slot. Slots are assigned by
  criome on Assert. How does the author write
  `(Field $K_Node 0 $T_VecGraph)` if slot ids aren't known yet?
- **Per-kind slot indexes + ordered bootstrap.** Each kind has its
  own slot counter from 0. The bootstrap is processed top-to-
  bottom; the Nth assertion of kind K gets slot N in K's index.
  Author predicts slots by counting their declarations. Self-
  reference and mutual recursion fall out for free.
- **Bootstrap from where, exactly?** Nexus files seeding sema is
  rejected (nexus is messages, not storage). The boot path
  hand-codes the bootstrap kinds in criome's init, programmatically
  constructing records before opening the UDS listener.

---

## 2 · The shape today (best current articulation)

Stated for orientation; this lives positively in
[reports/122](122-schema-bootstrap-architecture-2026-04-30.md) and
in criome's `ARCHITECTURE.md` §10.1–§10.3.

```
   ┌────────────────────────────────────────────────────────────────┐
   │                                                                │
   │   bootstrap (hand-written Rust in signal/)                     │
   │   Kind, Field, Variant, TypeExpression, KindShape,             │
   │   Primitive, Localization, Language, Slot<T>                   │
   │                          │                                     │
   │                          ▼                                     │
   │   criome's init constructs bootstrap records;                  │
   │   per-kind slot counters start at 0;                           │
   │   UDS listener opens                                           │
   │                          │                                     │
   │                          ▼                                     │
   │   front-end clients (mentci-egui, agents, scripts)             │
   │   send signal Assert frames;                                   │
   │   domain kinds (Node, Edge, Graph, Principal, …) enter         │
   │                          │                                     │
   │                          ▼                                     │
   │   prism reads schema records from sema, emits Rust source      │
   │   for every domain kind                                        │
   │                          │                                     │
   │                          ▼                                     │
   │   rustc compiles new binary                                    │
   │                          │                                     │
   │                          ▼                                     │
   │   new binary reads same sema; vocabulary closes the loop       │
   │                                                                │
   └────────────────────────────────────────────────────────────────┘
```

A separate **localization store** (owner shape open) holds per-
language Localization records mapping slot ids → display strings.
Nexus and mentci-egui consult it for text rendering and label
generation.

---

## 3 · The live open question

**Who owns the localization store?**

Constraints:
- Sema is string-free at the schema layer (Li 2026-05-01).
- Nexus is messages, not storage (Li 2026-05-01).
- Compile-time baking is wrong; localization is data (Li 2026-05-01).
- "Option 1" was the chosen direction (separate database), but
  not owned by nexus.

Candidates (none decided):
- **A separate criome-engine instance** scoped to localization.
  Same record-engine machinery (validator, signal Frames, redb).
  Most uniform; heaviest. Bootstrap problem mirrors criome's.
- **A dedicated `localization-daemon`** speaking signal Frames
  over its own UDS. Lighter than full criome instance; still
  uses signal protocol. New daemon to operate.
- **A library linked into nexus and mentci-egui.** The library
  owns the localization records (probably in its own redb file).
  No daemon; cross-process consistency is the consumer's
  problem.
- **Something else** — option 4 hasn't surfaced.

This blocks:
- Mentci-egui label rendering (everything localized).
- Nexus text rendering in the user's chosen language.
- Schema authoring tools — adding a new Kind also needs to
  author its localization.

---

## 4 · Sub-shapes also open

- **`Kind` shape.** Single record with optional `fields` /
  `variants` (matches "struct with optional fields covering every
  case" phrasing literally), vs split into `StructKind` and
  `EnumKind` (type-system enforces the invariant).
- **`TypeExpression` shape.** Single record with optional
  `primitive` / `kind_reference` / `constructor + arguments`,
  vs split per case.
- **`Localization.target` typing.** `Slot<AnyKind>` (type-
  erased, criome validates target kind at write time) vs typed
  enum `Target = TargetKind | TargetField | TargetVariant`.
- **Bootstrap mechanism details.** Hand-written constructors in
  criome's init, OR prism reads a canonical declaration once at
  build time and emits a static Records array criome init asserts.
  Both keep the "no nexus files seed sema" constraint.

---

## 5 · Bd issues tied to this thread

After the 2026-05-01 audit:

**Live, P1:**
- `mentci-next-m5m` — Add Kind + Field + Variant + TypeExpression
  + KindShape + Localization record kinds to signal.
- `mentci-next-4v6` — signal-derive direction post rejected-frames.
  Crate's role open: keep / repurpose / retire.
- `mentci-next-wd3` — process-manager crate.
- `mentci-next-ef3` — Self-hosting "done" moment — concrete first
  feature.

**Live, P2 (downstream):**
- `mentci-next-149` — mentci-lib CompiledSchema queries sema for
  schema records.
- `mentci-next-7tv` — per-kind sema tables (replaces 1-byte
  discriminator). **Infrastructure dependency for the per-kind
  slot indexes.**
- `mentci-next-7dj` — Cross-repo wiring (flake input pattern).
- `mentci-next-0tj` — Implement prism records-to-Rust projection.
- `mentci-next-zv3` — M6 bootstrap demonstration.
- `mentci-next-4jd`, `mentci-next-8ba` — milestone plumbing.

The localization-store ownership decision unblocks new bd work
on label rendering, the schema authoring UI, and language
switching. None of those are issues yet; create when the owner
shape lands.

---

## 6 · What this report deliberately is not

- Not a finished architecture. Decisions in §3 and §4 are open.
- Not a restate-to-refute. The journey notes in §1 are
  orientation for picking up the thread, not enumerations of
  wrong frames; the rejected patterns live silently dropped from
  the canonical docs (criome's `ARCHITECTURE.md`, lore's
  `AGENTS.md`).
- Not a successor to [reports/122](122-schema-bootstrap-architecture-2026-04-30.md).
  122 is the polished form of what's *currently* believed; this
  doc is the live exploration alongside it. When the open
  questions land, this report folds away.

---

*End report 124.*
