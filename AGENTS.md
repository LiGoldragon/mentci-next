# Agent instructions

Tool references live in [`repos/tools-documentation/`](repos/tools-documentation/) — a symlink to `~/git/tools-documentation/` created on `nix develop` / direnv entry.

Start there for: cross-project rules (jj workflow, always-push, Rust style — see [rust/style.md](repos/tools-documentation/rust/style.md)) in [`repos/tools-documentation/AGENTS.md`](repos/tools-documentation/AGENTS.md), and curated daily-use docs for jj, bd, dolt, nix under [`repos/tools-documentation/<tool>/basic-usage.md`](repos/tools-documentation/).

## Architecture

Design docs live in [`reports/`](reports/). Read in order: [001 orientation](reports/001-migration-doc-reading.md), [002 database](reports/002-sema-db-architecture.md), [003 MVP plan](reports/003-mvp-implementation-plan.md), [004 Rust types](reports/004-sema-types-for-rust.md), [007 nota/nexus split](reports/007-nota-nexus-layer-split.md).

Nine repos for the MVP, one artifact per repo (rule 1): `nota` (spec — data-layer format), `nota-serde` (Rust impl), `nexus` (spec — messaging superset of nota), `nexus-serde`, `nexus-schema`, `sema` (the database), `nexusd`, `nexus-cli`, `rsc`. All symlinked into [`repos/`](repos/) via `devshell.nix`.

MVP goal: **self-hosting** — write the system's own source as records in the sema database; rsc projects those records to `.rs` files; rustc compiles them; the new binary reads and extends its own database.

An **opus** is the database's compilation-unit term — one opus compiles to one artifact (library or binary). Corresponds to one Rust crate on the filesystem side.

Write discoveries in [`reports/`](reports/) or in tools-documentation as topic files, don't scatter them across the repo root.

## Tooling

`bd` (beads) tracks short items (issues, tasks, workflow). Designs and reports go in files. See [reference_bd_vs_files](repos/tools-documentation/bd/basic-usage.md#bd-vs-files--when-each-is-the-right-home).

`bd prime` auto-runs at session start and gives current state.
