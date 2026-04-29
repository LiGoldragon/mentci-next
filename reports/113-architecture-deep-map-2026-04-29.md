# 113 — Architecture deep map: signal · criome · mentci-lib · mentci-egui · nix

*A visual reading of the workspace at end of 2026-04-29 — every claim
verified directly against source. File:line references throughout. Lifetime:
until 112's threads land in the per-repo `ARCHITECTURE.md` files and this
map is no longer the convenient way to see the whole.*

---

## 0 · The four invariants, observed

[criome ARCHITECTURE §2](../repos/criome/ARCHITECTURE.md) defines four
load-bearing invariants. Each is checked against current code below.

| | invariant | how the code embodies it |
|---|---|---|
| **A** | Rust is only an output | grep across criome shows no `.rs` ingester, no prism/codegen path |
| **B** | Nexus is a language, not a record format | criome's wire is `signal::Frame` (rkyv); text crosses only at the nexus-daemon boundary |
| **C** | Sema is the concern; everything orbits | `Engine::State` owns `Arc<Sema>` ([criome/src/engine.rs:38-41](../repos/criome/src/engine.rs#L38-L41)); no fs writes outside sema; effect-bearing work belongs to `forge` (not yet wired) |
| **D** | Perfect specificity | every typed boundary names its kinds — `Records::Node(Vec<(Slot, Node)>)`, `AssertOperation::{Node,Edge,Graph}`, no wrapper enum, no string-tag fallback |

The rest of this report is a structural map of how those invariants are
enforced in practice.

---

## 1 · The whole picture

```
        ┌──────────────────────────────────────────────────────────────────┐
        │                       OUTER USER (Li)                            │
        │     typing nexus text · clicking egui · scripting tests          │
        └──────┬─────────────────────────────────┬─────────────────────────┘
               │                                 │
   ─────── TEXT ──────                ─────── GUI ────────
               │                                 │
   ┌───────────▼────────┐         ┌──────────────▼────────────┐
   │     nexus-cli      │         │       mentci-egui         │  thin shell
   │   (one-shot CLI)   │         │  eframe + tokio runtime   │  repaint @50ms
   └───────────┬────────┘         └──────────────┬────────────┘
               │                                 │
               │ stdin/stdout text               │ depends on
               │                                 ▼
   ┌───────────▼────────┐         ┌───────────────────────────┐
   │   nexus-daemon     │         │       mentci-lib          │  heavy MVU model
   │  (signal ↔ nexus)  │         │  WorkbenchState · view()  │  pure update fn
   │   bright-line      │         │  on_user_event · on_      │  auto-subscribe
   │     scope          │         │   engine_event · Cmd       │  on connect
   └───────────┬────────┘         └──────┬───────────────┬────┘
               │                         │               │
               │ signal::Frame           │ DriverCmd     │ DriverCmd
               │                         ▼               ▼
   ╔══════════════════════════════════════════════════════════════════╗
   ║         ─── UDS WIRE: signal::Frame ───                          ║
   ║   Frame{ principal_hint, auth_proof, body }                       ║
   ║   transport: 4-byte big-endian length prefix · then rkyv bytes    ║
   ║   FIFO position pairing · one Subscribe per connection            ║
   ╚════════════════════╤══════════════════════╤═════════════════════╝
                        │                      │
              /tmp/criome.sock          /tmp/nexus.sock
                        │                      │
              ┌─────────▼──────────┐  ┌────────▼───────────────┐
              │   criome-daemon    │  │     nexus-daemon       │
              │  (state engine)    │  │  "translate signal ↔   │
              │                    │  │   nexus, nothing else" │
              │  ractor actor tree │  └────────────────────────┘
              │   ┌──────────────┐ │
              │   │   Daemon     │ │  supervisor (no msgs)
              │   │      │       │ │
              │   │   ┌──┴───┐   │ │
              │   │   │      │   │ │
              │   │ Engine  Listener
              │   │   │       │   │ │
              │   │   ▼       ▼   │ │
              │   │ Reader  Connection × M
              │   │  × N        │ │ │
              │   │ (MVCC)      │ │ │
              │   └──────────────┘ │
              └─────────┬──────────┘
                        │ Arc<Sema>  (redb MVCC)
                        ▼
                 ┌──────────────┐
                 │     sema     │   typed records DB (redb)
                 │   (the DB)   │   slot-keyed · rkyv-encoded
                 │              │   1-byte kind tag prepended
                 └──────────────┘
```

Length-prefix evidence: [criome/src/connection.rs:78-94](../repos/criome/src/connection.rs#L78-L94)
reads/writes a 4-byte big-endian length per frame; [mentci-lib/src/connection/driver.rs:282-300](../repos/mentci-lib/src/connection/driver.rs#L282-L300)
matches. The rkyv schema is the framing *within* a frame's bytes; the
transport layer slices the stream ([tools-documentation/rust/rkyv.md §"Wire framing"](../repos/tools-documentation/rust/rkyv.md)).

---

## 2 · Wire protocol — [`../repos/signal/`](../repos/signal/)

### 2.1 Frame envelope · [signal/src/frame.rs:28-45](../repos/signal/src/frame.rs#L28-L45)

```
   ┌─── Frame ─────────────────────────────────────────────────────┐
   │  principal_hint : Option<Slot>     (u64 newtype)              │
   │  auth_proof     : Option<AuthProof>                           │
   │  body           : Body                                        │
   │                   ├── Request(Request)                        │
   │                   └── Reply(Reply)                            │
   └───────────────────────────────────────────────────────────────┘

   AuthProof (3): SingleOperator · BlsSignature{ signature, signer }
                  · QuorumProof{ committed }
   rkyv 0.8 features: std + bytecheck + little_endian +
                      pointer_width_32 + unaligned
```

### 2.2 Verbs · [signal/src/request.rs:24-45](../repos/signal/src/request.rs#L24-L45) / replies · [signal/src/reply.rs:32-49](../repos/signal/src/reply.rs#L32-L49)

```
   ┌─── Request (8) ──────────────────────┬─── Reply (5) ──────────────────┐
   │                                       │                                │
   │  Handshake(HandshakeRequest)          │  HandshakeAccepted(reply)      │
   │                                       │  HandshakeRejected(reason)     │
   │  Assert (AssertOperation)             │                                │
   │  Mutate (MutateOperation)       M1+   │  Outcome (OutcomeMessage)      │
   │  Retract(RetractOperation)      M1+   │  Outcomes(Vec<OutcomeMessage>) │
   │  AtomicBatch(AtomicBatch)       M1+   │                                │
   │                                       │  Records(Records)              │
   │  Query    (QueryOperation)            │   ├── Node (Vec<(Slot, Node)>) │
   │  Subscribe(QueryOperation)            │   ├── Edge (Vec<(Slot, Edge)>) │
   │                                       │   └── Graph(Vec<(Slot, Graph)>)│
   │  Validate(ValidateOperation)    M1+   │                                │
   └───────────────────────────────────────┴────────────────────────────────┘

   OutcomeMessage(2):  Ok(Ok) | Diagnostic(Diagnostic{ code, level, … })
   SIGNAL_PROTOCOL_VERSION = 0.1.0  ([signal/src/handshake.rs:23](../repos/signal/src/handshake.rs#L23))
   HandshakeRejectionReason(3): IncompatibleMajor · ClientMinorAhead ·
                                ServerUnavailable
```

The headline: **`Records` carries `Vec<(Slot, T)>`, not `Vec<T>`** —
records on the wire travel with their sema slots so edge endpoints
resolve by lookup. This is the records-with-slots shape that produces
the `(Tuple <slot> (Node "..."))` text form on rendering.

### 2.3 Record-kind atlas (variant counts re-verified against source)

```
 ┌── Flow graph (flow.rs)              ┌── Identity (identity.rs / tweaks.rs)
 │   Node   { name }                   │   Principal { display_name, note }
 │   Edge   { from:Slot, to:Slot,      │   Tweaks    { principal:Slot,
 │            kind:RelationKind }      │              theme:Slot,
 │   Graph  { title, nodes, edges,     │              layout:Slot,
 │            subgraphs }              │              keybinds:Slot }
 │   Ok     { }                        │
 │                                     ├── Style intent (style.rs)
 │   RelationKind (9):                 │   Theme        { display_name +
 │     Flow · DependsOn · Contains     │                  7 IntentTokens }
 │     References · Produces           │   KindStyle    { kind_name, glyph,
 │     Consumes · Calls · Implements   │                  intent }
 │     IsA                             │   RelationKindStyle{ relation, stroke }
 │                                     │
 │                                     │   IntentToken (7):
 │                                     │     NeutralBg · NeutralFg ·
 │                                     │     PrimaryAccent · SecondaryAccent
 │                                     │     Pending · Stale · Rejected
 │                                     │
 │                                     │   GlyphToken (6):
 │                                     │     SourceCircle ⊙ · TransformerSquare ⊡
 │                                     │     SinkSquareX ⊠ · JunctionPlus ⊕
 │                                     │     SupervisorTriangle ▶ · Generic
 │                                     │
 │                                     │   StrokeToken (5):
 │                                     │     SolidOpenArrow · DashedFilledArrow
 │                                     │     ThickBracketArrow · ThinDot · Generic
 │
 ├── Layout (layout.rs)                ┌── Keybinds (keybind.rs)
 │   Layout       { display_name +     │   KeybindMap   { display_name,
 │                  4 SizeIntents +    │                  bindings }
 │                  wire_visible:bool }│   KeybindEntry { input, action }
 │   NodePlacement{ graph:Slot,        │
 │                  node:Slot,         │   ActionToken (11):
 │                  x_hundredths:i64,  │     ToggleWirePane · ToggleTweaksPane
 │                  y_hundredths:i64 } │     PauseWire · ResumeWire
 │                                     │     CancelFlow · CommitFlow
 │   SizeIntent (3):                   │     PinFocused · UnpinFocused
 │     Narrow · Medium · Wide          │     ClearDiagnostics · BeginRename
 │                                     │     RequestRetract
 │
 └── Diagnostic (diagnostic.rs)
     Diagnostic { level, code (E0xxx),
                  message, primary_site, context, suggestions,
                  durable_record:Option<Slot> }
     levels (3):  Error · Warning · Info
     site (3):    Slot · SourceSpan · OperationInBatch
```

Themes describe **intent, not appearance**. Layouts describe **size hints,
not pixels**. Each shell maps the abstract tokens to its native palette
and units — the same Theme record paints correctly in egui today and in
iced/Flutter shells when those land. This is the criome ARCHITECTURE §2D
perfect-specificity discipline applied to visual presentation.

### 2.4 Codec derive vocabulary

| derive | purpose | example types |
|---|---|---|
| `NotaRecord` | data records (per-record text encode/decode) | Node · Edge · Graph · Principal · Theme · Layout · NodePlacement · KeybindMap |
| `NexusVerb` | sigil-dispatched verb payloads | AssertOperation · MutateOperation · QueryOperation |
| `NexusPattern` | `*Query` types using `PatternField<T>` | NodeQuery · EdgeQuery · GraphQuery · PrincipalQuery · ThemeQuery |
| `NotaEnum` | closed unit-only vocabularies | RelationKind · IntentToken · GlyphToken · StrokeToken · ActionToken · SizeIntent · DiagnosticLevel |
| `NotaTransparent` | newtypes that unwrap to inner value | Slot · Revision (both wrap `u64`) |

`PatternField<T>` is `Wildcard | Bind | Match(value)`; the bind name is
implicit from the field's position in its surrounding `*Query` struct.

---

## 3 · State engine — [`../repos/criome/`](../repos/criome/)

### 3.1 Actor supervision tree

```
                  ┌────────── Daemon ─────────┐    [criome/src/daemon.rs]
                  │  no Message variants      │    pure supervisor;
                  └──────┬──────────┬─────────┘    bootstraps in pre_start
                         │          │
                         ▼          ▼
              ┌───────────────┐  ┌──────────────────┐
              │    Engine     │  │     Listener     │   src/listener.rs
              │  Arc<Sema>    │  │  UnixListener    │   self-cast Accept
              │  Vec<Sub>     │  │                  │
              │               │  │  Message: Accept │
              │ Messages (4): │  └────────┬─────────┘
              │  Handshake    │           │ accept() → spawn_linked
              │  Assert       │           ▼
              │  Subscribe    │  ┌──────────────────────┐
              │  DeferredVerb │  │   Connection × M     │
              │               │◄─│  stream + engine ref │  src/connection.rs
              └────┬──────────┘  │  + readers vec       │
                   │             │                      │
       cast        │             │  Messages (2):       │
   SubscriptionPush│             │   ReadNext (self)    │
                   └────────────►│   SubscriptionPush   │
                                 └──────────┬───────────┘
                                            │ pick_reader (round-robin)
                                            ▼
                                 ┌──────────────────────┐
                                 │   Reader × N         │  N = sema.reader_count()
                                 │   Arc<Sema>          │  concurrent via redb MVCC
                                 │                      │
                                 │   Message (1): Query │
                                 └──────────────────────┘
```

Counts verified at source: Daemon 0 · Engine 4 ([criome/src/engine.rs:47-75](../repos/criome/src/engine.rs#L47-L75)) ·
Listener 1 · Connection 2 ([criome/src/connection.rs:42-51](../repos/criome/src/connection.rs#L42-L51)) ·
Reader 1.

Every Message enum is *closed*: no wrapper, no string-tag fallback. This
is the `ractor`-shape recommended in [tools-documentation/rust/ractor.md](../repos/tools-documentation/rust/ractor.md).

### 3.2 The push-on-write loop · [criome/src/engine.rs:93-101](../repos/criome/src/engine.rs#L93-L101)

```
   Connection                        Engine                       Reader (temp State)
   ──────────                        ──────                       ───────────────────

   ReadNext ──► read_frame()
                ├── Subscribe(op):
                │    engine.call(Subscribe{ op,
                │      connection: myself, reply})
                │           ▼              ┐
                │   reader_state           │  initial Records
                │     .handle_query(op)────┤
                │           │              │
                │           └── push Subscription{op, conn} into
                │                state.subscriptions
                │   reply: Records(initial)
                │
                ├── Assert(op) ─► engine.call(Assert{op, reply})
                │                   ├── handle_assert:
                │                   │     prepend_tag(NODE|EDGE|GRAPH, value)
                │                   │     sema.store(&bytes)
                │                   │   → Ok(OkRecord) or E0500/E0501
                │                   │
                │                   ├── if Ok:
                │                   │   push_subscriptions():
                │                   │     for sub in subscriptions (retain):
                │                   │       records = reader_state.handle_query(sub.query)
                │                   │       sub.connection.cast(SubscriptionPush{records})
                │                   │           │
                │                   │           │ if cast fails ──► retain returns false
                │                   │           ▼                   (sub auto-pruned)
                │                   │       (every other live conn)
                │                   │
                │                   └── reply: Outcome(Ok | Diagnostic)
                │
   write_frame()◄┘
                └── self-cast ReadNext (re-arm)

   SubscriptionPush{records} ──► write_frame(Frame{Body::Reply(Records)})
                                 (out-of-band write between ReadNext ticks)
```

Pairing: replies match requests **by FIFO position** — no correlation IDs.
Subscriptions die with their connection; closing the socket prunes them
on the next write via the failed cast.

### 3.3 Status by verb

| verb | status | evidence |
|---|---|---|
| Handshake | wired | [`handle_handshake`](../repos/criome/src/engine.rs#L142-L153) does `is_compatible_with` |
| Assert | wired | [`handle_assert`](../repos/criome/src/engine.rs#L166-L185) prepends kind tag, calls `sema.store` |
| Query | wired | round-robin to Reader pool ([criome/src/connection.rs:125-141](../repos/criome/src/connection.rs#L125-L141)) |
| Subscribe | wired | initial snapshot + ongoing push ([criome/src/engine.rs:248-253](../repos/criome/src/engine.rs#L248-L253)) |
| Mutate · Retract · AtomicBatch · Validate | E0099 stubs | `handle_deferred` returns deferred-verb diagnostic ([criome/src/engine.rs:187-192](../repos/criome/src/engine.rs#L187-L192)) |
| Validator pipeline (schema · refs · invariants · permissions · write · cascade) | skeletons | every `validator/*.rs` file reads `todo!()` |

### 3.4 Sync façade — the testing leverage

`Engine::State::handle_frame(frame) → frame` ([criome/src/engine.rs:107-116](../repos/criome/src/engine.rs#L107-L116))
is the no-actor entrypoint that powers:

- the `criome-handle-frame` one-shot binary (length-prefixed frame on
  stdin → reply frame on stdout, ~30 LoC, the canonical shape from
  [AGENTS.md §"One-shot binaries"](../AGENTS.md))
- the integration tests in `tests/engine.rs` (six tests, no actor system)

This sync façade is what lets the `roundtrip-chain` Nix derivations work:
parse → handle → render across separate OS processes, with `state.redb`
carrying durable state between handle invocations.

### 3.5 Kind-tag scheme

```rust
// criome/src/kinds.rs
pub const NODE:      u8 = 1;
pub const EDGE:      u8 = 2;
pub const GRAPH:     u8 = 3;
pub const KIND_DECL: u8 = 4;   // reserved
```

One byte prepended to each rkyv archive. Reader's `decode_kind::<T>(tag)`
short-circuits non-matching bytes before rkyv bytecheck — bytecheck does
not detect type-punning between same-size archives. M2+ replaces this
with per-kind tables.

---

## 4 · The MVU library — [`../repos/mentci-lib/`](../repos/mentci-lib/)

### 4.1 The cycle

```
   ┌──────────────────────────────────────────────────────────────────────────┐
   │                  SHELL (egui · iced · flutter · …)                       │
   │   ─ owns tokio runtime           ─ owns ConnectionHandles                │
   │   ─ paints WorkbenchView         ─ pushes UserEvents into mentci-lib     │
   │   ─ executes Cmds outside        ─ feeds EngineEvents into mentci-lib    │
   └────────────┬─────────────────────────────────────────────┬───────────────┘
                │                                             │
                ▼                                             ▼
    ┌──────────────────────────────┐         ┌──────────────────────────────┐
    │  on_user_event(ev) →         │         │  on_engine_event(ev) →       │
    │     Vec<Cmd>                 │         │     Vec<Cmd>                 │
    │                              │         │                              │
    │  10 of 31 variants wired:    │         │  5 of 11 variants wired:     │
    │   ToggleWirePane             │         │   CriomeConnected            │
    │   ToggleTweaksPane           │         │     ↳ auto-issue 3 Subscribe │
    │   SelectGraph                │         │       verbs (Graph/Node/Edge │
    │   SelectSlot                 │         │       wildcard)              │
    │   OpenNewNodeFlow            │         │   CriomeDisconnected         │
    │   ConstructorFieldChanged    │         │   NexusConnected             │
    │   ConstructorCommit ─Frame─►│         │   NexusDisconnected           │
    │   ConstructorCancel          │         │   QueryReplied               │
    │   ReconnectCriome / Nexus    │         │     ↳ cache.absorb(records)  │
    │                              │         │                              │
    │  21 fall through to          │         │  6 fall through (Subscription│
    │   Vec::new() (drag, pan,     │         │   Push, OutcomeArrived,      │
    │   zoom, scrub, rename,       │         │   DiagnosticEmitted,         │
    │   retract, batch, …)         │         │   FrameSeen, NexusRendered,  │
    │                              │         │   NexusParsed)               │
    └────────────┬─────────────────┘         └────────────┬─────────────────┘
                 │                                        │
                 └────────────────────┬───────────────────┘
                                      ▼
                 ┌─────────────────────────────────────────────┐
                 │            WorkbenchState                   │   src/state.rs
                 │  connections : ConnectionState              │
                 │  principal   : Slot                         │
                 │  theme       : ThemeState                   │
                 │  layout      : LayoutState                  │
                 │  canvas      : CanvasState                  │
                 │  inspector   : InspectorState               │
                 │  diagnostics : DiagnosticsState             │
                 │  wire        : WireState                    │
                 │  active_constructor : Option<…>             │
                 │  cache       : ModelCache                   │
                 │                                             │
                 │  view(&self) → WorkbenchView (pure snapshot)│
                 └────────────────────┬────────────────────────┘
                                      ▼
                          paint / capture gestures
                          (next frame → top of cycle)
```

Counts verified directly: `UserEvent` has 31 variants ([mentci-lib/src/event.rs:11-91](../repos/mentci-lib/src/event.rs#L11-L91)),
`EngineEvent` has 11 variants ([mentci-lib/src/event.rs:96-122](../repos/mentci-lib/src/event.rs#L96-L122)),
`Cmd` has 8 variants ([mentci-lib/src/cmd.rs:12-38](../repos/mentci-lib/src/cmd.rs#L12-L38)).
The 10/31 + 5/11 wired counts come from reading the match arms in
[on_user_event](../repos/mentci-lib/src/state.rs#L194-L269) and
[on_engine_event](../repos/mentci-lib/src/state.rs#L275-L330) directly.

### 4.2 Driver loop · [mentci-lib/src/connection/driver.rs](../repos/mentci-lib/src/connection/driver.rs)

```
   spawn_driver(runtime, socket_path, role) → ConnectionHandle{events_rx, cmds_tx}

   driver_loop (one async task per daemon):
     ┌────────────────────────────────────────┐
     │ 1. dial UnixStream::connect(path)      │
     │    on err → emit *Disconnected, exit   │
     │                                        │
     │ 2. handshake exchange                  │
     │    write Frame{Request::Handshake}     │
     │    read  Frame{Reply::Handshake…}      │
     │    emit FrameSeen for both directions  │
     │    on Accept → emit *Connected{ver}    │
     │    on Reject → emit *Disconnected      │
     │                                        │
     │ 3. tokio::select! main loop            │
     │     ├── read_frame() arrives           │
     │     │   emit FrameSeen{In}             │
     │     │   emit_inbound_typed(reply):     │
     │     │     Outcome   → OutcomeArrived   │
     │     │     Outcomes  → OutcomeArrived×N │
     │     │     Records   → QueryReplied     │
     │     │   (sub-id tracking is future     │
     │     │    work; today every Records →   │
     │     │    QueryReplied — driver.rs:262) │
     │     │                                  │
     │     └── cmds_rx.recv():                │
     │           DriverCmd::SendFrame(frame): │
     │             emit FrameSeen{Out}        │
     │             write_frame(frame)         │
     │           DriverCmd::Disconnect:       │
     │             break                      │
     │                                        │
     │ 4. emit final *Disconnected            │
     └────────────────────────────────────────┘
```

`FrameDirection` has 3 variants — `Out`, `In`, `SubscriptionPush` ([mentci-lib/src/event.rs:126-130](../repos/mentci-lib/src/event.rs#L126-L130))
— but `SubscriptionPush` is currently unused; today every inbound
`Reply::Records` becomes `EngineEvent::QueryReplied` regardless of whether
it was a one-shot Query reply or a Subscribe push. The `FrameSeen{In|Out}`
events do fire ([driver.rs:118-121, 133-136, 172-175, 195-198](../repos/mentci-lib/src/connection/driver.rs#L118-L121)).

### 4.3 Module map (file → ownership)

```
   src/lib.rs            module exports + crate prelude
   src/state.rs          WorkbenchState · ModelCache · view() · on_*_event
                         · commit_active_constructor · build_flow_graph_view
   src/event.rs          UserEvent (31) · EngineEvent (11) ·
                         FrameDirection · CanvasPos · ConstructorField ·
                         WireFilter
   src/cmd.rs            Cmd (8) · NexusRenderRequest · TimerTag
   src/view.rs           WorkbenchView · HeaderView · GraphsNavView
   src/canvas/mod.rs     CanvasState · KindCanvasState · CanvasView ·
                         CanvasRenderer trait
   src/canvas/flow_graph.rs  FlowGraphCanvasState · FlowGraphView ·
                         RenderedNode · RenderedEdge · KindGlyph ·
                         NodeStateIntent · EdgeStateIntent
   src/connection/mod.rs ConnectionState · PerDaemonState · DaemonStatus ·
                         ConnectionView
   src/connection/driver.rs  spawn_driver · ConnectionHandle · DriverCmd ·
                         DaemonRole · driver_loop · emit_inbound_typed
   src/constructor.rs    ActiveConstructor (5) · NewNodeFlow + view ·
                         NewEdgeFlow + view · RenameFlow + view ·
                         RetractFlow + view · BatchFlow + view
   src/schema.rs         SchemaSource trait · CompiledSchema · FieldDesc ·
                         FieldType (6 variants)
   src/theme.rs          ThemeState · ThemeIntents · ThemeSource
   src/layout.rs         LayoutState · LayoutIntents · LayoutSource
   src/inspector.rs      InspectorState · InspectorView · FocusedSlotView
   src/diagnostics.rs    DiagnosticsState · DiagnosticsView · DiagnosticEntry
   src/wire.rs           WireState · WireView · WireFilter · WireEntry
   src/error.rs          Error (7 variants) · Result<T>
   examples/handshake.rs E2E test, aliased as [[bin]] mentci-handshake-test
```

---

## 5 · The first shell — [`../repos/mentci-egui/`](../repos/mentci-egui/)

### 5.1 The five-step per-frame loop · [mentci-egui/src/app.rs:158-193](../repos/mentci-egui/src/app.rs#L158-L193)

Read directly from source, the steps are numbered 0..5 (the docstring
calls them 1..5; step 0 is the implicit first-frame bootstrap):

```
                  fn update(ctx, _frame)  ── frame N ──┐
                                                       │
   STEP 0 ─ bootstrap_if_needed()                      │
            once: pending_cmds += [ConnectCriome,      │
                                   ConnectNexus]       │
                                                       │
   STEP 1 ─ drain_engine_events()                      │
            try_recv on criome_handle.events_rx        │
            try_recv on nexus_handle.events_rx         │
            for ev: pending_cmds += workbench          │
                    .on_engine_event(ev)               │
                                                       │
   STEP 2 ─ view = workbench.view()                    │
                                                       │
   STEP 3 ─ render::workbench(ctx, &view, &mut         │
                              user_events)             │
            ┌────────────────────────────────────┐     │
            │ TopBottomPanel header              │     │
            │ TopBottomPanel diagnostics (if any)│     │
            │ TopBottomPanel wire (if toggled)   │     │
            │ SidePanel left  graphs_nav         │     │
            │ SidePanel right inspector          │     │
            │ CentralPanel    canvas (kind disp) │     │
            │ Window modal    constructor (if)   │     │
            └────────────────────────────────────┘     │
            each pane writes UserEvents into the vec   │
                                                       │
   STEP 4 ─ for ev in user_events:                     │
            pending_cmds += workbench                  │
                            .on_user_event(ev)         │
                                                       │
   STEP 5 ─ for cmd in take(&mut pending_cmds):        │
            execute_cmd(cmd):                          │
              ConnectCriome  → spawn_driver(rt, sock)  │
              ConnectNexus   → spawn_driver(rt, sock)  │
              SendCriome{f}  → cmds_tx.send(SendFrame) │
              SendNexus{f}   → cmds_tx.send(SendFrame) │
              Disconnect*    → send Disconnect, drop   │
                              handle                   │
              RenderViaNexus·SetTimer → noop           │
                                                       │
   STEP 6 ─ ctx.request_repaint_after(50ms)            │
                                                       │
              ───────────────────────────────► frame N+1
```

The `Cmd::RenderViaNexus | Cmd::SetTimer` arm is explicitly noop today
([mentci-egui/src/app.rs:147-151](../repos/mentci-egui/src/app.rs#L147-L151)) —
"Real wiring lands as the corresponding wire verbs are exercised
end-to-end."

### 5.2 Gestures → UserEvents (what each pane emits today)

| pane | gesture | UserEvent |
|---|---|---|
| header | reconnect chip click | ReconnectCriome / ReconnectNexus |
| header | wire / tweaks toggle | ToggleWirePane / ToggleTweaksPane |
| graphs nav | row click | SelectGraph{slot} |
| canvas (FlowGraph) | "+ node" button | OpenNewNodeFlow |
| diagnostics | clear button | ClearDiagnostics |
| wire | pause / resume button | PauseWire / ResumeWire |
| constructor (NewNode) | kind radio click | ConstructorFieldChanged{EnumChoice} |
| constructor (NewNode) | name typing | ConstructorFieldChanged{Text} |
| constructor | cancel / commit | ConstructorCancel / ConstructorCommit |

The remaining 21 `UserEvent` variants — drag-new-box, drag-wire,
move-node, pan-canvas, zoom-canvas, scrub-time, begin-rename,
commit-rename, request-retract, set-wire-filter, jump-to-diagnostic-target,
pin-slot, unpin-slot, etc. — exist in mentci-lib's enum but no egui
handler emits them yet.

### 5.3 Flow-graph paint · [mentci-egui/src/render/canvas/flow_graph.rs](../repos/mentci-egui/src/render/canvas/flow_graph.rs)

```
   paint(view: &FlowGraphView):
     allocate canvas rect, fill gray(28)

     for each edge in view.edges:
       from = nodes.iter().find(|n| n.slot == edge.from)?    ← real slot lookup
       to   = nodes.iter().find(|n| n.slot == edge.to)?
       draw line center-to-center; label = format!("{:?}", edge.relation_intent)

     for each node in view.nodes:
       rect = (node.at, NODE_W=120, NODE_H=60)
       fill+stroke = node_colours(node.state_intent):
         Stable   → gray(48)        / gray(120)
         Pending  → rgb(60,50,30)   / rgb(220,180,90)   yellow-brown
         Stale    → rgb(40,40,50)   / rgb(140,140,200)  blue
         Rejected → rgb(60,30,30)   / rgb(220,90,90)    red
       glyph = glyph_char(node.kind_glyph):
         Source ⊙  Transformer ⊡  Sink ⊠  Junction ⊕  Supervisor ▶  Unknown ○

     if nodes empty: hint text "(this graph has no member records yet)"
```

The slot-lookup-then-draw is the consumer side of records-with-slots:
edges on the wire carry `(Slot, Edge)` pairs, mentci-lib's `RenderedEdge`
keeps the `from`/`to` slots untouched ([mentci-lib/src/state.rs:438-448](../repos/mentci-lib/src/state.rs#L438-L448)),
and the paint layer resolves them at draw time. If a slot isn't in the
cached node set, the edge is silently skipped.

---

## 6 · End-to-end constructor flow (gesture → push back to all subscribers)

```
   user clicks "+ node" in canvas pane
          │
          ▼
   UserEvent::OpenNewNodeFlow                      (mentci-egui captures)
          │
          ▼
   workbench.on_user_event(OpenNewNodeFlow):       state.rs:223-242
     active_constructor := Some(NewNode(NewNodeFlow{ graph: focus, … }))
     returns Vec::new()
          │
          ▼
   next view():
     constructor: Some(ConstructorView::NewNode{
       kind_choices=["Node"], commit_enabled=false })
          │
          ▼
   egui paints centered modal: kind picker + name field + cancel/commit
          │
   ─── user types "double" ────
          │
          ▼
   UserEvent::ConstructorFieldChanged{Text{ field_name:"name", value:"double" }}
          │
          ▼
   state mutates display_name_input; commit_enabled flips true        (state.rs:243-253)
          │
   ─── user clicks "commit" ────
          │
          ▼
   UserEvent::ConstructorCommit
          │
          ▼
   workbench.on_user_event(ConstructorCommit):                        (state.rs:255-258)
     → commit_active_constructor():                                   (state.rs:337-367)
         NewNode flow → Frame{ Body::Request(Assert(Node{name:"double"})) }
         returns vec![Cmd::SendCriome{ frame }]
          │
          ▼
   execute_cmd(SendCriome{frame}):                                    (mentci-egui/src/app.rs:129-137)
     criome_handle.cmds_tx.send(DriverCmd::SendFrame(frame))
          │
          ▼ (across UDS)

   criome Connection actor's ReadNext tick:
     Request::Assert(Node) → engine.call(Assert{op})                  (criome/src/connection.rs:113-124)
          │
          ▼
   engine.handle_assert:                                              (criome/src/engine.rs:166-185)
     prepend_tag(NODE, value); sema.store(bytes); → Ok(OkRecord)
          │
          ├─► reply Outcome(Ok) → write_frame to *this* connection
          │
          └─► push_subscriptions():                                   (criome/src/engine.rs:93-101)
                for each subscription (the auto-subscribed
                Graph/Node/Edge wildcards from every connected client):
                  records = reader.handle_query(sub.query)  ← includes new node
                  sub.connection.cast(SubscriptionPush{records})
          │
          ▼ (for this connection)

   Connection's handle(SubscriptionPush{records}):                    (criome/src/connection.rs:202-213)
     write_frame(Frame{ Body::Reply(Records) })
          │
          ▼ (across UDS)

   driver_loop's read branch picks up Records:                        (mentci-lib/src/connection/driver.rs:169-182)
     emit FrameSeen{In, frame}
     emit_inbound_typed: Records → QueryReplied{ records }            (driver.rs:259-271)
          │
          ▼
   next frame's STEP 1:
     workbench.on_engine_event(QueryReplied) → cache.absorb(records)  (state.rs:321-323)
          │
          ▼
   next frame's STEP 2:
     view() rebuilds GraphsNavView + FlowGraphView from cache
          │
   next frame's STEP 3:
     canvas paints "double" node at next grid cell
     constructor pane closes (active_constructor = None on commit)
```

Round-trip is bounded only by tokio scheduling + UDS hop + redb write —
microseconds. The perceived latency floor is `request_repaint_after(50ms)`.

---

## 7 · Nix derivation graph

```
   ┌─── flake.nix ────────────────────────────────────────────────────────┐
   │  inputs (blueprint-driven):                                          │
   │   nota-derive  nota-codec  signal  sema  criome  nexus  nexus-cli    │
   │   mentci-lib   mentci-egui                                           │
   │  outputs = blueprint { inherit inputs; }                             │
   │                                                                      │
   │  blueprint auto-discovers:                                           │
   │   - checks/*.nix → checks.${system}.<file-stem>                      │
   │   - devshell.nix → devShells.${system}.default                       │
   │   - lib/default.nix → lib.* (currently lib.scenario)                 │
   └──────────────────────────────────────────────────────────────────────┘

   crate-checks linkFarm                                Workspace E2E checks
   ─────────────────────                                ────────────────────

   checks/default.nix                                   checks/integration.nix
       ├── nota-derive/checks.default                       fast loop, no chain
       ├── nota-codec/checks.default                        spawn both daemons,
       ├── signal/checks.default                            pipe demo, assert
       ├── sema/checks.default                              `(Tuple <slot> ...)`
       ├── criome/checks.default
       ├── nexus/checks.default                         checks/scenario-mentci-
       ├── nexus-cli/checks.default                       lib-handshake.nix
       ├── mentci-lib/checks.default                        E2E criome ↔ lib
       └── mentci-egui/checks.default                       greps event stream

                                                        scenario-chain (text):
                                                          assert-node ──┐
                                                                        ▼
                                                          query-nodes ─► chain
                                                          (state.redb forwarded
                                                           via priorState arg)

                                                        roundtrip-chain (binary):
                                                          ┌─ assert-parse ─┐
                                                          │       ▼        │
                                                          │  assert-handle ┤
                                                          │       │        │
                                                          │       ▼  state.redb
                                                          │  assert-render ┤
                                                          │                │
                                                          ├─ query-parse ──┤
                                                          │       ▼        │
                                                          │  query-handle ─┤
                                                          │       ▼        │
                                                          │  query-render ─┘
                                                          │
                                                          └─► roundtrip-chain
                                                              greps both texts
```

Total `nix flake check` derivations: 9 crate checks + 5 workspace checks
= 14, all green from cold cache (per [reports/112 §2.3](112-session-handoff-2026-04-29.md)).

### 7.1 The eframe nix dance · [mentci-egui/flake.nix:30-67](../repos/mentci-egui/flake.nix#L30-L67)

```
   guiBuildInputs = libxkbcommon · libGL · vulkan-loader · wayland ·
                    xorg.{libX11,libXcursor,libXi,libXrandr,libxcb} ·
                    fontconfig
   guiNativeBuildInputs = pkg-config
   runtimeLibPath = pkgs.lib.makeLibraryPath guiBuildInputs

   packages.default:
     postInstall: wrapProgram $out/bin/mentci-egui
                    --prefix LD_LIBRARY_PATH : "${runtimeLibPath}"
     (because eframe dlopens libwayland-client + libxkbcommon at runtime)

   devShells.default:
     LD_LIBRARY_PATH = runtimeLibPath
     (so `cargo run` works without the wrapper)
```

### 7.2 Toolchain pin

All four flakes I checked (criome, signal, mentci-lib, mentci-egui) pin
`rust-toolchain.toml` channel to `"stable"` — uniform across the
workspace today. Per [tools-documentation/rust/nix-packaging.md](../repos/tools-documentation/rust/nix-packaging.md)
the convention is `channel = "stable"` floating with upstream; pin to an
explicit version at release time when bit-for-bit reproducibility matters.

---

## 8 · Where the rough edges are

Five things a fresh agent should expect to find half-finished:

1. **Driver doesn't tag subscription pushes.** Both `Reply::Records` from
   a Query and from a Subscribe push arrive at the model as
   `EngineEvent::QueryReplied`. Sub-id tracking is the next driver-level
   evolution — explicit comment at [driver.rs:262-266](../repos/mentci-lib/src/connection/driver.rs#L262-L266).

2. **Constructor commits are NewNode-only.** NewEdge / Rename / Retract /
   Batch flows have state, view, modal — but their commit bodies just
   put the flow back without producing a Cmd ([state.rs:339-365](../repos/mentci-lib/src/state.rs#L339-L365)).
   Drag-wire is the natural next one: NewEdge slot exists; needs an
   `Assert(Edge)` body.

3. **Schema knowledge is `todo!()`.** `CompiledSchema::kinds()` and
   `fields_of()` panic; `constructor_view_for` surfaces a hardcoded
   `["Node"]` palette ([state.rs:464-468](../repos/mentci-lib/src/state.rs#L464-L468)).
   Wiring this to signal's compile-time record types is the immediate
   next step; wiring it to schema-in-sema is the medium-term shape.

4. **Theme/Layout records aren't applied.** mentci-lib has
   `ThemeState::builtin_default()` and `LayoutState::builtin_default()`
   ([state.rs:105-110](../repos/mentci-lib/src/state.rs#L105-L110)); the
   path from a Theme record in sema to `ThemeIntents` in `ThemeState`
   isn't wired. Egui paint uses hardcoded gray(28)/gray(48) colours, not
   the IntentToken-mapped palette.

5. **Nexus-daemon connection is dialed but unused.** mentci-egui spawns
   a driver for `/tmp/nexus.sock` and the connection handshakes
   successfully — but `Cmd::RenderViaNexus` is a noop ([app.rs:147-151](../repos/mentci-egui/src/app.rs#L147-L151))
   and inspector/wire panes never show "[as nexus]" lines. The driver
   is ready; the rendering Cmd flow is what's missing.

The criome side has Mutate / Retract / AtomicBatch as E0099 stubs; until
they land, deletions and edits are invisible to subscribers.

---

## 9 · Lifetime

This map lives until 112's threads land in `criome/ARCHITECTURE.md`,
`mentci-lib/ARCHITECTURE.md`, and `mentci-egui/ARCHITECTURE.md`. At that
point the per-repo files carry the picture in code and this report folds
into a forward-pointing successor or gets deleted (default: deletion, per
[AGENTS.md §"Report rollover"](../AGENTS.md)).

*End report 113.*
