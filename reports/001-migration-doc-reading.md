# 001 — Orientation

*Claude Opus 4.7 / 2026-04-23*

---

## Architecture

- **Criome** — the dynamic, content-addressed **web of sema**.
  "Local criome" = a host's on-disk slice; content-addressed, so
  it genuinely *holds* its piece rather than caches it.
- **Sema** — the last database format. Universal binary format
  *of meaning*. Self-transforming (spec-change cascades through
  stored data). Rendered for humans via **mentci**.
- **Nexus** — the data format. A serde-compatible text syntax
  (6 delimiter pairs, 4 sigils, no keywords) with
  [`nexus-serde`](https://github.com/LiGoldragon/nexus-serde) as
  the Rust implementation.
- **Nexusd** — daemon that accepts nexus messages, applies edits,
  serves queries over the database.
- **Criomed / Semad** — future daemons on the path toward sema
  native. Nexusd is the MVP.
- **rsc** — records → `.rs` projector. Compiles the database back
  out to Rust source + binary.

---

## MVP scope — self-hosting

Write the system's own source as records in the database. Have
`rsc` produce `.rs` files, rustc-compile them, run the resulting
binary, let it edit its own DB to extend itself. When the loop
closes — editing the DB via nexus, rsc producing a build that
passes — the MVP is done.

This is "pseudo-sema" for now: rkyv-typed Rust records as the
canonical form. Full sema bytes come later.

See [report 003](003-mvp-implementation-plan.md) for the milestone
plan, [report 002](002-sema-db-architecture.md) for the database
layer, [report 004](004-sema-types-for-rust.md) for the Rust type
coverage.
