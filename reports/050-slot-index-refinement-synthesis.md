# 050 — slot/index refinement synthesis — answers to Li's 4 points + tensions

*Claude Opus 4.7 / 2026-04-24 · synthesis of reports 047 (slot-id
design), 048 (per-kind change log), 049 (global scope) into
direct answers on Li's four sub-questions, with the tensions
between the three agents' recommendations made explicit.
Replaces the "clarifying sub-questions" section of report 046 §P0.1.*

---

## TL;DR — refined recommendations

| Sub-Q | Li's lean | Ratified |
|---|---|---|
| 1 · Slot-id shape | Incrementing int + freelist + enum mapping | `Slot(u64)` counter + freelist + rsc-generated per-opus enum |
| 2 · Scope | Global | Global. **One name per slot** (`SlotBinding.display_name`), globally consistent. Rename changes it everywhere. |
| 3 · Change log per-kind | Per-kind | Per-kind; ground truth; `index::K` + `rev_index` derivable. |
| 4 · Cascade trigger | Suggestion accepted | Subscription on index-entry (`SlotBinding` kind). |
| + | Width | `u64` (ratified 2026-04-24). |
| + | Composite name ownership | Ingester computes initial name; criomed handles subsequent renames. |

**Net**: all five decisions ratified. Remaining work is mechanical (record shapes + redb tables).

---

## 1 · Slot-id shape (Li's point 1)

Your proposal:
> could just be an incrementally increasing number, with free
> slots being reused. cheap. could eventually be mapped to an
> enum (or initially even; then enum name becomes the object
> name — could be a composite name made from module name and
> in-module name (shapeOuterCircle or parseFromObjectsInnerDiameterNew,
> etc) — then a rename doesn't change the int representation,
> which is what is stored as rkyv, right? It could still have an
> "opus-local" name-field, and a freed slot can be reused.

### What the research confirmed

- **Integer with freelist is the right substrate.** Cheap rkyv
  footprint (4–8 bytes per reference site), standard
  Datomic/Postgres pattern.
- **Slot reuse is safe** — but only if the index keeps
  **bitemporal bindings** (report 047): a slot's history is not
  "current-hash only" but a series of `SlotBinding { slot,
  content_hash, display_name, valid_from, valid_to }` records.
  Querying sema at rev R1 sees the binding that was active at
  R1, not whatever was reassigned later.
- **Enum mapping = rsc-generated, per-opus** (047 §2 lean on
  your option (a)). A global enum with every slot ever minted
  (your option (b)) breaks rustc at scale (rustc chokes on
  enums with ~10k+ variants). Per-opus keeps the enum small
  and lets cross-opus references render as
  `other_opus::SemaSlot::X`.
- **Rename works as you described**: the stored `u64` is
  unchanged. rsc regenerates the per-opus enum with the new
  variant name on next projection.

### Tensions between the research reports

Two tensions surfaced that Li should decide:

**a) u32 vs u64 width**
- 047 recommends `Slot(u32)` — 4.3B capacity, 4-byte rkyv cost.
- 049 recommends `Slot(u64)` — 8-byte rkyv cost, room for
  federation-partition prefix bits.

My lean: **u64**. The extra 4 bytes per reference is minor;
the federation headroom is real (high 8 bits = partition, low
56 bits = counter). u32 forces a migration later.

**b) Who computes the composite display-name?**
- 047 says **the ingester** (it's the only component that knows
  module paths at slot-creation time).
- Your phrasing suggests criomed or the index owns it.

My lean: **ingester owns the display-name at creation**;
subsequent edits (rename) are mutations on the `SlotBinding`
record's `display_name` field, owned by criomed. This is
consistent with "criomed doesn't see Rust source, it sees
records" — the ingester is the component that translates
text → records and thus owns first-pass naming.

### Concrete shape

```
pub struct Slot(pub u64);          // rkyv-archived as 8 bytes.

// Record kind stored in the per-kind log for SlotBinding.
pub struct SlotBinding {
    slot: Slot,
    content_hash: Hash,            // current content for this slot at this rev
    display_name: Name,            // ONE global name; composite like shapeOuterCircle
                                   // rename changes this; every opus's rsc
                                   // projection picks up the new name
    valid_from: RevisionId,
    valid_to: Option<RevisionId>,  // None = current; Some = historical (slot reused)
}

// Opus-level record: declares which slots this opus defines and their
// visibility. NO per-opus name — names are global via SlotBinding.
pub struct MemberEntry {
    slot: Slot,
    visibility: Visibility,
    kind: KindId,                  // Fn / Struct / ...
}
```

Note: no per-opus name aliasing in the MVP. A slot has one
global display-name. If `use X as Y` aliasing ever matters,
add an `AliasEntry { target_slot, local_name }` record kind
later — don't design for it now.

Seed-slot reservation: `[0, 1024)` is reserved for compiled-in
seed records. The allocator refuses to mint slots in that
range; seed slots are hardcoded `const SEED_SCHEMA_ROOT: Slot
= Slot(0); const SEED_OPUS_KIND: Slot = Slot(1);` etc.
User-authored content starts at slot 1024.

---

## 2 · Global scope (Li's point 2)

Your position:
> I think global is better; then we create the right abstraction
> from the beginning, where an object is referred to absolutely.
> When represented in rust, it would use its opus-local
> name-field.

### What the research confirmed

- **Global is the cleaner abstraction.** Sema becomes genuinely
  *the* semantic store rather than a per-opus shard.
- **The rename concern dissolves mechanically.** Names live on
  the opus's `MemberEntry`, never on the slot. Renaming a
  function in opus A doesn't touch opus B's `MemberEntry` that
  happens to reference the same slot. Each opus keeps its own
  view.
- **Name collisions aren't real under global**. Two unrelated
  crates with `fn parse` get different slots because the
  ingester resolves by import-path (not by name). Slot identity
  is orthogonal to naming; naming is a per-opus per-scope
  concern.
- **Cross-opus deps cleaner than Rust's `use`** — references
  cross opus boundaries via the same slot-ref as intra-opus,
  gated only by `Visibility` on `MemberEntry`. `OpusDep`
  becomes a visibility gate, not a re-export plumbing layer.

### Recommendation supersedes 046 §P0.1 sub-Q 2

Drop the earlier "opus-scoped lean" in 046. Global is the
canonical choice. Federation (multi-criomed peers) is the only
post-MVP concern; the mitigation is a partition prefix in the
high bits of `Slot` (`u64` gives 8 bits × 255 partitions
easily).

### Concrete plumbing

- **Allocator**: criomed has a single `next_slot: u64` counter
  in a sema redb table; mutations that need a new slot increment
  it (single-writer, no coordination).
- **Opus membership**: each Opus record carries a
  `Vec<MemberEntry>` — the opus's view of which slots it
  contributes + renames.
- **rsc projection**: walks from referring opus down; at a
  cross-opus slot-ref, rsc looks up `MemberEntry` in the
  referring opus first (if the opus re-exports or aliases the
  slot), otherwise falls back to the defining opus's
  `MemberEntry`.

### Post-MVP path

Report 049 suggests migrating the slot-id shape post-MVP from
`Slot(u64)` counter to `Slot(Blake3)` — the *birth-hash* of the
record at creation. Advantages:
- Content-addressing-consistent (identity is derived from
  content as it was when born).
- Federation-friendly (collision-free across peers without
  partition coordination).

This contradicts your "incrementally increasing number"
framing. I'd lean: keep the counter for MVP (simpler,
cheaper); revisit birth-hash at federation time. The migration
would rewrite all stored slot-refs once; per-kind change logs
make this a scan-replace-per-kind operation.

---

## 3 · Per-kind change log (Li's point 3)

Your position:
> Those changes live in a change log. Change logs should be
> per-kind, to make lookups faster and logs more manageable.

### What the research confirmed

- **Per-kind is the right primary index.** Strongly wins on
  IDE-shaped queries ("history of this one Fn"), on federation
  diffs, and on world-model high-churn kinds (sensor data
  doesn't pollute code kinds' logs).
- **Unified-log losses are cheap to cover**: cross-kind time-
  window audits use a global `rev_index: RevisionId → Vec<(KindId,
  Slot, seq)>` auxiliary table. Doesn't duplicate data — points
  at per-kind logs.
- **Per-kind change log is ground truth.** Everything else —
  current-state index tables, `rev_index`, audit-by-principal
  indexes — is a derivable view. If an index corrupts, rebuild
  from the logs.

### Concrete shape

```
// One redb table per record-kind K:
// key   = (Slot, seq: u64)
// value = ChangeLogEntry rkyv
//
// Entry shape:
pub struct ChangeLogEntry {
    seq: u64,             // per-kind monotonic
    rev: RevisionId,      // global commit clock
    slot: Slot,
    op: Op,               // Assert | Mutate | Retract
    new_content: Option<Hash>,  // None on Retract
    old_content: Option<Hash>,  // None on Assert
    principal: PrincipalId,
    sig_proof: Option<SigProofId>, // for BLS-quorum mutations
}

// Global auxiliary index for cross-kind queries:
// redb table `rev_index : RevisionId -> Vec<(KindId, Slot, seq)>`
// Rebuildable from all per-kind logs.

// Current-state index (the thing P0.1 talks about):
// redb table `index::K : Slot -> (Hash, display_name, ...)`
// Derived from per-kind log; rebuildable.
```

### Audit log placement

Audit metadata is **embedded in each ChangeLogEntry**
(principal + sig_proof). A separate audit log would duplicate.
If we later want fast "who did what" queries, build a
`audit_by_principal: PrincipalId -> Vec<(KindId, Slot, seq)>`
derived index — same pattern as `rev_index`.

### Interactions with other architecture

- **Global Revision clock** coexists fine with per-kind `seq`.
  The revision is the transaction; the per-kind seq is the
  local index entry.
- **Index-indirection (P0.1)**: the `index::K` tables are
  derived from the per-kind logs. Current-state reads hit
  `index::K` for O(1) lookup; historical reads walk the log.
- **BLS-quorum (report 035)**: each entry carries the
  sig_proof inline; `CommittedMutation` records are *proof
  records pointing at* log entries, not duplicates.
- **Multi-category (report 034)**: world-model kinds
  (Observation, etc.) have their own per-kind logs; high
  churn doesn't affect code-kind log performance. Compaction
  policy can be per-kind.
- **Lazy-materialised kinds** (report 043 §P1.4): still have
  logs, just sparser.

---

## 4 · Cascade trigger via subscription on index entries (Li's point 4)

> is that a suggestion? sounds logical

Yes, suggestion; accepted. Concrete mechanism:

- Each dependent analysis (e.g., `TypeAssignment`,
  `CompilesCleanly(opus)`) is materialised keyed by the
  `input_closure_hash` of its inputs.
- Inputs are slot-refs. When any input's `SlotBinding.content_hash`
  changes (= a new SlotBinding row appears in the SlotBinding
  kind's log for that slot), the subscription system fires
  invalidation for dependents.
- Invalidation is salsa-style: mark the memoised derivation
  stale; re-derive on next query or eagerly if there's an
  eager subscriber on the result.

### Engineering plumbing

- **Subscription index**: `slot -> Set<(DependentKind, DependentSlot)>`
  — when slot X's binding changes, look up who cares.
- **Coalescing**: subscriptions fire once per committed
  Revision, not once per index update within a mutation.
- **Durability**: subscription intents are records (per report
  033 Part 2), so they survive criomed restart.

---

## What this unlocks, in order

### Immediate (can start in nexus-schema now)

1. **Introduce `Slot(u64)` newtype** in nexus-schema.
2. **Replace string-ref fields** (`Type::Named(TypeName)`,
   `TypeApplication.constructor: TypeName`,
   `TraitBound.trait_name: TraitName`,
   `Import.names: Vec<TypeName>`) with their slot-ref
   equivalents: `Type::Ref(Slot)`, etc.
3. **Introduce `SlotBinding` and `MemberEntry` record kinds**.
4. **Reserve `[0, 1024)` for seed slots**; enumerate each seed
   slot as a `const` in nexus-schema.
5. **Add `ChangeLogEntry` record shape** (per-kind; stored in
   redb tables per kind).

### Gated on criomed scaffolding

6. **Write the slot allocator** (mutable `next_slot` counter +
   freelist table in sema redb).
7. **Write the per-kind log writer** (appends ChangeLogEntry
   to the kind's redb table; updates `index::K`; derives
   `rev_index`).
8. **Write the subscription system** (slot → Vec<dependent>
   subscription index).
9. **Write rsc's per-opus enum codegen** (emits `enum
   <Opus>Slot { ... }` from the opus's `MemberEntry` list).

### Gated on ingester

10. **Ingester computes composite display-names** at slot-
    creation; emits `SlotBinding` + `MemberEntry` records.

### Deferred

- Birth-hash (`Slot(Blake3)`) migration — post-MVP federation.
- `audit_by_principal` derived index — when authz grows
  past trivial.
- `KindChangeLog` compaction / archival policies — per-kind
  retention when storage pressure emerges.

---

## Mild pushback on three points

These aren't rejections of your directions; just flagging where
the research pushed back or added nuance.

### 1. `u64` not `u32`

You said "incrementally increasing number" without pinning
width. 047 leans `u32`; 049 leans `u64`. I recommend `u64`:
- 4 extra bytes per reference site is not material.
- `u64` gives partition-prefix room (post-MVP federation).
- `u32` is just enough for a single-instance MVP but forces a
  migration at scale.

Decide whether headroom-now or bytes-now wins.

### 2. Ingester (not criomed) owns composite names

You wrote names could live in the index. True, they do —
`SlotBinding.display_name` is the index entry. But the
**original** composite name (`shapeOuterCircle`) has to come
from somewhere, and it has to be computed at slot-creation
time. Criomed at mutation time doesn't see the Rust source;
it sees a record tree. The ingester does see source; it can
compute `<module>.<item-name>` and pass that as the initial
`display_name` in the Assert.

Ratify or override.

### 3. Enum codegen in rsc, not in sema

You implied the enum could carry the integer representation:
"Could eventually be mapped to an enum ... then enum name
becomes the object name". 047 argues the enum is a
*projection* by rsc, not something sema carries. Sema stores
`Slot(u64)` + `MemberEntry { slot, local_name }`. rsc emits
`enum OpusNameSlot { <local_name> = <slot>, ... }` per opus
when projecting `.rs`.

This keeps sema agnostic about Rust's enum syntax; rsc owns
the text-side projection.

Ratify or override.

---

## Updated 046 §P0.1 (pending 046 in-place edit)

The clarifying sub-questions block in 046 should be replaced
with:

> **Decisions ratified 2026-04-24**:
> 1. Slot-id is `Slot(u64)` — monotonic counter minted by
>    criomed, with a freelist in a sema redb table. Seed
>    slots in `[0, 1024)`.
> 2. Scope is **global**. Opus-local names live in each
>    opus's `Vec<MemberEntry>`.
> 3. History is per-kind change logs (one redb table per kind),
>    with a global `rev_index` auxiliary table for cross-kind
>    queries.
> 4. Cascade trigger is a subscription system keyed on Slot →
>    dependents; fires on `SlotBinding.content_hash` changes;
>    coalesced at Revision commit.
> 5. Post-MVP: `Slot(Blake3)` birth-hash for federation-friendly
>    identity.

---

*End report 050.*
