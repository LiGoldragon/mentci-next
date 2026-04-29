# 111 — First mentci-ui: introspection workbench + basic interaction

*Research report. The aim is a coherent first incarnation of the
mentci interaction surface — one that lets Li see into criome's
running state, edit the database with direct gestures, and use that
combination to refine the engine itself. The report concentrates on
**visuals** of what the surface should look like; concrete code
shapes belong in skeleton-as-design once the visual answers settle.
Lifecycle: lives until the questions in §10 are answered and the
shape is encoded in mentci-lib + the GUI repo.*

---

## 0 · Aim

The first mentci-ui exists for one reason: **let agents (Li,
LLMs, future humans) see the engine clearly enough to participate
in its design**. Per [INTENTION](../INTENTION.md), introspection
is first-class — the surface is not a downstream consumer of
criome but a peer of it.

Two intertwined goals shape every decision below:

1. **Introspection** — every record, every change, every
   subscription, every wire frame, every diagnostic is visible at
   the surface. Nothing is hidden in the engine that the engine
   itself can produce a representation of.
2. **Basic interaction** — the user can edit the database directly
   through gestures (and equivalently through nexus text); every
   gesture maps to a signal verb, validated by criome, reflected
   in the UI on accept.

These are inseparable: introspection without interaction is a
read-only viewer; interaction without introspection is a database
admin tool with no learning surface. The first mentci-ui must do
both at once.

---

## 1 · What must be visible

Introspection is design pressure. To say "the engine reveals
itself" we must enumerate what the engine has to reveal:

- **Records.** Every record in sema, by kind, with its slot, its
  current content hash, its display name, its current revision.
- **The graph.** When the records form a flow-graph, the surface
  renders the graph itself — Graph node, member Nodes, Edges
  carrying their `RelationKind` typed.
- **History.** The change log per slot — every Assert, Mutate,
  Retract, with content before/after, principal, hash transition,
  timestamp.
- **Diagnostics.** Validation rejections (schema fail, broken
  reference, stale revision, permission denied) shown as
  first-class events, not buried in a console.
- **The wire.** Every signal frame in either direction —
  request, reply, subscription push — at the level of typed
  variants, not raw bytes.
- **Subscriptions.** What the surface is subscribed to, what's
  pushing, what arrived when.
- **Connection state.** Handshake status, protocol version,
  whether the link is up.
- **Cascades.** When a write triggers further changes (a Mutate
  that fires a subscription that re-derives a record), the cascade
  is visible — not collapsed into "something changed."

Each of these is a pane or surface in the workbench below.

---

## 2 · The workbench

A multi-pane shell. The point of the multi-pane shape is that
introspection is *concurrent* with editing — you see the engine
*while* you act on it, not as a separate "debug mode."

```
┌─────────────────────────────────────────────────────────────────┐
│ [conn: /tmp/criome.sock · v0.1.0 · ●connected]                  │
├──────────┬────────────────────────────────────┬─────────────────┤
│          │                                    │                 │
│  GRAPHS  │            CANVAS                  │  INSPECTOR      │
│          │                                    │                 │
│ ▸ Echo   │      ⊙ Source ──Flow──▶ ⊡ Transf   │   slot 1042     │
│   Pipe   │            ╲                │      │  ─────────────  │
│ ▸ Build  │             ╲              Flow    │   kind: Node    │
│   Defs   │              Flow            │     │   name: "Echo"  │
│ ▸ Authz  │                ╲             │     │   rev:  7       │
│ ▸ ...    │                 ▼            ▼     │   hash: 8a3f…   │
│          │              ⊠ Sink     ⊠ Sink     │                 │
│ + new G  │                                    │  HISTORY        │
│          │                                    │  ─────────────  │
│          │                                    │  ▼ rev 7  now   │
│          │                                    │  ▼ rev 6  -3m   │
│          │                                    │  ▼ rev 5  -8m   │
│          │                                    │  ▼ rev 4  …     │
├──────────┴────────────────────┬───────────────┴─────────────────┤
│ DIAGNOSTICS                   │ WIRE                            │
│ ─────────────────────────     │ ─────────────────────────       │
│ ✗ rev8 STALE_REV slot 1042    │ →  17:23:08  Mutate(Node …)     │
│ ⚠ rev7 batch partial 2/3      │ ←  17:23:08  Outcome(Ok)        │
│ ✓ rev6 Assert ok              │ →  17:23:09  Query(NodeQuery)   │
│                               │ ←  17:23:09  Records::Node([…]) │
│                               │ ⇣  17:23:20  Records::Node([…]) │
│                               │      (push, sub#3)              │
├───────────────────────────────┴─────────────────────────────────┤
│ NEXUS                                                           │
│ > (Query (NodeQuery (name @any)))                               │
│ < [(Node "Echo"), (Node "ticks"), (Node "stdout")]              │
│ >                                                               │
└─────────────────────────────────────────────────────────────────┘
```

The shape is not novel — it's a workbench in the same family as a
debugger or a database admin tool. The novelty is that **the
surface itself is the engine's introspection mechanism**, not a
separate tool the engine is opaque to.

Five panes:

- **Graphs** (left) — the navigation tree; lists every Graph
  record sema holds, plus saved queries and recent activity.
- **Canvas** (centre) — the primary visualisation; flow-graph
  rendering when the selected scope is a Graph, alternative views
  (records list, kind-grouped) when not.
- **Inspector** (right) — what's selected, in detail; current
  state at the top, change history below.
- **Diagnostics + Wire** (bottom strip, split) — the two
  introspection feeds. Diagnostics shows validation outcomes;
  Wire shows raw signal traffic.
- **Nexus REPL** (bottom) — text input, text output; the same
  wire path the gestures take, but exposed as text for the cases
  where text is faster than gesture (or where a careful agent
  wants to construct a request precisely).

---

## 3 · The flow-graph canvas

The centrepiece. When the selection is a Graph, the canvas
renders it as the actual flow-graph — nodes positioned in space,
edges drawn between them, kinds and relations encoded visually.

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

**Visual encoding:**

- Glyphs for node-kind: ⊙ Source · ⊡ Transformer · ⊠ Sink · ⊕
  Junction · ▶ Supervisor.
- Stroke style for `RelationKind`: solid+open-arrow for Flow;
  dashed+filled-arrow for DependsOn; thick+bracket-arrow for
  Contains; thin+dot-arrow for References. Each closed-enum
  variant gets one consistent rendering.
- Colour reserved for *state*, not kind: a node rendered red
  is one whose last write was rejected; amber means an
  in-flight optimistic edit; grey means stale (subscription
  push pending). Kind is glyph; state is colour.
- Labels show display name first (load-bearing for human
  recognition), slot id second (introspection), hash never
  (too noisy; lives in inspector).

The canvas is **always live to subscriptions** — when criome
pushes a record change, the canvas updates in place, and the
node visibly transitions through "stale" to current.

---

## 4 · The inspector

A selected slot's complete state. Two stacked sections: current,
and history.

```
SLOT 1042                                              [▢ pin]
═══════════════════════════════════════════════════════════════
 kind:        Node
 name:        Echo
 rev:         7
 hash:        8a3f7c…
 derived?     no
 last write:  17:23:14  (Mutate, by Li)
 referenced:  3 edges in · 1 edge out
───────────────────────────────────────────────────────────────
 [signal in nexus]   (Node "Echo")
───────────────────────────────────────────────────────────────

HISTORY (full log, scroll for older)
═══════════════════════════════════════════════════════════════

▼ rev 7  ·  17:23:14   ·  Mutate     ·  by Li
│   slot   1042
│   before Node { name: "Doubler", kind: Transformer }
│   after  Node { name: "Echo",    kind: Transformer }
│   hash   cd9e…  →  8a3f…

▼ rev 6  ·  17:20:02   ·  Assert     ·  by Li
│   created  Node { name: "Doubler", kind: Transformer }
│   hash    cd9e…

▼ rev 5  ·  17:18:51   ·  Mutate     ·  by Li
│   ...
═══════════════════════════════════════════════════════════════
```

Every entry has an arrow that **scrubs the canvas backward** to
that point in time — you can watch the graph evolve. The point
isn't time-travel-debugging in general; it's that history is a
first-class introspection surface, not a derived view buried in a
text log.

---

## 5 · Diagnostics surface

Validation outcomes are first-class. Every Outcome that's not
`Ok`, every Reply that carries a `Diagnostic`, lands here in
chronological order, with a permanent jump-link to the slot or
batch the diagnostic concerns.

```
DIAGNOSTICS                                          [clear all]
════════════════════════════════════════════════════════════════

✗  17:23:14   STALE_REVISION
   Mutate { slot: 1042, expected_rev: 5, actual_rev: 7 }
   suggestion: refresh slot 1042 and retry
   ↳ jump to slot 1042

⚠  17:23:08   PARTIAL_BATCH
   AtomicBatch [3 ops]
   2 ok, 1 SCHEMA_FAIL on op#2
     op#2:  Assert(Edge { from: 9999, to: 1042, kind: Flow })
            slot 9999 does not exist
   ↳ inspect batch · ↳ retry without op#2

✓  17:20:02   ok
   Assert(Node { name: "Doubler", kind: Transformer })
   ↳ slot 1042
```

The pane never aggregates ("3 errors") and never elides; every
outcome is shown in full, because the failure modes of the
engine are themselves part of what an agent has to see. The
suggestion line is whatever criome put in the `Diagnostic`
record's suggestion field — the surface displays; it does not
synthesise advice.

---

## 6 · The wire inspector

Every signal frame in either direction, at the level of typed
variants, never collapsed. Always on.

```
WIRE                                          [pause] [filter…]
═══════════════════════════════════════════════════════════════

→ 17:23:08.412  req#41  Mutate(MutOp::Node {
                         slot:1042, expected_rev:6, new:Node{…}
                       })
← 17:23:08.418  req#41  Outcome(Ok)
→ 17:23:09.001  req#42  Query(QueryOp::Node(NodeQuery{…}))
← 17:23:09.004  req#42  Records(Records::Node([…]))     [3 items]
→ 17:23:14.776  req#43  Mutate(MutOp::Node{ … })
← 17:23:14.780  req#43  Outcome(Diagnostic(STALE_REVISION))
⇣ 17:23:20.012  sub#3   Records(Records::Node([…]))     [1 item]

═══════════════════════════════════════════════════════════════
   →  request out      ←  reply in      ⇣  subscription push
```

This pane is the strongest expression of the introspection-
first principle in the report. Most database UIs hide the wire;
this one foregrounds it. The reasoning is in §9.

A frame can be expanded inline to show its full typed payload —
no JSON, no string-rendering, just the rkyv types laid out.

---

## 7 · Gesture vocabulary

The map from direct manipulation to signal verbs. Every gesture
is a signal request; the same path the REPL takes.

```
USER GESTURE                              SIGNAL VERB
─────────────────────────────────────────────────────────────────

drag-new-box on canvas               →    Assert(AssertOp::Node(…))
                                          (kind picked from palette;
                                           position cached locally —
                                           layout records arrive
                                           later, see §10 Q14)

drag-wire from box A to box B        →    Assert(AssertOp::Edge {
                                            from: A.slot,
                                            to:   B.slot,
                                            kind: <RelationKind
                                                   selected via
                                                   modifier or
                                                   palette>
                                          })

select box, type new name, Enter     →    Mutate(MutOp::Node {
                                            slot,
                                            new: Node{name:…, …},
                                            expected_rev: <rev>
                                          })

select wire, Backspace               →    Retract(RetractOp::Edge
                                                   { slot })

select box, Backspace                →    Retract(RetractOp::Node
                                                   { slot })

multi-select + bulk-edit             →    AtomicBatch([…])

text in REPL pane                    →    same wire shape; the
                                          parser produces the same
                                          signal verb the gesture
                                          would have produced
```

Two principles inform every entry:

- **Commit at gesture-end.** A gesture commits when it's
  unambiguously complete (mouseup on drag, Enter on rename) —
  not while typing, not mid-drag. The canvas may show the
  in-flight intent visually, but no signal frame leaves until
  commit. The local in-flight buffer is *pending input*, not a
  contradicting projection of the engine state.
- **Accept-and-reflect.** The canvas updates only after criome's
  Outcome arrives. Optimistic UI is rejected — it makes the
  engine's authority blurry and corrupts introspection.

---

## 8 · Connection lifecycle

The connection's state is always shown in the status bar. There
is no hidden state.

```
                ┌────────────────┐
                │  disconnected  │   shown as: "● disconnected"
                └────────┬───────┘
                         │  user opens session / picks socket
                         ▼
                ┌────────────────┐
                │  connecting    │   "◑ connecting…"
                └────────┬───────┘
                         │  socket up
                         ▼
                ┌────────────────┐
                │  handshaking   │   "◑ negotiating protocol"
                └────────┬───────┘
                         │  HandshakeAccepted
                         ▼
                ┌────────────────┐
                │   connected    │   "● connected · v0.1.0"
                └─┬───┬──────────┘
                  │   │
       socket dies│   │  user closes
                  ▼   ▼
                ┌────────────────┐
                │  disconnected  │   "● disconnected · why"
                └────────────────┘
```

Auto-reconnect is rejected. When the link drops, the user sees
why and reconnects deliberately. Hidden retries hide the engine
from the user.

---

## 9 · What this asks of the engine

Introspection is design pressure. The surface above asks the
engine to expose things some engines hide. Each ask is a *good*
ask — it shapes the engine for the better.

- **State must be representable, not just queryable.** Every
  record kind needs a canonical visual rendering. The flow-graph
  rendering already exists conceptually; new kinds will need
  their own. This pressures the engine toward kinds whose state
  is *visible* — no opaque blobs, no "internal" fields without
  meaning.
- **Diagnostics must carry structured suggestions, not strings.**
  The diagnostics pane shows `suggestion` as actionable
  ("refresh slot 1042 and retry"). That requires criome to emit
  diagnostics with structured suggestions, not just an error
  message. This pressures the engine toward modelled failure.
- **Wire frames must be inspectable typed payloads, end to end.**
  No string-tagged variants, no `Box<dyn Any>`, no JSON-as-
  payload. This pressures the engine toward perfect specificity
  at the wire (which the engine claims as Invariant D anyway).
- **Subscriptions must push the *whole* affected record, not
  diffs alone.** The canvas can recompute its rendering from a
  current record; computing a current record from a series of
  diffs is fragile. Push-not-pull discipline already implies
  full records on subscription events.
- **Cascades must be observable.** When write A triggers
  derivation B, the wire pane should show both — not a single
  collapsed event. This pressures the engine to surface its
  cascade graph rather than hide it.
- **Time must be queryable.** The history scrubber implies
  point-in-time queries against sema. This is consistent with
  sema's bitemporal SlotBinding.

The deepest one: **nothing the engine does is hidden from the
agent who is shaping the engine**. That property is what makes
the engine improvable.

---

## 10 · Open questions

The questions Li answers shape the rest. Each cites the
principle that frames it.

| # | Question | Principle |
|---|---|---|
| Q1 | Subscribe is post-MVP in the engine plan; the canvas's "always live" property assumes it. Does the first mentci-ui ship without live updates (showing a manual refresh affordance and an explicit "this view may be stale" badge until Subscribe lands)? Or does the first mentci-ui wait for Subscribe so live-update is intrinsic? | Push, never pull. A poll-on-refresh model violates the discipline; an explicit "stale until refreshed" badge does not, because the staleness is named. |
| Q2 | Where does the first mentci-ui live — same repo as `mentci-lib`, or a separate "GUI repo" as ARCH §11 suggests? | One capability, one crate, one repo. If gesture→signal mapping is its own capability, mentci-lib is its own repo and the GUI is a separate consumer. If they're the same capability while small, one repo. |
| Q3 | Wire pane: always on, or opt-in via a developer-mode toggle? | Introspection is first-class. Recommendation: always on. A toggle that hides the wire trains the agent to forget it exists. |
| Q4 | Diagnostics pane: also visualised on the canvas (failed write rendered red on the affected node, cleared on next successful write)? | Introspection is first-class. Recommendation: yes — the diagnostic should be visible *at the site*, not only in the pane. |
| Q5 | RelationKind visual encoding: stroke style alone, or stroke+colour together? | Clarity > aesthetic. Colour is needed for *state*; stroke style is needed for kind. Should they overlap or stay separate? |
| Q6 | Multi-graph navigation in the Graphs pane: tabs (one open at a time), tree (hierarchical), or workspace-shaped (multiple canvases tiled)? | Introspection. Tree shows the most at once but eats screen space; tabs hide siblings; tiles get unwieldy past a few graphs. |
| Q7 | Authoring split: gestures-first with REPL as fallback, REPL-first with gestures as enhancement, or both equal? | Clarity. The agent (and Li) should be able to construct any request through either path; equivalence is load-bearing. But which is the *primary* visual focus for the new user? |
| Q8 | History depth in the inspector: full per-slot log, last N entries with paginate, or summarised-with-expand? | Introspection. Recommendation: full, scrollable. Hiding history is hiding the engine. |
| Q9 | Should rejected operations remain in the wire and diagnostics pane forever, or scroll out after a window? | Introspection. Recommendation: forever within session; cleared only when user clears. |
| Q10 | Cascades: render every cascade event in the wire pane, or only direct user actions and their first-order cascades? | Introspection. Recommendation: every cascade — but with visual nesting so a user-triggered chain reads as a single tree, not a flat sequence. |
| Q11 | Position of nodes on the canvas: stored as records (so layout is itself sema state), stored locally per-client (so different agents see different layouts), or auto-laid-out (no stored positions)? | The flow-graph IS the program. If layout is part of the program (Li's mental model of "where things are"), it's records. If layout is the agent's tool-state, it's local. Both have arguments. |
| Q12 | Large graphs (hundreds of nodes): pan-and-zoom only, mini-map, level-of-detail collapse, or filtered subgraphs? | Clarity > completeness. Recommendation: pan/zoom + mini-map first; filtering follows when scale demands. |
| Q13 | Renaming UX: in-place edit on the node label vs. an inspector field? | Direct manipulation should compose. Recommendation: both — they produce the same Mutate verb. |
| Q14 | When Subscribe ships and the canvas goes live, how is the boundary between "my pending edit" and "criome's pushed update" rendered? | Accept-and-reflect; the canvas reflects criome, not the user's intent. The pending-edit must be visually distinct. |
| Q15 | Connection model: a single criome connection per UI session, or multiple parallel connections (so independent panes can be subscribed independently)? | Each connection is its own serial lane. Multiple connections enable parallel subscriptions; a single connection is simpler but serialises updates. |
| Q16 | Authentication / capability tokens: does the first mentci-ui ship with the auth model fully wired, or is it allowed to operate as `SingleOperator` with no real auth? | Foundations not features. The auth model's *shape* must be wired even if the verification is a stub — so that the wire contracts are honest. |

---

## 11 · What is not in this report

- **Visual aesthetics.** Theme, colour palette, font choices,
  exact iconography. The visuals above use ASCII glyphs as
  placeholders for what the rendered surface will show; the
  visual design is its own work.
- **The mentci-lib API surface.** Type-level definitions are
  skeleton-as-design work; this report concentrates on the
  visual shape of the surface that will sit atop them.
- **Performance.** No targets, no benchmarks. Iteration speed
  matters when implementing; steady-state performance is its
  own concern.
- **Mobile / alternative form-factors.** This is the desktop
  workbench; phone/tablet variants come after the desktop shape
  is right.
- **The eventual universal-UI scope.** mentci as the universal
  interaction surface for all of computing is the long view; the
  first mentci-ui is the introspection workbench that begins
  earning the right to that scope.
- **Code shapes.** Ractor topology, egui widget choices, state
  management style — none of that here. Visuals first; code
  shapes follow once the visual answers settle.

---

## 12 · Lifetime

This report lives until:

- Q1–Q16 are answered (or explicitly deferred with a stated
  reason).
- The shape is encoded in mentci-lib's skeleton-as-design and the
  GUI repo's first scaffolding.
- The first running mentci-ui produces visible records on the
  canvas, accepts a gesture, and shows a diagnostic.

When the surface exists in code at the level this report sketches
in visuals, the report is deleted; its content has moved into the
implementation it described.

---

*End report 111.*
