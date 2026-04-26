# 087 — M0 plan, decisions, grammar findings

*Supersedes 086 (deleted). Carries: my own arch-doc review,
capitalization research, re-explanations of the questions
that were unclear, my recommendation on Q4, your decisions on
Q3/Q5/Q6/Q7/Q8 absorbed into the M0 plan.*

All file references use relative paths via the workspace
symlinks at [`../repos/`](../repos/) so they open in the
editor.

---

## 1 · Arch-doc review (my own pass)

I grepped each file for the deprecated terms and read each
section against the current `signal::Request` / `Reply` enums
in [`../repos/signal/src/request.rs`](../repos/signal/src/request.rs)
and [`../repos/signal/src/reply.rs`](../repos/signal/src/reply.rs).

### 1.1 [`../repos/nexus-cli/ARCHITECTURE.md`](../repos/nexus-cli/ARCHITECTURE.md) — heavy rewrite

```
L10  "All speak client-msg"                  → client_msg deleted; CLI
                                                writes pure nexus text bytes
                                                to /tmp/nexus.sock
L11  "rkyv envelope around nexus text         → no envelope at this leg;
      payloads + heartbeat / cancel / resume   text is self-delimited by
      control verbs"                           matched parens
L18  "Wrapping it in a client_msg::Send       → no wrapper; just write text
      with optional fallback path"             bytes
L21  "Cancel / resume from a fallback file"  → no cancel/resume; close
                                                socket = end
L32  "Patch, TxnBatch"                       → AtomicBatch only; Patch is
                                                Mutate-with-pattern
L45  "{|| ... ||} syntax"                    → real syntax is [| |]
L52  "Reply::Rejected"                       → OutcomeMessage::Diagnostic
                                                inside Reply::Outcome /
                                                Reply::Outcomes
L70  "retrievable via Resume"                → no Resume verb
L85  "[nexus::client_msg] link"              → dead link
```

This file needs a clean rewrite, not patches. The whole §Role
+ §Boundaries + §Edit UX + §Diagnostics paragraphs are built
on the deleted client_msg framing.

### 1.2 [`../repos/sema/ARCHITECTURE.md`](../repos/sema/ARCHITECTURE.md) — 2-line fix

```
L43  "(those live in nexus-schema)"   → "(those live in signal)"
L81  "Backing types are in            → "Backing types are in signal."
      nexus-schema."
```

### 1.3 [`../repos/criome/ARCHITECTURE.md`](../repos/criome/ARCHITECTURE.md) — surgical edits + an aspirational-vs-current ambiguity

**Stale references:**

```
L198-199  "criome-schema (CANON-MISSING; not yet      → signal (types
           a separate crate); subsequent ones           absorbed there)
           validate against records the genesis
           stream has already asserted"
L458      Layer-1 row "nexus-schema (record-kind     → drop the row;
           declarations: Fn, Struct, Opus, …)"         schema vocabulary
                                                       lives in signal now
L581      "Pattern reference: [nexus-schema]"        → redirect to signal
```

**Aspirational-vs-current ambiguity around `Compile`:**
The doc lists `Compile` as a request verb in 6 places (lines
40, 168, 368, 416, 424, 438, 518, 539). `signal::Request` has
no `Compile` variant — it's a planned future verb that
triggers the lojix-schema dispatch pipeline.

This isn't a "lie" per se — the arch doc describes the
long-term shape — but it reads ambiguously alongside current
verbs (Assert / Mutate / Query) that DO exist today. Two ways
to fix:

- **(A) Mark Compile as forward-looking** in §1 / §3 / §9
  with a parenthetical "(planned; not yet in signal::Request)".
- **(B) Add `Compile` to `signal::Request` now** as a stub so
  the doc tells the truth about what exists.

I lean (A) — adding a verb just to back-fill a doc claim is
backwards. A two-word parenthetical fixes it.

### 1.4 Other docs

- [`../repos/nexus/ARCHITECTURE.md`](../repos/nexus/ARCHITECTURE.md) — clean. No stale terms. ✓
- [`../repos/signal/ARCHITECTURE.md`](../repos/signal/ARCHITECTURE.md) — one line (56) acknowledges "absorbed from the former nexus-schema crate" as historical context. That's accurate. ✓
- [`../repos/nexus/spec/grammar.md`](../repos/nexus/spec/grammar.md) — locked v3, current. ✓
- [`../repos/nota/README.md`](../repos/nota/README.md) — current. One nuance worth flagging — see §2 (capitalization) below.
- [`../repos/sema/reference/Vision.md`](../repos/sema/reference/Vision.md) — plain language, current. ✓

---

## 2 · Capitalization in nexus — research findings

You said "I feel like not using Pascal/camel is a lost
opportunity." The research bears that out. Findings:

### 2.1 What the grammar currently says

Per [`../repos/nota/README.md`](../repos/nota/README.md#L66-L83)
the lexer recognises three disjoint identifier classes:

```
PascalCase      first char uppercase           types/variants (convention)
camelCase       first char lowercase or _      fields/instances (convention)
                no '-' in body
kebab-case      first char lowercase or _      titles/tags (convention)
                at least one '-' in body
```

**The classes are tokenised separately but not enforced
semantically.** The lexer in
[`../repos/nota-serde-core/src/lexer.rs`](../repos/nota-serde-core/src/lexer.rs)
emits a single `Token::Ident(String)` regardless of class.
The deserialiser in
[`../repos/nota-serde-core/src/de.rs`](../repos/nota-serde-core/src/de.rs)
uses case-sensitive string matching against Rust type names —
so writing `(node "X")` instead of `(Node "X")` fails the
type-name match, but only as a downstream consequence, not as
a parse error.

The **one place** case is enforced is bind-name validation in
[`../repos/nexus-serde/src/lib.rs`](../repos/nexus-serde/src/lib.rs):
binds must be camelCase or kebab-case (no uppercase). This is
checked at *serialisation* time, not parse time.

### 2.2 What the example `.nexus` files do (consistent convention)

```
PascalCase    Node, Edge, Graph, Flow, DependsOn, RelationKind variants
camelCase     @name, @from, @to, @kind, @nodes, @edges, @subgraphs (binds)
kebab-case    "nexus daemon", "criome request flow" (string contents,
              quoted because they have spaces — kebab as a syntactic
              identifier doesn't actually appear in the engine examples)
UPPER_SNAKE   absent
snake_case    absent
```

So in practice: PascalCase = type/variant, camelCase = bind,
and kebab-case is a stylistic option for human-language tags
(but actual examples use quoted strings for those).

### 2.3 What's the lost opportunity

The classes exist at the lexer level but carry no parse-time
semantic weight. Two cheap wins:

**Idea A — enforce PascalCase for record/variant names.**
Writing `(node "X")` fails at parse time with "expected
PascalCase type name" rather than later as a type lookup
failure. ~5 LoC in the deserialiser. No cost: every working
example already complies.

```nexus
(Node "User")        ✓
(node "User")        ✗ parse error: type name must be PascalCase
```

**Idea B — enforce `@`-prefix on every bind.** The grammar
already requires this (binds are `@name`), but bare lowercase
identifiers in pattern positions today aren't rejected. With
this rule, the parser distinguishes "literal value" from
"bind" lexically:

```nexus
(| Point @x @y |)        ✓ binds are @-prefixed
(| Point x y |)          ✗ parse error: bare lowercase in pattern
                            position must be @-prefixed
(| Point 3.0 @y |)       ✓ literal + bind mix
(| Point @Bind y |)      ✗ parse error: bind name must be camelCase
```

### 2.4 What I'd skip

- **UPPER_SNAKE for constants.** Constants belong in the
  schema, not the text. Adding a fourth lexer class for a
  use-case the schema already covers buys nothing.
- **kebab-case as a separate enforced role.** It's a styling
  choice for tag-like identifiers; leave as convention.

### 2.5 Decision — adopt A + B both

**Reasoning (Li, 2026-04-27):** *"both actually; since
unquoted single words can be strings, we need a way to know
its a bind — otherwise what is the sigil for?"*

This is the load-bearing argument. Bare-ident-strings are
already in the grammar (per
[`../repos/nota/README.md`](../repos/nota/README.md#L99-L131)
§Bare-identifier strings) — `(Package nota-serde)` is a
valid record where `nota-serde` is a String. In a pattern
context, an unprefixed lowercase identifier would be
genuinely ambiguous: bare-string-literal or bind?

The `@` sigil exists precisely to remove that ambiguity.
Enforcing it (Idea B) is what gives the sigil its purpose;
without enforcement the sigil is decorative and the parser
has to guess.

Idea A (PascalCase for types/variants) follows by symmetry:
if lowercase-without-`@` means "string literal" in pattern
position, then PascalCase must mean "type/variant name",
consistently. The lexer already classifies; we just enforce.

**Concrete grammar updates:**

1. [`../repos/nota/README.md`](../repos/nota/README.md)
   §Identifiers — promote PascalCase rule from convention to
   parse-time requirement for record/variant head positions.
2. [`../repos/nexus/spec/grammar.md`](../repos/nexus/spec/grammar.md)
   §Binds — state explicitly: in pattern position, every
   bind must carry the `@` prefix; bare lowercase
   identifiers are bare-string literals (matched by value
   equality), not binds.
3. [`../repos/nota-serde-core/src/de.rs`](../repos/nota-serde-core/src/de.rs)
   — add the case-check at struct-name dispatch (Idea A,
   ~5 LoC) and the `@`-required-in-pattern check (Idea B,
   ~10 LoC).

Total cost ~15 LoC of parser changes, ~10 lines of grammar
spec edits. Zero breakage of current examples.

---

## 3 · Q1 re-explained — typed→RawRecord conversion

I asked this badly. Let me set the context first.

### 3.1 The setup

The signal wire envelope carries `AssertOp { record: RawRecord }`
([`../repos/signal/src/edit.rs`](../repos/signal/src/edit.rs#L23)),
where `RawRecord` is:

```rust
pub struct RawRecord {
    pub kind_name: String,
    pub fields: Vec<(String, RawValue)>,   // ← named fields
}
```

But the nexus text is **positional** — field names live in
the schema, not the text. So `(Node "User")` parses without
knowing the field is called `name`.

### 3.2 The problem

When the nexus daemon receives `(Node "User")` text, it has
to produce a `RawRecord { kind_name: "Node", fields: [("name",
RawValue::Lit(RawLiteral::String("User")))] }` to wrap into
an AssertOp. Where does the field name `"name"` come from?

```
   text in:    (Node "User")
                     │
                     │ parse via nota-serde-core
                     ▼
        ┌────────────┴───────────────┐
        │ FORK: how do we get from   │
        │ positional text to NAMED   │
        │ RawRecord fields?          │
        └────────────┬───────────────┘
                     │
        ┌────────────┴────────────────┐
        │                              │
        ▼                              ▼
   PATH A:                        PATH B:
   typed first,                   straight to RawRecord,
   then reflect                   synthetic field names
        │                              │
        ▼                              ▼
   Node{name:"User"}               RawRecord{
   (needs serde derives             kind:"Node",
    on Node)                         fields:[("_0",..)]
                                    }  ← criome can't validate
        │                              │  against schema names
        │ reflect helper               │
        │ (~30 LoC; can be             ▼
        │  hand-written per kind       (this loses the named-
        │  or generic via              field benefit;
        │  serde-reflection)           hard to scale)
        ▼
   RawRecord{
     kind:"Node",
     fields:[("name", "User")]
   }
        │
        ▼
   AssertOp{record} → Frame → criome
```

### 3.3 The decision

Path A is the path the architecture implies. The cost is:

1. Add `serde::Serialize, serde::Deserialize` derives to
   `Node`, `Edge`, `Graph`, `RelationKind` in
   [`../repos/signal/src/flow.rs`](../repos/signal/src/flow.rs)
   (3 lines per type).
2. Write a reflect helper in the nexus daemon — ~30 LoC —
   that walks a typed value and produces RawRecord. Either
   one match arm per kind (grows linearly), or generic via
   `serde-reflection` crate (one-time cost, scales).

**Question for you:** Path A or B? If A, per-kind match arms
or `serde-reflection`?

---

## 4 · Q2 re-explained — schema-check rigour

Context I left out: "schema-check" is the first stage of the
six-stage validator pipeline in
[`../repos/criome/src/validator/`](../repos/criome/src/validator/).
It runs when criome receives an `Assert(AssertOp)` frame. Its
job: reject malformed records before they touch sema.

The stages are listed in
[`../repos/criome/ARCHITECTURE.md`](../repos/criome/ARCHITECTURE.md#L7-L17)
§1: schema → refs → invariants → permissions → write → cascade.

### 4.1 What "schema-check" could check

```
┌──────────────────────────────────────────────────────────┐
│ Three rigour levels for schema-check on RawRecord        │
├──────────────────────────────────────────────────────────┤
│                                                          │
│ Level 0 — kind name only                                 │
│   KNOWN_KINDS.contains(&record.kind_name)                │
│   accepts: (Node "X")                                    │
│   accepts: (Node)              ← arity wrong, accepts    │
│   accepts: (Node 5)            ← type wrong, accepts     │
│   rejects: (Frobnicator …)                               │
│                                                          │
│ Level 1 — name + arity                                   │
│   + record.fields.len() == expected_for_kind             │
│   rejects: (Node)                                        │
│   accepts: (Node "X")                                    │
│   accepts: (Node 5)            ← type wrong, accepts     │
│                                                          │
│ Level 2 — name + arity + literal types                   │
│   + each RawValue::Lit variant matches expected type     │
│   accepts only: (Node "X")                               │
│                                                          │
└──────────────────────────────────────────────────────────┘
```

### 4.2 Why this matters now

If we go Path A in Q1 (typed parse first), then by the time
RawRecord reaches criome it's already L2-validated by
serde at the daemon. So criome's schema-check stage becomes:

- **L0 in criome** (just confirm kind_name exists in
  KNOWN_KINDS, since the daemon parser would have rejected
  any malformed typed value before reflecting to RawRecord)
- *or* L2 in criome (defensive — re-validate, in case some
  other signal-speaking client sends a malformed RawRecord
  bypassing the daemon)

For M0 with only the daemon as a signal client, L0 is enough.
For "trust no client" (which makes sense for M3 when external
signal-speaking peers join), L2 in criome.

**Question for you:** L0 in criome at M0, with L2 deferred to
when non-daemon signal clients exist? Or do L2 from day one?

---

## 5 · Q4 — Slot newtype on the wire (my answer + a deeper conflict)

You said *"if we start passing the type through, then we are
defeating the point of the newtype"*. This actually surfaces
a real conflict in the docs.

### 5.1 What the example shows

[`../repos/nexus/spec/examples/flow-graph.nexus`](../repos/nexus/spec/examples/flow-graph.nexus#L37):

```nexus
(Edge 100 101 Flow)        ;; bare integers in slot positions
```

### 5.2 What [`../repos/nota/README.md`](../repos/nota/README.md#L165-L176) says

> Rust single-field unnamed structs (`struct Id(u32)`) are
> allowed and serialize *wrapped*, with one positional
> value: `(Id 42)`. **Not transparently** — `(Id 42)` is the
> canonical form, not bare `42`. This preserves structural
> integrity across the wire.

So the canonical form per nota would be:

```nexus
(Edge (Slot 100) (Slot 101) Flow)
```

The example file violates the nota newtype rule. This is a
real inconsistency in the docs.

### 5.3 The two ways out

```
┌──────────────────────────────────────────────────────────────┐
│ OPTION 1 — keep nota's "newtypes always wrap" rule          │
│                                                              │
│ change examples to (Edge (Slot 100) (Slot 101) Flow)         │
│                                                              │
│ pro:  consistent rule across all newtypes                    │
│ pro:  type marker visible on wire (your concern preserved)   │
│ con:  every slot reference becomes verbose                   │
│ con:  example "(Edge 100 101 Flow)" was the appealing form   │
└──────────────────────────────────────────────────────────────┘

┌──────────────────────────────────────────────────────────────┐
│ OPTION 2 — extend nota's bare-ident-string rule to           │
│            "bare-literal-for-newtype-of-primitive when       │
│             the schema position expects it"                  │
│                                                              │
│ keep examples as (Edge 100 101 Flow); the parser knows       │
│ position 0 expects Slot (newtype of u64) and accepts bare    │
│                                                              │
│ pro:  matches the appealing example                          │
│ pro:  consistent with bare-ident-string already in nota      │
│       (both are "schema position determines what literals    │
│        the parser accepts; literals coerce to expected       │
│        types")                                               │
│ con:  newtype's type marker is hidden on wire                │
│ con:  needs a nota README update — the current rule          │
│       explicitly forbids this                                │
└──────────────────────────────────────────────────────────────┘
```

### 5.4 My recommendation — Option 2

The bare-ident-string rule already does exactly this for
strings:

```nexus
(Package nota-serde)         ;; not (Package (String "nota-serde"))
```

The schema knows the field is a String, so bare-ident is
accepted and coerces. The newtype concern ("don't lose the
type") is addressed in *Rust* — the type-safety of `Slot(u64)`
prevents you from passing a `u64` where a `Slot` is required.
The wire form is positional + schema-driven; the type is
implicit in position.

`#[serde(transparent)]` on Slot/Revision is the mechanism;
the *grammar rule* update to nota README is what makes it
canonical.

Counter: if you want type markers visible on wire as a
discipline, Option 1 is your call. The cost is verbosity.

**Decision needed:** Option 1 or Option 2? My recommendation
is 2 — but it's a real grammar choice.

---

## 6 · Decisions you made

Absorbing your answers into the plan:

| Q | Your answer | Plan effect |
|---|---|---|
| Q3 — slot allocation | Sema-owned, agreed | sema's `meta` table holds `next_slot` counter; `sema.store(bytes) → Slot` |
| Q5 — lojix-schema dep | "Maybe a form of documentation; comment next to it" | Keep dep in [`../repos/criome/Cargo.toml`](../repos/criome/Cargo.toml); add comment "// reserved for M2+ Compile/Bundle dispatch" |
| Q6 — reply rendering | "NO HARDCODING — put this in the arch doc" | Daemon renders all replies via nota-serde-core; add Serialize derives to `Ok`, `Diagnostic`, etc. Architecture rule: "no hardcoded text rendering of typed values; all rendering goes through nota-serde-core / nexus-serde". Lands in [`../repos/criome/ARCHITECTURE.md`](../repos/criome/ARCHITECTURE.md) §10 as a project-wide rule. |
| Q7 — genesis vs hardcoded KNOWN_KINDS | "can we do a genesis nexus instead of hardcoding?" | Yes. Drop the `KNOWN_KINDS` const. Replace with a `genesis.nexus` file that asserts `KindDecl` records for `Node`, `Edge`, `Graph`. Criome boots, dispatches genesis text through the same parsing path, KindDecls land in sema, schema-check validates against in-sema KindDecls. (~50 extra LoC; eliminates the Rust-side const.) |
| Q8 — queries in M0 | "Absolutely. what is a database without query?" | Yes. M0 includes pattern matching. Adds ~80 LoC for the parser deserializer paths (LParenPipe, LBrace, LBracePipe) and ~60 LoC for the matcher in criome. New M0 total: ~450 LoC. |

---

## 7 · M0 plan, updated

### 7.1 Architecture (with daemon, genesis, queries)

```
   ┌─────────────────┐
   │   nexus-cli     │  ~30 LoC — text shuttle
   └────────┬────────┘
            │ pure nexus text
            ▼
   /tmp/nexus.sock
   ┌─────────────────────────────────────────┐
   │           nexus daemon                  │  ~120 LoC
   │                                         │
   │ accept loop                             │
   │   │                                     │
   │   ▼                                     │
   │ parse text via nota-serde-core          │
   │   │                                     │
   │   ▼                                     │
   │ typed value (Node / Edge / Graph        │
   │                / Pattern / Selection)   │
   │   │                                     │
   │   ▼                                     │
   │ reflect to RawRecord / RawPattern       │
   │   │                                     │
   │   ▼                                     │
   │ wrap in signal Frame                    │
   │   │                                     │
   │   ▼                                     │
   │ send to criome; receive Frame reply     │
   │   │                                     │
   │   ▼                                     │
   │ render reply via nota-serde-core        │
   │   │                                     │
   │   ▼                                     │
   │ write text back to client               │
   └─────────────────────────────────────────┘
            │ length-prefixed rkyv Frame
            ▼
   /tmp/criome.sock
   ┌─────────────────────────────────────────┐  ┌──────────────────┐
   │           criome daemon                 │──│   sema (lib)     │
   │                                         │  │   redb file      │
   │ on boot:                                │  │                  │
   │   open sema                             │  │ ~50 LoC          │
   │   if first boot: dispatch genesis.nexus │  │                  │
   │     through full parse pipeline         │  │ store(bytes)→Slot│
   │                                         │  │ get(Slot)→bytes  │
   │ accept loop                             │  └──────────────────┘
   │   │                                     │
   │   ▼                                     │
   │ length-prefixed Frame decode            │
   │   │                                     │
   │   ▼                                     │
   │ dispatch on Request::*                  │
   │   ├ Handshake → HandshakeAccepted       │
   │   ├ Assert → schema-check + write       │
   │   ├ Query → matcher → Records           │
   │   └ _      → Diagnostic E0099           │
   │                                         │
   │ schema-check: kind in sema KindDecls?   │
   │   (genesis loaded these on boot)        │
   │                                         │
   │ ~180 LoC total                          │
   └─────────────────────────────────────────┘
```

### 7.2 The pieces — updated count

| # | What | Where | LoC |
|---|------|-------|-----|
| 1 | redb store/get + slot counter | [`../repos/sema/src/lib.rs`](../repos/sema/src/lib.rs) | ~50 |
| 2 | KindDecl type + reflect helpers | [`../repos/signal/src/`](../repos/signal/src/) (new module) | ~40 |
| 3 | schema-check body — match against KindDecl records in sema | [`../repos/criome/src/validator/schema.rs`](../repos/criome/src/validator/schema.rs) | ~30 |
| 4 | write body — rkyv encode + sema.store | [`../repos/criome/src/validator/write.rs`](../repos/criome/src/validator/write.rs) | ~30 |
| 5 | matcher body — walk RawPattern over sema | [`../repos/criome/src/validator/`](../repos/criome/src/validator/) (new module `matcher.rs`) | ~60 |
| 6 | criome UDS + accept loop + dispatch + genesis bootstrap | [`../repos/criome/src/uds.rs`](../repos/criome/src/uds.rs) + [`main.rs`](../repos/criome/src/main.rs) | ~100 |
| 7 | nexus daemon: text accept + parse + reflect + signal client + render | [`../repos/nexus/src/main.rs`](../repos/nexus/src/main.rs) + helpers | ~120 |
| 8 | nexus-cli text shuttle | [`../repos/nexus-cli/src/main.rs`](../repos/nexus-cli/src/main.rs) | ~30 |
| 9 | parser: LParenPipe / LBrace / LBracePipe deserializer paths | [`../repos/nota-serde-core/src/de.rs`](../repos/nota-serde-core/src/de.rs) | ~80 |
| 10 | `genesis.nexus` text file shipped with criome | [`../repos/criome/genesis.nexus`](../repos/criome/genesis.nexus) (new) | ~20 (3 KindDecls) |
|   | **Total** |   | **~560** |

Up from 310 because of the daemon + queries + genesis. Still
small. Genesis adds the most leverage — it eliminates the
hardcoded const and exercises the full pipeline on boot.

---

## 8 · What's blocking the next step

To start coding I need two more answers:

1. **Q1 (Path A or B)** for typed→RawRecord. My recommendation: A, with per-kind match arms (grow to `serde-reflection` later when worth it).
2. **Q4 (Option 1 or 2)** for Slot wire form. My recommendation: 2 (bare integer + nota rule update).

Settled:
- **Capitalization** — Idea A + B both (per §2.5; the `@`-sigil's purpose is exactly the disambiguation between bind and bare-string).

Plus optional but worth confirming:
- **Compile verb in arch doc** — keep as aspirational with parenthetical, or back-fill stub in signal::Request? (My recommendation: parenthetical.)

Once those are answered I'd:

1. Land the arch-doc fixes from §1 (durable; ~30 min).
2. Land the grammar updates from §2 if Idea A/B accepted (small parser edits + spec updates).
3. Land the M0 code per §7.

---

## 9 · Open architectural questions worth flagging

These didn't make the Q1-Q8 list earlier but surfaced during
this review:

- **Compile verb in `signal::Request`** — long-term planned;
  not present now. See §1.3.
- **Nota README's newtype rule vs. example .nexus** —
  inconsistency surfaced in §5; needs grammar decision.
- **Reply rendering rule** — your "NO HARDCODING" reply (Q6)
  becomes a project-wide architecture rule. I'd write it
  into criome's ARCHITECTURE.md §10 as part of the §1 fix
  pass. Suggested wording: *"No daemon emits typed values as
  hardcoded text strings. All rendering of typed Rust values
  to nexus text goes through nota-serde-core / nexus-serde
  serialisation. The mechanism stays consistent as new kinds
  land."*

---

*End 087.*
