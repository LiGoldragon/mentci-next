# 102 — Visual architecture: per-repo internals + cross-repo interactions

*Per Li 2026-04-27: "create a high-level visual representation
of the workings of every repo, and then a visual of how they
interact together, showing the datatypes, methods and their
signatures."*

This is a comprehensive visual reference for the M0 system as
shipped this session. Per-repo diagrams show types, methods,
and signatures; cross-repo diagrams show the dependency graph,
the running-process graph, and the per-request type flow.

All diagrams are Mermaid — render in Codium, GitHub, or any
CommonMark + Mermaid viewer.

---

## 1 · Cross-repo crate dependency graph

How the seven CANON crates depend on each other. `nota-codec`
and `nota-derive` form the codec layer; `signal` is the wire
schema; `sema` is the record store; `criome` and `nexus` are
the two daemons; `nexus-cli` is the text-shuttle client.

```mermaid
flowchart TD
    subgraph CodecLayer["Layer 0 — text codec"]
        notaderive["nota-derive<br/>(proc-macro)"]
        notacodec["nota-codec<br/>(runtime)"]
    end

    subgraph SchemaLayer["Layer 1 — schema vocabulary"]
        signal["signal<br/>(typed payloads + wire envelope)"]
    end

    subgraph StorageLayer["Layer 2 — record store"]
        sema["sema<br/>(redb-backed records)"]
    end

    subgraph DaemonLayer["Layer 3 — daemons"]
        criome["criome<br/>(validator + dispatcher)"]
        nexus["nexus<br/>(text translator)"]
    end

    subgraph ClientLayer["Layer 4 — text client"]
        nexuscli["nexus-cli<br/>(byte shuttle)"]
    end

    notacodec -->|re-exports six derives| notaderive
    signal -->|"NotaEncode/NotaDecode<br/>+ derives"| notacodec
    criome -->|"Frame, Request, Reply,<br/>typed payloads"| signal
    criome -->|"Sema::open/store/get/iter"| sema
    nexus -->|"Frame, Request, Reply"| signal
    nexus -->|"Decoder/Encoder"| notacodec
    nexuscli -.->|"plain UDS bytes<br/>(no signal dep)"| nexus
```

**Key:** dotted line = process-to-process socket boundary; solid
arrow = compile-time crate dependency.

`nexus-cli` deliberately has no `signal` or `nota-codec`
dependency — it is a pure byte shuttle per
[`nexus-cli/ARCHITECTURE.md`](../repos/nexus-cli/ARCHITECTURE.md)
§Boundaries.

---

## 2 · Cross-repo running-process graph

Three processes at runtime: the user invokes `nexus-cli`,
which connects to the long-running `nexus` daemon, which in
turn opens a paired connection to the long-running `criome`
daemon. Each socket carries a different format.

```mermaid
flowchart LR
    user(["user / agent / script"])

    subgraph NexusCLIProc["nexus-cli process<br/>(one-shot)"]
        client["Client::shuttle"]
    end

    subgraph NexusDaemonProc["nexus daemon process<br/>(long-running)"]
        ndaemon["Daemon::run"]
        nconn["Connection::shuttle<br/>(one task per accept)"]
    end

    subgraph CriomeDaemonProc["criome daemon process<br/>(long-running)"]
        clistener["Listener::run"]
        cdaemon["Daemon::handle_frame"]
    end

    subgraph SemaDB["sema database<br/>(redb file)"]
        records[("records table<br/>+ meta table")]
    end

    user -->|".nexus text<br/>via stdin or file"| client
    client -->|"text bytes<br/>UDS /tmp/nexus.sock"| ndaemon
    ndaemon -->|"spawns task"| nconn
    nconn -->|"length-prefixed Frame<br/>UDS /tmp/criome.sock"| clistener
    clistener -->|"per-frame call"| cdaemon
    cdaemon -->|"store/get/iter"| records
    records -->|"bytes"| cdaemon
    cdaemon -->|"Reply Frame"| clistener
    clistener -->|"length-prefixed Frame"| nconn
    nconn -->|"rendered text bytes"| client
    client -->|"stdout"| user
```

**Sockets:**
- `/tmp/nexus.sock` — pure nexus text. No framing other than
  matched parens. The CLI half-closes its write side after
  sending; the daemon reads to EOF, processes, writes the
  rendered reply, closes.
- `/tmp/criome.sock` — length-prefixed signal Frames (4-byte
  big-endian length + N rkyv bytes per
  [`signal/ARCHITECTURE.md`](../repos/signal/ARCHITECTURE.md)
  §"Wire format"). Replies pair to requests by FIFO position.

---

## 3 · Cross-repo type flow per request

What types travel through each boundary for a single
`(Node "User")` round-trip. This sequence shows the same
journey as §2 but typed — at every arrow you can see the
exact type that crosses.

```mermaid
sequenceDiagram
    participant User as user
    participant Cli as nexus-cli<br/>Client
    participant NDaemon as nexus daemon<br/>Daemon → Connection
    participant Parser as nexus<br/>Parser
    participant Link as nexus<br/>CriomeLink
    participant Renderer as nexus<br/>Renderer
    participant CListener as criome<br/>Listener
    participant CDaemon as criome<br/>Daemon
    participant Sema as sema<br/>Sema

    User->>Cli: "(Node \"User\")"<br/>(text bytes)
    Cli->>NDaemon: text bytes via UnixStream
    NDaemon->>Parser: Parser::new(&text)
    Parser-->>NDaemon: Request::Assert(<br/>AssertOperation::Node(Node{name:"User"}))

    Note over NDaemon,Link: First request opens link
    NDaemon->>Link: CriomeLink::open(criome_socket)
    Link->>CListener: Frame{Body::Request(<br/>Request::Handshake(...))}
    CListener->>CDaemon: handle_frame(Frame)
    CDaemon-->>CListener: Frame{Body::Reply(<br/>Reply::HandshakeAccepted(...))}
    CListener-->>Link: Frame
    Link-->>NDaemon: CriomeLink (post-handshake)

    NDaemon->>Link: link.send(Request::Assert(...))
    Link->>CListener: Frame{Body::Request(<br/>Request::Assert(AssertOperation::Node(...)))}
    CListener->>CDaemon: handle_frame(Frame)
    CDaemon->>CDaemon: handle_request → handle_assert
    CDaemon->>Sema: sema.store(tagged_bytes) → Slot
    Sema-->>CDaemon: Result<Slot>
    CDaemon-->>CListener: Frame{Body::Reply(<br/>Reply::Outcome(<br/>OutcomeMessage::Ok(Ok)))}
    CListener-->>Link: Frame
    Link-->>NDaemon: Reply::Outcome(<br/>OutcomeMessage::Ok(Ok))

    NDaemon->>Renderer: render_reply(&reply)
    Renderer-->>NDaemon: () (output buffer now contains "(Ok)")
    NDaemon->>Cli: text bytes "(Ok)"
    Cli->>User: stdout "(Ok)"
```

---

## 4 · `nota-codec` — typed text codec

The runtime half of the codec stack. Decoder + Encoder + the
two traits + blanket impls + `PatternField`. Re-exports the
six derives from `nota-derive` so users depend on a single
crate.

### 4a · Public types and methods

```mermaid
classDiagram
    %% ─── Lexer & Token ───
    class Dialect {
        <<enum>>
        Nota
        Nexus
    }

    class Token {
        <<enum>>
        LParen
        RParen
        LBracket
        RBracket
        Equals
        Colon
        Bool(bool)
        Int(i128)
        UInt(u128)
        Float(f64)
        Str(String)
        Bytes(Vec~u8~)
        Ident(String)
        Tilde
        At
        Bang
        Question
        Star
        LBrace
        RBrace
        LBracePipe
        RBracePipe
        LParenPipe
        RParenPipe
        LBracketPipe
        RBracketPipe
    }

    class Lexer {
        -input: &str
        -pos: usize
        -dialect: Dialect
        +new(input: &str) Lexer
        +nexus(input: &str) Lexer
        +with_dialect(input: &str, dialect: Dialect) Lexer
        +dialect() Dialect
        +next_token() Result~Option~Token~~
    }

    %% ─── Decoder ───
    class Decoder {
        -lexer: Lexer
        -pushback: VecDeque~Token~
        +nexus(input: &str) Decoder
        +nota(input: &str) Decoder
        +read_u64() Result~u64~
        +read_u32() Result~u32~
        +read_u16() Result~u16~
        +read_u8() Result~u8~
        +read_i64() Result~i64~
        +read_i32() Result~i32~
        +read_i16() Result~i16~
        +read_i8() Result~i8~
        +read_f64() Result~f64~
        +read_f32() Result~f32~
        +read_bytes() Result~Vec~u8~~
        +read_pascal_identifier() Result~String~
        +read_string() Result~String~
        +read_bool() Result~bool~
        +expect_record_head(expected) Result~()~
        +expect_record_end() Result~()~
        +expect_pattern_record_head(expected) Result~()~
        +expect_pattern_record_end() Result~()~
        +decode_pattern_field~T~(expected_bind_name) Result~PatternField~T~~
        +peek_is_wildcard() Result~bool~
        +consume_wildcard() Result~()~
        +peek_is_bind_marker() Result~bool~
        +peek_is_record_end() Result~bool~
        +peek_is_explicit_none() Result~bool~
        +consume_explicit_none() Result~()~
        +expect_seq_start() Result~()~
        +expect_seq_end() Result~()~
        +peek_is_seq_end() Result~bool~
        +peek_token() Result~Option~Token~~
        +peek_record_head() Result~String~
    }

    %% ─── Encoder ───
    class Encoder {
        -output: String
        -dialect: Dialect
        -needs_space: bool
        +nexus() Encoder
        +nota() Encoder
        +into_string(self) String
        +write_u64(value: u64) Result~()~
        +write_i64(value: i64) Result~()~
        +write_f64(value: f64) Result~()~
        +write_bytes(bytes: &[u8]) Result~()~
        +write_pascal_identifier(name: &str) Result~()~
        +write_string(value: &str) Result~()~
        +write_bool(value: bool) Result~()~
        +start_record(name: &str) Result~()~
        +end_record() Result~()~
        +start_pattern_record(name: &str) Result~()~
        +end_pattern_record() Result~()~
        +encode_pattern_field~T~(field, bind_name) Result~()~
        +write_wildcard() Result~()~
        +write_bind(name: &str) Result~()~
        +start_seq() Result~()~
        +end_seq() Result~()~
    }

    %% ─── Traits ───
    class NotaEncode {
        <<trait>>
        +encode(encoder: &mut Encoder) Result~()~
    }

    class NotaDecode {
        <<trait>>
        +decode(decoder: &mut Decoder) Result~Self~
    }

    %% ─── PatternField ───
    class PatternField {
        <<enum>>
        Wildcard
        Bind
        Match(T)
    }

    %% ─── Error ───
    class Error {
        <<enum>>
        Lexer(String)
        UnexpectedToken
        ExpectedRecordHead
        WrongBindName
        UnknownVariant
        UnknownKindForVerb
        UnexpectedEnd
        Validation
        IntegerOutOfRange
    }

    Decoder --> Lexer
    Decoder --> Token
    Decoder --> PatternField
    Encoder --> PatternField
    PatternField ..|> NotaEncode
    PatternField ..|> NotaDecode

    note for NotaEncode "Blanket impls for primitives + containers:\nu8/u16/u32/u64/i8/i16/i32/i64/f32/f64/bool/String\nOption~T~ Vec~T~ BTreeMap~K,V~ HashMap~K,V~\nBTreeSet~T~ HashSet~T~ Box~T~ tuples (A,B) (A,B,C) (A,B,C,D)"
```

### 4b · Module relationships

```mermaid
flowchart TD
    lib["lib.rs<br/>(re-exports + Result alias)"]
    lexer["lexer.rs<br/>(Lexer, Token, Dialect)"]
    decoder["decoder.rs<br/>(Decoder + protocol)"]
    encoder["encoder.rs<br/>(Encoder + protocol)"]
    traits["traits.rs<br/>(NotaEncode, NotaDecode)<br/>+ blanket impls"]
    error["error.rs<br/>(Error enum)"]
    pattern["pattern_field.rs<br/>(PatternField~T~)"]

    lib --> lexer
    lib --> decoder
    lib --> encoder
    lib --> traits
    lib --> error
    lib --> pattern

    decoder --> lexer
    decoder --> error
    decoder --> pattern
    encoder --> error
    encoder --> pattern
    traits --> decoder
    traits --> encoder
    traits --> error
```

---

## 5 · `nota-derive` — proc-macro derives

Six derives that map any record kind to its wire form by
emitting `NotaEncode` + `NotaDecode` impls (and conversions
where applicable).

### 5a · Derive table

| Derive | Accepts | Emits | Wire form | Use site (signal types) |
|---|---|---|---|---|
| `NotaRecord` | named-field struct or unit struct | `NotaEncode` + `NotaDecode` | `(TypeName field0 field1 …)` | `Node`, `Edge`, `Graph`, `Ok`, `KindDecl`, `FieldDecl`, `RetractOperation` |
| `NotaEnum` | unit-variant enum | `NotaEncode` + `NotaDecode` | PascalCase identifier (`Flow`, `DependsOn`, …) | `RelationKind`, `Cardinality`, `DiagnosticLevel`, `Applicability` |
| `NotaTransparent` | tuple struct, single field | `NotaEncode` + `NotaDecode` + `From<inner>` + `From<Self> for inner` | bare inner value (invisible wrapper) | `Slot`, `Revision` |
| `NotaTryTransparent` | tuple struct + `fn try_new(inner) -> Result<Self, E>` | `NotaEncode` + `NotaDecode` + `From<Self> for inner` (no `From<inner>`) | bare inner value (validated) | (schema support; no current site) |
| `NexusPattern` | named-field struct of `PatternField<T>` + `#[nota(queries = "Name")]` | `NotaEncode` + `NotaDecode` | `(\| RecordName field0 field1 … \|)` | `NodeQuery`, `EdgeQuery`, `GraphQuery`, `KindDeclQuery` |
| `NexusVerb` | closed enum (newtype or struct variants) | `NotaEncode` + `NotaDecode` | variant name as record head; peeks head for dispatch | `AssertOperation`, `MutateOperation`, `QueryOperation`, `BatchOperation` |

### 5b · Derive expansion path

```mermaid
flowchart TD
    A["User type<br/>#[derive(NotaRecord)]"] --> B["nota-derive<br/>proc-macro"]
    B --> C["DeriveInput parse"]
    C --> D{"Dispatch by<br/>derive name"}
    D --> E1["NotaRecord<br/>field iteration"]
    D --> E2["NotaEnum<br/>variant matching"]
    D --> E3["NotaTransparent<br/>inner-type extraction"]
    D --> E4["NotaTryTransparent<br/>+ try_new path"]
    D --> E5["NexusPattern<br/>PatternField fields"]
    D --> E6["NexusVerb<br/>variant-head dispatch"]
    E1 --> F["quote! → TokenStream"]
    E2 --> F
    E3 --> F
    E4 --> F
    E5 --> F
    E6 --> F
    F --> G["impl NotaEncode for T<br/>impl NotaDecode for T<br/>(+ From conversions for transparent variants)"]
    G --> H["compiled into user crate"]
```

### 5c · Attribute

`NexusPattern` is the only derive that requires an attribute:
`#[nota(queries = "Name")]` names the data record whose wire
form (not the query type's Rust name) appears in the
pattern-record encoding. Used by every `*Query` type in
`signal`.

---

## 6 · `signal` — wire envelope + per-verb typed payloads

All types derive `Archive + RkyvSerialize + RkyvDeserialize`
for wire transport. Stereotypes (`<<NotaRecord>>`, `<<NexusVerb>>`,
etc.) indicate which `nota-codec` derive each type uses for
its text form.

### 6a · Wire envelope

```mermaid
classDiagram
    class Frame {
        principal_hint: Option~Slot~
        auth_proof: Option~AuthProof~
        body: Body
        +encode() Vec~u8~
        +decode(bytes: &[u8]) Result~Frame, FrameDecodeError~
    }

    class Body {
        <<enum>>
        Request(Request)
        Reply(Reply)
    }

    class FrameDecodeError {
        <<error>>
        BadArchive
    }

    Frame --> Body
    Frame --> AuthProof
    Frame --> FrameDecodeError
```

### 6b · Request and Reply

```mermaid
classDiagram
    class Request {
        <<enum>>
        Handshake(HandshakeRequest)
        Assert(AssertOperation)
        Mutate(MutateOperation)
        Retract(RetractOperation)
        AtomicBatch(AtomicBatch)
        Query(QueryOperation)
        Subscribe(QueryOperation)
        Validate(ValidateOperation)
    }

    class Reply {
        <<enum>>
        HandshakeAccepted(HandshakeReply)
        HandshakeRejected(HandshakeRejectionReason)
        Outcome(OutcomeMessage)
        Outcomes(Vec~OutcomeMessage~)
        Records(Records)
    }

    class HandshakeRequest {
        client_version: ProtocolVersion
        client_name: String
    }

    class HandshakeReply {
        server_version: ProtocolVersion
        server_id: Slot
    }

    class ProtocolVersion {
        major: u16
        minor: u16
        patch: u16
        +is_compatible_with(server) bool
    }

    class HandshakeRejectionReason {
        <<enum>>
        IncompatibleMajor
        ClientMinorAhead
        ServerUnavailable
    }

    class OutcomeMessage {
        <<enum>>
        Ok(Ok)
        Diagnostic(Diagnostic)
    }

    class Records {
        <<enum>>
        Node(Vec~Node~)
        Edge(Vec~Edge~)
        Graph(Vec~Graph~)
        KindDecl(Vec~KindDecl~)
    }

    class ValidateOperation {
        operation: Box~BatchOperation~
    }

    Request --> HandshakeRequest
    Request --> AssertOperation
    Request --> MutateOperation
    Request --> RetractOperation
    Request --> AtomicBatch
    Request --> QueryOperation
    Request --> ValidateOperation
    Reply --> HandshakeReply
    Reply --> HandshakeRejectionReason
    Reply --> OutcomeMessage
    Reply --> Records
    HandshakeRequest --> ProtocolVersion
    HandshakeReply --> ProtocolVersion
```

### 6c · Per-verb operation enums

```mermaid
classDiagram
    class AssertOperation {
        <<NexusVerb>>
        Node(Node)
        Edge(Edge)
        Graph(Graph)
        KindDecl(KindDecl)
    }

    class MutateOperation {
        <<NexusVerb>>
        Node{slot, new, expected_rev}
        Edge{slot, new, expected_rev}
        Graph{slot, new, expected_rev}
        KindDecl{slot, new, expected_rev}
    }

    class RetractOperation {
        <<NotaRecord>>
        slot: Slot
        expected_rev: Option~Revision~
    }

    class AtomicBatch {
        <<rkyv-only>>
        operations: Vec~BatchOperation~
    }

    class BatchOperation {
        <<rkyv-only>>
        Assert(AssertOperation)
        Mutate(MutateOperation)
        Retract(RetractOperation)
    }

    class QueryOperation {
        <<NexusVerb>>
        Node(NodeQuery)
        Edge(EdgeQuery)
        Graph(GraphQuery)
        KindDecl(KindDeclQuery)
    }

    AssertOperation --> Node
    AssertOperation --> Edge
    AssertOperation --> Graph
    AssertOperation --> KindDecl
    MutateOperation --> Slot
    MutateOperation --> Revision
    RetractOperation --> Slot
    RetractOperation --> Revision
    BatchOperation --> AssertOperation
    BatchOperation --> MutateOperation
    BatchOperation --> RetractOperation
    AtomicBatch --> BatchOperation
    QueryOperation --> NodeQuery
    QueryOperation --> EdgeQuery
    QueryOperation --> GraphQuery
    QueryOperation --> KindDeclQuery
```

### 6d · Data kinds + supporting types

```mermaid
classDiagram
    class Node {
        <<NotaRecord>>
        name: String
    }

    class Edge {
        <<NotaRecord>>
        from: Slot
        to: Slot
        kind: RelationKind
    }

    class Graph {
        <<NotaRecord>>
        title: String
        nodes: Vec~Slot~
        edges: Vec~Slot~
        subgraphs: Vec~Slot~
    }

    class NodeQuery {
        <<NexusPattern>>
        name: PatternField~String~
    }

    class EdgeQuery {
        <<NexusPattern>>
        from: PatternField~Slot~
        to: PatternField~Slot~
        kind: PatternField~RelationKind~
    }

    class GraphQuery {
        <<NexusPattern>>
        title: PatternField~String~
    }

    class RelationKind {
        <<NotaEnum>>
        Flow
        DependsOn
        Contains
        References
        Produces
        Consumes
        Calls
        Implements
        IsA
    }

    class KindDecl {
        <<NotaRecord>>
        name: String
        fields: Vec~FieldDecl~
    }

    class FieldDecl {
        <<NotaRecord>>
        name: String
        type_name: String
        cardinality: Cardinality
    }

    class Cardinality {
        <<NotaEnum>>
        One
        Many
        Optional
    }

    class KindDeclQuery {
        <<NexusPattern>>
        name: PatternField~String~
    }

    class Slot {
        <<NotaTransparent>>
        -value: u64
        +from(u64) Slot
        +into() u64
    }

    class Revision {
        <<NotaTransparent>>
        -value: u64
        +from(u64) Revision
        +into() u64
    }

    class Hash {
        <<type alias>>
        [u8; 32]
    }

    class Ok {
        <<NotaRecord>>
    }

    class Diagnostic {
        level: DiagnosticLevel
        code: String
        message: String
        primary_site: Option~DiagnosticSite~
        context: Vec~(String, String)~
        suggestions: Vec~DiagnosticSuggestion~
        durable_record: Option~Slot~
    }

    class DiagnosticLevel {
        <<NotaEnum>>
        Error
        Warning
        Info
    }

    class DiagnosticSite {
        <<enum>>
        Slot(Slot)
        SourceSpan{offset, length, source}
        OperationInBatch(u32)
    }

    Node --> NodeQuery
    Edge --> EdgeQuery
    Edge --> Slot
    Edge --> RelationKind
    Graph --> GraphQuery
    Graph --> Slot
    KindDecl --> FieldDecl
    FieldDecl --> Cardinality
    Diagnostic --> DiagnosticLevel
    Diagnostic --> DiagnosticSite
    DiagnosticSite --> Slot
```

---

## 7 · `sema` — record store

Single-file crate. `Sema::open / store / get / iter` over a
redb-backed records table + a meta table holding the slot
counter.

```mermaid
classDiagram
    class Sema {
        -database: Database
        +open(path: &Path) Result~Sema~
        +store(record_bytes: &[u8]) Result~Slot~
        +get(slot: Slot) Result~Option~Vec~u8~~~
        +iter() Result~Vec~(Slot, Vec~u8~)~~
    }

    class Slot {
        -0: u64
        +from(u64) Slot
        +into() u64
    }

    class Error {
        <<enum>>
        Database(redb::DatabaseError)
        Storage(redb::StorageError)
        Transaction(redb::TransactionError)
        Table(redb::TableError)
        Commit(redb::CommitError)
        MissingSlotCounter
    }

    class SEED_RANGE_END {
        <<const>>
        u64 = 1024
    }

    Sema --> Slot
    Sema --> Error
```

```mermaid
flowchart LR
    Sema["Sema<br/>(open/store/get/iter)"]
    DB["redb Database"]
    Records[("records table<br/>u64 → bytes")]
    Meta[("meta table<br/>str → u64<br/>slot counter")]

    Sema --> DB
    DB --> Records
    DB --> Meta
```

---

## 8 · `nexus` — text translator daemon

Five nouns. `Daemon` is the long-running entry; `Connection`
runs per accepted client; `CriomeLink` encapsulates the
post-handshake invariant; `Parser` and `Renderer` own the
text-↔-typed boundary.

### 8a · Nouns

```mermaid
classDiagram
    class Daemon {
        -listen_path: PathBuf
        -criome_socket_path: PathBuf
        +new(listen, criome) Self
        +run(self) Result~()~
    }

    class Connection {
        -client: UnixStream
        -criome_socket_path: PathBuf
        +new(client, criome_socket_path) Self
        +shuttle(self) Result~()~
        -process(text_input, criome_socket_path) Result~Renderer~
    }

    class CriomeLink {
        -stream: UnixStream
        +open(socket_path: &Path) Result~CriomeLink~
        +send(request: Request) Result~Reply~
        -handshake() Result~()~
        -write_frame(frame: &Frame) Result~()~
        -read_frame() Result~Frame~
    }

    class Parser {
        -decoder: Decoder~'input~
        +new(input: &str) Self
        +next_request() Result~Option~Request~~
    }

    class Renderer {
        -output: String
        +new() Self
        +render_reply(reply: &Reply) Result~()~
        +render_local_error(error: &Error) Result~()~
        +into_text(self) String
        -render_into(reply, encoder) Result~()~
        -render_outcome(outcome, encoder) Result~()~
        -render_diagnostic(diag, encoder) Result~()~
        -render_records(records, encoder) Result~()~
        -render_record_seq(items, encoder) Result~()~
        -local_error_code(error) &str
    }

    class Error {
        <<enum>>
        Io(std::io::Error)
        Codec(nota_codec::Error)
        Frame(signal::FrameDecodeError)
        FrameTooLarge
        HandshakeRejected
        HandshakePostReplyShape
        VerbNotInM0Scope
    }

    Daemon --> Connection
    Connection --> Parser
    Connection --> Renderer
    Connection --> CriomeLink
```

### 8b · Per-connection sequence

```mermaid
sequenceDiagram
    participant Client as client
    participant Daemon as Daemon
    participant Conn as Connection
    participant Parser as Parser
    participant Link as CriomeLink
    participant Criome as criome
    participant Render as Renderer

    Client->>Daemon: UDS connect
    Daemon->>Conn: new(client, criome_socket_path)
    Daemon-->>Client: (task spawned)

    Client->>Conn: nexus text (read until EOF)
    Conn->>Parser: Parser::new(text)
    Conn->>Parser: next_request()
    Parser-->>Conn: Some(Request)

    Note over Conn,Link: First request opens link
    Conn->>Link: CriomeLink::open(criome_socket_path)
    Link->>Criome: Frame{Handshake}
    Criome-->>Link: Frame{HandshakeAccepted}
    Link-->>Conn: CriomeLink (post-handshake)

    Conn->>Link: send(request)
    Link->>Criome: Frame{Request}
    Criome-->>Link: Frame{Reply}
    Link-->>Conn: Reply
    Conn->>Render: render_reply(&reply)
    Render-->>Conn: ()

    loop while parser yields more
        Conn->>Parser: next_request()
        Parser-->>Conn: Some(Request) | None
        Conn->>Link: send(request)
        Link->>Criome: Frame{Request}
        Criome-->>Link: Frame{Reply}
        Link-->>Conn: Reply
        Conn->>Render: render_reply(&reply)
    end

    Conn->>Render: into_text(self)
    Render-->>Conn: String
    Conn->>Client: write_all(text bytes)
```

---

## 9 · `criome` — sema's engine daemon

`Daemon` is the central noun owning `Arc<Sema>`. Per-verb
logic lives in sibling `impl Daemon { … }` blocks across
`dispatch.rs` / `handshake.rs` / `assert.rs` / `query.rs` —
all of which extend the same `Daemon` type. `Listener` holds
the UDS accept loop and shuttles frames through `Daemon`.

### 9a · Nouns

```mermaid
classDiagram
    class Daemon {
        -sema: Arc~Sema~
        +new(sema: Arc~Sema~) Daemon
        +sema() &Sema
        +handle_frame(frame: Frame) Frame
        +handle_request(request: Request) Reply
        +handle_handshake(request: HandshakeRequest) Reply
        +handle_assert(operation: AssertOperation) Reply
        +handle_query(operation: QueryOperation) Reply
        +deferred_verb(verb, milestone) Reply
        +protocol_error(code, message) Reply
    }

    class Listener {
        -listener: UnixListener
        +bind(socket_path: &str) Result~Listener~
        +run(self, daemon: Arc~Daemon~) Result~()~
        -handle_connection(socket, daemon) Result~()~
        -read_frame(socket) Result~Frame~
        -write_frame(socket, frame) Result~()~
    }

    class Error {
        <<enum>>
        Io(std::io::Error)
        Sema(sema::Error)
        Frame(signal::FrameDecodeError)
        FrameTooLarge
    }

    class kinds {
        <<module>>
        NODE: u8 = 1
        EDGE: u8 = 2
        GRAPH: u8 = 3
        KIND_DECL: u8 = 4
    }

    Daemon --> Sema
    Listener --> Daemon
```

**Note on `kinds`**: the 1-byte discriminator is M0
scaffolding. rkyv `bytecheck` doesn't catch type-punning
between same-size archives, so the tag gates the try-decode.
M1+ replaces this with per-kind redb tables in sema; the
`kinds` module disappears then.

### 9b · One Frame's journey

```mermaid
sequenceDiagram
    participant Nexus as nexus daemon
    participant Listener as Listener
    participant Daemon as Daemon
    participant Sema as Sema

    Nexus->>Listener: length-prefixed Frame bytes
    Listener->>Listener: read_frame: decode via Frame::decode
    Listener->>Daemon: handle_frame(frame)

    Daemon->>Daemon: match frame.body
    Daemon->>Daemon: handle_request(request)

    alt Request::Assert
        Daemon->>Sema: store(tagged_bytes)
        Sema-->>Daemon: Result~Slot~
        Daemon-->>Daemon: Reply::Outcome(Ok)
    else Request::Query
        Daemon->>Sema: iter()
        Sema-->>Daemon: Vec~(Slot, Vec~u8~)~
        Daemon->>Daemon: decode_kind, filter by PatternField
        Daemon-->>Daemon: Reply::Records(typed)
    else Request::Handshake
        Daemon-->>Daemon: handle_handshake (associated fn)
        Daemon-->>Daemon: Reply::HandshakeAccepted | HandshakeRejected
    else Request::Mutate / Retract / etc.
        Daemon-->>Daemon: deferred_verb('Mutate', 'M1')
        Daemon-->>Daemon: Reply::Outcome(Diagnostic E0099)
    end

    Daemon->>Daemon: wrap Reply in Frame
    Daemon-->>Listener: reply Frame
    Listener->>Listener: write_frame: encode + length-prefix
    Listener->>Nexus: reply Frame bytes
```

---

## 10 · `nexus-cli` — text shuttle client

Single noun. Stateless one-shot per invocation per
[`nexus-cli/ARCHITECTURE.md`](../repos/nexus-cli/ARCHITECTURE.md)
§Invariants.

```mermaid
classDiagram
    class Client {
        -socket_path: PathBuf
        +new(socket_path: PathBuf) Client
        +shuttle(input: &str) Result~String~
    }

    class Error {
        <<enum>>
        Io(std::io::Error)
    }

    Client --> Error
```

```mermaid
flowchart TD
    A["argv[1] file OR stdin<br/>→ input: String"] --> B["Client::shuttle(input)"]
    B --> C["UnixStream::connect(socket_path)"]
    C --> D["write_all(input.as_bytes())"]
    D --> E["shutdown(Write)"]
    E --> F["read_to_string() → reply: String"]
    F --> G["stdout.write_all(reply.as_bytes())"]
```

---

## 11 · Maintenance

This document is a snapshot. Per AGENTS.md "Delete wrong
reports; don't banner": when the system shape changes
materially (M1 lands, kind-tag scaffolding goes away,
nexus-cli grows beyond byte shuttle, lojix-schema lands as
real CANON), regenerate this report rather than patching it.

The agent prompts that produced these diagrams are reusable
— see the conversation log for 2026-04-27 (Phase 1 synthesis
+ Phase 2 per-repo agents pattern).

---

*End 102.*
