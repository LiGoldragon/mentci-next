# 107 — Fresh-context handoff snapshot

*Ephemeral. Delete after consumption — the workspace's target state is an
empty `reports/`.*

## State at end of 2026-04-28

- **M0 demo working end-to-end.** `(Node "User")` → `(Ok)` and
  `(| Node @name |)` → `[(Node "User")]` shuttle through
  `criome-daemon` + `nexus-daemon` via `nexus-cli`, verified by
  `mentci-integration` in `nix flake check`.
- `nix flake check` from mentci passes all 14 derivations.
- Every cross-repo `Cargo.toml` uses `branch = "main"` for sibling deps.
- `reports/` is clean except for this file.
- Zero free-function violations, zero ZST-method-holder violations, zero
  stale crate / deleted-report cross-references across CANON repos.

## Where to look

| Question | File |
|---|---|
| Workspace conventions, naming, commit style, jj+always-push, restate-to-refute prohibition, report-rollover discipline | [`mentci/AGENTS.md`](../AGENTS.md) |
| Repo inventory + status | [`mentci/docs/workspace-manifest.md`](../docs/workspace-manifest.md) |
| Project-wide architecture (the canonical doc) | `criome/ARCHITECTURE.md` |
| Per-repo orientation card | `<repo>/AGENTS.md` |
| Per-repo bird's-eye | `<repo>/ARCHITECTURE.md` |
| Beauty is the criterion | `tools-documentation/programming/beauty.md` |
| Methods on types + free-functions-are-incorrectly-specified-verbs | `tools-documentation/programming/abstractions.md` |
| Rust style + No-ZST-method-holders rule + branch-pin policy | `tools-documentation/rust/style.md` |
| Ractor 0.15 patterns | `tools-documentation/rust/ractor.md` |
| Rkyv 0.8 discipline | `tools-documentation/rust/rkyv.md` |
| Crane + fenix flake layout | `tools-documentation/rust/nix-packaging.md` |
| Nix integration-test patterns | `tools-documentation/nix/integration-tests.md` |

## Recent decisions worth carrying forward

- **`branch = "main"` for cross-repo Cargo deps.** Lockfiles still pin by
  sha for reproducibility. The Cargo.toml stays stable while upstream
  evolves; `cargo update -p <dep>` bumps the lock. Switch to `rev = "..."`
  only when a sibling stabilises.
- **`signal::Diagnostic::error(code, message)`** — canonical constructor
  for daemon-emitted Error-level diagnostics. The prior
  `criome::engine::diagnostic` free function was dropped.
- **`Daemon::start` was a ZST-method-holder violation, now gone.** Actor
  markers (`pub struct Daemon;`) carry only `impl Actor for Daemon`
  (trait impl, framework-marker exception). The old inherent
  `impl Daemon { pub async fn start }` is inlined into `main.rs` — the
  only legitimate free-function host.
- **`CriomedInstance` → `CriomeDaemonInstance`.** Daemon-suffix naming
  convention.
- **Style docs are patterns, not snapshots.** Cross-language and
  language-style docs do not embed specific repo file paths, actor
  counts, message-variant names, or cross-citations to downstream
  `ARCHITECTURE.md` files. Discipline encoded in
  `tools-documentation/AGENTS.md`.
- **Reports are ephemeral.** Default to deletion. Extract to architecture
  docs or tools-documentation only when the rationale has no other
  durable home.

## bd state

9 open issues, 0 in-progress, 0 blocked — all forward-looking work. Run
`bd ready` to see them.

| ID | P | Title |
|---|---|---|
| `mentci-next-ef3` | P1 | Self-hosting "done" moment — concrete first feature |
| `mentci-next-d3b` | P2 | M0 step 7 — genesis.nexus + bootstrap glue |
| `mentci-next-7tv` | P2 | M1 — per-kind sema tables (replace 1-byte kind discriminator) |
| `mentci-next-8ba` | P2 | M3 — sema redb wrapper (database library) |
| `mentci-next-4jd` | P2 | M2-remainder: method-body layer in nexus-schema |
| `mentci-next-0tj` | P2 | Implement rsc records-to-Rust projection |
| `mentci-next-7dj` | P2 | Cross-repo wiring — flake input pattern for local dev |
| `mentci-next-zv3` | P2 | M6 — bootstrap demo (DB → rsc → compile → demonstrate) |
| `mentci-next-dqp` | P3 | Rename rsc to a full English word |

## Lurking dangers (context worth keeping)

- **Lojix family carries the ZST-method-holder pattern** that criome +
  nexus had before this session; deferred per Li's "leave lojix alone
  for now." When lojix is next worked on, audit `lojix/src/{uds,actors/*.rs}`
  and `lojix-cli/src/{build,deploy,proposal,project,artifact}.rs` for
  inherent impls on `pub struct Foo;` and apply the same fix shape
  (move work into `main` or onto a real noun with fields).
- **`horizon-rs` flake structure** uses blueprint with a Cargo crate at
  `lib/`; blueprint tries to import `lib/default.nix` which doesn't
  exist, so `nix flake check` from horizon-rs fails. Direct
  `nix build .#packages.x86_64-linux.default` works. Pre-existing,
  unrelated to recent cleanups.

## This file's lifetime

If a fresh agent reads this, internalises the current state, and the
workspace remains coherent at next session start, the file has done its
job. `rm reports/107-*.md` returns `reports/` to its target empty shape.
