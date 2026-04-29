# 111 — First mentci-ui: introspection workbench + basic interaction

*Research report. The first incarnation of mentci is an
introspection workbench that lets a human see into criome's
running state and edit the database directly through gestures.
Concentrates on **visuals**; code shapes belong in
skeleton-as-design once enough of the surface is settled. This
revision (2026-04-29 / v3) absorbs Li's answers to the prior
draft's deeper questions, applies elegance/correctness/beauty
reasoning to the ones the agent can answer, and keeps only the
genuinely-load-bearing questions for Li. The first mentci-ui
must move; it does not need every detail decided in advance.*

---

## 0 · Aim

The first mentci-ui exists for one reason: **let the human
shaping the engine see it clearly enough to participate in its
design**. Per [INTENTION](../INTENTION.md), introspection is
first-class — the surface is a peer of the engine, not a
downstream consumer.

Two intertwined goals: introspection and direct interaction.
Introspection without interaction is read-only; interaction
without introspection is an admin tool. The first mentci-ui
must do both at once.

---

## 1 · What is settled

The shape below is no longer open at these points:

- **Subscribe is foundational.** The first mentci-ui assumes
  Subscribe ships as part of getting the surface working; the
  canvas is live to pushed updates from the start. No poll.
- **mentci is a family.** One repo per GUI library
  (`mentci-egui`, `mentci-iced`, `mentci-flutter`, …); each
  consumes one shared `mentci-lib`. Non-Rust GUIs additionally
  consume a foreign-interface bridge.
- **mentci-lib is heavy; GUI shells are thin.** All
  sema-viewing and editing logic lives in mentci-lib —
  category selection, graph selection, selected views,
  comparison, action-flows, submissions, responses, themes,
  layout. Each GUI is a thin rendering shell that responds to
  mentci-lib's interfaces in its own library's idiom. The
  family converges on the same workbench logic; each member
  feels native because of how its shell renders.
- **Two surfaces, two audiences.** Agents (LLMs, scripts,
  automations) use nexus text against criome via the
  nexus-daemon. Humans use gestures via mentci. The GUI is
  human-only.
- **Daemons compose.** mentci connects to *both* daemons:
  criome (over signal, for editing / queries / subscriptions)
  and nexus-daemon (over signal, used purely as a signal↔nexus
  rendering service). Per the bright-line scope in
  nexus/ARCHITECTURE.md, nexus-daemon does only translation,
  in both directions, nothing else.
- **Connection shapes:** persistent for both daemons;
  nexus-down → error pane; criome-down → mentci is useless and
  refuses to operate.
- **Surfaces are dynamic.** Panes appear when there's something
  to show (Diagnostics) and disappear when not. Some panes are
  user-toggled (Wire) even when content exists.
- **No raw nexus typing.** Humans never author wire payloads by
  hand. Editing happens through schema-aware constructor
  flows. Nexus is a *display* format for reading typed
  payloads, not a typing surface.
- **First library: egui.** Linux + Mac first-class, Rust-native
  (no foreign bridge), strong fit for the canvas's specific
  needs; reasoning in §11. The first repo is `mentci-egui`.

---

## 2 · What must be visible

Categories of engine state the surface reveals:

- **Records.** Every record, by kind, with slot, current hash,
  display name, current revision.
- **The graph.** Flow-graph rendering when the selection is a
  Graph — Graph node, member Nodes, Edges with `RelationKind`
  visually encoded.
- **History.** The change log per slot.
- **Diagnostics.** Validation rejections as first-class events.
- **The wire.** Every signal frame, both directions, at
  typed-variant level.
- **Subscriptions.** What's subscribed, what's pushing.
- **Connection state.** For *both* daemons.
- **Cascades.** When a write triggers further changes,
  visible — not collapsed.
- **The surface itself.** Theme, layout, pane visibility — as
  records, edited the same way as everything else.

---

## 3 · The mentci-lib / GUI shell pattern

The library defines interfaces; the shell implements them.

```
                ┌──────────────────────────────────┐
                │           mentci-lib             │
                │                                  │
                │  CONTAINS ALL APPLICATION LOGIC: │
                │  • view-state machines           │
                │      (canvas, inspector,         │
                │       diagnostics, wire,         │
                │       graph nav, …)              │
                │  • action-flow state machines    │
                │      (drag-wire, drag-new-box,   │
                │       rename, retract, batch)    │
                │  • engine connection management  │
                │      (criome + nexus-daemon)     │
                │  • subscription + reply demux    │
                │  • schema knowledge              │
                │      (constructor flow options)  │
                │  • theme + layout interpretation │
                │      (records → semantic intent) │
                │                                  │
                │  EXPOSES (per pane / per flow):  │
                │  • current-view data             │
                │  • input-event sink              │
                │                                  │
                └────────────────┬─────────────────┘
                                 │
                                 │ thin contract
                                 │ (data out, events in)
                                 │
              ┌──────────────────┼──────────────────┐
              ▼                  ▼                  ▼
       ┌─────────────┐    ┌─────────────┐    ┌─────────────┐
       │ mentci-egui │    │ mentci-iced │    │mentci-flutter│
       │             │    │             │    │  + foreign  │
       │ paint widg. │    │ Elm-arch    │    │  interface  │
       │ in egui     │    │ in iced     │    │  bridge     │
       │             │    │             │    │             │
       │ THIN shell  │    │ THIN shell  │    │ THIN shell  │
       └─────────────┘    └─────────────┘    └─────────────┘
```

Each shell is "really thin": it renders the data mentci-lib
provides in the shell's native idiom and forwards user events
back. The family converges on identical workbench *logic*; each
member feels different because of *how* its native rendering
interprets the same logical shape.

The contract — what the data + events look like at the
boundary — is the load-bearing design question for mentci-lib.
Settled in §13.

---

## 4 · The workbench

Always-visible: Graphs nav, Canvas, Inspector. State-driven:
Diagnostics (when ≥1 unread). User-toggled: Wire. Header shows
both daemon connections explicitly.

```
┌────────────────────────────────────────────────────────────────┐
│ [● criome v0.1.0]  [● nexus v0.1.0]      [⊞ wire] [⌗ themes]   │
├──────────┬─────────────────────────────────────┬───────────────┤
│          │                                     │               │
│  GRAPHS  │             CANVAS                  │  INSPECTOR    │
│          │                                     │               │
│ ▸ Echo   │      ⊙ Source ──Flow──▶ ⊡ Transf    │   slot 1042   │
│   Pipe   │            ╲                │       │   ───────     │
│ ▸ Build  │             ╲              Flow     │   kind: Node  │
│   Defs   │              Flow            │      │   name: Echo  │
│ ▸ Authz  │                ╲             ▼      │   rev:  7     │
│ ▸ Theme  │                 ▼          ⊠ Sink   │   hash: 8a3f… │
│   Layout │              ⊠ Sink                 │               │
│   ...    │                                     │  HISTORY      │
│          │                                     │  ▼ rev 7  now │
│          │                                     │  ▼ rev 6  -3m │
│          │                                     │  ▼ rev 5  -8m │
│ + new G  │                                     │               │
│          │                                                     │
│          │     [pane appears below only when needed]           │
├──────────┴─────────────────────────────────────┴───────────────┤
│ ⚠ DIAGNOSTICS (2)                                       [clear]│
│ ✗ rev8 STALE_REV slot 1042 · ↳ jump                            │
│ ⚠ rev7 batch partial 2/3 · ↳ inspect                           │
│                                                                │
│ (this strip not shown when diagnostics list is empty)          │
└────────────────────────────────────────────────────────────────┘
```

When `[⊞ wire]` toggles on, a wire strip slides in between
canvas and diagnostics — same dynamics. `[⌗ themes]` opens the
theme/layout editing surface (same constructor-flow pattern as
any record edit).

---

## 5 · The flow-graph canvas

The centrepiece. When the selection is a Graph, the canvas
renders it with kinds, edges, and state visually encoded.

```
                    ╭───────────────╮
                    │               │
                    │   ⊙  Source   │
                    │    "ticks"    │
                    │               │
                    ╰───────┬───────╯
                            │
                          Flow
                            │
                            ▼
                    ╭───────────────╮
                    │               │
                    │   ⊡ Transf.   │
                    │    "double"   │
                    │               │
                    ╰─┬───────┬─────╯
                      │       │
                    Flow    Flow
                      │       │
                      ▼       ▼
              ╭──────────╮ ╭──────────╮
              │          │ │          │
              │ ⊠ Sink   │ │ ⊠ Sink   │
              │ "stdout" │ │ "log"    │
              │          │ │          │
              ╰──────────╯ ╰──────────╯
```

Visual encoding (interim — final palette deferred):

- **Glyph encodes kind.** ⊙ Source · ⊡ Transformer · ⊠ Sink ·
  ⊕ Junction · ▶ Supervisor.
- **Stroke style encodes RelationKind.** Closed-enum variants
  get consistent stroke styles; the encoding is part of
  mentci-lib's theme interpretation.
- **Colour reserved for state.** Pending optimistic edit, stale
  (subscription push pending), rejected (failed write). Kind
  is glyph; state is colour.
- **Labels.** Display name first; slot id on hover; hash never
  on canvas (lives in inspector).

The canvas is **always live**. Subscription pushes from criome
update mentci-lib's model; the GUI shell re-renders. Nodes
visibly transition through state colours.

**Node positions are records.** Layout is sema state — readable,
editable, shareable across mentci sessions. Moving a node is a
Mutate to its `position` field on a `NodePlacement` (or
similar) record. Two mentci sessions on the same criome see
the same layout. This follows from "the surface itself is
records" — layout is part of the surface.

---

## 6 · The inspector

Selected slot's complete state. Two stacked sections:

```
SLOT 1042                                              [▢ pin]
═══════════════════════════════════════════════════════════════
 kind:        Node
 name:        Echo
 rev:         7
 hash:        8a3f7c…
 last write:  17:23:14   (Mutate, by Li)
 referenced:  3 edges in · 1 edge out
───────────────────────────────────────────────────────────────
 [as nexus]   (Node "Echo")            ← rendered via nexus-daemon
───────────────────────────────────────────────────────────────

HISTORY (full log; scroll for older)
═══════════════════════════════════════════════════════════════

▼ rev 7  ·  17:23:14   ·  Mutate     ·  by Li
│   slot   1042
│   before Node { name: "Doubler", kind: Transformer }
│   after  Node { name: "Echo",    kind: Transformer }
│   hash   cd9e…  →  8a3f…

▼ rev 6  ·  17:20:02   ·  Assert     ·  by Li
│   created  Node { name: "Doubler", kind: Transformer }
│   hash    cd9e…
═══════════════════════════════════════════════════════════════
```

The "as nexus" line is rendered by sending the typed payload to
nexus-daemon and showing what comes back. mentci does not embed
nexus's parser/renderer; it consults the daemon.

Every history entry's arrow scrubs the canvas backward to that
point in time. History is first-class.

---

## 7 · Diagnostics surface

```
DIAGNOSTICS                                          [clear all]
════════════════════════════════════════════════════════════════

✗  17:23:14   STALE_REVISION
   Mutate { slot: 1042, expected_rev: 5, actual_rev: 7 }
   suggestion: refresh slot 1042 and retry
   ↳ jump to slot 1042

⚠  17:23:08   PARTIAL_BATCH
   AtomicBatch [3 ops]   2 ok, 1 SCHEMA_FAIL on op#2
     op#2:  Assert(Edge { from: 9999, to: 1042, kind: Flow })
            slot 9999 does not exist
   ↳ inspect batch · ↳ retry without op#2

✓  17:20:02   ok
   Assert(Node { name: "Doubler", kind: Transformer })
   ↳ slot 1042
```

Pane appears when list is non-empty; vanishes on clear. Failed
writes also overlay on the canvas at the affected node (red
border, cleared on next successful write to the slot) — at-site
shows *where*; pane shows *when* and *what suggestion*.

---

## 8 · Wire inspector

```
WIRE                                          [pause] [filter…]
═══════════════════════════════════════════════════════════════

→ 17:23:08.412  req#41  to criome
                Mutate(MutOp::Node { slot:1042, expected_rev:6,
                                     new:Node{…} })
                [as nexus]   ~(Node 1042 (Node "Echo" …))

← 17:23:08.418  req#41  from criome
                Outcome(Ok)
                [as nexus]   (Ok)

→ 17:23:09.001  req#42  to criome
                Query(QueryOp::Node(NodeQuery{…}))

← 17:23:09.004  req#42  from criome
                Records(Records::Node([…]))     [3 items]

⇣ 17:23:20.012  sub#3   from criome (push)
                Records(Records::Node([…]))     [1 item]

═══════════════════════════════════════════════════════════════
   →  request out      ←  reply in      ⇣  subscription push
```

User-toggled. The "as nexus" expansion uses nexus-daemon for
rendering — the same primitive the agent's nexus-cli uses. The
introspection surface re-uses the agent surface's text codec.

For now, the wire pane shows frames from *this connection only*.
Engine-wide observability ("see what every other agent is doing
through criome") is a deeper future capability that requires
criome to expose a wire-tap subscription; surfaced as a question
in §13.

---

## 9 · Schema-aware constructor flows

Every gesture opens a context-specific flow that knows the
schema for the verb being constructed and surfaces only valid
options.

```
DRAG-WIRE FLOW (drag from box A to box B)
═══════════════════════════════════════════════════════════════

  ⊙ Source ╌╌╌╌╌╌╌╌╌╌╌▶ ⊡ Transf.            (pending preview)
                                              wire shown dashed

  ┌──────────────────────────────────────────┐
  │  NEW EDGE                                │
  │                                          │
  │  from:        slot 1043 ("ticks")        │
  │  to:          slot 1042 ("double")       │
  │  kind:        ┌─ select ────────────────┐│
  │               │ ▸ Flow                  ││
  │               │   DependsOn             ││
  │               │   Contains              ││
  │               │   References            ││
  │               │   Produces              ││
  │               │   Consumes              ││
  │               │   Calls                 ││
  │               │   Implements            ││
  │               │   IsA                   ││
  │               └─────────────────────────┘│
  │  description: [_________________________]│
  │                                          │
  │              [cancel]  [commit]          │
  └──────────────────────────────────────────┘

   ↑                                       ↑
   schema knowledge from mentci-lib        commit sends
                                           Assert(Edge {…})
```

Constructor-flow principles:

- **Pre-show but uncommitted.** The wire appears visually as
  soon as the drag completes (dashed, pending colour). Nothing
  leaves the wire until the user clicks commit. The pending
  preview is *intent*, not state.
- **Schema knowledge in mentci-lib.** When mentci-lib knows
  Edge has a `kind: RelationKind` field, the flow surfaces the
  variants. Adding a variant in `signal/flow.rs` reaches every
  family member through mentci-lib.
- **Validity narrows the choices.** When some
  source-kind/target-kind/RelationKind combinations are
  meaningless, the flow shows only the valid ones. The
  invariants live with the types in signal — adding them is a
  signal evolution, not a per-GUI concern.
- **Commit-at-flow-end.** No optimistic UI. The canvas reflects
  criome's accept; rejection vanishes the pending wire and
  surfaces a diagnostic.
- **Equivalence with the agent path.** Whatever an agent could
  send via nexus, a human can build via gestures; the two
  paths converge at the same signal verb.

Each verb gets its own flow shape (drag-new-box, rename,
mutate-field, batch-edit) — all defined in mentci-lib, rendered
per-shell.

---

## 10 · Connection topology — two daemons

```
                           ┌──────────────┐
                           │   mentci-*   │
                           │     GUI      │
                           └──────┬───────┘
                                  │ uses
                                  ▼
                           ┌──────────────┐
                           │  mentci-lib  │
                           │ owns BOTH    │
                           │ connections  │
                           └──┬────────┬──┘
                              │        │
                signal        │        │  signal
              (edits,         │        │  (signal↔nexus
               queries,       │        │   translation only —
               subscribe)     │        │   nexus-daemon's only
                              │        │   responsibility)
                              ▼        ▼
                       ┌──────────┐ ┌──────────────┐
                       │  criome  │ │ nexus-daemon │
                       └──────────┘ └──────────────┘

  Both connections are persistent (one per mentci session).
  The header status bar shows both states explicitly.

  Failure modes:
   • nexus down, criome up   → error pane appears explaining
                               why; "[as nexus]" lines hide;
                               raw typed-payload labels remain
                               functional (degraded but
                               operable).
   • criome down             → mentci is useless without it.
                               The surface refuses to operate
                               (no editing, no queries, no
                               canvas updates). Reconnect
                               required before further work.
   • both down               → same as criome down.
```

mentci-lib owns both connections. The GUI shell sees a unified
"engine" surface; the dual-daemon split is hidden from widget
code (and revealed in the header for the introspecting human).

This composition means **nexus-daemon is consulted as a
rendering service**, not embedded as code. The same daemon the
agent's nexus-cli connects to is the daemon mentci's display
layer consults. One translation primitive, two consumers.

---

## 11 · GUI library — first incarnation is mentci-egui

Linux + Mac first-class. Survey:

| Library | Lang | Linux | Mac | Custom canvas | Live updates fit | Graph-editor maturity |
|---|---|---|---|---|---|---|
| **egui** | Rust | ● | ● | ● strong | ● immediate-mode | ● strong (`egui_node_graph`, Rerun) |
| iced | Rust | ● | ● | ◐ | ◐ Elm-arch | ◐ |
| gpui | Rust | ◐ | ● | ● | ● | ◐ |
| slint | Rust | ● | ● | ◐ | ● | ✗ |
| dioxus desktop | Rust | ● | ● | ◐ | ● | ✗ |
| Flutter | Dart | ● | ● | ● | ● | ◐ + foreign-interface tax |
| Qt + cxx-qt | C++/Rust | ● | ● | ● | ● | ● heavy |
| Tauri | Web/Rust | ● | ● | ● | ● | ◐ JS-side complexity |

**Recommendation: egui.** Cited principles:

- **Clarity** — egui's immediate-mode shape (re-render from
  current state) reads cleanly in code that has to redraw on
  every subscription push. The model matches the surface's
  logical shape.
- **Introspection** — egui's debug overlays and inspection
  mode are themselves introspectable from the running app —
  the surface is inspectable at the GUI-toolkit level too.
- **Strong fit for the canvas's specific needs.**
  `egui_node_graph` exists; Rerun is the closest existing
  introspection-workbench precedent and is built on egui.
- **No foreign-interface bridge needed.** mentci-lib consumed
  directly.
- **Both platforms first-class without ceremony.**

What egui gives up: native-widget feel and a declarative
model. Both are recoverable in later mentci-* family members
(`mentci-iced` for Elm-arch, `mentci-flutter` for native
polish).

The first repo is **`mentci-egui`**. Other family members
follow naturally as mentci-lib's contract is exercised.

---

## 12 · What this asks of the engine

Introspection and the dual-daemon composition shape the engine.

- **Subscribe ships as part of this milestone.** The canvas's
  always-live property assumes Subscribe; without it, the
  surface cannot uphold push-not-pull. The engine work for
  Subscribe is in scope here.
- **State must be representable, not just queryable.** Every
  record kind needs a canonical visual rendering.
- **Diagnostics carry structured suggestions.** The pane
  displays `suggestion` directly; criome populates it with
  actionable structured data, not strings.
- **Wire frames are inspectable typed payloads end-to-end.**
- **Subscriptions push whole records.** Diff reconstruction is
  fragile; full records on push.
- **Cascades are observable.** When write A triggers
  derivation B, both are visible.
- **Time is queryable.** History scrubber implies point-in-time
  reads against sema's bitemporal index.
- **Nexus rendering is a daemon-served service.** The
  nexus-daemon's bright-line scope (signal↔nexus translation
  only) makes it usable by the agent surface and by mentci's
  display layer in exactly the same way.
- **Visual configuration as records is welcome.** Theme,
  Layout, NodePlacement, KeybindMap as candidate record kinds.
  Many small kinds (one per concern), per the engine's
  existing pattern.
- **The agent themselves is eventually a record.** A
  `Principal` record kind makes "who is acting" introspectable
  and connects to the authz model. Implicit principal is the
  starting point; explicit Principal records land when the
  authz model lands.

The deepest ask: **nothing the engine does is hidden from the
human shaping it.** The surface is itself part of the engine's
introspectable state.

---

## 13 · Still open

The dance of design/implement/review needs only a small set of
things settled before the first mentci-egui can take shape.
Most other questions — pane micro-behaviours, theme
specifics, layout details, multi-graph navigation paradigms —
will answer themselves once the surface exists and the second
review cycle begins. Below are the questions whose answers
genuinely block, or would meaningfully shape what we build.

### Q-A · The mentci-lib contract shape

mentci-lib defines the interfaces the GUI shells implement.
What *kind* of contract?

- **Trait-based view contracts.** mentci-lib exposes traits
  per pane (`CanvasView`, `InspectorView`, `DiagnosticsList`,
  `WireStream`, …). Each trait provides current data + accepts
  user events. The shell `impl`s rendering for each trait. Most
  Rust-native; awkward for Flutter via foreign-interface.
- **Data-and-events (MVU-shaped).** mentci-lib produces a
  `WorkbenchView` data structure each frame; the shell renders
  it. The shell pushes `UserEvent`s back. Maps cleanly to
  immediate-mode (egui) and Elm-architecture (iced) and
  declarative (Flutter); slightly more allocation per frame
  for the snapshot.
- **Async-channel + queries.** mentci-lib runs as actors; the
  shell holds channel handles for each pane (subscribe to
  changes; send events). Fits ractor style; harder for foreign
  interfaces.

The choice constrains both the family's portability and the
shape of mentci-lib's internals. Recommendation by clarity +
correctness: data-and-events (MVU). It matches subscription
semantics, ports to any GUI library, and keeps mentci-lib's
internal evolution decoupled from GUI shell evolution. But Li
has not stated a preference, and this is the first thing the
work will have to commit to.

### Q-B · Subscribe payload shape

For the canvas to be live, criome must push something on each
relevant change. What does the push contain?

- **The full updated record.** Simple; trivially correct;
  bandwidth grows with record size.
- **The slot + new content hash.** Tiny; mentci-lib re-fetches.
  But re-fetching is an additional round-trip per push, which
  smells like polling-with-extra-steps.
- **The full record + the diff against the prior revision.**
  Diff for incremental UI work; full record as ground truth.
  More to design.

Recommendation by elegance + push-not-pull: **full updated
record**. Re-fetch on push is a poll-shaped pattern; diff-only
is fragile when mentci-lib doesn't have the prior version
cached. The simplest correct shape is "what changed, in full."
But this is criome's design, not mentci's, and Li is the right
person to settle it.

### Q-C · Schema-as-records vs compile-time codegen

mentci-lib's constructor flows surface the right fields per
verb. The schema knowledge can come from:

- **Compile-time codegen from signal Rust types.** mentci-lib
  reads the signal types at build time, generates the
  constructor-flow descriptions. The schema is in code.
- **Runtime schema records.** Sema holds records describing
  every record kind ("a Node has fields name, kind"; "a Edge
  has fields from, to, kind"; "RelationKind has variants Flow,
  DependsOn, …"). mentci-lib reads them at startup. The
  schema is itself sema state.

The runtime path is recursively introspectable — the schema is
a record like everything else, edited the same way, visible in
the wire pane. That's the deeper-introspection answer. The
compile-time path is simpler today and matches signal's
existing closed-enum pattern.

This is one of the deepest engine questions in the report. Li
should weigh in: does the schema itself live in sema, or in
binaries?

### Q-D · Engine-wide wire-tap

The wire pane shows frames *from this connection*. An
engine-wide wire-tap subscription — "see every signal frame
across every connected client" — would let the human see all
agent activity, not just their own. This is a deeper
introspection capability that requires criome to expose a
wire-tap subscription verb.

This isn't blocking the first mentci-egui. But Li should
decide whether to *plan* for it now (so the wire pane's UI
shape leaves room) or treat it as a later, separate
introspection feature. The report's current shape assumes
this-connection-only.

### Q-E · Identity / Principal kind

Themes, layouts, node-positions are personal — different
agents want different ones. To represent that properly, sema
needs a `Principal` record kind (who is acting; whose
preferences these are). This connects to the authz model's
principal references in capability tokens.

The first mentci-egui can stub this — single user, single
machine, implicit principal. But a Principal kind is implied
by everything else in the report and will land sooner rather
than later. Li should decide whether the first mentci-egui
ships with implicit principal or with a Principal kind from
the start.

### Q-F · Theme/layout record kinds — granularity now

Granularity follows the existing one-kind-per-concept pattern:
candidate kinds include `Theme`, `Layout`, `NodePlacement`,
`PaneVisibility`, `KeybindMap`. The agent's recommendation is
many small kinds. But the *exact set* — which ones land in
signal alongside Graph/Node/Edge as part of getting the first
mentci-egui working — is Li's call. (This question is not a
blocker; mentci-lib can ship with built-in defaults until the
records exist. But the work to add the kinds wants a target
list.)

---

### What else is *not* on this list (and why)

The following the agent has now answered for itself by
reasoning from elegance / correctness / beauty. They are
no longer open; they appear in the body of this report as
settled.

- mentci-lib heavy / GUI shell thin (Li answered)
- nexus connection persistent (Li answered)
- nexus down → error pane (Li answered)
- criome down → mentci frozen (Li answered)
- nexus-daemon's role bright-line clear (Li, and now also in
  nexus/ARCHITECTURE.md)
- Family members converge on the same workbench logic; each
  feels native via its shell (follows from Li's answer to Q1)
- Constructor-flow centralisation in mentci-lib (follows from
  Li's answer to Q1)
- Validity rules narrow constructor-flow choices (follows from
  perfect-specificity invariant)
- Theme/layout intent vs appearance: **intent**. Semantic
  ("selected", "stale") is portable; appearance (RGB values)
  couples themes to renderers. Intent is more meaningful and
  more introspectable.
- First-run bootstrap: built-in defaults in mentci-lib until
  the user's first theme/layout assertion replaces them.
- Per-user themes: yes; depends on identity (Q-E).
- Cross-connection visibility: yes; surface "another
  connection edited X" as a visible event when Subscribe
  catches it.
- Pending-flow conflict: surface and re-confirm
  (accept-and-reflect).
- Node positions as records: yes (recursive consistency with
  layout-as-records).
- Large-graph degradation: pan/zoom + mini-map first;
  level-of-detail and filtering follow when scale demands.
- Nested Graphs (`Graph` Contains `Graph`): inline-with-
  collapse default; drill-in available on demand.
- mentci-egui as a Graph itself (self-host): eventually yes;
  the architecture should not preclude it but the first
  mentci-egui need not be a Graph.
- Multi-graph navigation: try several paradigms over time
  (Li answered).

---

## 14 · Not in scope

- **Visual aesthetics.** Final palette, iconography, type
  choices. Obvious choices for now; rich palette comes later
  (possibly via theme records).
- **mentci-lib's API surface in code.** Skeleton-as-design
  belongs in mentci-lib's own ARCHITECTURE.md; this report
  describes what the API must enable, not its types.
- **Mobile / alt form factors.** Desktop first.
- **The eventual universal-UI scope.** This is the
  introspection workbench that begins earning the wider
  scope.

---

## 15 · Lifetime

This report lives until the first mentci-egui shows records
on the canvas, accepts a constructor-flow gesture, and
displays a diagnostic served by criome. By then most of §13
will have answered itself through implementation; what
remains can move into the docs of the components that house
it (mentci-lib's ARCH for the contract; signal's evolution
notes for new record kinds; criome's ARCH for engine-side
asks).

The dance — design / implement / review — produces answers
that no amount of pre-design produces. This report's purpose
is not to settle every question; it is to settle enough that
the work can begin.

---

*End report 111.*
