# 100 — Explicit handoff after nota-codec shipping

*Read this first. Then read the files in §1 in the order
given, slowly. Then re-read §§2–10 of this report. Then
start work.*

This document is the post-context-reset entry point for the
session that follows. The previous handoff
([`094-handoff-explicit.md`](094-handoff-explicit.md)) is
**stale** and has been deleted — the project shape has
changed substantially since it was written. This file
supersedes it.

The user is **Li**. The project is **criome**. The dev
environment is **mentci**. The conversation that produced
this report ran 2026-04-27 and landed: the full
serde-replacement migration (new `nota-codec` + `nota-derive`
crates, retiring `nota-serde-core` / `nota-serde` /
`nexus-serde`); the `…Op` → `…Operation` rename across
signal; criome's M0 body restructured around a `Daemon` noun
(methods-on-types pattern); `Slot` / `Revision` / `BlsG1`
field privacy; sema's `Slot` made private with `From` traits
+ tests moved to `tests/`; production-readiness expansion of
nota-codec primitives + containers; and a feedback loop with
a downstream agent migrating horizon-rs that surfaced 5 real
gaps (all addressed). 137 tests pass across the new system.

After context reset, **resume the nota work**. Open items
named in §10.

---

## 1 · Required reading, in order — *Li wants you to read a lot*

Read **every** file listed below. Read in order. The order
matters — earlier files set up context for later ones.
**Spawn an `Explore` agent for any file you can't fit in
your own context budget**; the agent returns a compressed
summary that preserves structure. Don't skip files. Li
explicitly asked for thoroughness.

### 1a · Operational rules — load before doing anything

1. [`../AGENTS.md`](../AGENTS.md) — workspace operational
   rules. Substance-in-reports rule, jj workflow with
   blanket-auth always-push, naming rule with bad→good
   table + the "feels too verbose" anti-pattern,
   commit-message S-expression style, design-doc hygiene,
   no-version-history-in-designs, verify-each-parallel-tool
   -result, beauty-as-criterion section.
2. [`../repos/tools-documentation/AGENTS.md`](../repos/tools-documentation/AGENTS.md)
   — workspace-wide cross-project rules + pointers into
   per-tool docs.
3. [`../repos/tools-documentation/programming/beauty.md`](../repos/tools-documentation/programming/beauty.md)
   — **THE central principle.** Beauty is the criterion;
   ugly code is evidence of an unsolved problem; the
   diagnostic catalogue. **Read this twice.** Li reinforces
   this rule constantly. The first reading explains the
   rule; the second makes it operational.
4. [`../repos/tools-documentation/programming/abstractions.md`](../repos/tools-documentation/programming/abstractions.md)
   — methods-on-types discipline. Every reusable verb
   belongs to a noun. Forces noun-creation; LLMs need this
   rule more than humans because they lack tactile
   type-creation friction.
5. [`../repos/tools-documentation/programming/beauty-research.md`](../repos/tools-documentation/programming/beauty-research.md)
   — the deep research backing beauty.md (Plato through
   Alexander; Hardy / Hoare / Dijkstra / Brooks / Hickey /
   Torvalds; Therac-25 / Ariane 5 / Mars Climate Orbiter /
   Heartbleed / Boeing MCAS). **Read this.** Li wants the
   philosophical grounding to be load-bearing in your
   judgment.
6. [`../repos/tools-documentation/programming/abstractions-research.md`](../repos/tools-documentation/programming/abstractions-research.md)
   — deep research backing abstractions.md (Naur / Liskov /
   Parnas / Kay / Brooks / Cook / Fowler).
7. [`../repos/tools-documentation/programming/naming-research.md`](../repos/tools-documentation/programming/naming-research.md)
   — the empirical case for full-words naming (Lawrie 2006,
   Hofmeister 2017, Beniamini 2017, Avidan/Feitelson 2017,
   plus the cultural/historical roots).
8. [`../repos/tools-documentation/rust/style.md`](../repos/tools-documentation/rust/style.md)
   — **Rust style guide.** Beauty is the criterion (§
   second). Methods on types not free fns + the affordances
   rationale. Wrapped field is private. Naming — full words
   by default. Tests live in separate files. Errors via
   thiserror. Authored macros are transitional in the
   bootstrap era (this rule changed in this session — see
   the macro-philosophy section in criome ARCH).
9. [`../repos/tools-documentation/rust/nix-packaging.md`](../repos/tools-documentation/rust/nix-packaging.md)
   — crane + fenix flake layout for any Rust crate.
10. [`../repos/tools-documentation/jj/basic-usage.md`](../repos/tools-documentation/jj/basic-usage.md)
    — jj. **Use `jj commit` always, never `jj describe`**
    for normal commits (the latter creates surprising
    states).
11. [`../repos/tools-documentation/bd/basic-usage.md`](../repos/tools-documentation/bd/basic-usage.md)
    — beads (issue tracker).
12. [`../repos/tools-documentation/nix/basic-usage.md`](../repos/tools-documentation/nix/basic-usage.md)
    — nix. `nix run nixpkgs#<tool>`, never `cargo install`
    / `pip install` / `npm -g`.
13. [`../repos/tools-documentation/dolt/basic-usage.md`](../repos/tools-documentation/dolt/basic-usage.md)
    — dolt (the data store under bd).

### 1b · Project-wide architecture — load before designing

14. [`../repos/criome/ARCHITECTURE.md`](../repos/criome/ARCHITECTURE.md)
    — **THE canonical project doc.** Read in full. Specifically:
    - **§2 Invariants A / B / C / D** are load-bearing.
      - A: Rust is only an output (no `.rs` → sema parsing).
      - B: Nexus is a language, not a record format. Plus
        the four sub-rules (criome-speaks-signal-only,
        nexus-is-not-a-programming-language,
        no-parser-keywords-≠-no-schema-enums,
        slots-are-user-facing-identity).
      - C: Sema is the concern; everything orbits.
      - **D: Perfect specificity.** Every typed boundary
        names exactly what flows through it. Per-verb
        payload types. KindDecl-as-data + typed-Rust-as-
        projection. *Naming throughout uses
        `…Operation` — `AssertOperation` /
        `MutateOperation` / `QueryOperation` etc.*
    - §1 macro philosophy — **bootstrap-era allows authored
      macros**; the eventual self-hosting state replaces
      them with sema-rules + rsc projection.
    - §3 The request flow.
    - §10 Project-wide rules — the operational rules list +
      the rejected-framings list (the only place wrong
      frames are named).

### 1c · Grammar — load before any code that touches text

15. [`../repos/nota/README.md`](../repos/nota/README.md) —
    the base nota grammar. PascalCase / camelCase /
    kebab-case identifier classes; bare-identifier strings;
    the explicit clarification of `[ligoldragon]` shape (it
    is `Vec<String>` with one bare-ident element, *not* a
    third bare-bracketed-string form).
16. [`../repos/nexus/spec/grammar.md`](../repos/nexus/spec/grammar.md)
    — full nexus grammar. Verb table; **§Binds** with the
    strict auto-name-from-schema rule; reply semantics.
17. [`../repos/nexus/spec/examples/`](../repos/nexus/spec/examples/)
    — concrete `.nexus` files (flow-graph.nexus and
    patterns-and-edits.nexus).

### 1d · The codec stack — read in this order

18. [`../repos/nota-codec/ARCHITECTURE.md`](../repos/nota-codec/ARCHITECTURE.md)
    — runtime crate (Decoder / Encoder / NotaEncode /
    NotaDecode traits / Lexer / blanket impls / Error). The
    PROTOCOL surface.
19. [`../repos/nota-codec/src/lib.rs`](../repos/nota-codec/src/lib.rs)
    — module declarations + re-exports.
20. [`../repos/nota-codec/src/error.rs`](../repos/nota-codec/src/error.rs)
    — typed Error variants (no `Custom(String)` arm).
    `Lexer(String)` is a transitional catch-all that should
    refactor into typed sites; flagged in §10 as one of the
    open items.
21. [`../repos/nota-codec/src/lexer.rs`](../repos/nota-codec/src/lexer.rs)
    — pure tokenizer (525 LoC). `Token`, `Dialect`,
    `is_pascal_case`, `is_lowercase_identifier`. Copied
    verbatim from the retired nota-serde-core.
22. [`../repos/nota-codec/src/decoder.rs`](../repos/nota-codec/src/decoder.rs)
    — `Decoder<'input>` with the protocol methods derives
    call into. Pushback queue for two-token lookahead.
23. [`../repos/nota-codec/src/encoder.rs`](../repos/nota-codec/src/encoder.rs)
    — `Encoder` with `needs_space` state for automatic
    field-separator handling.
24. [`../repos/nota-codec/src/traits.rs`](../repos/nota-codec/src/traits.rs)
    — `NotaEncode` + `NotaDecode` traits + blanket impls
    for primitives (u8/u16/u32/u64/i8/i16/i32/i64/f32/f64/
    bool/String) + `Option<T>` + `Vec<T>` + `BTreeMap<K,V>`
    + `HashMap<K,V>` + `BTreeSet<T>` + `HashSet<T>` +
    `Box<T>` + tuples 2/3/4.
25. [`../repos/nota-codec/src/pattern_field.rs`](../repos/nota-codec/src/pattern_field.rs)
    — `PatternField<T> { Wildcard | Bind | Match(T) }`.
    Lives here (not signal) because the codec needs to
    pattern-match it.
26. [`../repos/nota-derive/ARCHITECTURE.md`](../repos/nota-derive/ARCHITECTURE.md)
    — proc-macro crate.
27. [`../repos/nota-derive/src/lib.rs`](../repos/nota-derive/src/lib.rs)
    — six `#[proc_macro_derive]` entry points.
28. [`../repos/nota-derive/src/`](../repos/nota-derive/src/)
    — per-derive codegen files (`nota_record.rs`,
    `nota_enum.rs`, `nota_transparent.rs`,
    `nota_try_transparent.rs`, `nexus_pattern.rs`,
    `nexus_verb.rs`, `shared.rs`).
29. [`../repos/nota-codec/tests/`](../repos/nota-codec/tests/)
    — read at least one or two test files to feel the
    decoder/encoder API in action.

### 1e · Per-repo architecture (load before touching that repo)

30. [`../repos/signal/ARCHITECTURE.md`](../repos/signal/ARCHITECTURE.md)
    — wire format + per-verb typed IR. Reads now use the
    `…Operation` names.
31. [`../repos/signal/src/lib.rs`](../repos/signal/src/lib.rs)
    — re-exports + module map.
32. [`../repos/signal/src/edit.rs`](../repos/signal/src/edit.rs)
    — `AssertOperation` / `MutateOperation` /
    `RetractOperation` / `AtomicBatch` / `BatchOperation`
    (the last two are rkyv-only for M0; see §6 for why).
33. [`../repos/nexus/ARCHITECTURE.md`](../repos/nexus/ARCHITECTURE.md)
    — text translator daemon. The `QueryParser` mention is
    gone (it was deleted; `NexusPattern` derive replaces it).
34. [`../repos/sema/ARCHITECTURE.md`](../repos/sema/ARCHITECTURE.md)
    — record store + "stored by precise kind."
35. [`../repos/sema/src/lib.rs`](../repos/sema/src/lib.rs)
    — `Sema::open / store / get / iter`. `Slot(u64)`
    private field with `From` conversions.
36. [`../repos/criome/ARCHITECTURE.md`](../repos/criome/ARCHITECTURE.md)
    — engine doc (high-level). The implementation now
    centers on a `Daemon` noun.
37. [`../repos/criome/src/daemon.rs`](../repos/criome/src/daemon.rs)
    — the central `Daemon { sema: Arc<Sema> }` type with
    `handle_frame`. Per-verb logic is in sibling
    `impl Daemon { … }` blocks across `dispatch.rs`,
    `handshake.rs`, `assert.rs`, `query.rs`, `kinds.rs`,
    `uds.rs`.
38. [`../repos/nexus-cli/ARCHITECTURE.md`](../repos/nexus-cli/ARCHITECTURE.md)
    — text shuttle client.
39. [`../repos/lojix-schema/ARCHITECTURE.md`](../repos/lojix-schema/ARCHITECTURE.md)
    — lojix verb payload types (M2+ pipeline).
40. [`../ARCHITECTURE.md`](../ARCHITECTURE.md) — workspace
    dev environment.
41. [`../docs/workspace-manifest.md`](../docs/workspace-manifest.md)
    — repo inventory + statuses.

### 1f · Reports — load when working on the topic each covers

Five active reports survive the rollover:

42. [`074-portable-rkyv-discipline.md`](074-portable-rkyv-discipline.md)
    — pinned rkyv feature set. Cited from every Cargo.toml
    using rkyv. Durable.
43. [`088-closed-vs-open-schema-research.md`](088-closed-vs-open-schema-research.md)
    — research backing perfect-specificity (Invariant D).
    Durable.
44. [`089-m0-implementation-plan-step-3-onwards.md`](089-m0-implementation-plan-step-3-onwards.md)
    — M0 plan. **Step 3 (criome body) is now DONE.** Steps
    5 (nexus daemon body), 6 (nexus-cli), 7 (genesis.nexus)
    are the next chunk.
45. [`091-pattern-rethink.md`](091-pattern-rethink.md) — the
    bind-name-from-schema rule. Implementation now lives in
    `NexusPattern` derive in nota-derive; the spec rule
    here is durable.
46. [`098-serde-replacement-decision-2026-04-27.md`](098-serde-replacement-decision-2026-04-27.md)
    — the deep decision report that justified building
    nota-codec + nota-derive. Durable.
47. [`099-custom-derive-design-2026-04-27.md`](099-custom-derive-design-2026-04-27.md)
    — design report for nota-codec/nota-derive. Now updated
    with the deviations that actually shipped (§6.1
    explicit-None reversal, §8 BatchOperation rkyv-only).
    Durable as the design record.

**Recently deleted reports** (don't reference; they were
superseded):
- `092` (naming research) — re-homed to
  `tools-documentation/programming/naming-research.md`.
- `094` (handoff) — superseded by THIS report (100).
- `095` (style audit) — Q1 reversed by 098, Q2/Q4 done in
  signal migration, Q3 mooted by serde replacement.
  Deleted; this report (100) carries forward what's
  outstanding.
- `093` (style review plan) — superseded by 098.
- `096` (methods-on-types research) — re-homed to
  `tools-documentation/programming/abstractions-research.md`.
- `097` (beauty research) — re-homed to
  `tools-documentation/programming/beauty-research.md`.

### 1g · This report

48. **This file** — re-read it after the others.

---

## 2 · Operational rules — the ones agents most often violate

Distilled from AGENTS.md + style.md + tools-documentation.
Internalise these as muscle memory.

### 2a · Substance in reports, not chat

The Claude Code UI is a poor reading interface. Li reviews
asynchronously while you move on. Anything that **explains,
proposes, analyses, or summarises** goes in a file under
[`../reports/`](../reports/) or in the right per-repo
documentation. The chat reply is one line pointing at it.

If your final-session response would be more than a few
lines, you've already failed. Write the report instead.

### 2b · Use `jj commit`, never `jj describe`

`jj describe` looks like it works but creates surprising
states. Always:

```
jj commit -m '<msg>'
jj bookmark set main -r @-
jj git push --bookmark main
```

`-r @-` because `jj commit` advances `@`; the commit you
just made is its parent.

**Always commit + push** after every meaningful change.
Blanket authorisation. Unpushed work is invisible to nix
flake-input consumers and to other machines.

### 2c · Beauty is the criterion

Read [`programming/beauty.md`](../repos/tools-documentation/programming/beauty.md)
before pushing back on any rule as "verbose" or
"ceremonial." Ugly code is evidence that the underlying
problem is unsolved. The aesthetic discomfort *is* the
diagnostic reading.

When something feels ugly, slow down and find the structure
that makes it beautiful — that structure is the one you
were missing. Per Li (2026-04-27): *"Fuck ugliness and
non-conciseness. Who knows how many people were put to
death and tortured because someone wasn't concise and
explicit enough."*

### 2d · Full English words

Spell every identifier as a full English word. `lex` →
`lexer`, `tok` → `token`, `de` → `deserializer`, `ctx` →
`context`, `op` → `operation` (or specific: `assert_op`),
`txn` → `transaction`, `db` → `database` (when scope >10
lines).

The "feels too verbose" objection to a spelled-out name is
**not** a signal to shorten the name — it is a signal that
training-data drift has corrupted your aesthetic. Question
the feeling. The name reads as English; the abbreviation
is ceremony to be decoded.

Six exception classes: tight-scope loop counters, math
symbols, generic type parameters (T/U/V/K/E),
general-English acronyms (id/url/json/db/io/etc.),
std-inherited names, ARCHITECTURE.md-documented short names.

### 2e · Methods on types, not free functions

Every reusable verb belongs to a noun. The criome refactor
this session turned every per-verb `pub fn handle(...)` into
`impl Daemon { fn handle_X(...) }` — same logic, but the
noun (`Daemon`) is now visible in the type system. Free
functions let agents skip the type-creation step; the rule
forces the noun.

Carve-outs: small private helpers genuinely local to one
module (`fn hex(h: &Hash) -> String` next to a single
Display impl); pure relational operations between values of
equal status (the ADT axis of Cook's taxonomy);
std-inherited names like `serde_json::from_str`.

### 2f · Wrapped field is private

`pub struct Slot(pub u64)` is **wrong**. Make the field
private; add `From<u64>` and `From<Slot> for u64` (or
`new`/`value` accessors, or `AsRef`). The whole point of a
newtype is to gate construction and read-out — a public
field defeats the purpose.

This rule applies to every newtype in the codebase. Slot,
Revision, BlsG1, Hash (when it becomes a struct) all follow
it. The signal migration this session converted them all.

### 2g · Tests live in separate files

Tests go in `tests/` at the crate root, not inline in
`#[cfg(test)] mod tests` blocks at the bottom of `src/`
files. The tests/ pattern forces tests to use the public
API, which keeps the API honest. sema's tests moved this
session; signal's split this session. Any new crate should
follow.

### 2h · Verify each parallel-tool result

When batching `Write` / `Edit` / `Bash` calls, scan every
result block for errors before any follow-up step. Failed
`Write` calls (typically the "must Read first" guard)
cascade silently. The bundle returning is not the bundle
succeeding.

### 2i · Authored macros — bootstrap-era policy

Per criome/ARCHITECTURE.md macro section: in the eventual
self-hosting state, sema-rules + rsc-projection replace
authored macros. **In the current bootstrap era, authored
macros are fine when they're the right tool.** This is what
made `nota-derive` possible. The rule reversed mid-session;
don't apply the eventual-state rule to today's code.

### 2j · Design-doc hygiene

State criteria positively. Don't accumulate "do not use X"
patterns. Excluded options are silently omitted. The
rejected-framings list in
[criome/ARCHITECTURE.md §10](../repos/criome/ARCHITECTURE.md)
is the *only* place wrong frames are named, and only as
one-line entries.

### 2k · Commit message style

Single-line nested-paren S-expression. First token = repo
name. `[...]` enumerates discrete bullets. `—` introduces
rationale. `((double parens))` mark direct quotes from Li.
Use double quotes around the message when it contains
apostrophes (single quotes terminate the shell string).
**Beware** of `$` inside double-quoted commit messages —
the shell interpolates it; use `'$'` or escape with
backslash.

---

## 3 · Project shape in one paragraph

**Criome** is a typed binary record-graph engine. **Sema**
is its heart — content-addressed records, native binary
form (rkyv-encoded), each kind a Rust struct (eventually
generated by `rsc` from `KindDecl` records in sema itself;
M0 hand-writes the projection). Records reference each other
by `Slot` (mutable identity). **Signal** is the wire form
(per-verb typed enums; no generic record wrapper).
**Nexus** is the text bridge — a daemon parsing text into
signal frames for criome, rendering signal replies back to
text for clients. **Nota-codec** is the typed text codec
(Decoder + Encoder + traits + blanket impls + `PatternField`)
shared by both nota and nexus dialects; **nota-derive** is
the proc-macro pair providing six derives that map any
record kind to its wire form. **Nexus-cli** is a thin text
shuttle client. **Lojix** + family handle the
build/store/deploy pillar (M2+). The project is
**self-hosting**: criome compiles its own source from
records in sema, via rsc + nix. The user exposes everything
as text through nexus; LLM agents author nexus text; criome
validates and stores.

---

## 4 · Code state (what's working today)

| Crate | LoC | State | Tests |
|---|---|---|---|
| [`../repos/nota-codec/`](../repos/nota-codec/) | ~1500 | **Production-ready** for M0 verb scope. Lexer + Decoder + Encoder + 6 derives re-exported from nota-derive. Blanket impls for all primitive integers, f32/f64, bool, String, Option<T> (explicit-None encoding, decode accepts both forms), Vec<T>, BTreeMap/HashMap/BTreeSet/HashSet, Box<T>, tuples 2/3/4, byte vectors via `#hex`. Typed `Error` enum with `Validation` variant for NotaTryTransparent. `peek_record_head` accepts both `(` and `(|` openers so NexusVerb can dispatch into NexusPattern variants. | 79 |
| [`../repos/nota-derive/`](../repos/nota-derive/) | ~600 | Six derives shipping: `NotaRecord`, `NotaEnum`, `NotaTransparent`, `NotaTryTransparent`, `NexusPattern`, `NexusVerb`. `NexusVerb` supports both newtype variants and struct-variants. `NotaTryTransparent` routes through `Self::try_new(inner) -> Result<Self, E>` and maps to `Error::Validation`. | 0 (compile-only) |
| [`../repos/signal/`](../repos/signal/) | ~1100 | All `…Op` types renamed to `…Operation`. Slot/Revision/BlsG1 fields private with `From` conversions (BlsG1 hand-written). Each kind derives the right Nota/Nexus derive plus rkyv. AtomicBatch + BatchOperation kept rkyv-only (canonical `[\| op1 op2 \|]` text form needs hand-impl in M1+). Diagnostic family + Reply / Frame / Body / Request / Handshake* all rkyv-only. Tests split: `tests/frame.rs` (rkyv) + `tests/text_round_trip.rs` (text). | 42 |
| [`../repos/sema/`](../repos/sema/) | ~140 | `Sema::open / store(&[u8]) → Slot / get(Slot) → Option<Vec<u8>> / iter() → Vec<(Slot, Vec<u8>)>`. `Slot(u64)` private field with `From<u64>` + `From<Slot> for u64`. `SEED_RANGE_END` is now `pub`. `db` → `database` and `txn` → `transaction` rename. Tests live in `tests/sema.rs` per the rule. | 10 |
| [`../repos/nexus/`](../repos/nexus/) | ~400 | **M0 step 5 done.** Five nouns — `Daemon` / `Listener`-as-method / `Connection` / `CriomeLink` / `Parser` / `Renderer` — across `daemon.rs` / `connection.rs` / `criome_link.rs` / `parser.rs` / `renderer.rs`. Plus one-shot binaries `nexus-parse` and `nexus-render` under `src/bin/` that wrap `Parser::next_request` and `Renderer::render_reply` as stdin/stdout filters. Tests in `tests/parser.rs` (11) + `tests/renderer.rs` (9). Daemon binary is `nexus-daemon`. | 20 |
| [`../repos/criome/`](../repos/criome/) | ~400 | **M0 step 3 done.** Restructured around `Daemon { sema: Arc<Sema> }` noun (methods-on-types). Per-verb logic in `impl Daemon { … }` across `handshake.rs` / `assert.rs` / `query.rs` / `dispatch.rs`. UDS `Listener` accepts connections, length-prefixed Frame I/O. Plus one-shot binary `criome-handle-frame` under `src/bin/` that wraps `Daemon::handle_frame` as a stdin/stdout filter against `$SEMA_PATH`. Kind-tag (1-byte discriminator) prepended to every record's bytes since rkyv bytecheck doesn't catch type-punning. M0 verb scope: Handshake + Assert + Query implemented; Mutate / Retract / AtomicBatch / Subscribe / Validate return `Diagnostic E0099`. Daemon binary is `criome-daemon`. | 6 |
| [`../repos/nexus-cli/`](../repos/nexus-cli/) | ~50 | **M0 step 6 done.** `Client::shuttle(input) -> Result<String>` sync byte shuttle. lib + bin split; binary stays `nexus`. | 0 |
| [`../repos/lojix-schema/`](../repos/lojix-schema/) | 112 | Typed scaffold (M2+ scope). Still has serde derives (don't migrate yet). | 0 |

All crates `cargo check` clean. Total ~4400 LoC, **157
unit tests + 4 integration suites passing across the system.**

**Workspace-level checks** (in mentci): `nix flake check`
runs all 7 per-crate `checks.default` (canonical
crane+fenix per
[`tools-documentation/rust/nix-packaging.md`](../repos/tools-documentation/rust/nix-packaging.md))
plus the workspace-level integration suites — `integration`
(monolithic daemon-graph shuttle), `scenario-chain`
(daemon-mode state-persistence across restarts), and
`roundtrip-chain` (one-shot binary mode, per-daemon
transformation across nix derivation boundaries). 24 flake
checks total.

**Repos out of M0 scope** (M2+): lojix, lojix-cli,
lojix-store, rsc (TRANSITIONAL), horizon-rs (separate
sub-project that the migration agent works on; not part of
core sema), CriomOS cluster.

**Repos retired this session** (renamed `*-archive` on
GitHub): nota-serde-core, nota-serde, nexus-serde. Local
copies deleted.

---

## 5 · M0 implementation plan — what's left

Read [`089`](089-m0-implementation-plan-step-3-onwards.md)
in full. Summary:

**Done:**
- Step 1 — signal rewrite to per-verb typed payloads.
- Step 2 — sema body (`Sema::open / store / get / iter`).
- Parser (was step 4) — the `NexusPattern` derive
  subsumes what the hand-written QueryParser used to do.
- **Step 3 — criome body.** `Daemon` + UDS + dispatch +
  handshake + assert + query handlers. 6 integration tests.
- **Step 5 — nexus daemon body.** `Daemon` / `Connection`
  / `CriomeLink` / `Parser` / `Renderer` nouns. 20 tests.
  Daemon binary is `nexus-daemon`.
- **Step 6 — nexus-cli text shuttle.** `Client::shuttle()`
  sync byte shuttle; binary `nexus`.
- **End-to-end demo working** — `(Node "User")` → `(Ok)`,
  `(| Node @name |)` → `[(Node "User")]`. Smoke-tested +
  automated as nix integration test from mentci.

**To do:**
- **Step 7 — `genesis.nexus` + bootstrap glue** (~50 LoC).
  Not blocking the demo since Node/Edge/Graph kinds are
  built into criome's M0 body; becomes load-bearing when
  KindDecl records are added dynamically in M1+.

---

## 6 · Settled architecture decisions — DO NOT relitigate

| Decision | Where it lives |
|---|---|
| Per-verb typed payloads (no generic wrapper enum) | criome/ARCH §2 Invariant D + signal/ARCH + 088 |
| `PatternField::Bind` carries no payload | nexus/spec/grammar.md §"The strict rule" + nota-codec/src/pattern_field.rs + 091 |
| Slot / Revision / BlsG1 use private fields with `From` traits | rust/style.md §"Domain values are types" + signal/src/slot.rs |
| Bind names MUST equal schema field name at the position they appear | nexus/spec/grammar.md §Binds + nota-derive `NexusPattern` codegen + 091 |
| PascalCase enforced for record/variant heads | nota/README.md §Identifiers + nota-codec parsing |
| Nexus daemon is in the path (CLI never speaks signal directly) | signal/ARCH + nexus/ARCH + nexus-cli/ARCH |
| Schema-as-data via `KindDecl`; closed Rust enum is rsc's projection | criome/ARCH §2 Invariant D + signal/src/schema.rs |
| Replies pair to requests by FIFO position; no correlation IDs | signal/ARCH + nexus/spec/grammar.md |
| All-rkyv discipline with pinned feature set | 074 + every Cargo.toml |
| **nota-codec + nota-derive replace serde for nota+nexus text** | 098 + 099 + nota-codec/ARCH + nota-derive/ARCH |
| **`Option<T>` encoder always emits explicit `None`; decoder accepts both `None` and trailing-omission** | nota-codec/src/traits.rs + 099 §6.1 (updated) |
| **`Decoder::read_string` accepts both quoted and bare-ident input; encoder emits quoted form** | nota-codec/src/decoder.rs + nota/README.md §Bare-identifier strings |
| **AtomicBatch + BatchOperation are rkyv-only for M0** (canonical text form needs hand-impl in M1+) | signal/src/edit.rs + 099 §8 |
| **Reply / Frame / Body / Request / Handshake* / Diagnostic family are rkyv-only** (per-position pairing, not record-head dispatch) | signal/src/{reply,frame,handshake,diagnostic}.rs |
| **`BTreeMap` / `HashMap` wire form**: `[(Entry key value) (Entry key value) …]` with sorted keys for HashMap on encode | nota-codec/src/traits.rs |
| **Tuples wire form**: `(Tuple a b …)` with explicit `Tuple` head | nota-codec/src/traits.rs |
| **Methods on types — criome restructured around `Daemon` noun** | criome/src/daemon.rs + per-verb impl-Daemon files |
| **Bootstrap-era allows authored macros**; eventual self-hosting state replaces them with sema-rules + rsc | criome/ARCH §"Macro philosophy" |
| **Beauty is the criterion** — ugly code is unsolved problem | programming/beauty.md + rust/style.md §"Beauty is the criterion" |
| **Daemon binaries carry the `-daemon` suffix** (`nexus-daemon`, `criome-daemon`, `lojix-daemon`); lib half keeps bare name | AGENTS.md §"Binary naming" |
| **One-shot binaries** `<crate>-<verb>` for stdin/stdout glue around a single library verb (`nexus-parse`, `nexus-render`, `criome-handle-frame`) | AGENTS.md §"One-shot binaries" |
| **Workspace-wide flake migration** to canonical crane+fenix; every CANON crate exposes `checks.default`; mentci aggregates | rust/style.md §"Nix-based tests" + nix-packaging.md + reports/101 |
| **Two integration suites** at the workspace level: `integration` (monolithic daemon shuttle) + `scenario-chain` (state persistence) + `roundtrip-chain` (binary stability per-daemon transformation) | mentci/checks/ + mentci/lib/scenario.nix |

**Rejected framings** — see
[`../repos/criome/ARCHITECTURE.md`](../repos/criome/ARCHITECTURE.md)
§10 reject-loud list.

---

## 7 · The lurking dangers — what trips agents

1. **`…Op` type names are deleted.** Every type renamed to
   `…Operation`. `AssertOp`, `MutateOp`, `RetractOp`,
   `BatchOp`, `QueryOp`, `ValidateOp` — all dead. Use
   `AssertOperation` etc.
2. **`nota-serde-core` / `nota-serde` / `nexus-serde` are
   deleted.** Local dirs gone. GitHub repos renamed to
   `*-archive`. Use `nota-codec` and `nota-derive`.
3. **`nexus/src/parse.rs` is deleted.** No more
   `QueryParser`. The same dispatch happens in the
   `NexusPattern` derive on each `*Query` type.
4. **Slot has a private field.** `Slot(u64)` not
   `Slot(pub u64)`. Use `Slot::from(value)` and `let value:
   u64 = slot.into()`.
5. **`Option<T>` wire form changed mid-session.** Encoder
   used to elide trailing None; **now always emits explicit
   `None`**. Decoder accepts both forms. Tests assert the
   new form. Don't assume the old wire shape.
6. **`Decoder::read_string` accepts bare idents now.** A
   wire `(Foo nota-codec)` decodes the same as
   `(Foo "nota-codec")`. Be aware in tests.
7. **`peek_record_head` accepts both `(` and `(|`.**
   `NexusVerb` can dispatch into `NexusPattern` variants
   (this is how `QueryOperation::Node(NodeQuery)` works).
   The bug that surfaced this is named in the test
   `query_operation_dispatches_to_node_query`.
8. **rkyv bytecheck doesn't catch type-punning.** criome
   prepends a 1-byte kind discriminator to every record's
   bytes; the query handler filters by tag before
   try-decoding. Per-kind tables in M1+ replace this.
9. **`AtomicBatch` + `BatchOperation` are rkyv-only.** Don't
   try to add Nota derives to them — the wire form is
   `[| op1 op2 |]` with sigil-dispatched inner ops which
   needs hand-impl. Defer to M1+.
10. **Authored macros are now allowed in bootstrap era.**
    Don't apply the "no-macros" rule that the previous
    handoff (094) carried; that rule is the eventual-state
    rule, not the current-state rule.
11. **Reports 092 / 094 / 095 / 093 / 096 / 097 are
    deleted.** If you reference them, you're working from
    stale info. Their content is in
    `tools-documentation/programming/` (research) or this
    report (handoff).
12. **`AtomicBatch.ops` is now `.operations`.**
    `ValidateOperation.op` is now `.operation`.
    `DiagnosticSite::OpInBatch` is `OperationInBatch`.
    `AuthProof::BlsSig` is `BlsSignature`.

---

## 8 · Reports inventory

| # | File | Purpose | Lifetime |
|---|---|---|---|
| 074 | [pinned-features rkyv discipline](074-portable-rkyv-discipline.md) | Cited from every Cargo.toml using rkyv | DURABLE |
| 088 | [closed-vs-open schema research](088-closed-vs-open-schema-research.md) | Research backing perfect specificity (Invariant D) | DURABLE |
| 089 | [M0 implementation plan steps 3+](089-m0-implementation-plan-step-3-onwards.md) | M0 plan — steps 3/5/6 done; step 7 (genesis.nexus) deferred but non-blocking | ACTIVE — needs refresh as execution record |
| 091 | [pattern parser rethink](091-pattern-rethink.md) | The auto-name-from-schema rule + corrected `PatternField` shape (now in `NexusPattern` derive) | DURABLE as backing |
| 098 | [serde-replacement decision](098-serde-replacement-decision-2026-04-27.md) | Decision report for nota-codec | DURABLE |
| 099 | [custom-derive design](099-custom-derive-design-2026-04-27.md) | Design report — updated with shipping deviations (§6.1 explicit-None, §8 BatchOperation rollback) | DURABLE |
| 100 | this report | Post-context-reset entry point | DURABLE — refresh as state evolves |
| 101 | [multi-agent style audit pass](101-style-audit-pass-2026-04-27.md) | Phase 1 synthesis + Phase 2 five parallel per-repo audits; zero deep findings; closed reports/100 §10 hygiene items | SNAPSHOT |
| 102 | [visual architecture](102-visual-architecture-2026-04-27.md) | 3 cross-repo views + 7 per-repo classDiagrams in mermaid | SNAPSHOT — regenerate when system shape changes |

Re-homed research syntheses (now in
`tools-documentation/programming/`):
- `naming-research.md` (was reports/092)
- `abstractions-research.md` (was reports/096)
- `beauty-research.md` (was reports/097)

---

## 9 · Tooling cheat sheet

```
# session-close protocol — every meaningful change
jj commit -m '<msg>'      # NEVER jj describe
jj bookmark set main -r @-
jj git push --bookmark main

# session start (via bd hook)
bd ready                  # what's available to work on
bd memories <keyword>     # search project-scoped memories

# building / testing
cd <repo> && cargo test                   # quick
cd <repo> && nix flake check              # canonical (sandboxed)

# missing tool? never install
nix run nixpkgs#<pkg> -- <args>

# bd — short tracked items only; long-form goes in files
bd create --title="X" --description="Y" --type=task --priority=2
bd update <id> --claim
bd close <id>
```

---

## 10 · Where to start work — open items in priority order

M0 steps 3 / 5 / 6 are landed and the demo round-trips
through the daemon graph (smoke-tested + automated as the
nix integration test). Open items follow:

### 10a · M0 step 7 — genesis.nexus + bootstrap (~50 LoC)

Text file at `criome/genesis.nexus` with bootstrap
KindDecls (KindDecl itself + Node + Edge + Graph). Bootstrap
glue in criome `main.rs`: on first boot (empty sema),
parse genesis text via nota-codec and dispatch each Assert
through the normal path. **Not blocking the demo** — Node /
Edge / Graph kinds are built into criome's M0 body. Becomes
load-bearing when KindDecl records are added dynamically in
M1+.

### 10b · M1 next moves — criome → lojix → rsc

Per Li 2026-04-28, the next deep design pass covers the
criome → lojix → rsc MVP loop. Open work for that loop is
tracked in bd: see `bd ready` and the open issues prefixed
`mentci-next-`. Notably:

- `mentci-next-ef3` — self-hosting "done" moment
- `mentci-next-0tj` — rsc records-to-Rust projection
- `mentci-next-8ba` — M3 sema redb wrapper
- `mentci-next-zv3` — M6 bootstrap

### 10c · Encoder bare-ident emission for strings

The nota README §"Strings" says canonical form emits bare
when eligible. Encoder currently always quotes. Adding
bare-emit when content fits a non-`true`/`false` ident class
would shorten output and match the spec. Cosmetic — defer
unless a real consumer asks.

### 10d · Open bd issues

- `mentci-next-dqp` — rename `rsc` to a full English word
  per the naming rule. Out of scope for M0; defer until
  rsc moves out of stub state.
- `mentci-next-rgs` — title says "ractor-hosted daemon" but
  daemons are tokio-based; flagged for clarification.

---

## 11 · The shape of a successful turn

A turn that goes well looks like:

1. Read the user's message; understand the actual ask.
2. If the task is non-trivial: read the relevant docs first
   (don't guess; verify against current code).
3. If multiple steps: track via `bd` only if the user
   wants tracked work; otherwise proceed without
   TodoWrite-style ceremony.
4. Edit code or docs.
5. Run tests if code touched. **Check that pre-existing
   tests still pass.**
6. `jj commit + bookmark + push` (per repo, per logical
   chunk). The S-expression commit message captures what
   changed AND why AND any direct user quote that
   justifies it.
7. Brief chat reply pointing at the change. If the change
   warrants explanation, the explanation lives in a doc,
   not in chat.

A turn that goes badly looks like: long chat replies, `jj
describe`, cryptic identifiers in new code, propagating
local dialect from surrounding code, half-finished
implementations sitting uncommitted at end-of-turn,
referencing deleted reports / renamed types / retired
crates.

---

## 12 · Reading priority if you're short on time

If you only have time to read FIVE files before starting
work, read these:

1. [`programming/beauty.md`](../repos/tools-documentation/programming/beauty.md)
   — the central principle.
2. [`programming/abstractions.md`](../repos/tools-documentation/programming/abstractions.md)
   — methods-on-types discipline.
3. [`../AGENTS.md`](../AGENTS.md) — operational rules with
   the naming + thinking-discipline + beauty sections.
4. [`../repos/criome/ARCHITECTURE.md`](../repos/criome/ARCHITECTURE.md)
   §2 Invariants A–D.
5. This report (100), at minimum §§4, 6, 7, 10.

Then start. Then read more as you need it (per §1).

But Li explicitly asked for thoroughness. **Read all of §1
when you have the budget.**

---

*End 100.*
