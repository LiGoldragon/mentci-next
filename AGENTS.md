# Agent instructions

Tool references live in [`repos/tools-documentation/`](repos/tools-documentation/) — a symlink to `~/git/tools-documentation/` created on `nix develop` / direnv entry.

Start there for: cross-project rules (jj workflow, always-push, Rust style — see [rust/style.md](repos/tools-documentation/rust/style.md)) in [`repos/tools-documentation/AGENTS.md`](repos/tools-documentation/AGENTS.md), and curated daily-use docs for jj, bd, dolt, nix under [`repos/tools-documentation/<tool>/basic-usage.md`](repos/tools-documentation/).

## Architecture

Canonical architecture: [`docs/architecture.md`](docs/architecture.md). Read it first; everything downstream is in [`reports/`](reports/) (see the reading order at the bottom of architecture.md).

**Workspace manifest**: [`docs/workspace-manifest.md`](docs/workspace-manifest.md) lists every repo under `~/git/` with its status. `devshell.nix`'s `linkedRepos` mirrors the CANON + TRANSITIONAL entries.

### Inclusion/exclusion rule — HARD

**If a repo is not listed as CANON or TRANSITIONAL in the workspace manifest, do not edit its source or docs.** Agents that drift outside the manifest corrupt repos that are either superseded, archived, or outside scope. To add a new canonical repo: update the manifest and `devshell.nix`, write a report, commit.

### AGENTS.md / CLAUDE.md pattern

Across all canonical repos we follow: **`AGENTS.md` holds the real content; `CLAUDE.md` is a one-line shim reading "See [AGENTS.md](AGENTS.md)."** This way Codex (which reads `AGENTS.md`) and Claude Code (which reads `CLAUDE.md`) converge on a single source of truth. When creating or restructuring a repo, keep this pattern.

MVP goal: **self-hosting** — write the system's own source as records in the sema database; rsc projects those records to `.rs` files; rustc compiles them; the new binary reads and extends its own database.

An **opus** is the database's compilation-unit term — one opus compiles to one artifact (library or binary). Corresponds to one Rust crate on the filesystem side.

Write discoveries in [`reports/`](reports/) or in tools-documentation as topic files, don't scatter them across the repo root.

## Tooling

`bd` (beads) tracks short items (issues, tasks, workflow). Designs and reports go in files. See [reference_bd_vs_files](repos/tools-documentation/bd/basic-usage.md#bd-vs-files--when-each-is-the-right-home).

`bd prime` auto-runs at session start and gives current state.
