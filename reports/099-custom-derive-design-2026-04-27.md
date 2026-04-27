# 099 — Deep design exploration: the custom-derive Option 2

*Per Li 2026-04-27: "do a deep exploration of 2." This report
expands [reports/098 §4.1 Option 2](098-serde-replacement-decision-2026-04-27.md)
— authoring our own `#[derive(NexusKind)]`-family proc-macros
to replace serde at the Stage 2 boundary. The intent is to
have a concrete enough design that the Stage 2 implementation
can start from this report rather than from a blank page.*

The full staged plan and the reasons-to-replace-serde live in
[098](098-serde-replacement-decision-2026-04-27.md). This
report assumes that decision and explores the
custom-derive implementation only.

---

## 1 · The derive vocabulary

Four derives cover the schema. Each one emits trait impls that
target the runtime `Decoder` / `Encoder` types in the new
nexus-codec crate.

| Derive | Applied to | Encodes as | Decodes from | Examples |
|---|---|---|---|---|
| `NexusRecord` | structs whose fields are plain values | `(Foo a b c)` | `(Foo a b c)` | `Node`, `Edge`, `Graph`, `KindDecl`, `FieldDecl`, `Ok`, `RetractOp` |
| `NexusPattern` | structs whose fields are `PatternField<T>` | `(\| Foo a b c \|)` | `(\| Foo a b c \|)` | `NodeQuery`, `EdgeQuery`, `GraphQuery`, `KindDeclQuery` |
| `NexusEnum` | unit-variant enums | PascalCase variant identifier | PascalCase variant identifier | `RelationKind`, `Cardinality`, `DiagnosticLevel` |
| `NexusVerb` | closed enums of kind variants | dispatched on head identifier | head-identifier-driven dispatch | `AssertOp`, `MutateOp`, `QueryOp`, `BatchOp` |

Two things are intentionally NOT derived and stay hand-written:

- **Top-level `Request` / `Reply` dispatch.** The Decoder's
  `next_request` method reads the leading sigil/delimiter
  (`Token::LParen`, `Token::Tilde`, `Token::LParenPipe`, etc.)
  and dispatches to the right verb's decode. This is the
  "native sigil dispatch" win — no derive needed because the
  dispatch is on a closed `Token` enum.
- **Transparent newtypes** (`Slot`, `Revision`, `Hash`,
  `BlsG1`). These are 4 types, each one method on
  `Decoder` / `Encoder`. A `NexusTransparent` derive could
  handle them, but the cost of hand-writing 4 trait impls
  (~40 LoC total) is lower than the cost of adding another
  derive variant. Defer.

---

## 2 · What each derive emits

### 2.1 `NexusRecord`

Input:

```rust
#[derive(NexusRecord)]
pub struct Node {
    pub name: String,
}
```

Generated:

```rust
impl NexusEncode for Node {
    fn encode(&self, encoder: &mut Encoder) -> Result<()> {
        encoder.start_record("Node")?;
        self.name.encode(encoder)?;
        encoder.end_record()
    }
}

impl NexusDecode for Node {
    fn decode(decoder: &mut Decoder) -> Result<Self> {
        decoder.expect_record_head("Node")?;
        let name = String::decode(decoder)?;
        decoder.expect_record_end()?;
        Ok(Self { name })
    }
}
```

For multi-field records:

```rust
#[derive(NexusRecord)]
pub struct Edge {
    pub from: Slot,
    pub to: Slot,
    pub kind: RelationKind,
}

// Generated:
impl NexusEncode for Edge {
    fn encode(&self, encoder: &mut Encoder) -> Result<()> {
        encoder.start_record("Edge")?;
        self.from.encode(encoder)?;
        self.to.encode(encoder)?;
        self.kind.encode(encoder)?;
        encoder.end_record()
    }
}
// (NexusDecode mirror)
```

For records with collections:

```rust
#[derive(NexusRecord)]
pub struct Graph {
    pub title: String,
    pub nodes: Vec<Slot>,
    pub edges: Vec<Slot>,
    pub subgraphs: Vec<Slot>,
}
```

`Vec<T>` encode/decode comes from a `NexusEncode` / `NexusDecode`
blanket impl on `Vec<T> where T: NexusEncode + NexusDecode`. The
derive does not need to know about Vec specifically; it just
calls the field's `encode` / `decode` method.

For empty records:

```rust
#[derive(NexusRecord)]
pub struct Ok {}

// Generated emits "(Ok)"; decode expects exactly that.
```

### 2.2 `NexusPattern`

Input:

```rust
#[derive(NexusPattern)]
pub struct EdgeQuery {
    pub from: PatternField<Slot>,
    pub to: PatternField<Slot>,
    pub kind: PatternField<RelationKind>,
}
```

Generated:

```rust
impl NexusEncode for EdgeQuery {
    fn encode(&self, encoder: &mut Encoder) -> Result<()> {
        encoder.start_pattern_record("Edge")?;  // emits "(| Edge "
        encoder.encode_pattern_field(&self.from, "from")?;
        encoder.encode_pattern_field(&self.to, "to")?;
        encoder.encode_pattern_field(&self.kind, "kind")?;
        encoder.end_pattern_record()  // emits " |)"
    }
}

impl NexusDecode for EdgeQuery {
    fn decode(decoder: &mut Decoder) -> Result<Self> {
        decoder.expect_pattern_record_head("Edge")?;
        let from = decoder.decode_pattern_field::<Slot>("from")?;
        let to = decoder.decode_pattern_field::<Slot>("to")?;
        let kind = decoder.decode_pattern_field::<RelationKind>("kind")?;
        decoder.expect_pattern_record_end()?;
        Ok(Self { from, to, kind })
    }
}
```

Three notes on the pattern derive:

1. **The record name in the nexus text is the data-kind name,
   not the query-type name.** `EdgeQuery` emits `(| Edge ... |)`,
   not `(| EdgeQuery ... |)`. The convention is that the query
   type name is `<DataKind>Query`; the derive strips the `Query`
   suffix. If a query type doesn't follow this convention, an
   explicit `#[nexus(record = "...")]` attribute names it.
2. **`decode_pattern_field` carries the schema field name.**
   When the input contains `@from`, the Decoder validates that
   the bind name "from" matches the schema field name "from"
   passed at this position. A mismatch (`@frm` or `@source`)
   produces a typed `Error::WrongBindName`. This is exactly the
   check `nexus/src/parse.rs::check_bind_name` does today, but
   automated by the derive emission.
3. **`PatternField<T>` requires `T: NexusEncode + NexusDecode`.**
   The derive doesn't need to know this — it's a trait bound on
   `decode_pattern_field` itself.

### 2.3 `NexusEnum`

Input:

```rust
#[derive(NexusEnum)]
pub enum RelationKind {
    Flow,
    DependsOn,
    Contains,
    References,
    Produces,
    Consumes,
    Calls,
    Implements,
    IsA,
}
```

Generated:

```rust
impl NexusEncode for RelationKind {
    fn encode(&self, encoder: &mut Encoder) -> Result<()> {
        let variant_name = match self {
            Self::Flow => "Flow",
            Self::DependsOn => "DependsOn",
            Self::Contains => "Contains",
            Self::References => "References",
            Self::Produces => "Produces",
            Self::Consumes => "Consumes",
            Self::Calls => "Calls",
            Self::Implements => "Implements",
            Self::IsA => "IsA",
        };
        encoder.write_pascal_identifier(variant_name)
    }
}

impl NexusDecode for RelationKind {
    fn decode(decoder: &mut Decoder) -> Result<Self> {
        let identifier = decoder.read_pascal_identifier()?;
        match identifier.as_str() {
            "Flow" => Ok(Self::Flow),
            "DependsOn" => Ok(Self::DependsOn),
            "Contains" => Ok(Self::Contains),
            "References" => Ok(Self::References),
            "Produces" => Ok(Self::Produces),
            "Consumes" => Ok(Self::Consumes),
            "Calls" => Ok(Self::Calls),
            "Implements" => Ok(Self::Implements),
            "IsA" => Ok(Self::IsA),
            other => Err(Error::UnknownVariant {
                enum_name: "RelationKind",
                got: other.to_string(),
            }),
        }
    }
}
```

This subsumes the existing hand-written
`RelationKind::from_variant_name` and
`RelationKind::variant_name` methods in
[`signal/src/flow.rs:96-126`](../repos/signal/src/flow.rs#L96)
— they fold into the derive emission and the methods can
delete.

### 2.4 `NexusVerb`

Input:

```rust
#[derive(NexusVerb)]
pub enum AssertOp {
    Node(Node),
    Edge(Edge),
    Graph(Graph),
    KindDecl(KindDecl),
}
```

Generated:

```rust
impl NexusEncode for AssertOp {
    fn encode(&self, encoder: &mut Encoder) -> Result<()> {
        match self {
            Self::Node(value) => value.encode(encoder),
            Self::Edge(value) => value.encode(encoder),
            Self::Graph(value) => value.encode(encoder),
            Self::KindDecl(value) => value.encode(encoder),
        }
    }
}

impl NexusDecode for AssertOp {
    fn decode(decoder: &mut Decoder) -> Result<Self> {
        // Peek at the head identifier without consuming the (
        let head = decoder.peek_record_head()?;
        match head.as_str() {
            "Node" => Ok(Self::Node(Node::decode(decoder)?)),
            "Edge" => Ok(Self::Edge(Edge::decode(decoder)?)),
            "Graph" => Ok(Self::Graph(Graph::decode(decoder)?)),
            "KindDecl" => Ok(Self::KindDecl(KindDecl::decode(decoder)?)),
            other => Err(Error::UnknownKindForVerb {
                verb: "Assert",
                got: other.to_string(),
            }),
        }
    }
}
```

Two key properties:

1. **The dispatch is closed.** Adding a kind to AssertOp means
   adding a variant, recompiling. The derive's exhaustive match
   guarantees no unknown-kind escape at the Rust level. The
   string match inside is bounded by the variant set — it's
   the [Invariant D §"closed enums at the wire"](https://github.com/LiGoldragon/criome/blob/main/ARCHITECTURE.md)
   discipline made mechanical.
2. **No wrapper sigils.** The derive doesn't emit `~` for
   Mutate or `!` for Retract — those sigils come from the
   *enclosing* dispatch, not the verb-payload encode. The verb
   enum just dispatches by head identifier; the request-level
   Decoder reads the sigil first to choose which verb-enum to
   dispatch into.

For struct-variant verbs (MutateOp), the derive needs more
shape:

```rust
#[derive(NexusVerb)]
pub enum MutateOp {
    Node { slot: Slot, new: Node, expected_rev: Option<Revision> },
    Edge { slot: Slot, new: Edge, expected_rev: Option<Revision> },
    Graph { slot: Slot, new: Graph, expected_rev: Option<Revision> },
    KindDecl { slot: Slot, new: KindDecl, expected_rev: Option<Revision> },
}
```

The derive emits encode/decode that handles the struct-variant
positional layout:

```rust
// Encoder side, Node variant:
Self::Node { slot, new, expected_rev } => {
    encoder.start_record("Node")?;
    slot.encode(encoder)?;
    new.encode(encoder)?;
    expected_rev.encode(encoder)?;
    encoder.end_record()
}
```

(See §3 for the `Option<T>` / variable-position open question.)

---

## 3 · The Decoder / Encoder runtime types

The runtime types the derives target. These are hand-written
in nexus-codec; the derives just emit method calls into them.

```rust
pub struct Decoder<'input> {
    lexer: Lexer<'input>,  // from nota-lexer (renamed nota-serde-core)
}

impl<'input> Decoder<'input> {
    pub fn nexus(input: &'input str) -> Self { ... }
    pub fn nota(input: &'input str) -> Self { ... }

    // Single entry for any NexusDecode type:
    pub fn decode<T: NexusDecode>(&mut self) -> Result<T> {
        T::decode(self)
    }

    // Sigil-dispatched request reader (the top-level entry):
    pub fn next_request(&mut self) -> Result<Request> {
        match self.peek_token()? {
            Token::LParen => {
                let assert_op = AssertOp::decode(self)?;
                Ok(Request::Assert(assert_op))
            }
            Token::Tilde => {
                self.consume_token(Token::Tilde)?;
                let mutate_op = MutateOp::decode(self)?;
                Ok(Request::Mutate(mutate_op))
            }
            Token::Bang => {
                self.consume_token(Token::Bang)?;
                let retract_op = RetractOp::decode(self)?;
                Ok(Request::Retract(retract_op))
            }
            Token::Question => {
                self.consume_token(Token::Question)?;
                let batch_op = BatchOp::decode(self)?;
                Ok(Request::Validate(batch_op))
            }
            Token::Star => {
                self.consume_token(Token::Star)?;
                let query_op = QueryOp::decode(self)?;
                Ok(Request::Subscribe(query_op))
            }
            Token::LParenPipe => {
                let query_op = QueryOp::decode(self)?;
                Ok(Request::Query(query_op))
            }
            Token::LBracketPipe => {
                let batch = AtomicBatch::decode(self)?;
                Ok(Request::AtomicBatch(batch))
            }
            other => Err(Error::UnexpectedToken {
                expected: "request sigil or delimiter",
                got: other.clone(),
            }),
        }
    }

    // Methods called by derived impls:
    pub fn expect_record_head(&mut self, name: &str) -> Result<()> { ... }
    pub fn expect_record_end(&mut self) -> Result<()> { ... }
    pub fn expect_pattern_record_head(&mut self, name: &str) -> Result<()> { ... }
    pub fn expect_pattern_record_end(&mut self) -> Result<()> { ... }
    pub fn peek_record_head(&mut self) -> Result<String> { ... }
    pub fn read_pascal_identifier(&mut self) -> Result<String> { ... }
    pub fn decode_pattern_field<T: NexusDecode>(
        &mut self,
        expected_bind_name: &str,
    ) -> Result<PatternField<T>> { ... }
    // ... primitive decoders for u64, i64, f64, String, bool, Vec<T>, Option<T>, etc.
}

pub struct Encoder {
    output: String,
    dialect: Dialect,
}

impl Encoder {
    pub fn nexus() -> Self { ... }
    pub fn nota() -> Self { ... }
    pub fn into_string(self) -> String { self.output }

    pub fn encode<T: NexusEncode>(&mut self, value: &T) -> Result<()> {
        value.encode(self)
    }

    // Methods called by derived impls:
    pub fn start_record(&mut self, name: &str) -> Result<()> { ... }
    pub fn end_record(&mut self) -> Result<()> { ... }
    pub fn start_pattern_record(&mut self, name: &str) -> Result<()> { ... }
    pub fn end_pattern_record(&mut self) -> Result<()> { ... }
    pub fn write_pascal_identifier(&mut self, name: &str) -> Result<()> { ... }
    pub fn encode_pattern_field<T: NexusEncode>(
        &mut self,
        value: &PatternField<T>,
        bind_name: &str,
    ) -> Result<()> { ... }
    // ... primitive encoders
}
```

The runtime types define the *protocol* the derives speak.
Adding a derive variant means deciding what method on the
runtime it calls into; the runtime itself is small and stable.

Estimated runtime LoC: ~300 (Decoder ~180, Encoder ~120),
plus Lexer (~525, unchanged from nota-serde-core).

---

## 4 · The `NexusEncode` / `NexusDecode` traits

The two traits everything ties to:

```rust
pub trait NexusEncode {
    fn encode(&self, encoder: &mut Encoder) -> Result<()>;
}

pub trait NexusDecode: Sized {
    fn decode(decoder: &mut Decoder) -> Result<Self>;
}
```

Blanket impls for primitives and standard containers are
hand-written once in nexus-codec:

- `impl NexusEncode/Decode for u64` — bare integer in nexus
  text
- `impl NexusEncode/Decode for i64` — bare integer (signed)
- `impl NexusEncode/Decode for f64` — float literal
- `impl NexusEncode/Decode for bool` — `true` / `false`
- `impl NexusEncode/Decode for String` — `"quoted"` form,
  with the bare-identifier optimization for short strings
- `impl NexusEncode/Decode for Vec<T> where T: NexusEncode/Decode` — `[a b c]` form
- `impl NexusEncode/Decode for Option<T> where T: NexusEncode/Decode` — see §6.1 open question
- `impl NexusEncode for &str` — convenience encode-only

The `Slot` / `Revision` / `Hash` / `BlsG1` newtypes get hand-
written impls too (4 types × ~10 LoC = ~40 LoC). They could
be derived via a `NexusTransparent` derive, but they're rare
enough that the hand-impl is cheaper than the derive.

---

## 5 · The proc-macro implementation

The `nexus-derive` crate (proc-macro). One file per derive,
plus a shared module for common machinery.

### 5.1 Crate setup

```
nexus-derive/
├── Cargo.toml      # proc-macro = true; deps: syn, quote, proc-macro2
├── src/
│   ├── lib.rs      # 4 #[proc_macro_derive] entry points
│   ├── record.rs   # NexusRecord implementation
│   ├── pattern.rs  # NexusPattern implementation
│   ├── enum.rs     # NexusEnum implementation (file: nexus_enum.rs to avoid keyword)
│   └── verb.rs     # NexusVerb implementation
```

Cargo.toml:

```toml
[package]
name = "nexus-derive"
edition = "2024"

[lib]
proc-macro = true

[dependencies]
syn = { version = "2.0", features = ["full"] }
quote = "1.0"
proc-macro2 = "1.0"
```

### 5.2 Skeleton of `record.rs`

```rust
use proc_macro2::TokenStream;
use quote::quote;
use syn::{Data, DeriveInput, Fields};

pub fn derive_record(input: DeriveInput) -> TokenStream {
    let name = &input.ident;
    let name_str = name.to_string();

    let fields = match &input.data {
        Data::Struct(s) => match &s.fields {
            Fields::Named(named) => &named.named,
            Fields::Unit => &syn::punctuated::Punctuated::new(),
            Fields::Unnamed(_) => panic!("NexusRecord requires named fields or unit"),
        },
        _ => panic!("NexusRecord can only be derived for structs"),
    };

    let encode_calls = fields.iter().map(|f| {
        let field_name = &f.ident;
        quote! { self.#field_name.encode(encoder)?; }
    });

    let decode_bindings = fields.iter().map(|f| {
        let field_name = &f.ident;
        let field_type = &f.ty;
        quote! {
            let #field_name = <#field_type as NexusDecode>::decode(decoder)?;
        }
    });

    let init_fields = fields.iter().map(|f| f.ident.clone());

    quote! {
        impl NexusEncode for #name {
            fn encode(&self, encoder: &mut Encoder) -> Result<(), nexus_codec::Error> {
                encoder.start_record(#name_str)?;
                #(#encode_calls)*
                encoder.end_record()
            }
        }

        impl NexusDecode for #name {
            fn decode(decoder: &mut Decoder) -> Result<Self, nexus_codec::Error> {
                decoder.expect_record_head(#name_str)?;
                #(#decode_bindings)*
                decoder.expect_record_end()?;
                Ok(Self { #(#init_fields),* })
            }
        }
    }
}
```

### 5.3 Estimated proc-macro crate size

| Module | LoC |
|---|---|
| `lib.rs` | ~30 (4 entry points + parsing) |
| `record.rs` | ~80 |
| `pattern.rs` | ~120 (more complex due to query-name suffix stripping + bind-name plumbing) |
| `enum.rs` | ~60 |
| `verb.rs` | ~100 (handles both newtype-variant and struct-variant cases) |
| Shared utilities | ~40 |
| **Total** | **~430 LoC** |

Plus the runtime crate (`nexus-codec`):

| Module | LoC |
|---|---|
| Lexer | 525 (unchanged from nota-serde-core) |
| Decoder + protocol methods | ~200 |
| Encoder + protocol methods | ~150 |
| Trait definitions + blanket impls for primitives/Vec/Option | ~120 |
| Error type | ~50 |
| **Total** | **~1045 LoC** |

Grand total for Stage 2: **~1475 LoC** (430 derive + 1045
runtime). Compare with today's ~1750 LoC across nota-serde-core
+ nexus-serde + the nexus QueryParser.

The derive-crate cost (~430 LoC) is **paid once** and
amortizes across every kind in the schema. Per-kind cost is
the `#[derive(...)]` line.

---

## 6 · Open design questions

These are decisions to make at Stage 2 implementation time.
Each affects the wire format, so they're load-bearing.

### 6.1 `Option<T>` representation

`MutateOp::Node { slot, new, expected_rev: Option<Revision> }`
needs a wire form for the absent case. Three options:

**(a) Trailing-omission.** If `expected_rev` is `None`, the
record ends one position early: `~(Node 100 (Node "User"))`.
If `Some(5)`, all positions present: `~(Node 100 (Node "User") 5)`.
Pros: short, natural. Cons: variable-arity records; the
decoder needs to peek-for-end after each optional position.
Optionals can only appear in trailing positions — non-trailing
optionals are illegal.

**(b) Sentinel.** `_` for None, value otherwise:
`~(Node 100 (Node "User") _)`. Pros: positions stay fixed.
Cons: `_` is also the wildcard in pattern positions —
context-disambiguated, but a possible reader trip.

**(c) Tagged.** `(None)` / `(Some 5)` for absent / present.
Pros: explicit. Cons: ugly in the common case; doubles every
optional field's wire bytes.

**Recommendation: (a) trailing-omission.** Forces a discipline
that optional fields appear last in the struct, which is
already a Rust style virtue. The variable-arity decoder has
one extra `peek_token` per optional field — cheap.

### 6.2 Struct-variant verbs

`MutateOp` has struct variants, not tuple variants. The wire
form for `MutateOp::Node { slot, new, expected_rev }` is
positional: `(Node slot new expected_rev)` after the `~`
sigil. The struct-variant field names are NOT in the wire form
— they're recovered by position.

This is a fine convention but requires the derive to emit
positional decoders for struct variants, ignoring the field
names at the wire boundary. The field names still serve as
the names in the decode-binding step (per §2.4).

### 6.3 `NexusPattern` query-type-name suffix stripping

The derive on `EdgeQuery` needs to know to emit `(| Edge ... |)`,
not `(| EdgeQuery ... |)`. Options:

**(a) Strip `Query` suffix automatically.** Convention-driven;
fails if a query type doesn't end in `Query`.

**(b) Require explicit `#[nexus(record = "Edge")]` attribute.**
Robust but ceremonial.

**(c) Both.** Strip if no attribute present; attribute wins
if specified.

**Recommendation: (c).** Convention works for the M0 kinds
(NodeQuery → Node, EdgeQuery → Edge, etc.) and the attribute
is the explicit override.

### 6.4 The blanket `Vec<T>` and `Option<T>` impls

These need to be in nexus-codec, not in user code. But the
derive-emitted code does `<#field_type as NexusDecode>::decode(decoder)`
which requires the impl to be visible at the derive call site.
Standard Rust orphan-rules play out: as long as nexus-codec
defines the trait + the blanket impls for std types,
downstream crates can derive freely.

### 6.5 Trait import ergonomics

The derived code says `NexusEncode for #name` and assumes the
trait is in scope. Two options:

**(a) Re-export from nexus-codec at the user-crate level.**
User does `use nexus_codec::*;` once.

**(b) Fully-qualify in the derive output.** `impl
nexus_codec::NexusEncode for #name`. Users don't need the
import.

**Recommendation: (b)** for the trait paths, with `use
nexus_codec::{Decoder, Encoder, Result};` for the runtime
types in user code. Standard proc-macro practice.

### 6.6 Error type — unified or per-crate?

The derives emit `Result<_, nexus_codec::Error>`. User crates
that want their own error types would need to wrap. Either:

**(a) Hard-code nexus-codec's Error in the trait signature.**
Simplest; binds users to one error type.

**(b) Associated error type on the trait.** `type Error;`
per the FromStr pattern. More flexibility, more ceremony in
the derive.

**Recommendation: (a)** for now. nexus-codec is the
canonical home for nexus-text errors; downstream crates
convert via `?` if they want to wrap.

### 6.7 Tests live where?

The proc-macro itself can be unit-tested via
`trybuild` (compile-fail tests for bad inputs) and via
**integration tests in nexus-codec** that derive on test
types and round-trip values. The derive crate itself doesn't
need separate tests beyond the trybuild compile-checks.

---

## 7 · Migration path from current serde

Concrete steps at the Stage 2 boundary:

1. **Create `nexus-derive` crate.** Implement the four
   derives. ~430 LoC.
2. **Create `nexus-codec` crate.** Implement Decoder,
   Encoder, traits, blanket impls. Reuse
   nota-serde-core::Lexer (which becomes nota-lexer in
   step 6).
3. **Add derives to signal types alongside existing serde
   derives.**
   ```rust
   #[derive(Archive, RkyvSerialize, RkyvDeserialize,
            NexusRecord,
            Serialize, Deserialize,    // ← still here for now
            Debug, Clone, PartialEq)]
   pub struct Node { pub name: String }
   ```
   This is a no-op behaviorally — the new traits exist but
   nothing calls them yet.
4. **Wire criome to use Decoder/Encoder.** Replace
   `from_str_nexus::<Request>(text)` calls with
   `Decoder::nexus(text).next_request()`. One daemon at a
   time.
5. **Wire nexus daemon to use Decoder/Encoder.** Same.
6. **Run the test suite.** Both serde and nexus-codec paths
   exist; tests on each pass independently. Integration
   tests round-trip through the new path.
7. **Drop serde derives from signal types.**
   ```rust
   #[derive(Archive, RkyvSerialize, RkyvDeserialize,
            NexusRecord,
            Debug, Clone, PartialEq)]
   ```
8. **Delete `nexus-serde` crate.** All six sentinel wrappers
   gone.
9. **Reduce `nota-serde-core` to just the lexer.** Rename to
   `nota-lexer`. ~525 LoC remaining, all of it
   format-positive. Delete `de.rs` and `ser.rs`.
10. **Delete `nexus/src/parse.rs::QueryParser`.** Its logic
    is now spread across the `NexusPattern` derive on each
    `*Query` type and the runtime `Decoder::decode_pattern_field`
    method.

Net code change at completion of Stage 2:

- **Added**: nexus-derive (~430 LoC), nexus-codec (~1045 LoC).
- **Deleted**: nota-serde-core/{de,ser}.rs (~1230 LoC),
  nexus-serde (~94 LoC), nexus/src/parse.rs (~240 LoC).
- **Renamed**: nota-serde-core → nota-lexer (525 LoC kept).
- **Net delta**: +~1475 LoC vs −~1564 LoC = ~−90 LoC,
  PLUS the deleted serde-derive expansion code that we
  weren't counting (probably another ~500 LoC of
  invisible code per kind across all derive sites).

The Stage 2 work nets to **less code** and the new code is
uniformly *our verb vocabulary*.

---

## 8 · Cost estimate revised

Per [reports/098 §4.2](098-serde-replacement-decision-2026-04-27.md),
the original estimate was ~3 days for Option 2 (one extra day
vs Option 1's hand-written approach for the proc-macro crate).
With the design above as a starting point, refined estimate:

- nexus-derive crate: 1.5 days
- nexus-codec crate: 1 day
- Migration (steps 3–10): 1 day
- **Total: ~3.5 days**

Estimate is a rough upper bound; the design work in this
report reduces ambiguity and should compress the implementation.

---

## 9 · Comparison with Option 1 (hand-written)

When Option 2 (custom derive) is preferable:

- **Kind count growing.** M1+ adds list-pattern types,
  constraint forms, possibly more flow-graph kinds. Each new
  kind = one `#[derive(NexusRecord)]` line, free.
- **Schema-as-data alignment.** rsc emits `#[derive(NexusRecord)]`
  on the projected struct; the derive emits the trait impl.
  Two-stage projection that decouples "what the kind looks like
  in Rust" from "what its wire format is."
- **Cross-cutting changes.** If the wire format gains a new
  feature (say, a per-record version tag), the derive emits
  the tag for every kind in one change.
- **Beauty.** `#[derive(NexusRecord)]` reads as "this is a
  nexus record"; that *is* what we mean.

When Option 1 (hand-written) is preferable:

- **Per-kind tuning needed.** If certain kinds need
  hand-tuned encoding (e.g., a special compact form for
  `Slot`), hand-writing is direct. The derive can be extended
  with attributes, but each attribute adds proc-macro
  complexity.
- **No new crate to maintain.** The derive crate is one more
  thing in the dependency graph.
- **Stage 3 directness.** rsc projects directly to hand-written
  methods, no derive intermediary. One less indirection.

**Recommendation: Option 2.** The schema is going to grow
post-M0 (criome plans flow-graph subkinds, machina records,
operational records, world-fact records — see
[criome ARCHITECTURE.md §10](https://github.com/LiGoldragon/criome/blob/main/ARCHITECTURE.md)).
The per-kind cost of Option 1 compounds linearly with kind
count. The proc-macro crate is one-time work that pays back
on every new kind.

The Stage 3 question — "rsc emits derive lines or hand-written
methods" — is independent and decided when rsc lands. If we
have the derive crate, rsc can emit one line per kind; without
it, rsc emits the full method body. Both are mechanical.

---

## 10 · Recommendation

**Implement Option 2 at the Stage 2 boundary.** This report's
design is concrete enough that a Stage 2 worker can start from
§§2–5 directly. The open questions in §6 are flagged as
implementation-time decisions; the answers don't change the
overall shape.

The custom-derive approach:

- aligns with [methods-on-types](../repos/tools-documentation/programming/abstractions.md)
  (every verb a method, no free functions),
- aligns with [perfect specificity (Invariant D)](https://github.com/LiGoldragon/criome/blob/main/ARCHITECTURE.md)
  (closed dispatch on Token enum + closed dispatch on
  variant set in NexusVerb derives),
- aligns with [beauty as criterion](../repos/tools-documentation/programming/beauty.md)
  (no sentinel wrappers, no carve-outs, no special cases —
  the QueryParser collapses into the normal case),
- aligns with the [bootstrap-era macro policy](https://github.com/LiGoldragon/criome/blob/main/ARCHITECTURE.md)
  (we may author macros now; they're transitional code that
  rsc later supersedes),
- and saves code (~−90 LoC net, plus ~−500 LoC of invisible
  serde-expansion).

The eventual rsc-projection (Stage 3) can emit either
`#[derive(NexusRecord)]` on the projected struct OR the full
method bodies — that decision is independent and lives at
the rsc-implementation boundary.

---

*End 099.*
