*Claude Opus 4.7 / 2026-04-24 · deep research on the three
Priority-0 decisions (hash-vs-name refs, mutually recursive
function hashing, ingester scope) — the load-bearing triad for
sema's "code as logic" thesis. Evaluates Unison, r-a, Datomic,
Git, chalk, and rustc precedents; recommends concrete schema
and ingester paths with migration plans.*

> **⚠ P0.1 recommendation updated 2026-04-24** per Li's follow-up.
> Original lean below ("dual-mode with hash storage at reference
> sites") is superseded. The correct lean is **index-
> indirection**: records store **slot-refs** at reference sites;
> sema owns an **index table** mapping
> `slot → { current-hash, display-name, … }`. Content edits
> update the slot's current-hash (cascade fires; no ripple-
> rehash of dependents). Renames update the slot's display-name
> (no record rewrites). This is Datomic's `eid` model + Git's
> ref-table, unified; solves the cascading-rehash problem that
> a pure hash-ref model would create. Report 046 §P0.1 and
> report 043 §P1.4 reflect the updated recommendation.
>
> The analysis below (Unison vs r-a vs Datomic, the three-model
> comparison) stands — it's just that the synthesis underweights
> the ripple-rehash cost. Li surfaced this cost as load-bearing;
> the index-indirection pattern is the resolution.

---

# 042 — Priority-0 decisions research: refs, SCCs, ingester

## P0.1 — Hash-refs vs name-refs

### Problem restatement

Report 026 declares the invariant:

> References are content-hash IDs validated at mutation time;
> a whole class of rustc errors (`unresolved import`, `cannot
> find type in this scope`) doesn't exist in sema.

The live `nexus-schema` crate partially contradicts this. Audit
of `src/ty.rs` and `src/module.rs` shows a **mixed regime**:

- **Hash-ref sites** (sub-record composition):
  `TypeApplication.args: Vec<TypeId>`, `GenericParam::Const.type_:
  TypeId`, `TraitBound.args: Vec<TypeId>`, `FnPtr.{params,
  return_type}`, `Field::Typed.type_`, `Newtype.wraps`,
  `Variant::Data.payload`, `Module.{enums, structs, newtypes,
  consts, trait_decls, trait_impls}`, and the `GenericParamId /
  OriginId` breakers for recursive cycles. These are already
  content-hashed.
- **Name-ref sites** (top-level naming surface):
  `Type::Named(TypeName)`, `TypeApplication.constructor:
  TypeName`, `TraitBound.trait_name: TraitName`,
  `Import.{source: ModuleName, names: Vec<TypeName>}`, the
  `name: …Name` field on every `Struct`/`Enum`/`Newtype`/`Const`
  declaration. The declaration's *own name* is a string; and a
  type *reference* made by spelling that name is also a string.

So the schema is *already* dual-mode — every sub-record edge
uses hashes, every name-binding / name-lookup edge uses strings.
The contradiction is not a simple fix-it-one-way; the current
code represents one coherent point on the hash/name spectrum
that the docs haven't acknowledged.

This section asks: **what is the right reference model**, given
the design pressure from mutability, renaming, recursion, and
self-hosting?

### Options

1. **Hash-only** — reference by `TypeId`, `FnId`, `StructId`.
   Names, if they exist at all, are an index layer sitting
   *outside* records (criomed's `OpusRoot`-style table).
2. **Name-only** — references carry strings; criomed resolves
   at query time against a mutable symbol table.
3. **Dual-mode** (current code, plus explicit doctrine) — users
   author and query by name; criomed canonicalises to hash-refs
   at commit time; resolved records carry hashes; the name-only
   face is transport, the hash-only face is storage.
4. **Hybrid by kind** — hash-ref where the referent is a *value*
   (the shape of a `Type`), name-ref where the referent is a
   *semantic role* (the identity of "the function called
   `resolve_pattern` in this module's current state").

### Precedents

**Unison** is the deepest precedent. Every term has a
`Reference::DerivedId(H)` (hash-addressed) or
`Reference::Builtin(name)` (reserved for the small built-in
vocabulary). User definitions are hash-only; names live in a
separate `Names` object that maps HQ (hashed-qualified) names
to references. Renaming is metadata — it touches zero term
values, invalidates zero caches, and never produces "did you
mean X" errors because names have no role in the resolved
term. Their retrospective ("The future of Unison: hash-based
programming" and the various RFC threads) lists the downsides
we care about:

- **Alias proliferation.** Two users can independently define
  the same hash under different names; mergers have to decide
  which names to propagate. Unison handles this by letting
  multiple names point at the same hash — cheap — but UI that
  surfaces "the canonical name" is not solved, it's per-codebase
  convention.
- **Recursion requires up-front cycle detection.** Every Unison
  definition goes through an SCC computation before hashing
  (see P0.2). A single `let rec` requires the compiler to know
  the whole group.
- **Refactoring across a "rename" is a branded operation.**
  Unison adds a `move.term` verb rather than letting names drift.
  Good UX; assumes a commit-style workflow with named
  rename-operations as first-class.
- **"Find all callers of X"** requires an index over the hash
  graph — expensive to build incrementally; Unison rebuilds it
  on save.
- **Error messages degrade** when many user-facing names alias
  the same hash. They compensate with "show me the shortest
  name for this hash" queries but the UX tax is real.

**rust-analyzer's HIR layer** gives a different model. `DefId`
is a salsa-interned ID — not a content hash. Two
structurally-identical function bodies that live at different
`DefPath`s get distinct `DefId`s. This is because r-a's primary
axis is *position in the source tree*, not *value*. Their
`hir-def` discipline: every cross-item reference is a `DefId`,
resolved once at the `DefMap` level and cached in salsa.
Incrementality works because a single-file edit only
invalidates the `DefMap` of that file's crate (and only if
items were added/removed). Names never appear in the back-half
queries; the back half works entirely on `DefId`. Lesson: the
cost of name-resolution is paid once per crate per
item-structure-changing edit, and then forgotten. Sema would
gain the same amortisation property if name resolution is a
*commit-time* operation, not a *read-time* one.

**Datomic** is an explicit dual-mode design. Every entity has a
numeric `eid` (stable identity) and optionally a `:db/ident`
keyword (human-readable, mutable in principle but
conventionally not). Transaction data can refer to an entity
by either. The read path is `eid`-keyed; the write path and
query path accept either. Lessons:
(a) keyword-ident and eid *coexist peacefully* because only one
is identity — the keyword is a sidecar, not a primary key.
(b) Datomic's queries (Datalog) bind across the dual mode —
writing `[?e :person/name "Alice"]` matches by attribute and
doesn't care whether the user thinks of `?e` by keyword or eid.
(c) Datomic never normalises the keyword away; it trusts users
to avoid self-inflicted name collisions. This is roughly the
"hybrid by kind" option: **identity** is numeric; **vocabulary**
is keywords.

**Git** is almost a pure hash-only model for objects and a pure
name-only model for refs. `refs/heads/main` is a file containing
a hash; all the hard work (commit graph, tree structure, blob
identity) is hash-addressed; the names are a separate, editable
layer. The crucial Git insight: **the two layers interact
exclusively through the ref mechanism**. You don't store
"branch name" inside a commit; commits reference parents by
hash; branch names reference commits by hash; renames happen
entirely inside the ref layer. Sema's `OpusRoot` table is the
refs/heads analogue; right now we have no equivalent for
individual code items.

**CRDT approaches** (LSeq, RGA, Yjs) are for collaborative edit
of an ordered sequence; applied to names, they'd let two
concurrent "rename f to g" operations merge without one
winning. Overkill for MVP — we have single-writer criomed and
no distributed-merge story. Name when we discuss multi-editor
workflows in post-MVP; don't build.

**Koka / Lean 4** — intermediate precedents I didn't see
explicitly mentioned in prior reports but that bear naming.
Lean's environment is name-keyed; its terms are hash-identifiable
but the standard library machinery goes through names. A
Lean-style approach would validate both names and hashes but
with name as primary. This gets you bidirectional query (by
name or by hash) at the cost of never really reaping the
hash-identity benefit — if `f`'s body changes and callers
resolve by name, they silently bind to the new body, exactly
like rustc.

### Tradeoff analysis

Four properties matter: **rename cost**, **content-edit cost**,
**recursion handling**, **storage overhead**. Let's run each
option against each.

**Hash-only.**

- *Rename*: touches zero records. A rename is metadata only —
  change the index entry. Unison-like.
- *Content edit*: a function's hash changes; every caller of it
  is a *different record* (its hash changed too, because its
  body now cites the new hash). This is the cascade report 027
  §6 worries about. Properly factored with firewalls (separate
  `FnSignature` from `Fn`) the cascade touches only callers of
  the *signature* when the signature changed, and only callers
  of the *body* when the body changed. But the cascade is
  unavoidable: every transitive caller's hash changes. In
  exchange you get: zero stale-reference errors, zero "what
  version of f did I mean" ambiguity, trivial validation.
- *Recursion*: doesn't work naively. See P0.2.
- *Storage*: minimal. No name sidecar inside records; names
  live in a single index. Deduplication works — two
  structurally-identical helper fns have one record.

**Name-only.**

- *Rename*: one record (the declaration) plus every caller. In
  the `nexus-schema` code today, every `Import`, every
  `TypeApplication.constructor`, every `TraitBound.trait_name`,
  every `Type::Named`. Every body-level `Call(Named("f"))`. The
  full reference closure gets rewritten on each rename. This is
  exactly the rustc rename-refactor cost, done as a sema
  mutation batch.
- *Content edit*: cheap. Change `f`'s body → `f`'s name still
  points at "the fn called f"; callers are unaffected at the
  reference level. But this is exactly why rustc has "`cannot
  find type`" errors — a name might resolve to nothing, or
  shadow the wrong thing, or resolve differently under
  different `use` statements.
- *Recursion*: trivial — name-refs are not values, so cycles
  are fine.
- *Storage*: higher than hash-only, because every call site
  carries a possibly-long name string. No structural
  deduplication (two helpers with the same body but different
  names are different records).

**Dual-mode (user-name, store-hash).**

- *Rename*: criomed intercepts the rename at commit; finds the
  old name's current hash; updates the index entry; re-resolves
  every caller that referenced the old name. This is the
  "touch every caller at commit time" cost, paid up front. BUT:
  if the schema is redrafted so callers cite hash only, the
  rename at the index layer is free *at the storage level*, and
  the authoring-surface rename is a batch-rewrite *of the nexus
  text coming over the wire* before it hits storage — like
  rustc's rename does to source text. Different layer, same
  cost, but the cost is front-loaded into the edit transaction
  rather than paid on every subsequent cascade.
- *Content edit*: hash changes at storage; callers see the
  rebinding instantly (index redirects); `Fn` identity at the
  *name* layer is stable.
- *Recursion*: handled via SCC at the hash layer (see P0.2);
  names are symbolic and fine.
- *Storage*: hash-refs inside stored records; name-index as a
  single mutable table. Same as hash-only at the record layer.

**Hybrid by kind.** The current code's de facto model: hash-ref
for *composing a value* (the structure of a `Type`), name-ref
for *binding to a role* (the identity "the function called f in
this module's current state"). This is Datomic's discipline,
applied to sema. It accepts that a reference to "`f` as called
from g" is semantically a name-ref (the caller wants whichever
`f` is current), while a reference to "the type of `f`'s second
parameter" is semantically a hash-ref (it's a *value*, not a
role). The cost of accepting this distinction is extra spec
work: each record field has to declare its axis.

### Recommendation

**Dual-mode, with a clarifying refinement**: the *stored* form
is hash-only at every reference site. The *authoring* and
*query* surface is name-aware. Criomed does canonicalisation
(names → hashes) as part of every commit transaction. Renames
are a distinct verb at the index layer, not a record mutation.

This matches Unison in spirit and Git in mechanism. The key
concessions:

1. **The `nexus-schema` crate needs a refactor.** Today it
   stores `Type::Named(TypeName)` — this is a name-ref inside a
   value. Under the recommendation, this becomes
   `Type::Named(TypeId)` (or better, `Type::Decl(TypeId)`,
   dropping the "Named" framing). The string name disappears
   from the value representation. It reappears at the authoring
   surface (nexus text; ingester input) and at the query
   surface (criomed's name-index).
2. **Criomed grows a name-index.** A set of tables (one per
   kind: fn-names, struct-names, trait-names, module-names)
   mapping `(scope_path, name) → current_hash`. This is the
   `OpusRoot` pattern generalised — what architecture.md §3
   calls the "name→root-hash table, git-refs analogue" scaled
   to every named record. Each opus has its own scope path
   (like Unison's codebases).
3. **Rename is a first-class transaction verb.** Not a
   `Mutate` of the record — instead `(Rename (Fn old_name)
   new_name)` at the criome-msg level. Criomed executes it by
   updating the index entry *without touching the record*.
   Unison's `move.term` precedent.
4. **The ingester normalises at ingest time.** When the
   ingester sees `use foo::Bar; … Bar::new(...)`, it resolves
   the name chain against the ingested module graph's name-index
   and emits records with hash references. No name-ref ever
   reaches storage.

The "whole class of rustc errors vanishes" claim becomes
precise: **after canonicalisation**, references are hash-refs
and can't be unresolved. *Before* canonicalisation — at the
authoring surface — the same errors do exist, and criomed
reports them at commit time, like rustc does at parse time.

The aesthetic advantage over rustc: the canonicalisation point
is sharp. Once a record is in sema, it is fully resolved.
rustc's "is this name resolved?" is a property that shifts
across phases. Sema's answer is "resolved, full stop."

### Migration plan

The current `nexus-schema` code ships (at least) hash-refs for
composition and name-refs for naming. To reach the recommended
state:

1. **Introduce `FnId`, `MethodName->MethodId`, etc.** The names
   stay as convenience newtypes but migrate out of value
   positions. Declaration records keep their `name:
   StructName` field (it's the declared name, inherent to the
   declaration record).
2. **Rewrite reference-position `…Name` fields to `…Id`.**
   Specifically: `Type::Named` becomes a `TypeId` reference
   (rename the variant for clarity); `TypeApplication.constructor:
   TypeName` → `constructor: TypeId` (a reference to a
   constructor — struct, enum, or alias — addressable by hash);
   `TraitBound.trait_name: TraitName` → `trait_ref: TraitDeclId`;
   `Import.names: Vec<TypeName>` → `imports: Vec<ImportItem>`
   where `ImportItem` resolves to a `ModuleId + kind + Id`.
3. **Add a name-index subsystem to criomed.** Two tables per
   opus: (a) `(scope, name) → current_hash` for name-based
   lookup; (b) `hash → (name, scope)` reverse map for error
   messages and rsc projection. Both in the same redb as sema.
4. **Add `Rename` verb to criome-msg.** Index-only operation;
   does not create a new record.
5. **Redraft 026 and architecture.md §1**. Replace "references
   are content-hash IDs validated at mutation time" with
   something like: "Every reference inside a stored record is a
   content-hash ID. The authoring surface and the name-index
   accept names; criomed resolves names to hashes at commit
   time. A `cannot find type` error is a commit-time
   rejection, not a runtime error."

Phase order: (3) before (2) — can't remove name-refs from
records without a name-index to drive the ingester's resolution
step. (1) → (3) → (4) → (2) → (5).

### Open sub-questions

- **Where does `scope` live?** An opus is a scope; a module is
  a sub-scope. Name resolution inside a function body needs
  access to the module-path-local and opus-wide scopes. This
  is the `DefMap`-analogue discipline r-a teaches. Probably a
  `ScopeId` layer that the ingester builds and criomed uses on
  name-lookup.
- **Cross-opus name references.** An external crate's records
  (serde's `Serialize` trait, e.g.) are referenced by something
  like `serde::Serialize`. What `scope` resolves that? Either
  an `ExternOpus` sub-scope with its own name-index, or explicit
  FQN at the authoring surface. Lean: both — ingest brings
  external-opus records in under their own opus-scope; imports
  become name-index aliases.
- **Display names inside records.** For error messages and rsc
  projection, criomed needs to know "this `Fn` was named X". A
  display-name sidecar (or a `Provenance { ingested_name: …,
  ingested_at: Revision }` record kind) — not load-bearing for
  identity, helpful for UX. Probably a sidecar record that
  `DerivedFrom`s the canonical `Fn`.
- **Conflict under rename.** Two concurrent `Rename` verbs on
  the same item. Single-writer criomed serialises them; the
  second observes the renamed state and either no-ops or errors.
  Spec this.

---

## P0.2 — Mutually recursive functions (SCC hashing)

### Problem restatement

Content hashing demands a DAG. If `f` calls `g` and `g` calls
`f`, the hash of `Fn { name: f, body: … g … }` depends on the
hash of `Fn { name: g, body: … f … }` — which depends on the
hash of `Fn { name: f, body: … }` — a cycle. Simple hash-of-
content doesn't terminate.

This is not a pathological corner case. Self-recursion and
mutual recursion appear in every non-trivial codebase: parser
mutual-recurse (expr/stmt), tree traversal (visit/visit_children),
type-checking (check/check_list), to say nothing of the
recursive-descent code in rsc and the resolver in criomed
itself.

Under the P0.1 recommendation — hash-ref inside stored records —
the cycle is unavoidable *unless the schema breaks it
explicitly*.

### Options

1. **Unison-style SCC hashing.** Compute the SCCs of the
   definition graph; hash each SCC as a single value; within
   the SCC, use by-position references; individual function
   identity is the component-hash + position.
2. **Name-ref inside SCCs.** Break the cycle with a name-ref
   indirection: `f`'s body contains `Call(Named("g"))`, which
   resolves against a *local* (SCC-scoped) name table. The
   outer SCC record has a hash; the inner name-ref is
   SCC-local and stable within.
3. **Fixed-point hashing.** Start with a placeholder hash for
   each member; compute hashes assuming placeholders; iterate
   until fixed point. Works for monotone, converging schemes
   (mostly; the math is Banach-y when the function is a
   contraction). Research-grade; not MVP.
4. **Mutual definitions always live in the same record.**
   Require the user to declare a `RecFnGroup { members:
   Vec<Fn> }` record that syntactically batches the mutual-
   recursive set. Cycles are inside the record, stored flat,
   member identity is position.

### Precedents

**Unison.** The compiler front-end computes the
**dependency graph over named definitions** and runs Tarjan's
SCC. Each SCC becomes a *component* with a single hash. Within
a component, references to sibling components members are
**positional** (`Reference::DerivedId(component_hash, index)`).
Acyclic singletons are components of size 1. This is the
model report 022 cited; it works, ships in the Unison compiler,
and has existed for years.

Specific details from Unison's `Reference` type:

- `Reference::Derived { hash: H, i: Pos, size: Pos }` — where
  `size` is the total number of members in the component and
  `i` is this member's index. Size is implicit in the component
  record; it's carried here for integrity (catch wrong-size
  mismatches).
- Deserialisation of a reference requires fetching the
  component record to resolve what member is at index `i`.
- Canonicalisation inside the component uses a stable total
  ordering (a canonical permutation computed from the body
  hashes assuming all members get index-0 placeholders first,
  then reordered). This defeats incidental renumbering.

**Rust / rustc.** Rust has mutual recursion within a module
(all items in a module are simultaneously visible to all others
during name resolution, by design) and across modules in a
crate (mod graph is intra-crate). rustc handles this via its
phase separation: the module graph is built, name resolution
runs, *then* type check. Mutual-recursive typing is via the
item-local fixpoint in trait solving + type inference; for
non-dependent types, the function signature is enough to break
the cycle at the body-type-check layer (you can check `f`
against `g`'s signature without `g`'s body). *Intra-crate
recursion only* — across-crate cycles are disallowed by the
crate-dep DAG. Relevant to sema: **signature-body factoring is
the natural firewall**. `f`'s body cites `g`'s *signature*, not
`g`'s body. As long as signatures don't cycle (they rarely do —
only in unusual polymorphic-recursion cases), bodies can
reference each other through signatures.

**Alpha-equivalence.** If we hash up to alpha-renaming,
parameter names don't affect hashes — this means two
structurally-identical mutual-recursive SCCs with different
parameter names get one component-hash. Does this break
anything? No, but it does make "the hash of `f`" less stable
under trivial renames of `g`'s parameters — the *component*
hash changes, even though `f`'s body didn't syntactically
change. Unison accepts this; it's the cost of value-identity.

**OCaml / ML `let rec … and …`** and **Haskell's `letrec`** —
language designers have consistently opted for explicit
syntactic grouping of mutual-recursive members. `let rec f x = …
and g x = … in …` requires the user to name the group. This
aligns with option 4; it's the least-magic answer.

### Tradeoff analysis

**SCC hashing (option 1).** Works for all cases. Cost: every
body-edit requires recomputing the SCC it sits in — potentially
touching many members. Cost scales with SCC size. Real
codebases have SCCs dominated by size-1 components with a long
tail of small SCCs (size 2–5 is typical); pathological cases
(mutual-recursive visitors with 15 `visit_*` methods) go
higher but are bounded. Semantic cost: component-hash is the
identity of *the group*, not of `f` or `g` individually. Every
cross-component reference carries `(component_hash, index)`;
"what is `f`'s hash" requires "the hash of the component
containing `f`, at its index." Good enough; Unison lives here.

**Name-ref inside SCCs (option 2).** Works if we accept that
"reference inside an SCC" is name-based. But it means sema
records aren't uniformly hash-ref; they have a second axis
(local name-ref vs. global hash-ref) with different invariants.
Lots of complexity for a modest gain over option 1. The one
win: edit-of-one-member doesn't force re-hashing siblings —
each member is its own record — but then cross-member
references go stale in exactly the way P0.1 was supposed to
fix. Net: worse than option 1.

**Fixed-point hashing (option 3).** Mathematically attractive;
practically brittle. Convergence depends on the hash function's
mixing properties and the graph's structure; adversarial inputs
can prevent convergence. Unison considered this and chose SCC-
positional instead. Not MVP. Probably not ever.

**Required grouping (option 4).** Clean if users author sema
directly. Bad if ingesting Rust: real Rust code doesn't mark
mutual-recursive groups. The ingester would have to detect
them — which is exactly the SCC computation from option 1,
with the extra step of emitting a grouping record. So option 4
≈ option 1 with a larger record, where the grouping is the
component boundary. Probably redundant.

### Recommendation

**Unison-style SCC hashing**, with a small refinement: the SCC
is represented as an explicit `FnGroup` (or `ItemGroup`) record
kind, size-1 included.

Specifically:

- A new record kind in `nexus-schema`:
  `FnGroup { members: Vec<FnMember> }` where each `FnMember`
  carries the fn's `signature: Signature`, `body: Block`, and
  `name: FnName`. The group's hash covers all members in a
  canonical ordering (e.g. members sorted by the hash of their
  body relative to member-index-0 placeholders).
- Individual function identity is `FnRef { group: FnGroupId,
  index: u16 }`. Every place that would have been a `FnId` under
  naive hashing becomes an `FnRef`.
- The ingester runs Tarjan on the call graph and emits one
  `FnGroup` per SCC. Size-1 components are groups of one; no
  syntactic marking differs between standalone and recursive fns.
- **Signatures are factored out of the group body boundary.**
  A `Signature` record stands alone, hashed by its content; `g`
  can be called from `f`'s body via `FnRef { group: G, index: i }`
  where the call site only looks at `FnRef` → group → member's
  signature. The *body* doesn't need to be dereferenced for
  call-site typing. This is r-a's body/signature firewall,
  applied here: the recompute scope for a body-edit is the body
  itself plus downstream analyses, not the caller's body.
- **Trait impls pointing into SCCs**: a `TraitImpl` that
  implements a method calling recursive helpers in its impl
  body sits inside whatever `FnGroup` the implementation method
  is part of — which means a `TraitImpl` record references an
  `FnGroup` for its method bodies. If the group crosses
  `TraitImpl` boundaries (rare but possible — free functions in
  a module mutually recursive with trait impl methods), the
  group record contains the trait-impl's methods plus the free
  functions, all as members. The `TraitImpl` record references
  its method members by `FnRef`. No special case.
- **Nested SCCs**: by definition, a strongly-connected component
  is maximal. If `{ f, g }` forms an SCC and `h` calls both `f`
  and `g` but neither calls back to `h`, `h` is not in the SCC.
  `h` sits outside the `FnGroup`; its body cites `FnRef` to the
  group. Nesting doesn't happen.
- **SCCs with many members.** Not a special case; `members`
  vector just gets longer. Canonical ordering costs O(n log n)
  per SCC; for typical sizes this is negligible.
- **Alpha-equivalence**: applied *within* bodies (parameter
  names don't affect body hash). *Not* applied across group
  members — member names matter for `FnRef` resolution because
  callers need stable index mapping.

### Migration plan

The existing `nexus-schema` has `Fn` not yet implemented (report
004's body/method-slice layer is the "next push" — the domain
records exist, the body records are planned). This means SCC
hashing can be designed in from the start, without retrofit.

Order:

1. Design `FnGroup`, `FnMember`, `FnRef`, `Signature` record
   kinds now (pre-body-layer-implementation).
2. Specify the Tarjan + canonical-ordering algorithm for the
   ingester. Write it in the ingester codepath, not in
   criomed's hot path — SCC detection is an ingest-time
   operation.
3. On warm edit (user mutates a body), the edit is scoped to a
   `FnMember` inside a `FnGroup`. Criomed must recompute the
   group's hash (affects only this group's record). Downstream
   propagation is normal cascade — callers citing `FnRef {
   group: G_old, index: i }` get redirected via the
   group-name-index (the name of the SCC's head function, or a
   derived group-name) to the new group hash.
4. Specify that the group-name-index lives in the P0.1 name
   index (groups are named by their head function's name, or
   by the sorted members' names concatenated — design
   decision).

### Open sub-questions

- **SCC churn on body edit.** A body edit inside an SCC of
  size 5 changes the hashes of all 5 members' references
  (because the group-hash changed). Is this a problem? The
  *record count* grows modestly; the *storage cost* grows by
  one `FnGroup` record per edit; the *cascade cost* is the
  number of external callers of the group, which is usually
  small. Measure once implemented.
- **Mutual-recursive traits.** A trait method calling another
  trait method (through trait dispatch, so via vtable) creates a
  dynamic dependency, not a static one. These are *not* SCC
  members — the call is through `Self::method`, resolved at
  monomorphisation. Stay out of the `FnGroup` membership set;
  treated as normal non-cyclic.
- **Mutual-recursive types** (e.g. `enum Tree { Leaf, Node(Box<Tree>) }`).
  Boxes break the cycle at the type layer — `Tree` references
  itself via `Box<TypeId>`, and `TypeId` is a hash reference.
  This is *already* handled by the existing `TypeId` indirection
  in `nexus-schema`. No SCC for types.
- **Constants referring to each other** (`const A: i32 = B; const B: i32 = A + 1`).
  Disallowed by Rust's semantics; skip. If legal cycles appear
  at the const layer (they generally don't — Rust says no), fold
  into the same `FnGroup`-like mechanism under a `ConstGroup`
  kind.
- **Type parameters of mutual-recursive fns.** `fn f<T>(x: T) {
  g(x) } fn g<T>(x: T) { f(x) }` — does this force `T` into
  the group? Parameter scoping is already intra-fn; the group
  record carries per-member generic parameter lists. No special
  case.

---

## P0.3 — Ingester scope

### Problem restatement

The ingester converts `.rs` text into nexus-schema records.
Report 026 calls it a "one-shot bootstrap tool"; reports 027
and 031 correctly push back: Rust parsing + name resolution +
macro expansion + trait metadata + external crate metadata is
a substantial chunk of what rustc's frontend does. LLMs emit
text constantly, so ingest happens on every AI-mediated edit
cycle, not just at bootstrap. The ingester is therefore
continuously on the hot path, not a one-time tool.

And it is the engine-external gateway: the hash-ref discipline
(P0.1) and the SCC computation (P0.2) are both run *by the
ingester* at commit time. Ingest is where the "code as logic"
invariant is established for external inputs.

### Options

1. **Link r-a crates** (`ra_ap_syntax`, `ra_ap_hir_def`,
   `ra_ap_hir_ty`, etc.) as a library; translate r-a's `hir-def`
   / `hir-ty` output to `nexus-schema` records.
2. **`syn` + custom minimal resolver** for a hand-rolled
   ingester. Trivial subset: no non-derive macros, no
   trait-bound generics, trait impls shallow, etc.
3. **Shell out to `rustc`** (or a rustc-driver-linked helper)
   and consume some resolved-form output. `rustc --emit=dep-info`,
   `--emit=metadata`, or more recently `rustc_driver`-hosted
   queries.

### Precedents

**rust-analyzer as a library.** r-a does publish crates to
crates.io via the `ra_ap_*` prefix (`ra_ap_syntax`,
`ra_ap_hir_expand`, `ra_ap_hir_def`, `ra_ap_hir_ty`,
`ra_ap_ide`, etc.). These are versioned and buildable outside
r-a proper; they are not stability-guaranteed — r-a's own
releases are "the product", and the published crates lag /
churn. Projects that have used them in anger: [rustic]
(syntax-tree RPC for editors — defunct), [roslyn-ish
experiments], and internally at rustc-for-tooling projects
where people want r-a's name resolution without an LSP. The
published crates get a fresh release every 1–2 weeks tracking
r-a's nightly; breaking changes are not guarded; the surface is
vast. *Consumable — with a pin-and-patch discipline.*

Concretely, for our ingester, the relevant subset:

- `ra_ap_syntax` — rowan red-tree parser. Stable input; text
  in, syntax tree out. Lightweight.
- `ra_ap_mbe` + `ra_ap_hir_expand` — macro-by-example expander
  + hir-expand (proc macro host connection). Essential for
  `vec!`, `format!`, etc.
- `ra_ap_hir_def` — item-tree and def-map. The "what items
  exist in what scope" answer. Key for our name resolution.
- `ra_ap_hir_ty` — inference + chalk-based trait solver. Key
  for knowing what `Bar::new(…)` resolves to.
- `ra_ap_base_db` / `ra_ap_vfs` — the file abstraction r-a
  uses; we'd adapt this to read from our workspace.
- `ra_ap_proc_macro_srv` / `ra_ap_proc_macro_api` — the
  proc-macro host subprocess. Essential; hard to avoid if any
  crate uses `#[derive(Serialize)]` or similar.

Cost of (1): vendor or pin-and-patch `ra_ap_*` at a specific
r-a commit, write the HIR→nexus-schema translator (probably
3–5 KLOC of translation code), maintain against r-a churn.
Coverage: everything rustc stable supports, modulo r-a's own
lag. Tied to r-a's Cargo feature flags; some transitive
dependencies pull in heavy crates (syn 1.x + 2.x, various
crate-graph libraries).

**`syn` alone.** `syn` is a mature, stable proc-macro parser.
Its capabilities end at *syntax*: it gives you a typed AST of
Rust syntax but does not resolve names, expand macros, or know
anything about trait bounds being satisfied. For a "trivial
subset" MVP:

- No proc macros (derive skipped or run through a side channel).
- No macros-by-example except trivial ones we can expand by
  hand.
- No generics with non-trivial bounds.
- Name resolution: hand-written, scoped-by-module. The
  algorithm is published (rustc-dev-guide has it); ~1–2 KLOC
  careful implementation for a subset. Doesn't handle:
  glob-imports, re-exports, `use self`, `use crate`, macros
  affecting the module graph, cfg-attrs gating items. For a
  subset of the engine's own code that deliberately avoids
  these, this is workable.

Cost of (2): 3–6 KLOC of ingester code, with many known
limitations. Coverage is the subset we decide to accept, and
expands only as we grow the ingester. Maintenance is cheap —
`syn` is stable, our code is small. Alignment with sema: we
directly build nexus-schema records, no translation layer.

**rustc-driver / `--emit=metadata`.** `rustc_driver` is
rustc's own library interface, callable from Rust code. It
gives us access to rustc's everything — phases, IR, trait
solver, borrow checker. Tied to nightly and highly unstable
(rustc_private); every rustc version breaks it. It is what
Miri, clippy, and rustdoc use — all of which ship alongside
rustc on a per-nightly rhythm. For an external project, using
`rustc_driver` means tying your release schedule to rustc's.

`--emit=metadata` is the compiled-metadata output rustc uses
for cross-crate dependency resolution. It is a rustc-internal
binary format (`rmeta`); decoding it requires linking
`rustc_metadata`, which is rustc_private. So this reduces to
"shell out to rustc and then link rustc_private to read the
output" — same coupling cost as `rustc_driver`.

Cost of (3): tight coupling to rustc nightly (a new nightly
breaks you until you adapt); extremely high coverage (rustc is
the oracle); the rmeta decoding is a whole subsystem. For
tooling-heavy, moving targets, this is the approach.

### Tradeoff analysis

**Coverage.**

- (1) r-a: ~stable-Rust coverage, modulo r-a's lag. Handles
  macros, proc-macros, trait solving, name res at production
  quality.
- (2) `syn`: minimal syntactic coverage. Name res is what we
  write. No macros beyond derive.
- (3) rustc: ~100%, bleeding-edge.

**Cost-of-initial.**

- (1) Several team-months (half of that in learning the r-a
  API surface + adapters). Assume 2–4 team-months to a
  passable translator, another 2–3 to harden.
- (2) 1–2 team-months for the subset MVP, clearly working on
  our own code. Grows per feature we want to support.
- (3) 2–4 team-months + ongoing churn handling. High risk.

**Cost-of-maintenance.**

- (1) Ongoing. Every few weeks, r-a releases a new version;
  our pin floats forward with translator patches. Estimate
  1–2 engineer-days per r-a bump for small breakage; occasional
  larger surgery when r-a refactors an internal crate we touch.
- (2) Low — our code, `syn`'s stability. Features we don't
  support stay out.
- (3) Very high. Every rustc nightly potentially breaks.
  Miri / clippy devote real labor to keep up; we shouldn't.

**Alignment with sema shapes.**

- (1) r-a's `hir-def` data shapes are close-to-but-not-the-
  same-as our nexus-schema. The translation is mostly
  mechanical (ItemTree → Module records, Body → Block, etc.)
  with a few mismatches (r-a's name-resolution sometimes
  differs from what we want in edge cases, e.g. glob-import
  shadowing). Good but not trivial.
- (2) Perfect — we build records directly; no translation.
- (3) rustc HIR is much lower-level than nexus-schema; MIR is
  even lower. Translation is substantial.

**Risk to the "code as logic" invariant.**

- (1) r-a inherits rustc's classical "unresolved name" errors;
  the translator can encounter partially-resolved output and
  must handle it. Acceptable: ingest can reject partial inputs
  and report the same classical errors as rustc does (exactly
  what 026 conceded would happen at the commit boundary).
- (2) Custom resolver — we control failure modes precisely;
  can tailor error reporting to sema's model.
- (3) rustc: gives us everything, but it has opinions about
  *when* to fail (sometimes in the middle of monomorphisation).
  We'd need to run enough phases to get resolution out without
  triggering the expensive phases.

### Recommendation

**For MVP: (2) `syn` + custom minimal resolver**, with a
deliberate path toward (1) for post-MVP breadth.

Rationale:

- **MVP scope is self-hosting.** The engine's own source is
  small, macro-light (mostly `derive`), and we can control its
  shape. A hand-written ingester tuned to this code is feasible
  in 1–2 team-months. We know exactly what Rust features we
  need to support.
- **Control over edge cases.** Our name resolution can be
  implemented with sema's model front-of-mind — hash-ref
  canonicalisation, SCC detection, etc. — without fighting
  r-a's internal assumptions.
- **Reducing the r-a dependency surface buys schedule
  certainty.** r-a crate churn is the biggest external
  uncertainty for (1); avoiding it until post-MVP means our
  MVP milestone doesn't depend on r-a keeping things stable.
- **Path to (1) post-MVP is open.** Once we have a working
  MVP, adding r-a-based ingest for "arbitrary external Rust
  crates" is purely additive — the record-emitting interface
  doesn't change; we swap the frontend.

**Team-months estimate**:

- MVP `syn` ingester covering the engine's own code + small
  helpers: **2 team-months** for the ingester; **0.5
  team-month** for workspace integration and CI.
- Expand to cover `std` interfacing (ExternOpus
  ingestion, limited): **+1 team-month**.
- Expand to full `ra_ap_*` integration for arbitrary external
  crates: **+3–5 team-months**, + ongoing churn handling of
  maybe 1 engineer-day per fortnight indefinitely.

**What MVP supports**:

- All structural Rust needed for the engine's own crates
  (nexus-schema, criomed, nexusd, rsc, lojixd).
- `derive` macros (handled by expansion into records using
  known-by-hand derive patterns, the way `syn` proc-macros do).
- Non-generic trait impls. Generic bounds on known traits
  (`Send`, `Sync`, `Clone`, `Debug`).
- Plain `use` imports, no globs, no re-exports.
- No `#[cfg(…)]` gating except `#[cfg(test)]` (rejected).
- No function-like / attribute proc macros.

This covers ~90% of the engine's own code syntactically. The
remaining 10% is code we can refactor to fit the ingester, or
feed through a pre-processor.

**What MVP explicitly does not support**: `std` sources — we
use `ExternCrate { name, pinned_version, lockfile_hash }`
opaque references, matching report 031 P0.3's hint. `std`'s
types are referenceable by name *across* the opaque boundary
(the ingester has a small hand-curated map of well-known
names: `std::option::Option`, `Vec`, `String`, `HashMap`, etc.,
mapped to synthetic trait/type records). This is a pragmatic
shortcut; ingesting full `std` is (1)-level territory.

### Migration plan

Phase A — `syn` ingester for self-host:

1. Vendor `syn 2.x` + `proc-macro2`.
2. Write module-graph walker (walk `Cargo.toml`, find crate
   roots, recurse through `mod` items).
3. Write name resolver: a scope chain of opus → module →
   function-body, with the hash-ref canonicalisation from P0.1
   applied at the end.
4. Write item translator: `syn::Item` → `nexus-schema` record
   of the appropriate kind. Needs a matching record kind for
   every Rust item we intend to support.
5. Write body translator: `syn::Expr` / `syn::Stmt` → record.
   This is the largest single chunk of the ingester; probably
   ~1000–1500 LoC.
6. Run Tarjan over the def-use graph; emit `FnGroup`s per
   P0.2.
7. Emit `Assert` verbs to criomed over nexus.

Phase B — growing the ingester:

8. Expand item translator to cover more features (generics with
   bounds, lifetimes in non-trivial positions, async fn,
   etc.). Each addition is a bounded piece of work.
9. Add `#[derive(…)]` expansion via `ra_ap_proc_macro_srv` if
   we want real proc-macro derives; otherwise, hand-match common
   derives (Debug, Clone, Serialize) in the ingester.

Phase C — swap to r-a for external crates:

10. Vendor / pin `ra_ap_syntax`, `ra_ap_hir_expand`,
    `ra_ap_hir_def` at a specific r-a commit.
11. Write the HIR→nexus-schema translator as a separate
    backend. Our custom ingester remains for the engine's own
    code; r-a backend covers "ingest this external crate for
    ExternOpus referencing."
12. (Optional, well post-MVP) Unify: r-a-backed ingest
    everywhere. Retire the `syn` frontend once feature parity.

The staged path means we never have both ingesters *required*
simultaneously — the custom one handles the engine; r-a
handles externals; later they can merge but don't have to.

### Open sub-questions

- **Proc-macro hosting.** For derives beyond the hand-matched
  set, we need `ra_ap_proc_macro_srv` (or an equivalent).
  Running this in Phase A is possible; it's a separable dep.
  Defer unless we hit a derive we can't hand-pattern.
- **Incremental ingest.** User adds a new file — does the
  ingester re-scan the whole workspace or just the delta? r-a
  gets this for free from salsa; our custom ingester would
  need to track per-file hashes and re-emit only changed items.
  Defer — MVP is full-workspace re-ingest per edit session.
- **Diagnostic attribution.** When the ingester rejects a name
  (P0.1 "cannot find type"), it should emit a sema-level
  `IngestDiagnostic` record with the failing site marked by a
  path into the source text. Span-attribution infrastructure,
  parallel to rsc's span table — small.
- **Dependency-order ingestion.** The ingester needs to ingest
  crates in topological order (leaves first, so references
  resolve to already-emitted hashes). Cargo's metadata
  already gives this. Not a design question, a correctness
  requirement.
- **Re-ingest on LLM-generated text.** When an LLM emits text
  for a record subtree, does it go through the full ingester
  or through a smaller "re-ingest one body" path? Probably
  the latter, tuned for the specific context (scope already
  known, name-index already primed). Shape this out once the
  MVP ingester exists.

---

## Cross-cutting

The three decisions are not independent; they cascade.

**Ordering.** P0.1 (hash vs name) is the root. Its
recommendation shapes what the ingester has to do (P0.3) and
constrains how SCC hashing works (P0.2). So the effective
decision order is P0.1 → P0.2 → P0.3.

If P0.1 lands as "dual-mode with hash-only storage," then:

- P0.2's SCC hashing becomes *necessary* (every cycle must
  resolve to a DAG at storage) — there's no escape hatch like
  "leave a name-ref for cycles."
- P0.3's ingester becomes *responsible for canonicalisation*
  (names → hashes), which in turn means it's responsible for
  running Tarjan and emitting `FnGroup`s. The ingester is a
  substantial frontend, matching the "not a weekend project"
  reality.

If instead P0.1 lands as "name-ref only" (current code
implicitly):

- P0.2 disappears — name-refs are symbolic, so cycles are fine.
- P0.3's ingester is lighter — name resolution is deferred to
  criomed query time. But we've lost the "class of rustc
  errors vanishes" claim entirely.

**Ingester + hash-ref + r-a.** If we eventually go r-a
(P0.3 option 1 for external crates), r-a's `DefId` is a close
analog of our hash-ref: the DefId is salsa-interned by
(crate_id, def_path) *content*, not by identity. Swapping
salsa-intern-by-content with blake3-hash-by-content is a
relatively shallow adapter. Several reports (029 Part 7) make
this observation already; the current recommendation preserves
the option: our custom `syn` ingester emits hash-refs from the
start; r-a's translator would also emit hash-refs; the ingester
frontend is swappable.

**SCC hashing in the ingester.** The `FnGroup` record (P0.2)
is emitted by the ingester, not by criomed. Ingesting is where
Tarjan runs. This is clean: criomed receives already-grouped
records; its only job is hash-ref validation + SCC record
shape-check + storage. If the ingester were in-daemon, the
boundary would blur; keeping it external preserves the rule
"criomed does not parse or resolve."

**The edit UX question (P1.1, out of scope here but tangent).**
If edits arrive as `(Mutate (Fn …))` at the nexus surface, the
*caller* has already done name resolution: they spelled a hash
already. In practice, LLMs emit text; the ingester path must be
cheap enough to run on every save / every suggestion. A
per-body re-ingest (not full-workspace) is the efficient shape.
P0.3's Phase A lays groundwork; per-body efficiency is a Phase
B concern.

**Decision velocity.** The three Priority-0 questions can be
closed in short order because:

1. P0.1 has a clear winner (dual-mode with hash-only storage)
   once the current code's half-done dual-mode is acknowledged.
2. P0.2 has a clear precedent (Unison's SCC hashing) that
   applies directly.
3. P0.3's MVP path (`syn` + custom resolver) is bounded and
   estimatable; expanding to r-a is a later, independent step.

None of these decisions require a research project before they
can be acted on. What *does* take time is the implementation
work (refactor `nexus-schema`, design `FnGroup` and friends,
write the ingester). Those are engineering, not research.

**One integration risk to flag.** The name-index subsystem in
criomed (P0.1 recommendation item 2) must be durable and
crash-safe — it's what lets the engine say "this is the current
`f`." If the name-index gets out of sync with sema records, the
claim "every reference is hash-ref, validated at commit" is
preserved but the query "find me the fn called `resolve_pattern`"
returns a stale hash. Subsystem ordering at commit: write
records → update name-index → ack. Reverse order at rollback.
This is a small redb transaction but worth spec'ing carefully.

---

*End report 042.*
