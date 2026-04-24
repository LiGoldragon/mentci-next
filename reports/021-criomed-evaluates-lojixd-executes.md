# 021 — criomed evaluates (incrementally); lojixd executes

*Claude Opus 4.7 / 2026-04-24 · important clarification from Li
near end-of-session, supersedes framing in reports/020 §6–§7
about lojixd-as-evaluator.*

## 1 · The correction

Li: *"lojix doesn't have much evaluation to do; everything it
receives is basically a 'do this' message (eval happens
incrementally, every time criomed edits the sema db)."*

This reverses the eval-location call in 020 §6–§7. The clean
picture:

- **criomed is an incremental evaluator.** Every mutation to
  sema records (Assert / Mutate / Retract) triggers
  re-evaluation of dependent derived state. Think reactive /
  salsa-style / differential dataflow — the evaluator
  materialises concrete plans as records change.
- **lojixd is a thin executor.** Receives concrete "do this"
  messages — run this cargo invocation, write these bytes, exec
  this nixos-rebuild, materialise these files. No resolution,
  no planning, no schema awareness beyond what's needed to
  deserialise its wire types.

## 2 · What changes from 020

| Aspect | 020 framing | 021 framing |
|---|---|---|
| lojixd's core role | "evaluator — resolves build specs" | **executor — runs concrete plans** |
| Hallucination wall (for builds) | "lojixd is the wall" | **criomed is the wall** (incrementally, at mutation time) |
| RawOpus → BoundOpus resolution | "inside lojixd" | **inside criomed** (on edit, not on compile) |
| Opus/Derivation records home | lojix-schema (new crate) | **nexus-schema (or sema-schema after rename)** — they're user-written sema records |
| lojix-schema crate | New — holds Opus/Derivation + nix newtypes | **May not exist as a separate crate** — most of what it was going to hold stays in nexus-schema |
| lojix-msg content | "CompileRequest { opus: OpusId, sema_rev, ... }" | **Concrete execution verbs** — RunCargo / RunNix / PutBlob / GetBlob / RunNixosRebuild / MaterializeFiles |
| criomed's role | Guardian + dispatcher | **Guardian + incremental evaluator + dispatcher** |

## 3 · What doesn't change

- Three daemons: nexusd, criomed, lojixd.
- No lojix-cli. Every request through nexus.
- lojix is the namespace umbrella; `lojix` repo reserved for
  spec README (nexus/nota precedent).
- lojixd owns lojix-store; writes are in-process; reads via
  mmap-safe reader library.
- Three-pillar framing (criome ⊇ {sema, lojix}; nexus is skin).
- 11 nix problems lojix fixes (report 019 §3).
- 8 lojix principles (019 §4 adjacent).

## 4 · The flow, corrected

### Edit-time (the heavy work)

```
 human/LLM: nexus-cli '(Mutate (Opus nexusd …))'
        ▼
 nexusd: text → rkyv
        ▼
 criomed:
   • accepts the mutation
   • writes new Opus record to sema
   • incremental evaluator fires:
     - re-resolves toolchain derivation hash
     - re-plans compile: cargo invocation, deps closure, feature union
     - if anything downstream depends on this opus's outputs,
       re-plans those too
   • caches the plan (keyed by opus content hash)
   • fires subscriptions for consumers
```

### Run-time (the thin work)

```
 human/LLM: nexus-cli '(Compile nexusd)'
        ▼
 nexusd → criomed
        ▼
 criomed: plan for opus is already cached (edit-time did it)
        ▼ rkyv (lojix-msg) — a concrete plan, not an Opus ref
 lojixd:
   • receives RunCargo { workdir, args, env, fetch_files, store_output_kind }
   • MaterializeFiles from criomed → workdir
   • spawn cargo with those args/env
   • on success, hash the binary and write into lojix-store
   • reply { output_hash, warnings, wall_ms }
```

lojixd never sees an `Opus` record. It sees a concrete plan.

## 5 · lojix-msg verbs (concrete, executor-facing)

Sketch — concrete shapes to be specified in later reports:

- **RunCargo** { workdir, args, env, fetch_files, toolchain_path,
  expected_outputs, output_kind } → Hash of emitted binary
- **RunNix** { flake_path, attr, overrides, system, expected_nar_hash }
  → narHash / store path of output
- **RunNixosRebuild** { flake_path, action, overrides, target_host }
  → deploy outcome (exit, logs)
- **PutBlob** { bytes } / **PutBlobStream** { session, chunks }
  → Hash
- **GetBlob** { hash } / **GetBlobStream** { hash } → bytes
- **ContainsBlob** { hash } → bool
- **MaterializeFiles** { files: Vec<(ContentHash, RelPath)>,
  target_dir } → Unit
- **DeleteBlob** { hash } → Unit (criomed-driven GC)

Notably absent: `CompileRequest { opus: OpusId }`. That level
of indirection isn't lojixd's business.

## 6 · criomed as an incremental evaluator — load-bearing

This is a significant capability that previous reports
understated. criomed is:

- A records database (sema's storage backing)
- A schema-bound resolver (turns RawPattern into PatternExpr
  at query time)
- A **reactive evaluator** — when a record changes, dependent
  derived state updates automatically
- A subscription dispatcher
- An overlord of lojix (signs tokens, tracks blob reachability,
  directs GC)
- A dispatcher to lojixd (concrete plans → execution)

The reactive-evaluator subsystem is where Opus/Derivation
resolution, pattern re-binding, dependency-closure computation
all live. It's salsa-adjacent — query memoization + invalidation
on upstream changes.

**Not solved in this report**: what reactive computation
framework criomed uses internally. Candidates: salsa-rs, custom
fine-grained dataflow, something simpler keyed on content
hashes. Worth a focused report when criomed implementation
begins.

## 7 · Type-home consequences

**Opus**, **Derivation**, **OpusDep**, **RustToolchainPin**,
**NarHashSri**, **FlakeRef**, **OverrideUri**, **TargetTriple**
— all are user-written sema records. They belong in
**nexus-schema** (to be renamed `sema-schema` per open
question from 019 §Q4).

`lojix-schema` **may not need to exist** as a separate crate.
What it was going to hold either:
- Moves back to nexus-schema (Opus, Derivation — they're
  records)
- Moves to `lojix-msg` (execution types — RunCargo, PutBlob)
- Stays scattered (pragmatic, revisit if pressure emerges)

This reverts 019's recommendation to create `lojix-schema`.
Now: **defer the question**; let types land wherever is
simplest for the first implementation pass.

## 8 · lojix-msg design principle

Keep lojix-msg verbs **as concrete as possible**. The thinner
the evaluator-surface on lojixd, the better. Every time a verb
starts needing "look up X from sema," it should be pushed back
into criomed's incremental evaluator and replaced with a
pre-resolved parameter.

Example refactor trajectory:
- v0: `RunCargo { opus: OpusId }` — lojixd must fetch records
  (too much evaluation in lojixd)
- v1: `RunCargo { opus: OpusId, sema_rev: Hash }` — still needs
  a fetch
- v2: `RunCargo { workdir, args, env, fetch_files: Vec<(Hash, Path)> }`
  — concrete; lojixd just fetches blobs and spawns the process

v2 is the target. All planning happened upstream.

## 9 · Updated daemon character-sketch

- **nexusd** — translator. Stateless. Thin.
- **criomed** — the brain. Stores records, evaluates
  incrementally, resolves schemas, dispatches work. Substantial.
- **lojixd** — the hands. Spawns processes, writes blobs,
  materialises files. Thin.

This asymmetry is deliberate. It mirrors the division of labor
in modern reactive systems: one place holds the thinking; many
places do the work. It gives us:
- One place to cache resolution work
- One place to hallucination-check
- One place to coordinate dependencies
- Workers (lojixd and any future siblings) that can be stateless
  per-request

## 10 · Open questions

**Q1 — What incremental-evaluation framework for criomed?**
salsa-rs? custom? rolled into redb via stored-procedure-like
derived tables? Important but post-MVP.

**Q2 — Does lojix-schema exist?** Lean: defer; let types land
where they fit during first implementation pass.

**Q3 — Does `Opus` / `Derivation` home change back to
`nexus-schema`?** Lean: yes (they're user-facing sema records).
Supersedes 019's recommendation to put them in lojix-schema.

**Q4 — Wire-size of concrete plans.** A `RunCargo` plan with
inline fetch_files listing may be large (hundreds of records
for a big opus). Chunked delivery? Or does lojixd fetch by
hash from lojix-store internally and the plan just carries
hashes? Lean: plan carries hashes; lojixd fetches on demand.

**Q5 — What's the concrete evaluator invalidation story?**
When an upstream Opus record changes, how does criomed know
which downstream plans to invalidate? Content-hash dependencies?
Watch-set per cached plan? Material for the reactive-framework
decision (Q1).

## 11 · docs/architecture.md updates needed

- §1 thesis: describe criomed as evaluator; lojixd as executor.
- §2 daemon diagram: lojixd's role list becomes "execute concrete
  plans"; criomed's grows "incremental evaluator of sema changes."
- §4 repo layout: remove lojix-schema if we defer it; keep
  Opus/Derivation in nexus-schema.
- §5 type families: Opus/Derivation are sema records. lojix-msg
  is execution verbs (concrete, not Opus-referential).
- §6 compile loop: split into edit-time (criomed evaluates) +
  run-time (lojixd executes).
- §8 rules: add "criomed owns all evaluation; lojixd is a worker."

---

*End report 021.*
