# 111 — First mentci-ui: introspection workbench + basic interaction

*Research report. The first incarnation of mentci is an
introspection workbench that lets a human see into criome's
running state and edit the database through gestures.
Concentrates on **visuals**; code shapes belong in
skeleton-as-design once enough is settled. Revision v4
(2026-04-29) absorbs Li's answers on Subscribe payloads, the
schema-in-sema direction, identity/Tweaks, engine-wide wire-tap,
and theme records' egui-shape; deep-dives the one remaining
load-bearing question — mentci-lib's contract shape.*

---

## 0 · Aim

The first mentci-ui exists for one reason: **let the human
shaping the engine see it clearly enough to participate in its
design**. Per [INTENTION](../INTENTION.md), introspection is
first-class — the surface is a peer of the engine, not a
downstream consumer. The first mentci-ui must do introspection
and direct interaction at once.

---

## 1 · What is settled

After three rounds of Li's answers, the following are no
longer open:

- **Subscribe is foundational.** Engine work for it is part of
  this milestone. Canvas is live to pushed updates from start.
- **Subscribe payload: the full updated record.** Signal is
  small, typed, binary; full-record on push is correct.
  Diff-reconstruction is fragile; refetch-on-push is
  poll-shaped and rejected.
- **mentci is a family.** One `mentci-lib` + one repo per GUI
  library (`mentci-egui`, `mentci-iced`, `mentci-flutter`, …).
  Foreign-interface barriers handled by per-language shim
  crates when needed.
- **mentci-lib is heavy; shells are thin.** All sema-viewing
  and editing logic lives in mentci-lib — view-state machines,
  action-flow state machines, connection management, schema
  knowledge, theme + layout interpretation. Each GUI is a
  rendering shell.
- **Two surfaces, two audiences.** Agents → nexus. Humans →
  mentci. The GUI is human-only.
- **Daemons compose.** Two persistent connections from mentci:
  to criome (signal — editing, queries, subscriptions) and to
  nexus-daemon (signal — used as a signal↔nexus rendering
  service, per nexus/ARCH's bright-line scope).
- **Failure modes.** nexus down → error pane appears, "[as
  nexus]" lines hide, raw typed payloads remain visible.
  criome down → mentci is useless and refuses to operate.
- **Surfaces are dynamic.** Diagnostics pane appears when
  ≥1 unread; wire pane is user-toggled.
- **No raw nexus typing.** Humans gesture; nexus is display-
  only via the rendering service.
- **First library: egui.** Linux + Mac first-class, Rust-native,
  strong fit for the workbench. The first repo is
  `mentci-egui`.
- **Schema-in-sema is the medium-term direction.** Signal's
  type definitions are intended to live as records in sema
  (records describing record kinds — "datatypes-datatypes"),
  fitting the graph system; first target for forge's Rust
  generation. For the first mentci-ui, schema knowledge in
  mentci-lib is compile-time-codegen; design accommodates the
  swap. See §13.
- **Engine-wide wire-tap is wanted.** Documented for later
  design. Not blocker for the first mentci-ui. See §16.
- **Identity + Tweaks land in the engine.** A `Principal`
  record kind plus a "mentci config/tweaks" index for
  per-Principal styles. Specific shape in §14.
- **Theme/layout record kinds shape with egui.** The first
  set is informed by egui's rendering features; semantic-
  intent rather than appearance values. See §15.

---

## 2 · What must be visible

Categories of engine state the surface reveals:

- Records (every record, by kind, with slot, hash, name, rev).
- The graph (Graph + member Nodes + Edges with `RelationKind`
  visually encoded).
- History (per-slot change log).
- Diagnostics (validation rejections as first-class events).
- The wire (every signal frame, both directions, typed).
- Subscriptions (what's subscribed, what's pushing).
- Connection state (both daemons).
- Cascades (when a write triggers further changes).
- The surface itself (theme, layout, pane visibility — as
  records, edited the same way as everything else).

---

## 3 · The mentci-lib / shell pattern

```
              ┌──────────────────────────────────┐
              │           mentci-lib             │
              │                                  │
              │  ALL APPLICATION LOGIC:          │
              │   • view-state machines          │
              │   • action-flow state machines   │
              │   • engine connection management │
              │   • subscription + reply demux   │
              │   • schema knowledge             │
              │   • theme + layout interpretation│
              │                                  │
              │  EXPOSES (shape: see §12):       │
              │   • current-view data            │
              │   • input-event sink             │
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
     │ paints      │    │ Elm-arch    │    │  interface  │
     │ widgets in  │    │ in iced     │    │  shim crate │
     │ egui        │    │             │    │             │
     │ THIN shell  │    │ THIN shell  │    │ THIN shell  │
     └─────────────┘    └─────────────┘    └─────────────┘
```

The contract — what the data + events look like at the
boundary — is the load-bearing decision deep-dived in §12.

---

## 4 · The workbench

```
┌────────────────────────────────────────────────────────────────┐
│ [● criome v0.1.0]  [● nexus v0.1.0]      [⊞ wire] [⌗ tweaks]   │
├──────────┬─────────────────────────────────────┬───────────────┤
│          │                                     │               │
│  GRAPHS  │             CANVAS                  │  INSPECTOR    │
│          │                                     │               │
│ ▸ Echo   │      ⊙ Source ──Flow──▶ ⊡ Transf    │   slot 1042   │
│   Pipe   │            ╲                │       │   ───────     │
│ ▸ Build  │             ╲              Flow     │   kind: Node  │
│   Defs   │              Flow            │      │   name: Echo  │
│ ▸ Authz  │                ╲             ▼      │   rev:  7     │
│ ▸ Tweaks │                 ▼          ⊠ Sink   │   hash: 8a3f… │
│   …      │              ⊠ Sink                 │               │
│          │                                     │  HISTORY      │
│ + new G  │                                     │  ▼ rev 7  now │
│          │                                     │  ▼ rev 6  -3m │
├──────────┴─────────────────────────────────────┴───────────────┤
│ ⚠ DIAGNOSTICS (2)                                       [clear]│
│ ✗ rev8 STALE_REV slot 1042 · ↳ jump                            │
│ ⚠ rev7 batch partial 2/3 · ↳ inspect                           │
└────────────────────────────────────────────────────────────────┘
```

Always-visible: Graphs, Canvas, Inspector. Diagnostics: when
non-empty. Wire: user toggle. Tweaks button opens the
per-Principal Tweaks editor (themes, layout, keybinds — same
constructor-flow pattern as any record edit).

---

## 5 · The flow-graph canvas

```
                    ╭───────────────╮
                    │   ⊙  Source   │
                    │    "ticks"    │
                    ╰───────┬───────╯
                            │ Flow
                            ▼
                    ╭───────────────╮
                    │   ⊡ Transf.   │
                    │    "double"   │
                    ╰─┬───────┬─────╯
                      │ Flow  │ Flow
                      ▼       ▼
              ╭──────────╮ ╭──────────╮
              │ ⊠ Sink   │ │ ⊠ Sink   │
              │ "stdout" │ │ "log"    │
              ╰──────────╯ ╰──────────╯
```

- **Glyph encodes kind.** ⊙ Source · ⊡ Transformer · ⊠ Sink ·
  ⊕ Junction · ▶ Supervisor.
- **Stroke style encodes RelationKind.** Each closed-enum
  variant gets a consistent stroke style; encoding lives in
  mentci-lib's theme interpretation.
- **Colour reserved for state.** Pending optimistic edit,
  stale (subscription push pending), rejected (failed write).
- **Labels.** Display name on the node; slot id on hover;
  hash never on canvas.

The canvas is **always live** to subscription pushes from
criome.

**Node positions are records.** Layout is sema state — readable,
editable, shareable across mentci sessions on the same criome.
Moving a node generates a Mutate to its position record.

---

## 6 · The inspector

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

The "[as nexus]" line: typed payload sent to nexus-daemon;
nexus text comes back; mentci displays. mentci does not embed
nexus's parser/renderer.

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

Pane appears when list non-empty; vanishes on clear. Failed
writes also overlay on the canvas at the affected node.

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

→ 17:23:09.001  req#42  to criome
                Query(QueryOp::Node(NodeQuery{…}))

← 17:23:09.004  req#42  from criome
                Records(Records::Node([…]))     [3 items]

⇣ 17:23:20.012  sub#3   from criome (push)
                Records(Records::Node([…]))     [1 item]

═══════════════════════════════════════════════════════════════
   →  request out      ←  reply in      ⇣  subscription push
```

User-toggled. "[as nexus]" lines render via nexus-daemon. The
introspection surface re-uses the agent surface's text codec.

For the first mentci-ui: this-connection-only. Engine-wide
wire-tap is documented for later design; see §16.

---

## 9 · Schema-aware constructor flows

```
DRAG-WIRE FLOW (drag from box A to box B)
═══════════════════════════════════════════════════════════════

  ⊙ Source ╌╌╌╌╌╌╌╌╌╌╌▶ ⊡ Transf.            (pending preview,
                                              wire shown dashed)

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
  │               │   …                     ││
  │               └─────────────────────────┘│
  │  description: [_________________________]│
  │                                          │
  │              [cancel]  [commit]          │
  └──────────────────────────────────────────┘
```

- **Pre-show but uncommitted.** The wire appears dashed; no
  signal frame leaves until commit.
- **Schema knowledge in mentci-lib.** mentci-lib knows Edge has
  a `kind: RelationKind` field; surfaces variants. New variants
  in `signal/flow.rs` reach every family member through
  mentci-lib.
- **Validity narrows the choices.** When some
  source-kind/target-kind/RelationKind combinations are
  meaningless, only valid options surface. Invariants live with
  the types in signal.
- **Commit-at-flow-end.** No optimistic UI. Canvas reflects
  criome's accept; rejection vanishes the pending preview and
  surfaces a diagnostic.
- **Equivalence with the agent path.** Whatever an agent could
  send via nexus, a human can build via gestures.

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
               queries,       │        │   translation only)
               subscribe)     │        │
                              ▼        ▼
                       ┌──────────┐ ┌──────────────┐
                       │  criome  │ │ nexus-daemon │
                       └──────────┘ └──────────────┘
```

Both connections persistent (one per session). Header shows
both states. Failure modes per §1.

---

## 11 · GUI library — egui

Settled per the prior round. Linux + Mac first-class, Rust-
native, strong fit for the workbench's specific needs (custom
canvas, dynamic panes, immediate-mode = re-render-from-current-
state matching subscription-push semantics, `egui_node_graph` /
Rerun precedent for the canvas).

The first repo is **`mentci-egui`**. Other family members
(`mentci-iced`, `mentci-flutter`, …) follow.

---

## 12 · DEEP DIVE — mentci-lib's contract shape

This is the load-bearing decision. mentci-lib defines the
interfaces; the shell implements them. *What kind of interface?*
Three candidates — visualised, analysed, recommended.

### 12.1 Approach A — Trait-based view contracts

```
┌──────────────────────────────────────────────────────────────┐
│  mentci-lib                                                  │
│                                                              │
│  pub struct Workbench { state: WorkbenchState }              │
│                                                              │
│  pub trait CanvasView {                                      │
│      fn canvas(&self) -> &CanvasState;                       │
│      fn on_canvas_event(&mut self, ev: CanvasEvent);         │
│  }                                                           │
│  pub trait InspectorView { ... }                             │
│  pub trait DiagnosticsList { ... }                           │
│  pub trait WireStream { ... }                                │
│                                                              │
│  impl CanvasView    for Workbench { ... }                    │
│  impl InspectorView for Workbench { ... }                    │
│  ...                                                         │
└────────────────────────────┬─────────────────────────────────┘
                             │
                             │ each shell holds &mut Workbench
                             │ and calls trait methods per pane
                             ▼
                       ┌──────────┐
                       │  shell   │
                       │ for each │
                       │ pane:    │
                       │  read    │
                       │  state,  │
                       │  paint,  │
                       │  emit    │
                       │  events  │
                       └──────────┘
```

**Clarity.** Each pane is its own typed contract. Adding a
pane means adding a trait. Reads object-oriented in the Rust
sense. But: the contract is Rust-trait-shaped, which is
Rust-language-specific.

**Correctness.** Type system enforces every shell impls every
trait. If mentci-lib adds a pane, every shell breaks the build
until updated. Loud refactoring.

**Beauty.** The `&mut Workbench` exposed to the shell makes
state ownership ambiguous — the shell can in principle reach
through traits and tangle with internals it shouldn't. Cleaner
than free-function APIs; less clean than pure-data flow.

**Foreign interfaces.** Awkward. Dart, Swift, JS don't have
Rust traits. A shim crate per language would expose C-FFI
functions wrapping each trait method by hand. Verbose; couples
the FFI surface to Rust trait shapes.

**Subscriptions.** Need a re-render-please callback or polling
on every frame. Either way the trait is augmented with a
notification channel — and at that point the shape converges
toward the actor approach.

### 12.2 Approach B — Data-and-events (MVU)

```
┌──────────────────────────────────────────────────────────────┐
│  mentci-lib                                                  │
│                                                              │
│  pub struct WorkbenchState { ... }                           │
│                                                              │
│  pub struct WorkbenchView {                                  │
│      canvas:      CanvasView,                                │
│      inspector:   InspectorView,                             │
│      diagnostics: Option<DiagnosticsList>,                   │
│      wire:        Option<WireFrames>,                        │
│      ...                                                     │
│  }                                                           │
│  pub enum UserEvent { ... }                                  │
│  pub enum EngineEvent { ... }   ← from criome subscriptions  │
│                                                              │
│  impl WorkbenchState {                                       │
│      pub fn view(&self) -> WorkbenchView;                    │
│      pub fn on_user_event(&mut self, ev: UserEvent)          │
│            -> Vec<Cmd>;                                      │
│      pub fn on_engine_event(&mut self, ev: EngineEvent)      │
│            -> Vec<Cmd>;                                      │
│  }                                                           │
│                                                              │
│  Cmd: SendSignal(Frame), RenderViaNexus(Payload), …          │
└────────────────────────────┬─────────────────────────────────┘
                             │
                  view: WorkbenchView   ◀── data OUT
                             │
                             ▼
                       ┌──────────┐
                       │  shell   │
                       │ paints   │
                       │ from the │
                       │ snapshot │
                       └────┬─────┘
                            │
                  user event: UserEvent  ──▶ data IN
                            │
                            ▼
                   on_user_event(state, ev) → state'
```

The library is two pure functions plus a state struct:
- `view: state → WorkbenchView` (data the shell paints)
- `update: state, event → state` (how state evolves)

The shell is a function `WorkbenchView → pixels` plus a
gesture handler emitting `UserEvent`s. Subscription pushes from
criome enter as `EngineEvent`s and flow through the same
`update` path.

**Clarity.** Pure data flowing out, pure data flowing in. No
shared mutable references. The shell knows nothing about
mentci-lib's internals; mentci-lib knows nothing about the
shell's rendering. The contract is a struct + an enum; that's
the entire surface.

**Correctness.** Every change is a typed event; every view is
a typed snapshot. Time-travel debugging is trivial — record the
event log and replay. Refactoring is loud (compiler errors at
every break).

**Beauty.** This is the cleanest abstract shape. State owned
by mentci-lib. Views are projections. Events are intent. Maps
exactly to immediate-mode (re-render the view every frame) and
to retained-mode (diff against prior view). The same shape Elm,
Redux, Bevy ECS, and React all settle on for the same reason —
it composes.

**Foreign interfaces.** Excellent. `WorkbenchView` and
`UserEvent` serialise (rkyv would be the natural choice in this
workspace; matches the wire). The C-FFI shim is two functions:
`get_view() -> bytes` and `send_event(bytes)`. Flutter via FFI,
WASM in a browser, Swift on iOS — all the same shape. The
foreign interface IS the contract.

**Subscriptions.** Push from criome → mentci-lib emits an
internal `EngineEvent` → state updates → view changes → shell
re-renders. Linear. Traceable.

**Concerns.** Allocates a snapshot per change. Mitigation:
rkyv zero-copy; or per-pane sub-views with stable IDs and only
the changed sub-views rebuild. This is a known pattern (the
React `key` discipline; Elm's lazy nodes); the engine's existing
rkyv discipline already handles zero-copy serialisation
identically.

### 12.3 Approach C — Async-channel actors

```
┌──────────────────────────────────────────────────────────────┐
│  mentci-lib                                                  │
│                                                              │
│  Actor: WorkbenchSupervisor                                  │
│      ├── Actor: CanvasModel                                  │
│      │      Message: { ev: CanvasEvent }                     │
│      │      publishes: CanvasView                            │
│      ├── Actor: InspectorModel                               │
│      ├── Actor: DiagnosticsModel                             │
│      └── Actor: WireModel                                    │
│                                                              │
│  Public API:                                                 │
│      fn subscribe_canvas() -> Receiver<CanvasView>           │
│      fn send_canvas_event(ev: CanvasEvent)                   │
│      fn subscribe_inspector() -> Receiver<InspectorView>     │
│      ...                                                     │
└──────────────────┬───────────────────────────────────────────┘
                   │
                   │ shell holds N receivers + N senders
                   ▼
              ┌─────────┐    ┌─────────┐
              │ Receiver│    │ Sender  │
              │ <View>  │    │ <Event> │
              └────┬────┘    └────▲────┘
                   ▼              │
                 ┌─────────────────┐
                 │   GUI shell     │
                 │  poll receivers │
                 │  paint changes  │
                 │  send events    │
                 └─────────────────┘
```

**Clarity.** Each pane is an actor. The shell talks per pane.
Maps to ractor (the engine's pattern).

**Correctness.** Actor isolation prevents shared-state bugs.
Cross-pane coordination (canvas selection updates inspector)
requires explicit messaging via the supervisor or pub/sub —
adds machinery the simpler shapes don't need.

**Beauty.** Workbench-as-supervision-tree is faithful to
ractor's idiom in the engine. But: the GUI shell *is*
synchronous (egui's frame loop, iced's update, Flutter's UI
thread). Putting actors between the shell and the model adds
async/concurrency machinery the shell doesn't actually need.
Subscribe in criome already pushes — pushing a second
async-channel layer between criome and the shell is
async-on-async without a reason.

**Foreign interfaces.** Hard. Rust mpsc / ractor channels
don't FFI cleanly. A shim could expose a polling API or a
callback-registration API on top of channels — but at that
point it's MVU underneath, with extra boxes.

**Subscriptions.** Natural fit if you accept the actor
framework. But the natural fit is into MVU's `EngineEvent` flow
without the actor layer.

### 12.4 Comparison

| Property | A: Trait | B: MVU | C: Actor |
|---|:---:|:---:|:---:|
| Code clarity | ◐ | ● | ◐ |
| State ownership | ambiguous | clear | clear-per-actor |
| Subscribe fit | clunky | natural | natural |
| Foreign interface portability | per-trait FFI shim | serialise view + event | poor |
| Time-travel debugging | hard | trivial (event log) | hard |
| Adding a pane | new trait + shell impls | new struct field + variant | new actor + spawn |
| Concurrency surface | low | low | high |
| Match with engine's actor pattern | low | medium | high |
| Match with egui's idiom | medium | high | low |
| Match with iced's idiom (Elm-arch) | low | identical | low |
| Match with Flutter (declarative) | low | high | low |
| Cleanest pure shape | no | yes | no |

### 12.5 Recommendation

**B (MVU)**, by clarity + correctness + beauty + foreign-
interface portability all simultaneously:

- **Clarity.** Pure data + pure events is the smallest possible
  contract surface.
- **Correctness.** Snapshots are diffable; events are
  recordable; time-travel debugging arrives free.
- **Beauty.** mentci-lib's whole role — "all sema-viewing and
  editing logic" per Li's framing — has a natural shape as a
  state machine that produces views and consumes events.
- **Foreign-interface portability.** The contract is a
  serialisable data structure plus an event enum. Every GUI
  library — egui, iced, Flutter, future ones — consumes the
  same two things in their native idiom. The shim crate per
  foreign language is shallow because the contract is shallow.
- **Match with subscription semantics.** Criome's Subscribe
  pushes a record; mentci-lib lifts it to an `EngineEvent`;
  state updates; new view emerges; shell re-renders. Linear.
- **Match with the workspace's existing rkyv discipline.**
  WorkbenchView and UserEvent are rkyv-serialisable like every
  other typed payload in the system.

The actor approach (C) double-encapsulates state — once in
ractor's actor framework, again in the model — and doesn't
buy concurrency the UI needs. The trait approach (A) couples
the contract to Rust's trait semantics, which the foreign-
interface goal explicitly asks us to abstract over.

If Li confirms B, mentci-lib's skeleton-as-design follows
this shape.

---

## 13 · Schema-in-sema — the medium-term direction

Per Li: *"the question is really about putting signal in
sema. This is certainly the most important medium-term goal.
Certainly the first target for Rust generation through forge.
Specifying datatypes-datatypes to live in sema — and of course
they should fit in the graph system."*

The endpoint: signal's record-kind type definitions are
themselves records in sema, of a meta-kind that describes
record kinds. The flow-graph IS the program — and the *types
of records* are flow-graphs too.

```
                    ┌─────────────────────────┐
                    │  Today: signal types    │
                    │  hand-written in Rust   │
                    │   pub struct Node { … } │
                    └────────────┬────────────┘
                                 │
                                 │ direction
                                 ▼
                    ┌─────────────────────────┐
                    │  Eventually:            │
                    │  signal's types are     │
                    │  records in sema —      │
                    │  Graph + Node + Edge    │
                    │  whose Nodes are        │
                    │  field-of-type          │
                    │  descriptors            │
                    │                         │
                    │  forge + prism emit     │
                    │  the Rust types from    │
                    │  these records          │
                    │                         │
                    │  Adding a record kind   │
                    │  = editing records.     │
                    └─────────────────────────┘
```

**Implication for the first mentci-ui.** mentci-lib's schema
knowledge today is compile-time — it sees the hand-written
signal types directly. The schema-aware constructor flows in
§9 work this way.

**The design must not preclude the swap.** mentci-lib's
constructor flows treat schema as *data they consume*, not as
hardcoded knowledge they embed in flow code. Today the data
comes from compile-time-derived metadata; tomorrow the data
comes from sema. Either way, the flows render the same.

**Order.** Schema-in-sema is medium-term — after the first
mentci-ui exists, after forge can generate Rust, after the
node-kind family in `signal/flow.rs` has stabilised. Until
then, compile-time schema serves the first mentci-ui.

---

## 14 · Identity + Tweaks

Per Li: *"sure, lets implement that, its not hard. And a
'mentci config/tweaks' index for those styles."*

Two new record kinds land in signal:

### `Principal`

```
   Principal { ... }
   ↑
   referenced from:
     - capability tokens (the "issuer / subject" today
       conceptually carried in tokens; now an explicit ref)
     - ChangeLogEntry's "by" field
     - Tweaks (per-Principal preferences)
```

Concrete shape lands in skeleton-as-design in `signal/`. For
the first mentci-ui: a single default Principal exists at
genesis (representing the local human). Multi-Principal
support comes when the authz model lands.

### `Tweaks`

```
   Tweaks {
       principal: Slot,         ← whose tweaks
       theme:     Slot,         ← Theme record
       layout:    Slot,         ← Layout record
       keybinds:  Slot,         ← KeybindMap record
       ...
   }
```

A *per-Principal index* of style/configuration records (Li's
phrasing). Each preference category is a record on its own (see
§15); Tweaks is the bundle that ties them to a Principal.

Editing one Tweak — pick a different Theme, change a
keybind — is the same Mutate flow as editing any record.
Visible in the wire pane; loggable in history; recursively
introspectable.

The mentci-egui status bar `[⌗ tweaks]` button opens the
Tweaks editor for the current Principal.

---

## 15 · Theme / layout record kinds — shaped by egui

Per Li: F is *"tied to a research on the rendering/layout
features of the first GUI we chose."*

What egui exposes:

- **Visuals** — colours, stroke widths, rounding, spacing,
  text styles. Every widget reads from `Visuals`; overriding
  Visuals re-themes the whole app.
- **Layout** — egui's layout is mostly imperative (described
  in render code). Persistable bits: panel widths, pane
  visibility, splitter positions. egui's `Memory` already
  persists these; what's new in mentci is they live in sema
  instead of egui's own memory, so they survive across
  sessions and across machines.
- **Custom rendering** — the canvas paints its own glyphs,
  strokes, colours; needs per-kind and per-RelationKind data
  to do so.

Given Li's "intent not appearance" answer: themes describe
*semantic* intent (colour names like "selected", "stale",
"rejected"); each shell maps to its native palette.

**First record kinds for the workbench:**

| Kind | What it carries |
|---|---|
| `Theme` | semantic palette: `selected`, `stale`, `rejected`, `pending`, `bg`, `fg`, `accent`, … (each a typed colour-intent slot, not RGB) |
| `Layout` | pane visibility (Diagnostics auto / Wire on-off), pane sizes (left nav width, inspector width, diagnostics height, wire height) |
| `NodePlacement` | per-Graph-per-Node 2D position (the canvas's "where things are") |
| `KindStyle` | per-node-kind glyph + colour-intent (Source: "⊙" + accent-A) |
| `RelationKindStyle` | per-RelationKind stroke style (Flow: solid+arrow, DependsOn: dashed+filled, …) |
| `KeybindMap` | gesture/key → action mapping |

Each is small and focused. Tweaks (§14) references one of
each per Principal.

For the first mentci-egui: built-in defaults in mentci-lib for
each kind so the surface works on a fresh sema. First user
edit of a Tweak inserts the corresponding record. The default
ladder is the bootstrap.

---

## 16 · Engine-wide wire-tap — documented for later

Per Li: *"I absolutely want this. further down the road, but
document it for later design."*

Concept: criome exposes a "wire-tap" subscription that streams
*every signal frame* across *every connected client* to the
subscriber. The introspecting human in mentci-egui can see
what every other agent (LLM, script, CI harness) is doing in
real time. Engine-wide observability.

Constraints to think about when designing it later:

- **Scope of taps.** Tap everything? Tap by client? Tap by
  verb? Tap by record-kind?
- **Privacy of payloads.** A wire-tap subscriber sees frame
  payloads that other clients sent — capability-token
  semantics must allow or refuse this.
- **Frame ordering.** Frames from different connections
  interleave; the tap subscriber needs ordering metadata
  (timestamp, originating connection id).
- **Mentci-egui UI shape.** When the wire pane gets a "show
  all connections" toggle, it needs to render frames with
  their originating-connection label, distinct from this-
  connection.

The first mentci-ui's wire pane is this-connection-only. The
UI shape leaves room for the toggle without redesign — frames
already carry direction (request/reply/push); adding an
originating-connection field is additive.

---

## 17 · What this asks of the engine

- **Subscribe ships as part of this milestone.** Foundational.
- **Subscribe pushes the full updated record.**
- **State is representable.** Every kind has a canonical visual
  rendering.
- **Diagnostics carry structured suggestions.** Not strings;
  actionable.
- **Wire frames are inspectable typed payloads end-to-end.**
- **Cascades are observable.** Triggered derivations visible,
  not collapsed.
- **Time is queryable.** History scrubber implies point-in-time
  reads against sema's bitemporal index.
- **nexus-daemon is a translation service** with bright-line
  scope. Already encoded in nexus/ARCH.
- **New record kinds land in signal:** `Principal`, `Tweaks`,
  `Theme`, `Layout`, `NodePlacement`, `KindStyle`,
  `RelationKindStyle`, `KeybindMap`.
- **Schema-in-sema is the medium-term direction.** The first
  target for forge's Rust generation. Design accommodates the
  swap from compile-time schema to sema-records schema in
  mentci-lib.
- **Engine-wide wire-tap documented for later.** Not blocker;
  not precluded.

---

## 18 · The one remaining decision

Only one decision genuinely blocks starting:

**Confirm Approach B (MVU) for mentci-lib's contract shape.**

The deep dive in §12 lays out the three candidates, the
trade-offs, and recommends B by clarity + correctness + beauty
+ foreign-interface fit. If B is right, mentci-lib's
skeleton-as-design begins shaping the WorkbenchState +
WorkbenchView + UserEvent + EngineEvent + Cmd quartet, with the
schema metadata they consume initially compile-time-derived
and later sema-sourced.

If A or C is preferred, the deep dive shows what's gained and
lost.

Everything else this report describes can begin under any
contract shape; the contract is the only thing the work needs
fixed before code lands.

---

## 19 · Not in scope

- **Visual aesthetics.** Final palette, iconography, type
  choices — obvious choices for now; rich palette via theme
  records later.
- **mentci-lib's API in code.** Skeleton-as-design belongs in
  mentci-lib's own ARCHITECTURE.md.
- **Mobile / alt form factors.** Desktop-first.
- **The eventual universal-UI scope.** This is the
  introspection workbench that begins earning the wider scope.

---

## 20 · Lifetime

This report lives until the first mentci-egui shows records on
the canvas, accepts a constructor-flow gesture, and displays a
diagnostic served by criome — at which point most of its
content has migrated into mentci-lib's ARCH (the contract,
state shapes), signal's evolution notes (the new record kinds),
criome's ARCH (Subscribe payload, wire-tap deferral), and
egui-specific files for the rendering details.

The dance — design / implement / review — produces answers no
amount of pre-design produces. This report's purpose is not to
settle every question; it is to settle enough that the work can
begin. After the contract decision in §18 it is.

---

*End report 111.*
