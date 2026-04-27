# 089 — M0 implementation plan, steps 3 → 7

*Detailed plan for the remaining M0 work after step 1 (signal
rewrite — done, 18 tests) and step 2 (sema body — done, 7 tests).
Companion to 088. Five steps left, with shape, code sketches,
tests, decisions surfaced during planning.*

---

## 1 · Recap of what's done

- [signal rewrite](../repos/signal/src/) per Invariant D: per-verb
  typed payloads (`AssertOp`, `MutateOp`, `QueryOp`, `Records`),
  paired Query kinds (`NodeQuery`, `EdgeQuery`, `GraphQuery`,
  `KindDeclQuery`), `KindDecl` schema-as-data type.
  18 round-trip tests cover every verb shape end-to-end.
- [sema body](../repos/sema/src/lib.rs): `Sema::open / store /
  get` over a redb file, monotone slot counter starting at
  `SEED_RANGE_END = 1024`, persistent across reopens. 7 tests.

Both pushed to main on their respective repos.

---

## 2 · Step 3 — criome body (~150 LoC)

The daemon: UDS accept loop, length-prefixed Frame I/O, dispatch
per Request variant, sema integration.

### 2.1 Sema needs one revision first

For Query support, criome must enumerate records *of a given
kind* without decoding every blob. Sema currently stores opaque
bytes by slot; nothing tells criome which slot is a Node vs Edge.

**Revision to sema (~30 LoC):**

```rust
// sema/src/lib.rs — extended API

pub fn store(&self, kind_tag: u8, payload: &[u8]) -> Result<Slot>;
pub fn get(&self, slot: Slot) -> Result<Option<(u8, Vec<u8>)>>;
pub fn iter_kind(&self, kind_tag: u8)
    -> Result<impl Iterator<Item = Result<(Slot, Vec<u8>)>>>;
```

Storage form: prepend a u8 tag byte to the payload bytes in the
records table. `iter_kind` does a full table scan in M0 (filter
by first byte); a secondary index by kind_tag is M1+ optimization.

`u8` is sema's view of kind. Sema doesn't interpret tags —
criome assigns them. (Sema stays free of kind-name strings;
the tag is just a discriminator.)

### 2.2 Criome layout

```
criome/src/
├── main.rs       — entry: open sema, bind UDS, accept loop
├── lib.rs        — re-exports + Result type
├── error.rs      — existing; add new variants
├── uds.rs        — Listener wrapper around tokio UnixListener
├── dispatch.rs   — NEW: Request → Reply
├── kinds.rs      — NEW: KIND_NODE/EDGE/GRAPH/KINDDECL u8 consts
├── handshake.rs  — NEW: handshake handler (small)
├── assert.rs     — NEW: AssertOp dispatch + sema.store
├── query.rs      — NEW: QueryOp dispatch + matcher
└── validator/    — existing stubs (unchanged for M0)
```

### 2.3 Code shape

```rust
// criome/src/main.rs
use std::path::PathBuf;
use std::sync::Arc;
use criome::{uds::Listener, Result};
use sema::Sema;

#[tokio::main]
async fn main() -> Result<()> {
    let socket_path = "/tmp/criome.sock";
    let sema_path: PathBuf = std::env::var("SEMA_PATH")
        .unwrap_or_else(|_| "/tmp/sema.redb".into())
        .into();
    let sema = Arc::new(Sema::open(&sema_path)?);
    Listener::bind(socket_path).await?.run(sema).await
}

// criome/src/uds.rs
pub struct Listener { listener: tokio::net::UnixListener }

impl Listener {
    pub async fn bind(path: &str) -> Result<Self> {
        let _ = std::fs::remove_file(path);  // clear stale socket
        Ok(Listener { listener: tokio::net::UnixListener::bind(path)? })
    }

    pub async fn run(self, sema: Arc<Sema>) -> Result<()> {
        loop {
            let (sock, _) = self.listener.accept().await?;
            let sema = sema.clone();
            tokio::spawn(async move {
                let _ = handle_conn(sock, sema).await;
            });
        }
    }
}

async fn handle_conn(mut sock: UnixStream, sema: Arc<Sema>) -> Result<()> {
    loop {
        let frame = read_frame(&mut sock).await?;
        let reply = dispatch::handle(frame, &sema);
        write_frame(&mut sock, reply).await?;
    }
}

// length-prefixed Frame I/O — 4-byte BE u32 + N rkyv bytes
async fn read_frame(sock: &mut UnixStream) -> Result<Frame> { ... }
async fn write_frame(sock: &mut UnixStream, frame: Frame) -> Result<()> { ... }
```

```rust
// criome/src/dispatch.rs
pub fn handle(frame: Frame, sema: &Sema) -> Frame {
    let reply = match frame.body {
        Body::Request(req) => process(req, sema),
        Body::Reply(_) => return reject(),  // criome doesn't process replies
    };
    Frame { principal_hint: None, auth_proof: None, body: Body::Reply(reply) }
}

fn process(req: Request, sema: &Sema) -> Reply {
    match req {
        Request::Handshake(h)    => handshake::handle(h),
        Request::Assert(op)      => assert::handle(op, sema),
        Request::Query(op)       => query::handle(op, sema),
        Request::Mutate(_)       => deferred("Mutate", "M1"),
        Request::Retract(_)      => deferred("Retract", "M1"),
        Request::AtomicBatch(_)  => deferred("AtomicBatch", "M1"),
        Request::Subscribe(_)    => deferred("Subscribe", "M2"),
        Request::Validate(_)     => deferred("Validate", "M1"),
    }
}

fn deferred(verb: &str, milestone: &str) -> Reply {
    Reply::Outcome(OutcomeMessage::Diagnostic(Diagnostic {
        level: DiagnosticLevel::Error,
        code: "E0099".into(),
        message: format!("{verb} verb not implemented in M0; planned for {milestone}"),
        primary_site: None,
        context: vec![],
        suggestions: vec![],
        durable_record: None,
    }))
}
```

```rust
// criome/src/assert.rs
pub fn handle(op: AssertOp, sema: &Sema) -> Reply {
    let (kind_tag, bytes_result) = match op {
        AssertOp::Node(n)     => (kinds::NODE,      encode(&n)),
        AssertOp::Edge(e)     => (kinds::EDGE,      encode(&e)),
        AssertOp::Graph(g)    => (kinds::GRAPH,     encode(&g)),
        AssertOp::KindDecl(k) => (kinds::KIND_DECL, encode(&k)),
    };
    match bytes_result.and_then(|b| sema.store(kind_tag, &b).map_err(...)) {
        Ok(_slot) => Reply::Outcome(OutcomeMessage::Ok(Ok {})),
        Err(e)    => Reply::Outcome(OutcomeMessage::Diagnostic(...)),
    }
}

fn encode<T>(value: &T) -> Result<Vec<u8>>
where T: rkyv::Serialize<...>,
{
    rkyv::to_bytes::<rkyv::rancor::Error>(value)
        .map(|b| b.to_vec())
        .map_err(|e| Error::Encode(e.to_string()))
}
```

```rust
// criome/src/query.rs
pub fn handle(op: QueryOp, sema: &Sema) -> Reply {
    let result = match op {
        QueryOp::Node(q)     => find_nodes(sema, q).map(Records::Node),
        QueryOp::Edge(q)     => find_edges(sema, q).map(Records::Edge),
        QueryOp::Graph(q)    => find_graphs(sema, q).map(Records::Graph),
        QueryOp::KindDecl(q) => find_kind_decls(sema, q).map(Records::KindDecl),
    };
    match result {
        Ok(records) => Reply::Records(records),
        Err(e)      => Reply::Outcome(OutcomeMessage::Diagnostic(...)),
    }
}

fn find_nodes(sema: &Sema, q: NodeQuery) -> Result<Vec<Node>> {
    let mut out = Vec::new();
    for entry in sema.iter_kind(kinds::NODE)? {
        let (_slot, bytes) = entry?;
        let node: Node = decode(&bytes)?;
        if matches_node(&node, &q) {
            out.push(node);
        }
    }
    Ok(out)
}

fn matches_node(n: &Node, q: &NodeQuery) -> bool {
    matches_pf(&n.name, &q.name)
}

fn matches_pf<T: PartialEq>(value: &T, pf: &PatternField<T>) -> bool {
    match pf {
        PatternField::Wildcard | PatternField::Bind(_) => true,
        PatternField::Match(v) => value == v,
    }
}
```

### 2.4 Tests for criome

Three integration tests with a temp sema file and direct
`dispatch::handle` calls (no UDS round-trip needed for unit
correctness — the UDS path is exercised by the end-to-end
test in step 5):

1. `assert_node_then_query_finds_it` — Assert + Query Wildcard
   returns the node.
2. `assert_three_kinds_query_filters_correctly` — Assert
   Node + Edge + Graph; QueryOp::Node returns only the node.
3. `query_with_match_filters_by_value` — Assert two Nodes
   with different names; Query Match returns only the
   matching one.
4. `unimplemented_verb_returns_e0099` — Mutate returns
   Diagnostic E0099.

Plus the existing 18 signal tests still cover the Frame
round-trip path.

---

## 3 · Step 4 — parser extensions (~50 LoC, deferred to nexus daemon)

The grammar's `(| Kind ... |)` query syntax needs deserializer
paths in [nota-serde-core](../repos/nota-serde-core/src/de.rs):
LParenPipe handler, plus PatternField<T> dispatch on `_`,
`@name`, or literal-T.

### 3.1 The hard part — PatternField<T> dispatch

`PatternField<T>` has three variants distinguished by token at
deserialization time:

```
text          → variant
─────────────────────────────────
_             → Wildcard
@name         → Bind("name")
"hello" / 5   → Match(value of type T)
```

The deserializer has to peek the next token and dispatch. But
serde's `Deserializer::deserialize_enum` doesn't naturally
expose this — variant dispatch is normally driven by an ident
matching the variant name.

**Two paths:**

**(A) Native parser support** — extend `de.rs` with custom
dispatch for `PatternField`. Requires either: a sentinel
(like `BIND_SENTINEL` for nexus binds), making PatternField a
sentinel type in nexus-serde; or a hand-written `Deserialize`
impl on `PatternField` that uses an internal API of nota-serde-
core to peek tokens. ~80 LoC + design judgment.

**(B) Hand-written daemon-side parser** — the nexus daemon owns
a small custom function `parse_query(&str) -> QueryOp` that
recognizes the `(| Kind ... |)` shape directly and constructs
the typed payload. Inside the kind block, it reads each
position with kind-aware logic:

```rust
fn parse_query(input: &str) -> Result<QueryOp> {
    let mut lex = Lexer::nexus(input);
    expect(lex, Token::LParenPipe)?;
    let kind = expect_pascal_ident(&mut lex)?;
    let q = match kind.as_str() {
        "Node"     => QueryOp::Node(NodeQuery {
            name: parse_pf_string(&mut lex)?,
        }),
        "Edge"     => QueryOp::Edge(EdgeQuery {
            from: parse_pf_slot(&mut lex)?,
            to:   parse_pf_slot(&mut lex)?,
            kind: parse_pf_relation_kind(&mut lex)?,
        }),
        "Graph"    => QueryOp::Graph(GraphQuery {
            title: parse_pf_string(&mut lex)?,
        }),
        "KindDecl" => QueryOp::KindDecl(KindDeclQuery {
            name: parse_pf_string(&mut lex)?,
        }),
        other => return Err(format!("unknown query kind: {other}")),
    };
    expect(&mut lex, Token::RParenPipe)?;
    Ok(q)
}

fn parse_pf_string(lex: &mut Lexer) -> Result<PatternField<String>> {
    match lex.next_token()? {
        Some(Token::Ident(s)) if s == "_" => Ok(PatternField::Wildcard),
        Some(Token::At) => {
            let name = expect_lower_ident(lex)?;
            Ok(PatternField::Bind(name))
        }
        Some(Token::Ident(s)) => Ok(PatternField::Match(s)),  // bare-ident
        Some(Token::Str(s))   => Ok(PatternField::Match(s)),  // quoted
        other => Err(format!("expected pattern field, got {other:?}")),
    }
}
// parse_pf_slot: bare integer → Match(Slot(n)), @name → Bind, _ → Wildcard
// parse_pf_relation_kind: bare PascalCase → Match(variant), @name → Bind, _ → Wildcard
```

**Recommendation:** path B for M0 (~50 LoC in nexus daemon).
Defers the parser-kernel design until kinds grow enough to
justify it. Path A becomes attractive when rsc lands and can
generate per-kind pattern parsers from KindDecl records.

---

## 4 · Step 5 — nexus daemon body (~200 LoC)

### 4.1 Files

```
nexus/src/
├── main.rs    — entry: bind /tmp/nexus.sock, accept, spawn handler
├── lib.rs     — existing: error + module re-exports
├── error.rs   — existing
├── handler.rs — NEW: per-connection handler (text in/out)
├── parse.rs   — NEW: text → typed Request (uses nota-serde-core for asserts; hand-written for queries per §3)
└── render.rs  — NEW: typed Reply → text (uses nota-serde-core)
```

### 4.2 Per-connection flow

```rust
async fn handle_conn(mut client_sock: UnixStream) -> Result<()> {
    // Open a paired criome connection for this client session
    let mut criome = UnixStream::connect("/tmp/criome.sock").await?;
    do_handshake(&mut criome).await?;

    let mut text_buffer = String::new();
    let mut read_buf = [0u8; 4096];

    loop {
        let n = client_sock.read(&mut read_buf).await?;
        if n == 0 { break; }
        text_buffer.push_str(std::str::from_utf8(&read_buf[..n])?);

        // Drain complete top-level expressions
        loop {
            match parse::next_top_level(&text_buffer)? {
                None => break,  // need more bytes
                Some((request, consumed)) => {
                    let reply = exchange(&mut criome, request).await?;
                    let response = render::reply(reply)?;
                    client_sock.write_all(response.as_bytes()).await?;
                    client_sock.write_all(b"\n").await?;
                    text_buffer.drain(..consumed);
                }
            }
        }
    }
    Ok(())
}
```

### 4.3 Parser dispatch

`parse::next_top_level` recognizes the verb from the leading
sigil/delimiter:

```
(Foo …)        → Request::Assert(AssertOp::Foo(...))     via nota-serde::from_str_nexus
(| Foo …|)     → Request::Query(QueryOp::Foo(...))       via hand-written §3 parser
~(Foo …)       → Request::Mutate(MutateOp::Foo{...})     via nota-serde-nexus (sentinel-based existing)
!slot          → Request::Retract(RetractOp{slot, ...})  hand-written
[| op1 op2 |]  → Request::AtomicBatch(...)               via nota-serde existing
?(...)         → Request::Validate(...)                  via nota-serde existing
*(| ... |)     → Request::Subscribe(...)                 hand-written wrapper around §3
```

For M0 only `(...)` and `(| ...|)` need to actually work; the
others can return `Diagnostic E0099` from the daemon side
(mirroring criome's deferred verbs from §2.3).

### 4.4 Reply rendering

```rust
pub fn reply(reply: Reply) -> Result<String> {
    match reply {
        Reply::HandshakeAccepted(_) => Ok("(Ok)".to_string()),  // collapsed for client
        Reply::HandshakeRejected(r) => Ok(render_handshake_reject(r)),

        Reply::Outcome(OutcomeMessage::Ok(_))            => Ok("(Ok)".into()),
        Reply::Outcome(OutcomeMessage::Diagnostic(d))    => Ok(render_diagnostic(&d)?),

        Reply::Outcomes(items) => {
            // sequence of (Ok) / (Diagnostic …) — emit as [(Ok) (Diag) …]
            let mut s = String::from("[");
            for (i, item) in items.iter().enumerate() {
                if i > 0 { s.push(' '); }
                s.push_str(&render_outcome_message(item)?);
            }
            s.push(']');
            Ok(s)
        }

        Reply::Records(Records::Node(ns))    => render_typed_seq(&ns),
        Reply::Records(Records::Edge(es))    => render_typed_seq(&es),
        Reply::Records(Records::Graph(gs))   => render_typed_seq(&gs),
        Reply::Records(Records::KindDecl(k)) => render_typed_seq(&k),
    }
}

fn render_typed_seq<T: serde::Serialize>(items: &[T]) -> Result<String> {
    // Per Q6 in 087: NO HARDCODING. Use nota-serde-core to render.
    nota_serde_core::to_string_nexus(items).map_err(|e| ...)
}
```

This honors the [criome arch Invariant D + Q6 decision](../repos/criome/ARCHITECTURE.md#invariant-d):
all rendering goes through nota-serde-core, never hardcoded.

### 4.5 Tests

- Unit tests on `parse::next_top_level` covering each verb
  shape's text → Request roundtrip (against the example
  flow-graph.nexus content).
- Unit tests on `render::reply` covering Ok / Diagnostic /
  typed Records.
- Integration test (in step 5 closing): full daemon spin-up,
  connect, send `(Node "User")`, expect `(Ok)` response.

---

## 5 · Step 6 — nexus-cli (~30 LoC)

```rust
use std::io::{Read, Write};
use std::os::unix::net::UnixStream;

fn main() -> Result<()> {
    let args: Vec<String> = std::env::args().collect();
    let input = match args.get(1) {
        Some(file) if file != "-" => std::fs::read_to_string(file)?,
        _ => {
            let mut s = String::new();
            std::io::stdin().read_to_string(&mut s)?;
            s
        }
    };

    let mut sock = UnixStream::connect("/tmp/nexus.sock")?;
    sock.write_all(input.as_bytes())?;
    sock.shutdown(std::net::Shutdown::Write)?;

    let mut response = String::new();
    sock.read_to_string(&mut response)?;
    print!("{response}");
    Ok(())
}
```

No tokio, no signal, no parser deps. Pure shuttle. The
[nexus-cli ARCHITECTURE.md](../repos/nexus-cli/ARCHITECTURE.md)
calls this out: *"Text is text. nexus-cli does not parse nexus;
it just shuttles bytes."*

Also note: that arch doc still has the stale `client_msg`
references caught in [087 §1.1](087-m0-plan-decisions-and-grammar.md);
fixing those concurrently with this step would be opportunistic.

---

## 6 · Step 7 — `genesis.nexus` (~30 LoC text)

A text file shipped with the criome binary (in
`criome/genesis.nexus`). At first boot, criome's main.rs
checks an empty sema, dispatches genesis through the same
Assert path that user data uses, and KindDecl records land in
sema.

```nexus
;; genesis.nexus — bootstrap KindDecls for the v0.0.1 schema.
;; Asserted by criome at first boot via the same Assert path
;; user data takes. Self-describing: KindDecl is itself the
;; first kind declared.

(KindDecl "KindDecl"
  [(FieldDecl "name"   "String"    One)
   (FieldDecl "fields" "FieldDecl" Many)])

(KindDecl "FieldDecl"
  [(FieldDecl "name"        "String"      One)
   (FieldDecl "type-name"   "String"      One)
   (FieldDecl "cardinality" "Cardinality" One)])

(KindDecl "Node"
  [(FieldDecl "name" "String" One)])

(KindDecl "Edge"
  [(FieldDecl "from" "Slot"         One)
   (FieldDecl "to"   "Slot"         One)
   (FieldDecl "kind" "RelationKind" One)])

(KindDecl "Graph"
  [(FieldDecl "title"     "String" One)
   (FieldDecl "nodes"     "Slot"   Many)
   (FieldDecl "edges"     "Slot"   Many)
   (FieldDecl "subgraphs" "Slot"   Many)])
```

**Bootstrap mechanic** (in criome main.rs):

```rust
async fn maybe_run_genesis(sema: &Sema) -> Result<()> {
    if sema.iter_kind(kinds::KIND_DECL)?.next().is_some() {
        return Ok(());  // already initialized
    }
    let genesis_text = include_str!("../genesis.nexus");
    // Parse + dispatch each KindDecl through normal Assert path
    for kd in parse_all_asserts(genesis_text)? {
        let _ = assert::handle(kd, sema);
    }
    Ok(())
}
```

This means M0 has TWO parse paths in criome:
- The wire path (signal Frame from network)
- The genesis-text path at boot (one-shot from embedded text)

For M0 simplest, the genesis path can use nota-serde-core's
`from_str_nexus` directly to deserialize each KindDecl, then
hand it to `assert::handle`. No frame envelope, just typed
values.

---

## 7 · Open decisions before I proceed

These came up during planning. Pre-confirming saves churn.

### 7.1 Sema kind-tag storage form

My plan: prepend a u8 tag byte to the payload bytes in the
records table value. Pros: zero schema change, 1-byte cost
per record. Cons: full table scan for `iter_kind` (M0
acceptable; M1+ optimize with secondary index).

**Alternative:** parallel `kind_tags: Slot → u8` table.
Cleaner separation, +1 read per get. I lean prepend.

Confirm prepend, or want parallel table?

### 7.2 Verb scope for M0

My plan: M0 dispatches `Handshake` + `Assert` + `Query`. Other
verbs (`Mutate`, `Retract`, `AtomicBatch`, `Subscribe`,
`Validate`) return `Diagnostic E0099 "verb not implemented in
M0; planned for {milestone}"`. Both criome and nexus daemon
respect this.

This contradicts 088 §6 which sketched Mutate/Retract/Atomic-
Batch as part of the Op enums. Those types EXIST (signal
defines them) — they just aren't *processed* by criome at M0.

Acceptable? Or want Mutate + Retract + AtomicBatch processed
too (probably another ~80 LoC across criome + daemon parser)?

### 7.3 Parser approach for `(| ... |)`

My plan: hand-written in nexus daemon (path B from §3.1), ~50
LoC for 4 kinds. Defer the parser-kernel design to M1+.

Acceptable, or want native nota-serde-core support now?

### 7.4 Handshake at the CLI ↔ daemon leg

There IS no signal handshake on this leg — it's pure text. The
nexus daemon DOES handshake on the daemon ↔ criome leg (signal
required). For M0 the CLI just opens, writes, reads, closes.
Future protocol-version negotiation can layer on as a "(Hello
1.0)" verb if needed.

Confirm: no handshake on CLI ↔ daemon leg in M0?

### 7.5 nexus-cli stale arch doc

Concurrent or separate? My plan: fix the [stale references in
nexus-cli/ARCHITECTURE.md](../repos/nexus-cli/ARCHITECTURE.md)
(client_msg, TxnBatch, etc — see [087 §1.1](087-m0-plan-decisions-and-grammar.md))
during step 6.

Concurrent or as a follow-up? I lean concurrent (cheap, the
file is heavily wrong as-is).

---

## 8 · Order, dependencies, totals

```
   ┌─ step 3 (criome body) ─────────────────────┐
   │  3.0  sema kind-tag revision (~30 LoC)     │   independent of all else;
   │  3.1  uds.rs accept loop (~40 LoC)         │   can land first
   │  3.2  dispatch + assert + query (~80 LoC)  │
   │  3.3  4 integration tests                  │
   └────────────────────────────────────────────┘
              │
              ▼
   ┌─ step 7 (genesis.nexus + bootstrap) ───────┐
   │  ~30 LoC text + ~20 LoC bootstrap glue     │   needs §3 (criome
   │                                             │   processes Assert)
   └────────────────────────────────────────────┘
              │
              ▼
   ┌─ step 5 (nexus daemon) ────────────────────┐
   │  5.1  bind + accept (~30 LoC)              │   needs §3 (criome up)
   │  5.2  text parsing dispatch (~80 LoC)      │   §3.1 hand-written
   │       — uses nota-serde-core for asserts    │   query parser inline
   │       — hand-written §3.1 query parser     │
   │  5.3  reply rendering (~50 LoC)            │
   │  5.4  unit tests (~6) + 1 integration      │
   └────────────────────────────────────────────┘
              │
              ▼
   ┌─ step 6 (nexus-cli) ───────────────────────┐
   │  6.1  text shuttle (~30 LoC)               │   needs §5 (daemon up)
   │  6.2  fix nexus-cli/ARCHITECTURE.md stale  │
   │       references opportunistically         │
   └────────────────────────────────────────────┘

Step 4 (parser kernel extension) is FOLDED into step 5 as the
hand-written §3.1 query parser. No standalone step needed.

Total LoC estimate: ~390 (sema rev 30 + criome 150 + nexus
daemon 180 + nexus-cli 30 + genesis text 30, give or take).
Down slightly from 088's 495 because the parser kernel work
becomes the daemon's hand-written ~50 LoC rather than a full
deserializer extension.
```

End-to-end demo on completion: `nexus-cli example.nexus` where
example.nexus contains `(Node "User")` and `(| Node @name |)`,
with daemon + criome running, returns:
```
(Ok)
[(Node User)]
```

---

## 9 · What I'll do next

If decisions §7.1 prepend / §7.2 Assert+Query-only / §7.3
hand-written / §7.4 no-handshake / §7.5 concurrent are all
yes, I'll proceed in order: 3.0 → 3.1 → 3.2 → 3.3 → 7 → 5 →
6, committing per logical chunk. Each commit follows the
S-expression style; tests pass before each push.

Estimated 5-7 commits across 4 repos (sema, criome, nexus,
nexus-cli) plus one for the genesis text in criome.

If you want any of the §7 decisions different, say so and
I'll adjust before starting.

---

*End 089.*
