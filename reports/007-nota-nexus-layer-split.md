# Report 007 — nota + nexus, two-layer split

Supersedes the now-deleted report 006. Records the decision to
split the text format into a data-layer format (**nota**) and a
messaging-layer protocol (**nexus**, superset of nota), and
proposes the implementation of both.

---

## 1. Decision record

- **nota** — the text data format. JSON/TOML-class. No
  operational semantics. Target: every config file in the sema
  ecosystem.
- **nexus** — the messaging protocol. Strict superset of nota.
  Adds sigils and delimiter pairs that express query / mutate /
  bind / negate actions on a sema world-store.

Four artifacts, four repos (per rule 1, one crate per repo):

| Repo | Role |
|---|---|
| `nota` | Spec-only. Grammar + examples. |
| `nota-serde` | Rust impl — `serde::Serializer` + `Deserializer`. |
| `nexus` | Spec-only. "`nota` + these extensions." |
| `nexus-serde` | Rust impl — depends on `nota-serde`, adds query-layer lexer/parser. |

MVP repo count: 7 → 9.

The superset relation is strict: every valid nota text is also
valid nexus text. The reverse is not true — nexus text
containing `~` / `@` / `!` / `(| |)` / `{| |}` / `{ }` is a
syntax error under nota.

---

## 2. What's in each layer

### nota — data layer

**Delimiter pairs (4):**

| Pair | Role |
|---|---|
| `( )` | Record (named composite value) |
| `[ ]` | String (inline) |
| `[\| \|]` | String (multiline, auto-dedented) |
| `< >` | Sequence / tuple (heterogeneous allowed) |

**Sigils (2):**

| Sigil | Role |
|---|---|
| `;;` | Line comment |
| `#` | Byte-literal prefix (`#a1b2c3` = 3 bytes) |

**Identifier classes (3):** PascalCase, camelCase, kebab-case —
unchanged from current nexus spec.

**Literals:** integers (decimal / hex / binary / octal /
underscored), floats, booleans, `#`-prefixed hex byte runs
(lowercase, even length; blake3 is the length-64 case),
strings (via `[ ]` / `[| |]`).

**Path syntax:** `:` separates nested names.

### nexus — messaging layer

Everything in nota, plus:

**Additional delimiter pairs (3):**

| Pair | Role |
|---|---|
| `(\| \|)` | Pattern / query |
| `{\| \|}` | Constrain / subquery |
| `{ }` | Shape / projection |

**Additional sigils (3):**

| Sigil | Role |
|---|---|
| `~` | Mutate marker |
| `@` | Bind variable |
| `!` | Negate |

Total: 7 delimiter pairs, 4 sigils — same counts the current
nexus README claims, just redistributed across the two specs.
(Current spec counts 6 pairs; the `< >` addition is new.)

---

## 3. nota-serde — serde data-model mapping

Assumes the grammar decisions in §5 below.

| serde type | nota rendering |
|---|---|
| bool | `true` / `false` |
| i8 … i64, u8 … u64 | decimal (input accepts `0xFF`, `0b1010`, `_`) |
| f32 / f64 | shortest round-trip decimal; always a `.` |
| char | one-char `[x]` |
| &str / String | `[...]` inline; `[\| ... \|]` multiline |
| bytes | `#` + lowercase hex, even-length (`#a1b2c3`) |
| Option\<T\>: None | bare `None` |
| Option\<T\>: Some(x) | `x` transparently |
| unit | *forbidden* |
| unit_struct Foo | `Foo` |
| unit_variant V | `V` |
| newtype_struct N(x) | `x` transparently |
| newtype_variant V(x) | `(V x)` |
| seq \[a,b,c\] | `<a b c>` |
| tuple (a,b,c) | `<a b c>` |
| tuple_struct T(a,b,c) | `(T a b c)` |
| tuple_variant V(a,b,c) | `(V a b c)` |
| map {k:v,…} | `<(k v) …>` (canonical: sorted by key bytes) |
| struct S{f:v,…} | `(S f=v …)` |
| struct_variant V{f:v,…} | `(V f=v …)` |

---

## 4. Canonical form — nota

Used for content-addressing and stable diffs.

- **Field order:** Rust source-declaration order (serde
  preserves).
- **Integers:** decimal, no separators, minimum digits.
- **Floats:** shortest round-trip; `.` always present.
- **Strings:** inline unless content contains `]` or newline;
  otherwise `[| |]`.
- **Bytes:** lowercase hex, no separator.
- **Maps:** entries sorted by serialized key bytes.
- **Whitespace:** single space between tokens inside one
  expression; newline between top-level items; no indentation
  in canonical mode.

"Pretty" form is a separate output mode with indentation rules,
produced by a distinct entry point (`to_string_pretty`).

---

## 5. Grammar decisions inherited from report 006 §4

These were open in the nexus spec; they now land in nota.

- **§4.1 Sequences** → adopted **`< >`** as the fourth
  delimiter pair.
- **§4.2 Maps** → `<(k v) ...>`, sorted by key bytes in
  canonical form.
- **§4.3 Tuples** → same as sequences (`< >`); tuple structs
  keep their PascalCase wrapper.
- **§4.4 Bytes** → `#` + lowercase hex, even-length. Blake3 is
  the length-64 case (`#<64 hex chars>`). The `#` prefix
  resolves the bare-hex / camelCase-identifier ambiguity.
- **§4.5 Option** → `None` as bare variant, `Some(x)`
  transparent.
- **§4.6 Unit** → forbidden; use a named `Nil` or similar if
  absent-value semantics are needed.
- **§4.7 Field separator** → `=` mandatory for named fields;
  whitespace only for positional (sequences, tuples, tuple
  variants).

Six of six open questions resolved under the `nota` spec. One
follow-up from me in §8 below.

---

## 6. Implementation plan

**Phase 1 — `nota` spec repo.** Write the grammar doc (mirror
the shape of current nexus/README.md, but with the content
above). Small repo: spec + example file + flake + license.

**Phase 2 — `nota-serde` Serializer.** All of §3 above except
seq / map (which need the lexer to know about `< >`). Structs,
enums, options, primitives, strings. ~400-500 LoC.

**Phase 3 — `nota-serde` lexer + Deserializer.** Recursive
descent; first-token dispatch is mechanical. Sequences and
maps land here. ~800 LoC.

**Phase 4 — canonical-form round-trip tests.** Property tests:
`to_string(from_str(x)) == canonical(x)`.

**Phase 5 — first real consumer.** Pick one concrete config to
migrate: `devshell.nix`'s `linkedRepos` list is the smallest;
`.beads/config.yaml` is the loudest signal. Either way — a
real `.nota` file in the workspace.

**Phase 6 — `nexus` spec update.** Rewrite current nexus/README
as "nota + these extensions": patterns, constraints, shapes,
the three action sigils.

**Phase 7 — `nexus-serde`.** Depends on `nota-serde`. Adds the
query-layer lexer extensions and handlers for the messaging
types nexusd ↔ nexus-cli will send. Spec for those types comes
from `nexusd-k6x` (wire format, open in bd).

Phases 1-4 unblock config-file use. Phases 5-7 unblock nexusd.

---

## 7. Knock-on changes once accepted

- **mentci-next/devshell.nix** — add `nota` and `nota-serde`
  to `linkedRepos`.
- **mentci-next/AGENTS.md** — repo list grows from 7 to 9.
- **reports/003-mvp-implementation-plan.md** §2 repo table
  needs the two new rows.
- **reports/001-migration-doc-reading.md** — one-line mention
  of the split.
- **nexus/README.md** — rewritten as "nota + extensions"
  (Phase 6 above).
- **nexus-serde/Cargo.toml** — add `nota-serde` dependency
  once phase 2 publishes.
- **bd issues** — the spec-level questions in `nota`'s bd
  (none outstanding — §5 resolves them all); the `nexus-k6x`
  wire-format issue stays in nexusd's bd.

---

## 8. Open questions for you

1. **`< >` for sequences — confirmed?** §5 adopts it but it's
   the only non-obvious new syntax. Alternative was
   "require a wrapper record around every Vec" — worse UX in
   configs.
2. **Unit type — forbid or define?** §4.6 forbids. If you want
   a nota-level "no value" token, I'd suggest bare `Nil`
   (PascalCase); but I lean toward forbidding entirely since
   serde's unit is a quirk of Rust's type system, not a data
   concept.
3. **Pretty-form indentation style** — two-space (Rust default),
   tab, four-space? Minor but sticky once shipped.
4. **Who owns canonical-form tests?** nota-serde, or a separate
   `nota-conformance` crate that both nota-serde and future
   alternative impls can run against? I lean `nota-serde` for
   MVP; extract later if a second impl appears.

---

## 9. Validation target — first real .nota file

Once nota-serde phase 2 compiles, the first non-toy consumer
should be `mentci-next/devshell.nix`'s `linkedRepos` array —
today a Nix list, tomorrow a `.nota` file read by a small Nix
helper. Smallest possible dogfood; validates that the format
survives first contact with a real human edit cycle.

---

## 10. Summary

Two formats, two crates, two repos each. nota is the data
layer — a Rust-native TOML replacement. nexus is the messaging
protocol built on top. Grammar decisions from report 006 §4
land in nota's spec, not nexus's. Implementation proceeds
bottom-up: nota-serde first, then nexus-serde as an extension.
