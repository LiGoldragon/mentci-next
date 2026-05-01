# 126 — Pivot to Gas City

*Synthesis of a deep-dive on `github:gastownhall/gascity` (v1.x).
What Gas City is, where it lines up with our existing
beads + jj + nix-devshell + linked-repos workspace, where the
gaps are, and a concrete pivot path. Lifetime: until the pivot
lands as concrete `city.toml` + flake changes, then fold into
`workspace/ARCHITECTURE.md` and delete.*

---

## 0 · TL;DR

Gas City is a thin orchestration SDK on top of the **MEOW stack**
(beads → molecules → formulas) we already use. Beads is the same
beads — `github:gastownhall/beads` — so adopting Gas City is
**additive on top of our existing `bd` flow**, not a replacement.

The fit is strong on the data plane (beads, molecules, formulas)
and on the multi-repo shape (cities, rigs, packs map cleanly to
our workspace + linked sibling repos). The gaps are in the
delivery / containment plane:

1. **No Nix packaging.** Distribution is Homebrew + GoReleaser
   tarballs. We need to write a flake.
2. **No process sandboxing.** Provider isolation is per-runtime
   (tmux=none, subprocess=process-group only, k8s=pod, exec=BYO).
   No bubblewrap / landlock / seccomp anywhere in the SDK.
3. **Git-backed pack fetch.** Gas City `git clone`s pack
   sources; jj-only repos cannot be pack publishers. jj-on-git
   is fine.
4. **Go 1.25.9 + tmux + dolt + bd + flock + lsof + pgrep + jq**
   at runtime — devshell needs all of them.

The pivot is a layering, not a rewrite: keep our existing
`bd` + jj + flake setup; add a `city.toml` at workspace root
that registers each linked repo as a rig; let the gc controller
drive orders/formulas/health; agents continue to mutate beads
the same way they do today.

---

## 1 · What Gas City actually is

Gas City extracts the reusable infrastructure from Steve Yegge's
Gas Town into a Go SDK with **zero hardcoded roles**. The
"mayor / deacon / polecat / witness" vocabulary is pack-supplied
configuration; the SDK only ships five primitives and four
derived mechanisms.

**Five primitives** (Layer 0–1, from gas-city `AGENTS.md:42`):

1. **Agent Protocol** — start/stop/prompt/observe across
   providers (tmux, subprocess, exec, acp, k8s, hybrid, auto).
2. **Task Store (Beads)** — same beads. Everything is a bead:
   tasks, mail, molecules, convoys.
3. **Event Bus** — append-only pub/sub log; critical (bounded)
   + optional (fire-and-forget) tiers.
4. **Config** — TOML (`city.toml` + `pack.toml`) with
   progressive activation by section presence.
5. **Prompt Templates** — Go `text/template` over Markdown.

**Four derived mechanisms** (Layer 2–4):

6. Messaging (mail = bead with `type:"message"`; nudge =
   `AgentProtocol.SendPrompt`).
7. Formulas & Molecules (formula = TOML; molecule = root bead +
   step children; wisp = ephemeral molecule; order = formula
   gated on event-bus condition).
8. Sling (compose: spawn agent → select formula → create
   molecule → hook to agent → nudge → log).
9. Health Patrol (ping → compare → publish stall → restart with
   backoff).

**City-as-directory model.** A city = directory containing
`city.toml`, `.gc/` runtime state, and registered rigs (external
project paths). `gc init` bootstraps; `gc start` acquires
flock on `.gc/controller.lock`, opens a Unix socket at
`.gc/controller.sock`, runs the reconcile loop. State is
discovered from the live process table (`ps`/`lsof`/`pgrep`) —
no PID files, no lock-file truth.

---

## 2 · Alignment with the current workspace

| Our concept | Gas City concept | Notes |
|---|---|---|
| `bd` task tracking | beads task store | **Same project.** No migration needed. |
| `bd formula` / `bd mol pour` | formulas + molecules | Same primitives. Gas City formulas live in `pack.toml`; same molecule shape on the wire. |
| `bd remember` / `bd memories` | beads with `type:"memory"` | Compatible. |
| Linked sibling repos under `~/git/` | rigs (registered with `gc rig add`) | Each canonical repo becomes a rig. |
| `lore/AGENTS.md` (workspace contract) | pack `pack.toml` + per-rig overrides | Workspace contract stays in lore; pack supplies prompt templates, agent identities. |
| `workspace/devshell.nix` (linkedRepos) | `[imports.<binding>]` packs | Different mechanism, same intent: declarative composition. |
| jj on git | git (Gas City requirement) | Compatible because our jj sits on git-backed repos. |
| `repos/` symlink farm | rig path registration | Both expose sibling-repo views; complementary, not conflicting. |

**The two systems compose cleanly because they live at different
layers.** Our flake + linked-repos + jj setup is the
*development-environment* layer. Gas City is the *running-agents*
layer on top. The substrate they share is beads.

---

## 3 · Runtime providers and what they actually contain

Eight providers under `internal/runtime/`. The isolation story
matters because we'll be running Claude/Codex agents against
real source trees.

| Provider | Isolation | When to use |
|---|---|---|
| **tmux** | None — shared tmux server, panes can `send-keys` to each other | Interactive multi-agent dev on one machine. The default. |
| **subprocess** | Process-group via `Setpgid` (`subprocess.go:114`); stdout/err to `/dev/null`. **No namespaces, no cgroups, no seccomp.** Same UID, same FS view. | Background daemon agents, fire-and-forget. |
| **exec** | BYO — delegates to a user-supplied script (`script start\|stop\|attach\|nudge`). Can be the sandbox seam. | Custom isolation: route to bwrap, podman, ssh, k8s. |
| **k8s** | Pod-level OS isolation (depends on cluster policy). No automatic seccomp/AppArmor profile. | If we have a cluster. We don't. |
| **acp** | Process-level + structured JSON-RPC over Unix socket (`acp.go:60+`). Same trust model as subprocess. | Multi-turn approval / agent-client protocol. |
| **hybrid** | Routes per-agent to underlying providers | Mix interactive + daemon agents. |
| **auto** | Picks at session start: tmux → subprocess → k8s | Fallback chain. |
| **fake** | In-memory test double | Tests only. |

**Trust model from `SECURITY.md`:** "Expected behavior in trusted
local development environments... should be reported to the
relevant upstream project unless Gas City creates a new or
materially worse exposure." Gas City explicitly assumes a
trusted local environment. Sandboxing, when needed, is the
operator's responsibility.

---

## 4 · The Nix packaging gap

**Current state:** zero Nix support in the upstream repo.
`find /tmp/gascity -name '*.nix'` is empty. Distribution is:

- GoReleaser tarballs (linux/macos × amd64/arm64) on GitHub
  Releases with SHA-256 + SBOM + GitHub attestations.
- Homebrew tap (`gastownhall/gascity/gascity`).
- Docker images via `make docker-base` / `make docker-controller`.

**Our devshell already has** `pkgs.beads` and `pkgs.dolt`
(see `workspace/devshell.nix:43-46`). Beads is in nixpkgs.
Gas City pins `BD_VERSION=v1.0.3` and `DOLT_VERSION=1.86.6` in
`/tmp/gascity/deps.env`; whether nixpkgs versions satisfy these
must be verified before pinning.

**Pivot work — Nix:**

1. Write a `gascity` derivation. `pkgs.buildGoModule` over the
   v1.x release tag should suffice; it's a vendored Go module.
   Watch the `make build` ldflags — version metadata is injected
   via `-ldflags` and we'll want to mirror that.
2. Add as flake input to `workspace/flake.nix`; expose `gc` in
   `devshell.nix` packages alongside `beads` and `dolt`.
3. Add the runtime deps: `tmux`, `git`, `jq`, `flock` (from
   util-linux), `lsof`, `pgrep` (from procps).
4. Pin Go to 1.25 (gas-city's go.mod is `go 1.25.9`).
5. Optional: upstream the derivation as a flake in our fork or
   PR to nixpkgs once we've used it for a few weeks.

This is straightforward — no CGO, no native deps in the binary
itself, all the heavy infrastructure (dolt, tmux) is shelled out.

---

## 5 · The sandboxing gap — and the right place to close it

Gas City does not sandbox agent processes. The `subprocess`
provider gives a process group; `tmux` gives a tmux pane;
neither contains the agent at the kernel level. An agent
running `claude` against `/home/li/git/criome` can also touch
`/home/li/.ssh` if it decides to.

**Three places sandboxing could live:**

1. **Inside Gas City** — add a bwrap/landlock provider upstream.
   High-leverage but a real upstream feature ask; not a pivot
   blocker.
2. **In an `exec` provider script** — write a shell script that
   wraps `bwrap` (or systemd-run with `RootDirectory=` and
   namespace flags) around the agent invocation, point
   `[session] type = "exec"` at it. This is the documented
   Gas City extension seam. Lowest-friction.
3. **Outside the agent boundary** — rely on the user account /
   SELinux / a separate VM. Punt to OS-level controls.

**Recommendation:** start with (3) for the pivot — we already
trust agents at this level today — and prototype (2) as a
follow-up bd issue. Don't block the pivot on sandboxing;
treat it as a separate workstream once the orchestration is
running.

---

## 6 · Friction points to plan around

### 6.1 jj vs git

Gas City `git clone`s pack sources and uses git tags in release
workflows. Our repos are jj-on-git (jj backed by git), so
`git clone` against them works; this is fine. **What does NOT
work: jj-only repos.** None of our canonical repos are jj-only,
so this isn't a current blocker.

### 6.2 AGENTS.md / CLAUDE.md collisions

Gas City ships its own `AGENTS.md` (the upstream contributor
contract for the gascity repo itself) and a one-line `CLAUDE.md`
shim. Our workspace already has `lore/AGENTS.md` (the workspace
contract) and per-repo thin shims. **No collision** unless we
clone gas-city *into* the workspace as a sibling repo, in which
case its AGENTS.md scopes to its own subtree — which is the
correct behavior for a vendored dependency.

### 6.3 Beads ownership of mutations

Gas City's controller dispatches orders/formulas; our existing
`bd` workflows also mutate beads. Both are valid concurrent
writers via dolt. The integration plan:

- Run **one Dolt server** shared between our `bd` CLI usage and
  Gas City's controller.
- Use distinct **bead ID prefixes per rig** (`[rigs] prefix`) so
  city-driven beads don't visually collide with hand-created
  ones.
- Treat the controller as authoritative for order-driven /
  formula-driven beads; treat humans + ad-hoc agents as
  authoritative for everything else. There is no lock; this is
  a social contract enforced by prefix conventions.

### 6.4 Tmux server scope

Gas City's tmux provider can share the user's default tmux
server or run its own via `tmux -L <socket>`. **Use the per-city
socket** to avoid stomping on personal tmux sessions. The
gas-city `AGENTS.md:203-206` explicitly warns against bare
`tmux kill-server`.

### 6.5 Dashboard / HTTP API

Gas City ships an HTTP API + SSE event stream + a generated TS
dashboard under `cmd/gc/dashboard/`. We don't need this for the
pivot; it's gated behind `[api]` config presence. Skip it
initially.

---

## 7 · Pivot plan

Two viable shapes; we should pick one before building.

### 7.1 Shape A — minimal control-plane adoption

- Workspace becomes a Gas City *city*.
- `workspace/city.toml` declares one or two agents (mayor +
  generic worker) using the **tmux provider** against a
  per-city socket.
- Each canonical repo (criome, sema, mentci-egui, lore, …)
  registers as a rig: `gc rig add /home/li/git/criome`.
- Existing `bd` flows untouched. Orders/formulas added
  *additively* over time as we identify automatable patterns.
- Nix flake adds `gc` to devshell packages; no other changes.

This is the smallest reversible step. We can run it for a few
weeks and roll back by deleting `workspace/city.toml` + `.gc/`
without touching any other repo.

### 7.2 Shape B — full pack composition

- Author a workspace pack at `workspace/packs/sema/` with
  `pack.toml` + agent prompt templates + formulas + orders for
  the criome/sema/mentci flows we actually run.
- City imports the pack via `[imports.sema]`; each rig imports
  rig-scoped overrides.
- Migrate ad-hoc bd commands (memory hygiene, report rollover,
  AGENTS.md drift checks) into orders.

This is the destination but not the first step. Do Shape A
first; promote to Shape B once we know which patterns survive
contact with daily use.

### 7.3 Concrete first-week task list

Best tracked as bd issues, not in this report. Suggested seeds:

1. Write `nix/gascity.nix` derivation (buildGoModule against
   gas-city v1.0 release tag).
2. Add `gc`, `tmux`, `jq`, `flock`, `lsof`, `procps`, `go_1_25`
   to `workspace/devshell.nix`.
3. `gc init workspace/` and commit the generated `city.toml`
   skeleton (tmux provider, per-city socket, beads provider =
   `bd` pointed at our existing dolt).
4. Register criome + lore as the first two rigs.
5. Bring up controller; verify `gc session attach` works and
   that bd state survives controller restart.
6. Document the pivot in `workspace/ARCHITECTURE.md` once the
   above is stable; delete this report.

---

## 8 · Open questions worth flagging before commit

- **Per-city dolt server vs shared.** Gas City spawns its own
  dolt server from `.gc/bd/` by default. We're already running
  beads against a dolt server. Decide whether to point
  `[beads] dolt_host/port` at the existing instance or run a
  parallel one for the city.
- **What lives in the pack vs in lore.** Gas City packs supply
  prompt templates and role definitions. `lore/AGENTS.md` is
  *our* prompt-template-equivalent. Do we render lore content
  through pack templates, or keep them separate and reference
  lore from prompts? Likely the latter, but worth deciding.
- **Sandboxing follow-up.** File a bd issue for the
  bwrap/landlock `exec` script even though we're not blocking
  on it.
- **Upstream contribution surface.** A `flake.nix` PR to
  gas-city is a reasonable contribution if the derivation we
  end up writing is clean. Same for any sandboxing wrapper that
  proves useful.

---

## 9 · Why this is worth doing

The strongest argument for adopting Gas City rather than rolling
our own thin wrapper around `bd`: the **controller / order /
formula / health-patrol** loop is a real piece of infrastructure
to write, and gas-city has it tested with `TestOpenAPISpecInSync`,
`TestEveryKnownEventTypeHasRegisteredPayload`, and a sharded
integration suite. Our `bd remember` + ad-hoc scripts approach
is maintainable today because the workspace is small; once we
want declarative orders ("every Monday, run a memory hygiene
sweep across all rigs"), gas-city already has the dispatch
infrastructure and we'd be reinventing it.

The strongest argument against rushing: the project's distribution
story (Homebrew + tarballs) doesn't yet meet our reproducibility
bar. The Nix work in §4 is the entry tax. It's small, but it's
real, and it should land *before* we put any orders in beads
that depend on the controller running.
