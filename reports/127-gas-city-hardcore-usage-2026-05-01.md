# 127 — Gas City: hardcore operator's guide

*How to drive Gas City flat-out, oriented around Li's stated
first use: a sparring / teaching city — multiple agents with
distinct engineering aesthetics — used to develop a shared sense
of "good code" before any real project work goes through it.
Lifetime: until the philosophy-city is stood up and the operating
muscle memory is in fingers, then fold the bits worth keeping
into `lore/` per-tool docs and delete.*

---

## 0 · How to read this

Report 126 covered architecture and the pivot decision. This
report is the operating manual: tutorial digest, idiom, the
patterns experienced operators settle into, and a concrete
sketch of the philosophy-city tailored to the stated use.

The fastest path through it for someone new:
1. §3 — stand up a city in 4 commands.
2. §9 — the philosophy-city sketch (the actual thing Li wants
   to build first).
3. §6 — orders, because passive automation is what makes a city
   feel alive.
4. §7 — Gastown idioms, as the reference for "what mature
   operators do".

The rest is depth lookup.

---

## 1 · The mental model in one paragraph

A **city** is a directory on disk. Inside it: a `city.toml` (deployment), one or more imported **packs** (reusable bundles of agent prompt templates + formulas + orders), zero or more **rigs** (registered external repos), and a `.gc/` subtree (machine-local state — beads database, controller socket, session metadata). A long-running **controller** (`gc start`) reconciles desired state (config + beads) to actual running **sessions** (live processes — typically tmux panes running `claude` / `codex` / `gemini` / etc). Agents discover work by querying **beads** on each turn (via hooks), execute it, and close it. Nothing in Go knows about "Mayor" or "Polecat" — those are role names defined entirely by **prompt templates**. The five irreducible primitives are: Agent Protocol, Beads (task store), Event Bus, Config (TOML), Prompt Templates. Everything else (mail, formulas, molecules, orders, sling, health patrol) is composed from these five.

---

## 2 · The seven tutorials, condensed

`/tmp/gascity/docs/tutorials/01-07.md`. Each builds on the last; the operating model crystallizes at 04 and gets industrial at 07.

| # | Title | The aha |
|---|---|---|
| 01 | Cities and rigs | A city is a directory; a rig is a registered repo with its own beads prefix. `gc sling rig/agent "task"` creates a bead, starts a session, work happens. |
| 02 | Agents | Agents are parameterless. *All* role variation lives in `agents/<name>/prompt.template.md`. There is no built-in "Mayor". |
| 03 | Sessions | `gc session list / peek / attach / nudge / logs`. Sessions are processes you observe and prod; they pull work themselves through hooks. |
| 04 | Communication | No direct wiring between agents. Messages and work are beads. Hooks deliver them on each turn. Indirection is the reliability mechanism. |
| 05 | Formulas | Multi-step workflows expressed as TOML DAGs. Variables, gates, nested steps, loops. **Wisps** = ephemeral molecules, garbage-collected on close; default for dispatch. **Molecules** = persistent step trees; for visibility-demanding workflows. |
| 06 | Beads | Every primitive (task, message, session, molecule, wisp, convoy) is a bead. The store is the ground truth; sessions are stateless. |
| 07 | Orders | The automation heartbeat. Five trigger types: `cooldown`, `cron`, `condition`, `event`, `manual`. **Exec orders** run shell with no LLM (cheap, mechanical); **formula orders** sling a formula to a pool (judgment, costs tokens). |

---

## 3 · Standing up a city, fastest path

You already have `gc 1.0.0`, `bd`, `dolt`, `tmux`, `flock`, `pgrep`, `lsof` installed via home-manager (post the deploy that just landed). So:

```bash
gc init ~/philosophy-city
# Interactive: pick template (1=minimal, 2=gastown, 3=custom)
# Pick provider (1=Claude Code default)

cd ~/philosophy-city
gc start
gc session attach mayor
```

That's it. Talking to mayor at this point is a single-agent shell — the same as starting `claude` directly. The interesting bit is what you put in the city *between* `gc init` and `gc start`: prompt templates, additional agents, formulas, orders. §9 covers that.

### What `gc init` produces

```
~/philosophy-city/
├── pack.toml                 # the portable layer
├── city.toml                 # the deployment layer
├── agents/
│   └── mayor/
│       └── prompt.template.md
├── commands/                 # custom CLI command scaffolds
├── doctor/                   # health check scripts
├── formulas/
│   ├── mol-do-work.toml      # built-in: standard work formula
│   ├── mol-polecat-base.toml # built-in: polecat lifecycle
│   ├── mol-polecat-commit.toml
│   └── mol-scoped-work.toml
├── orders/                   # empty (you author these)
├── overlay/                  # additive files copied into agents
├── template-fragments/       # shared {{ define }} blocks
└── .gc/                      # machine-local, git-ignored
    ├── site.toml             # rig path bindings
    ├── settings.json         # provider hooks (Claude Code etc)
    ├── events.jsonl
    └── .beads/               # city-scoped bd database
```

`pack.toml` is the portable artifact (commits to git, travels). `city.toml` is the deployment-side: your provider, your rigs, daemon tuning. `.gc/` is local-only.

### Adding a rig is one line

```bash
gc rig add ~/some/repo
# Prefix derived from basename ("some-repo" → "sr"); rig-scoped
# bd database initialized; routes.jsonl written.
```

For the philosophy-city you don't need rigs at all — agents will work entirely in conversation, not in a codebase.

---

## 4 · The driving experience

What it feels like to run a city, day to day.

### The controller and the supervisor

`gc start` brings up the controller (per-city), backgrounded. You can also enroll cities with `gc supervisor run` (machine-wide), which gives you a single launchd/systemd-style overseer for multiple cities. For one city on one machine, plain `gc start` is sufficient.

### Watching a session

```bash
gc session list                    # all live sessions, agent + rig + pid
gc session peek mayor --lines 50   # last 50 lines of tmux scrollback
gc session attach mayor            # drop into the tmux pane (Ctrl-b d to leave)
gc session logs mayor -f           # follow conversation transcript (user/assistant turns)
```

`peek` is what you reach for most. `attach` when you want to actually steer a session in real time. `logs -f` is the structured-conversation view (no terminal artifacts).

### Three ways to send something to an agent

| Mechanism | Persistence | When to use |
|---|---|---|
| `gc session nudge <name> "msg"` | None — types into tmux | Quick steering of a live session you're watching |
| `gc mail send <to> -s "..." -m "..."` | Bead, persistent | Async message; survives session restart; injected via hook on next turn |
| `gc sling <agent> "task"` | Bead, persistent | Work item; agent claims, executes, closes |

The right default is **sling** for work and **mail** for "FYI / reply-when-you-can". `nudge` is for live debugging.

### Discovering what's happening

```bash
gc status              # one-screen overview: controller, agents, sessions, rigs
bd ready               # work eligible to start (the agents' own query)
bd list --status=open  # everything open, regardless of who owns it
gc order check         # which orders are due to fire right now
gc trace               # the reconciler's decision log (debug)
```

`gc trace` is the deep-debug tool — verbose, intended for "why didn't the controller restart this session?" investigations. Skip until you need it.

---

## 5 · Pack composition: where the leverage is

A pack is a directory containing `pack.toml` plus its `agents/`, `formulas/`, `orders/`, `assets/`, `template-fragments/`. Cities **import** packs via `[imports.<binding>]` in `city.toml`. The same pack can be imported into many cities; rig-scoped agents from a pack get stamped per-rig.

### What a pack contains, idiomatically

```
packs/<name>/
├── pack.toml
├── agents/<role>/prompt.template.md  ← the actual behavior
├── formulas/mol-<role>-patrol.toml   ← what each role's loop does
├── orders/<role>-cooldown.toml       ← when each loop fires
├── assets/scripts/                    ← helper shell scripts
├── assets/prompts/                    ← shared prompt fragments
└── template-fragments/                ← Go template {{ define }} blocks
```

### Why packs matter

1. **Reuse.** The Gastown pack ships agent definitions for mayor / deacon / boot / witness / refinery / polecat / dog. You can drop it whole into your city and adjust via patches.
2. **Composition.** Multiple packs can be imported in one city. The Gastown example layers `maintenance` (dog pool, exec orders), `dolt` (reusable Dolt mgmt), `gastown` (mayor / polecats / refineries).
3. **Override surface.** `[[patches.agent]]` in `city.toml` overrides any imported agent's fields. Rig-scoped `[[rigs.patches]]` overrides apply only to that rig's stamped agents.

For the philosophy-city you'll probably author your own pack rather than import Gastown — Gastown is shaped for code-shipping, not for engineering-aesthetic conversations. §9 sketches that pack.

---

## 6 · Orders and formulas: the automation layer

Orders + formulas are how a city stops being a chat session and starts being a system.

### Orders: when work fires

| Trigger | Behavior | Use |
|---|---|---|
| `cooldown` | Fires N seconds after last fire | Periodic checks ("every 5 min, sweep gates") |
| `cron` | Five-field Unix cron | Calendar-aligned ("daily at 09:00, generate digest") |
| `condition` | Fires when a shell command exits 0 | Gating on external state ("if `/tmp/deploy-flag` exists") |
| `event` | Fires on event-bus events | Reactive ("when a bead with label `needs-review` is created") |
| `manual` | Never auto-fires; only `gc order run <name>` | One-shot operator-triggered workflows |

### Two flavors of order body

```toml
# Formula order: dispatches a formula to a pool. Costs LLM tokens.
[order]
description = "Daily synthesis of conversations"
formula = "daily-synthesis"
trigger = "cron"
schedule = "0 9 * * *"
pool = "mayor"

# Exec order: runs a shell command on the controller. No LLM.
[order]
description = "Sweep stale conversation beads"
trigger = "cooldown"
interval = "10m"
exec = "$PACK_DIR/assets/scripts/sweep-stale.sh"
```

The shape that matters: **exec orders for mechanical work, formula orders for judgment**. Gastown's `maintenance` pack is heavy on exec orders (gate-sweep, orphan-sweep, prune-branches, wisp-compact) precisely because those don't need an LLM to make decisions.

### Formulas: what work fires

A formula is a TOML DAG with optional variables, gates, conditions, loops. Schema v2 (DAG with explicit `needs` edges) is required for anything serious; enable with `[daemon] formula_v2 = true`.

Minimal example:

```toml
formula = "daily-synthesis"

[vars]
topic = { default = "static typing", description = "Today's debate topic" }

[[steps]]
id = "propose"
title = "Propose framing for: {{topic}}"

[[steps]]
id = "aesthete"
title = "Aesthete: argue from beauty / clarity / composition"
needs = ["propose"]

[[steps]]
id = "pragmatist"
title = "Pragmatist: argue from cost / ship-ability / maintenance"
needs = ["propose"]

[[steps]]
id = "synthesis"
title = "Mayor: synthesize disagreements"
needs = ["aesthete", "pragmatist"]
```

When this formula fires (via order or `gc formula cook daily-synthesis`), each step becomes a bead, dependencies enforced, and routing distributes them to the right agents. **Wisp dispatch** (`gc sling <agent> daily-synthesis --formula`) makes the whole tree ephemeral — garbage-collected when it closes.

---

## 7 · Hardcore idioms (the Gastown reference)

The Gastown example pack at `/tmp/gascity/examples/gastown/` is the gold standard for production-shape orchestration. Worth knowing even if your first city looks nothing like it, because the patterns transfer.

### Pattern 1 — Mayor coordinates; polecats execute

The Gastown mayor prompt at `examples/gastown/packs/gastown/agents/mayor/prompt.template.md` is explicit:

> *Dispatch Liberally, Fix When Fast — The Mayor is a coordinator first… but you CAN and SHOULD edit code when it's the fastest path. The key is balance.*

Default: file beads, dispatch them to polecats:

```bash
gc bd create "Fix auth timeout" -t task --json
gc bd update <bead-id> --set-metadata gc.routed_to=<rig>/polecat
```

The polecat pool reconciler picks up the routed metadata and a polecat session claims it. The mayor's value is the *coordination* context — strategy, sequencing, sharing context across rigs — not the typing-into-files itself.

### Pattern 2 — Worktree-isolated polecats (fearless parallelism)

Each polecat session gets a disposable worktree:

```toml
# packs/gastown/pack.toml
[[patches.agent]]
name = "polecat"
wake_mode = "fresh"
work_dir = ".gc/agents/polecats/{{.AgentBase}}"
pre_start = ["packs/gastown/assets/scripts/worktree-setup.sh ..."]
```

`wake_mode = "fresh"` means each spawn is a brand-new session (no resume). Combined with the per-session worktree, multiple polecats can run on the same repo without colliding. If one crashes, the witness recovers any committed work; uncommitted changes were disposable anyway.

### Pattern 3 — Witness + refinery as the safety net

- **Witness** (rig-scoped, on-demand): looks for orphaned beads (assigned to dead sessions), recovers them, resets state. Detects stuck polecats — alive but looping — and intervenes.
- **Refinery** (rig-scoped, on-demand): the merge agent. Pulls beads handed off by polecats, rebases, runs tests, merges, closes the bead, deletes the branch. If a merge fails, returns the bead to the pool with a rejection reason.

The polecat → refinery handoff is via beads. The polecat doesn't talk to the refinery directly; it sets a metadata field, and the refinery's `bd ready` query finds the work next turn. **Indirection through the store** is what makes crashes survivable.

### Pattern 4 — Exec orders for the boring stuff

Gastown's `maintenance` pack has zero LLM cost on its automation:

| Order | Trigger | What it does |
|---|---|---|
| `gate-sweep` | cooldown 30s | Evaluates timer / cron / condition gates; closes those that fired |
| `orphan-sweep` | cooldown 5m | Finds beads assigned to sessions that no longer exist; resets them |
| `prune-branches` | cron daily | Deletes merged feature branches from worktrees |
| `wisp-compact` | cooldown 1h | Garbage-collects closed wisps from the bead store |

None of these need an LLM. All are bash scripts triggered by the controller. Tokens go to actual work, not bookkeeping.

### Pattern 5 — Global fragments for prompt consistency

```toml
# city.toml
[workspace]
global_fragments = ["command-glossary", "operational-awareness"]
```

Every agent's prompt gets these fragments appended. `command-glossary` lists `bd` / `gc` commands the agent can use; `operational-awareness` injects current city status (open work, active sessions). Define your own fragments in `template-fragments/<name>.tmpl` using Go template `{{ define "name" }} … {{ end }}`. Agents in the same city share idiom by default.

### Pattern 6 — `wake_mode = "fresh"` vs `"resume"`

- `"resume"` (default): on respawn, the provider's session continuation key is reused. Conversation context survives.
- `"fresh"`: every respawn is a clean session. Used for stateless workers (polecats) where each run is a discrete task.

For the philosophy-city, you'll want `"resume"` on the persistent agents (mayor, aesthete) so they accumulate context, and `"fresh"` on any short-lived role.

---

## 8 · Tuning, observability, and what to watch

### Daemon settings

```toml
[daemon]
patrol_interval = "30s"   # how often the controller pings agents
max_restarts = 5          # quarantine after N crashes within restart_window
restart_window = "1h"
formula_v2 = true         # use the DAG-based formula schema
```

Tighten `patrol_interval` (e.g., `"10s"`) when you want fast crash detection during early operation; relax it later.

### Pool sizing

```toml
[[agent]]
name = "polecat"
min_active_sessions = 0
max_active_sessions = 5
scale_check = "scripts/desired-polecats.sh"   # outputs an integer
idle_timeout = "30m"
sleep_after_idle = "10s"
```

`scale_check` runs on every controller tick; its stdout is the desired session count, clamped to min/max. For a polecat pool, the script typically counts ready beads routed to the polecat pool: `bd ready --metadata-field gc.routed_to=rig/polecat --count`.

For the philosophy-city you can ignore pools entirely — single-instance agents are fine for conversation work.

### Convergence guards

```toml
[convergence]
max_depth = 100
max_iterations = 1000
timeout = "5m"
```

These are circuit breakers for runaway formula recursion. Defaults are conservative; raise only if you have a genuinely deep formula.

### Doctor

```bash
gc doctor                       # checks deps, config, supervisor, hook installation
gc config validate              # syntax + cross-reference check on city.toml
gc config show                  # the fully-merged effective config (post-imports/patches)
```

`gc config show` is invaluable when packs and patches start composing — it shows you what the controller actually sees.

---

## 9 · The philosophy-city, sketched

The first city worth building, given the stated use: a small ensemble of agents with distinct engineering aesthetics, a mayor that orchestrates disputes, a daily synthesis order. No rigs. The whole thing fits in one pack.

### Layout

```
~/philosophy-city/
├── city.toml
├── pack.toml
├── agents/
│   ├── mayor/prompt.template.md       # orchestrator, synthesizer
│   ├── aesthete/prompt.template.md    # clarity, simplicity, composition
│   ├── pragmatist/prompt.template.md  # cost, ship-ability, blast radius
│   ├── theorist/prompt.template.md    # types, correctness, formal reasoning
│   └── devil/prompt.template.md       # opposition, doubt, edge cases
├── formulas/
│   └── debate.toml
├── orders/
│   └── daily-debate.toml
└── template-fragments/
    └── house-style.tmpl
```

### `city.toml`

```toml
[workspace]
name = "philosophy-city"
provider = "claude"
global_fragments = ["house-style"]

[daemon]
patrol_interval = "30s"
formula_v2 = true
max_restarts = 5
```

### `pack.toml`

```toml
[pack]
name = "philosophy"
schema = 2

[[agent]]
name = "mayor"
prompt_template = "agents/mayor/prompt.template.md"
option_defaults = { model = "opus", permission_mode = "default" }

[[agent]]
name = "aesthete"
prompt_template = "agents/aesthete/prompt.template.md"
option_defaults = { model = "opus" }

[[agent]]
name = "pragmatist"
prompt_template = "agents/pragmatist/prompt.template.md"
option_defaults = { model = "opus" }

[[agent]]
name = "theorist"
prompt_template = "agents/theorist/prompt.template.md"
option_defaults = { model = "opus" }

[[agent]]
name = "devil"
prompt_template = "agents/devil/prompt.template.md"
option_defaults = { model = "opus" }

[[named_session]]
template = "mayor"
mode = "always"

[[named_session]]
template = "aesthete"
mode = "on_demand"

[[named_session]]
template = "pragmatist"
mode = "on_demand"

[[named_session]]
template = "theorist"
mode = "on_demand"

[[named_session]]
template = "devil"
mode = "on_demand"
```

`mode = "always"` keeps the mayor session alive across the city's lifetime. `on_demand` agents wake when work is slung to them and sleep otherwise — cheap.

### Prompt templates (sketches, the actual aesthetic is yours to refine)

`agents/mayor/prompt.template.md`:

```markdown
# Mayor

You orchestrate engineering conversations between four agents:

- **aesthete** — values clarity, simplicity, composition, taste
- **pragmatist** — values shipping, cost, blast radius, what works
- **theorist** — values types, invariants, formal reasoning, proof
- **devil** — argues whichever side is currently underweighted

When Li gives you a topic — a piece of code, a design choice, a
language preference, an architectural question — your job is to:

1. Frame the question crisply (1–2 sentences).
2. `gc sling aesthete / pragmatist / theorist "..."` with a focused
   prompt for each. Don't ask all four at once unless the topic is big.
3. Read each reply.
4. Where they disagree, push back. `gc mail send <agent> -s "..." -m "..."`
   with a sharp follow-up. Iterate until the disagreement is real, not
   semantic.
5. Synthesize: what is each agent right about? What is the resulting
   position you would defend?

Avoid summary-for-summary's-sake. The synthesis must take a position.

You are not a stenographer. You are the editor.
```

`agents/aesthete/prompt.template.md`:

```markdown
# Aesthete

You hold the line on what beautiful engineering looks like.

Your priors:
- Code is read more than written. Optimize for the reader.
- Composition over inheritance. Pure functions over methods.
  Data over behavior.
- Names carry meaning. A bad name is worse than no name.
- The smallest expression of an idea is usually the right one,
  *but* premature compression is worse than verbosity.
- Types are documentation that compiles.
- A good module has one reason to change.

When the mayor asks you to evaluate something, be specific. Don't
say "this is too complex"; say "the three concerns of X, Y, Z are
entangled here; separating Y reduces the surface of X by half".

When the pragmatist objects to your taste on cost grounds, take
the objection seriously. Sometimes shipping ugly is right.
But say so explicitly, and name what you're trading.
```

`agents/pragmatist/prompt.template.md`:

```markdown
# Pragmatist

You care about ship-ability, cost, and consequences.

Your priors:
- The best code is code in production. The second best is code
  that ships next week. The worst is code that's still being argued
  about.
- Constraints are real: time, attention, maintenance burden, the
  team's capacity to read what you write.
- Premature optimization is real; so is premature abstraction.
- A working ugly thing is more valuable than a beautiful absent thing.
- Reversibility matters. Prefer changes you can roll back.

When the aesthete or theorist propose a refactor, ask: what does
this cost, what does it buy, and what is the blast radius if it's
wrong? Do the math out loud.

You are not a cynic. You agree with beauty and rigor when the price
is right. Just make the price legible.
```

`agents/theorist/prompt.template.md`:

```markdown
# Theorist

You hold the line on correctness.

Your priors:
- Types are the cheapest correctness mechanism. Use them.
- Invariants stated in code (assertions, type signatures, smart
  constructors) are worth more than invariants stated in comments.
- A function that can return null in 1% of cases is a function
  that returns null. Plan for it.
- The right time to think about edge cases is *before* the happy
  path is finished. Edge cases are not a polish step.
- Formal reasoning isn't always paper-and-proof. A precise type
  signature is a small theorem.

When the pragmatist wants to ship without handling the empty-list
case, push back with a specific scenario where it bites. When the
aesthete proposes a beautiful abstraction, ask what it forbids
that's currently allowed.

You are not a pedant. You're the agent who keeps the team honest
about what they're claiming.
```

`agents/devil/prompt.template.md`:

```markdown
# Devil's Advocate

Your job is to argue the underweighted side.

If the team is converging on agreement, introduce doubt. If three
agents agree on X, you argue ¬X — and you have to make it good.
The standard for your argument is: would this change a careful
listener's mind by 10%?

You are not a contrarian for sport. You are the failure mode of
the rest of the team — when they all agree, you find what they
missed.

When the mayor synthesizes, ask: "what would have to be true for
this synthesis to be wrong?" If the answer is "nothing realistic",
let it pass. If the answer reveals a real assumption, say so.
```

### `formulas/debate.toml`

```toml
formula = "debate"

[vars]
topic = { description = "What we're debating", required = true }

[[steps]]
id = "frame"
title = "Mayor: frame the question — {{topic}}"

[[steps]]
id = "aesthete"
title = "Aesthete on {{topic}}"
needs = ["frame"]

[[steps]]
id = "pragmatist"
title = "Pragmatist on {{topic}}"
needs = ["frame"]

[[steps]]
id = "theorist"
title = "Theorist on {{topic}}"
needs = ["frame"]

[[steps]]
id = "devil"
title = "Devil's Advocate on {{topic}}"
needs = ["aesthete", "pragmatist", "theorist"]

[[steps]]
id = "synthesis"
title = "Mayor: synthesize — what's the position you'd defend?"
needs = ["aesthete", "pragmatist", "theorist", "devil"]
```

### `orders/daily-debate.toml`

```toml
[order]
description = "Daily debate — Li seeds a topic, the team works it"
trigger = "manual"
formula = "debate"
pool = "mayor"
```

`trigger = "manual"` means Li fires it explicitly with `gc order run daily-debate --var topic="should we use an effect system in this codebase"`. No auto-firing — the conversations are intentional.

### How it feels in use

```bash
cd ~/philosophy-city
gc start
gc session attach mayor

# In the mayor pane, type a topic. Mayor frames it, slings to the team.
# In another terminal:
gc session attach aesthete   # watch the aesthete reply
gc mail inbox mayor          # see what came back

# Or via formula:
gc order run daily-debate --var topic="when is dynamic typing the right call"
gc bd list --status=open     # watch the molecule fill in
```

When a topic produces a position you want to keep, `bd remember` it from the mayor session — that anchors the synthesis in beads-memory and survives across sessions.

---

## 10 · Operating maxims (paste-on-the-fridge)

Pulled from the gas-city `AGENTS.md` and the Gastown prompts:

1. **ZFC.** Decisions live in prompts, not in Go. If you find yourself wanting Go to make a judgment call, write it as a prompt or a formula.
2. **Bitter Lesson.** Every primitive must get *more* useful as the model improves. Heuristics rot; raw expressive primitives don't.
3. **GUPP.** "If you find work on your hook, YOU RUN IT." No confirmation, no waiting. The presence of work IS the assignment. Render this in agent prompts; don't enforce it in code.
4. **NDI.** Persistent beads + redundant observers + idempotent steps = reliability. Sessions are mortal; the store is forever.
5. **No status files.** Discover state from the live process table. PID files lie when they're stale.
6. **The controller drives infrastructure; agents execute work.** No SDK feature should require a specific named role to exist. (Test: if removing an `[[agent]]` entry breaks the SDK, that's the bug, not your config.)
7. **Indirection through the store.** Agents don't hold references to each other. They query beads on each turn. This is the same reason CRDT systems converge: state-based, not message-based.
8. **Worktree isolation = fearless parallelism.** Don't fight git; give each worker a disposable tree.
9. **Mail for context, sling for work, nudge for live.** Don't conflate the three.
10. **Roles are prompts, not Go.** If the same role concept can be expressed as different prompts, you have configuration; if it requires a code change, you have rigidity.

---

## 11 · Open paths after the philosophy-city is up

Tracked as bd issues, not in this report. Likely seeds:

- Add a **code-review formula** that takes a snippet (paste or path) and runs the four agents over it concurrently with a synthesis step.
- Stand up a **language-comparison ladder**: pick a small problem (a parser, a state machine, a queue), have the team express it idiomatically in three languages, debate the result.
- Build a **second city** — `criome-lab-city` — that imports the philosophy pack as a sub-pack and adds rigs for criome / sema / mentci. The aesthete's accumulated taste rolls forward into real work.
- Promote the most-cited synthesis beads into `lore/principles.md` once a critical mass exists. Memory → durable doc.

---

## 12 · Why this is the right first city

Three reasons.

**One:** The philosophy-city has no failure mode that costs anything but tokens. No code merged, no production touched. Maximum cycles to learn the operating model and the tool's idiom before stakes go up.

**Two:** The aesthetic the team converges on becomes durable. Synthesis beads are git-tracked; agent prompts evolve as positions sharpen; what you learn in conversation transfers to the prompts you'll use on real projects later. Report 126 framed adoption as additive over `bd`; this report frames the *first* substantive use of Gas City as additive over reasoning.

**Three:** A city is the smallest unit of "operating habit". Once you've driven one for a week — `gc session attach`, `gc sling`, `gc order run`, `bd ready` in muscle memory — every subsequent city is just rewiring the prompts and rigs. The cost of building a real-project city later collapses once the habits are formed.
