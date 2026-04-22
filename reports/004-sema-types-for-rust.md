# 004 — Rust types for sema representation

*Claude Opus 4.7 / 2026-04-23*

Status of the Rust types that shape sema records — the bootstrap
schema for everything the database stores about a Rust program.
Types live in [`nexus-schema`](../repos/nexus-schema/).

---

## 1. Compilation flow

```
sema DB (records typed by nexus-schema, content-addressed by blake3)
   ↓ rsc (sema → Rust projector)
.rs files
   ↓ rustc
binary / library
```

The types in nexus-schema are the *lower bound* on what sema can
represent about a Rust program. Every construct rsc emits must have
a record shape here.

---

## 2. Shape — DAG via content-hash indirection

Every top-level declaration is a sealed record stored in redb under
its blake3 hash. Cross-record references — anywhere one record
points at another — go through content-hash ID newtypes:

| ID | Points at |
|---|---|
| `TypeId` | a Type record |
| `GenericParamId` | a GenericParam record |
| `OriginId` | an Origin record |
| `EnumId`, `StructId`, `NewtypeId`, `ConstId` | declaration records |
| `TraitDeclId`, `TraitImplId` | trait records |
| `ModuleId`, `ProgramId` | containers |

All IDs wrap a `[u8; 32]` blake3 hash. Same content → same hash →
same record. Shared substructures (e.g., the `U32` type used by many
fields) are stored once and referenced everywhere.

Intra-record composition stays inline (a Field carries its TypeId
directly; a TypeApplication carries its args inline as `Vec<TypeId>`).
Recursion only appears at reference boundaries, and those boundaries
are hash IDs — so the shape is a DAG, never a cycle.

**rkyv derives compile clean throughout.** Every record in the DB is
rkyv-archived bytes; reads from redb's mmap are zero-copy into
`&Archived<T>`.

---

## 3. Current coverage (data-type layer)

Landed in `nexus-schema`:

| Module | Records |
|---|---|
| `names` | 17 identifier newtypes (String-wrapping) + 11 ID newtypes (Hash-wrapping) + `LiteralValue` |
| `primitive` | `Primitive` + built-in registry (25 entries) |
| `origin` | `Origin` — place-based lifetimes |
| `ty` | `Type`, `TypeApplication`, `GenericParam`, `TraitBound` — with raw pointers, fn pointer types, const generics |
| `domain` | `Enum` (+ `Variant`), `Struct`, `Newtype`, `Const`, `Field` — flat, no inline nested declarations |
| `module` | 5-level `Visibility` (Public / Crate / Super / InPath / Private), `Import`, `Module` |
| `program` | `Program` |

This covers Rust's **data-definition surface** completely. Generics,
bounds, borrows, view types, origins, raw pointers, fn pointer types,
scoped visibility — all in place. No inline nested declarations
(Rust doesn't have them; declarations live at module level and
reference each other).

---

## 4. Not yet landed

### Method-body layer (next crate push)

Needed for representing anything *inside* a function or method:

- `param` — method parameter shapes (self / named × owned / borrowed / mut-borrowed)
- `traits` — `TraitDecl`, `TraitImpl`, `Method`, `Signature`, `NamedMethod`, `AssociatedTypeBinding`
- `expr` — expressions (12 binops + 3 postfix + ~15 atoms)
- `statement` — statements + local-decl shapes + mutation
- `body` — blocks, loops, iterations, struct construction
- `pattern` — match patterns and arms
- `domain::Rfi` + `domain::RfiFunction` — referenced from Signature
- `program::body` — a Program's body of Statements

Same design pattern: hash-ID indirection where cycles would otherwise
form. Scope: ~400 lines of type definitions across ~7 files.

### Rust features not yet representable

Dedicated types needed before rsc can emit arbitrary Rust:

- `FreeFn` — top-level `fn foo()` at module root.
- `InherentImpl` — `impl Foo { ... }` without a trait.
- `TypeAlias` — `type Foo = Bar;`.
- `Unsafe` wrapper — on blocks, expressions, or trait declarations.
- `Fn` / `FnMut` / `FnOnce` distinction.
- Pattern richness: `StructDestructure`, `RefPattern`, `RangePattern`, `GuardClause`, `AtBinding`, `RestPattern`.
- `&str` / slice `[T]` as distinct `Type` variants.
- Assignment / compound-assignment statement forms.
- `break` / `continue` with labels; label slot on `Loop`.
- `where` clauses on signatures.
- `panic!` / `Error` trait representation.

### Can defer

Stdlib types (`Rc`, `Arc`, `Cell`, `RefCell`, `Mutex`, `RwLock`) are
records of existing shapes. Async/await, Send/Sync, macros beyond
derivation, Rust 2024 specifics — wait for concrete need.

---

## 5. MVP integration

- **M2 done (data-type slice):** the seven modules above exist, rkyv derives compile, records form a DAG.
- **M2 remaining:** port the method-body layer.
- **M3 — redb integration.** Each top-level record is stored under `blake3(rkyv(record))`. IDs inside records are just those hashes. Cross-record queries fetch by ID.
- **Post-MVP — rsc.** Walks records rooted at a Module, emits `.rs` files. Each enum variant in nexus-schema has one codegen rule.
