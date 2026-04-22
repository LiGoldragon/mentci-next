# 002 — Database architecture

*Claude Opus 4.7 / 2026-04-23*

The database layer for the sema MVP. The MVP scope (per reports/001)
is self-hosting: write the system's own code in the database, have
rsc compile it back to `.rs` files, rustc-compile those, run the new
binary, let it edit its own DB to extend itself.

---

## 1. Constraints

1. **Pure Rust implementation.**
2. **Ordered key-value with multi-keyspace support** — each record
   kind gets its own sort range for efficient prefix scans.
3. **Zero-copy reads** returning borrowed bytes rkyv can view
   directly.
4. **Transactional writes across keyspaces** — atomic
   "assert record + update index" commits.
5. **Content-hash-addressed records** — every stored record is
   keyed by `blake3(rkyv_bytes)`.
6. **Embeddable as a Rust crate** — in-process with the daemon.

---

## 2. Choice — redb

[redb](https://github.com/cberner/redb) 4.1.0 is a stable, active,
pure-Rust copy-on-write B-tree database. Typed tables via
`TableDefinition<K, V>`; zero-copy reads as `AccessGuard<V>`
straight off the mmap; multiple named tables per database map
directly to "one keyspace per record kind." ACID with MVCC readers
and single-writer transactions.

The [`sema`](https://github.com/LiGoldragon/sema) library wraps
redb with sema-specific semantics: record codec (rkyv), hash-keyed
addressing, opus-scoped organization, structural edit operations.
The daemon ([`nexusd`](https://github.com/LiGoldragon/nexusd))
embeds this library and exposes it over nexus messages.

---

## 3. rkyv composition

redb is serialization-format-agnostic. Records are rkyv-archived
bytes stored as `&[u8]` in redb. Reads return borrowed slices from
mmap; `rkyv::access::<ArchivedT>(bytes)` produces a zero-copy view
into the same mapped region.

Alignment: rkyv's `unaligned` feature flag removes the 16-byte-
alignment requirement at a small unaligned-load cost. That's the
default for our dependency; no wrapper needed.

---

## 4. Record addressing

Every record in the database is stored under its content hash:

```
key    = blake3(rkyv_archive(record))
value  = rkyv_archive(record)
```

Cross-record references use content-hash ID newtypes
(`TypeId`, `EnumId`, `StructId`, etc. in `nexus-schema`). Same
content → same hash → same row. Shared substructures are
deduplicated automatically.

---

## 5. What the database isn't (yet)

Defer until a real use case pulls them in:

- **Branches / git-for-data** — linear history suffices for self-
  hosting.
- **Query engine** (Datalog / pattern matching) — structural
  navigation (point lookup by hash, prefix scan by kind) covers
  the self-hosting workflow.
- **Signing + quorum** — single-user MVP.
- **Schema cascade** — the nexus-schema types are stable Rust for
  the MVP; user-type evolution is a later concern.
