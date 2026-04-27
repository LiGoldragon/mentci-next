# 091 — Pattern parser rethink (auto-named binds)

*Supersedes the deleted 090. Re-derives the query-parser
design with the auto-name-from-schema bind rule front and
centre. The whole problem becomes smaller than I'd been
making it.*

---

## 1 · The rule I forgot

From [`../repos/nexus/spec/grammar.md`](../repos/nexus/spec/grammar.md)
§Binds:

> The bind's name comes from the schema field at that
> position.

`@from` is the only valid bind name for `Edge.from`. `@f`
is wrong. The user can't pick names. Aliasing
(`@from=@x`) is the only way to introduce alternate names
and is M1+.

I was ignoring this in 089/090 — used arbitrary names
like `@n`, `@f @t @k`, treated `Bind(String)` as if the
string mattered.

---

## 2 · Corrected IR

```rust
pub enum PatternField<T> {
    Wildcard,        // _
    Bind,            // @<schema-field-name>;  name implicit from position
    Match(T),        // literal value
}
```

No String. The bind's "name" IS the *Query record's field
name at that position. The IR doesn't need to carry it.

Effect on existing code:
- [signal/src/pattern.rs](../repos/signal/src/pattern.rs)
  `PatternField::Bind(String)` → `PatternField::Bind`
- [signal/src/frame.rs](../repos/signal/src/frame.rs)
  4 round-trip tests use `Bind("name".into())` → drop
  the payload

Concrete trace, `(| Edge 100 @to DependsOn |)`:

```rust
QueryOp::Edge(EdgeQuery {
    from: PatternField::Match(Slot(100)),
    to:   PatternField::Bind,                       // ← was Bind("to")
    kind: PatternField::Match(RelationKind::DependsOn),
})
```

The result-set still has a binding named `"to"` (it's the
field name on EdgeQuery); the IR doesn't repeat it.

---

## 3 · The parser, much simpler

Per *Query field position the parser does:

```
peek next token:
  Token::Ident("_") → consume; emit Wildcard
  Token::At         → consume; read ident; emit Bind
                      (M0: ignore the ident; M1+: validate
                       == schema field name OR start of
                       alias form)
  anything else     → recurse: parse as T (the field's
                                typed Rust value);
                      emit Match(value)
```

Three primitive cases per position. The "dispatch" is
literally `match peek_token()`. There's no serde-machinery
problem because PatternField doesn't go through enum-by-
variant-name dispatch — it gets a small custom Deserialize
impl that owns these three cases.

For the kind dispatch (`(| Node ... |)` → which *Query),
the daemon's `parse_query` reads the kind name and
constructs the right `QueryOp::*` variant. Per-kind
match arm + per-field PatternField parsing. ~50 LoC
total for the four M0 kinds.

---

## 4 · Why this dissolves the "Path A vs Path B" debate

The earlier debate was over whether to fit PatternField
dispatch into nota-serde-core's enum machinery. Now:

- PatternField has a hand-written Deserialize impl
  (~15 lines) that uses nota-serde-core's existing public
  API for the recursive Match case.
- *Query types deserialize via standard derived
  Deserialize — each field calls into PatternField's
  custom impl.
- The OUTER `(| ... |)` form is recognised by the
  daemon's top-level parser dispatch (peek `LParenPipe`
  → it's a query → read kind name → dispatch to typed
  *Query).

No sentinel. No fork in the parser kernel for "pattern
mode". No duplicated logic between path A and path B.

---

## 5 · Bind-name validation — punt

The auto-name rule says `@from` for `Edge.from` is
required. Strict enforcement requires the parser to know
"I'm currently parsing the Nth field of EdgeQuery; its
schema name is `from`." That's threaded context the
default Deserialize machinery doesn't carry.

For M0:
- Parser accepts any `@<ident>`, ignores the ident
- Bind is a no-payload variant; the binding name in
  results comes from the *Query record's field
  position
- `@from` and `@xyz` produce the same IR

For M1+:
- Add a context-aware validator (post-parse pass over
  the typed value) OR thread schema info through the
  parser
- Reject `@xyz` for an Edge.from position with a clear
  error

This punt is honest: M0 trusts the user; M1+ catches
typos. The wire form / IR doesn't change between M0 and
M1+ — only the validation tightens.

---

## 6 · What the daemon's parser looks like end-to-end

```rust
// nexus daemon — parse.rs

pub fn next_top_level(text: &str) -> Result<Option<(Request, usize)>> {
    // Peek the first significant token; dispatch by verb shape.
    // For everything except (| ... |), use nota-serde-core's
    // standard from_str_nexus to parse into the right typed
    // payload (Assert/Mutate/Retract/etc).
    //
    // For (| ... |), call parse_query which uses nota-serde-
    // core's public lexer/peek API to walk the pattern.
}

fn parse_query(text: &str) -> Result<(QueryOp, usize)> {
    let mut lex = Lexer::nexus(text);
    expect(&mut lex, Token::LParenPipe)?;
    let kind = expect_pascal_ident(&mut lex)?;

    let q = match kind.as_str() {
        "Node" => QueryOp::Node(NodeQuery {
            name: parse_pf_string(&mut lex)?,
        }),
        "Edge" => QueryOp::Edge(EdgeQuery {
            from: parse_pf_slot(&mut lex)?,
            to:   parse_pf_slot(&mut lex)?,
            kind: parse_pf_relation_kind(&mut lex)?,
        }),
        "Graph" => QueryOp::Graph(GraphQuery {
            title: parse_pf_string(&mut lex)?,
        }),
        "KindDecl" => QueryOp::KindDecl(KindDeclQuery {
            name: parse_pf_string(&mut lex)?,
        }),
        other => return Err(Error::UnknownKind(other.into())),
    };

    expect(&mut lex, Token::RParenPipe)?;
    Ok((q, lex.consumed_bytes()))
}

fn parse_pf_string(lex: &mut Lexer) -> Result<PatternField<String>> {
    match lex.next_token()? {
        Some(Token::Ident(s)) if s == "_" => Ok(PatternField::Wildcard),
        Some(Token::At) => {
            let _ident = expect_lower_ident(lex)?;  // M0: ignore name
            Ok(PatternField::Bind)
        }
        Some(Token::Ident(s)) => Ok(PatternField::Match(s)),
        Some(Token::Str(s))   => Ok(PatternField::Match(s)),
        other => Err(Error::ExpectedPatternField(format!("{other:?}"))),
    }
}

// parse_pf_slot, parse_pf_relation_kind: same shape with the
// Match case parsing an integer / a PascalCase variant respectively.
```

That's it. ~50 LoC including all four kinds and all three
PatternField parsers. Lives in the nexus daemon.

---

## 7 · Required changes to land this

In order:

1. **signal**: drop the String payload from `PatternField::Bind`
   (one-line enum change), update the 4 round-trip tests in
   frame.rs, push.

2. **nota-serde-core**: expose enough lexer-level public API
   for the daemon's `parse_pf_*` functions to peek + consume
   tokens. Today the `Lexer` and `Token` are already public
   (used in the existing tests); just confirm the daemon can
   construct a Lexer and walk it. Likely no nota-serde-core
   changes needed.

3. **nexus daemon (step 5 of M0)**: implement `parse_query`
   per §6 alongside the rest of the daemon body. Parser
   integration is part of step 5, not a separate step 4.

This collapses what 089 had as steps 4 + 5 into a single
"daemon body" step.

---

## 8 · What this means for 089

[`089 §3`](089-m0-implementation-plan-step-3-onwards.md)
described the parser dispatch as a real complication. It
wasn't — the complication was self-imposed by trying to
fit through serde's enum-by-name machinery. The correct
approach is a direct hand-written parser (~50 LoC) using
the existing public Lexer API.

[`089 §7.3`](089-m0-implementation-plan-step-3-onwards.md)
asked path A vs path B. Both were overspecified. Real
answer: PatternField has a small custom Deserialize that
peeks; daemon has a small parse_query for the outer
container. ~50 LoC total either way.

[`089 §8`](089-m0-implementation-plan-step-3-onwards.md)
listed step 4 as a separate parser-extension task. Drop
it — folded into step 5.

---

## 9 · What I'll do next (if approved)

1. Update `signal/src/pattern.rs` to drop Bind's String
   (push to signal main).
2. Update `signal/src/frame.rs` round-trip tests for the
   new shape (push with above).
3. Continue with [089](089-m0-implementation-plan-step-3-onwards.md)
   step 3 (criome body) + the merged step 5 (daemon body
   with the §6 parser inline).

---

*End 091.*
