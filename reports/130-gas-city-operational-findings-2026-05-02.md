# 130 — Gas City: operational findings

*Comprehensive log of what we discovered while bringing Gas City
up on CriomOS — the bugs we hit, the workarounds we applied, the
durable fixes still pending, the operational idioms we learned.
Companion to [reports/126](126-gas-city-pivot-2026-05-01.md) (pivot decision) and [reports/127](127-gas-city-hardcore-usage-2026-05-01.md)
(operator manual). This one is the forensic record. Lifetime:
until each pending durable fix has shipped, then the resolved
sections drop out of this report and remaining items get
folded into a successor.*

---

## 0 · Frame

Three docs cover Gas City in this workspace:

- [reports/126](126-gas-city-pivot-2026-05-01.md) — *why we adopted it and how it
  composes with our existing setup*
- [reports/127](127-gas-city-hardcore-usage-2026-05-01.md) — *how to drive it as an
  operator, vocabulary, idioms*
- this report — *what we found by doing*

Read in that order if you're new. This one is for someone
extending the packaging or chasing a recurring symptom — every
non-trivial bug we hit is in here with root cause + applied
workaround + the durable fix that's still pending.

The ecosystem we built up:

- `gascity-nix` (`github:LiGoldragon/gascity-nix`) — our nix
  packaging flake; tracks gas-city's `origin/main` past the
  v1.0.0 tag with `postPatch` shebang rewrites
- `CriomOS-home` — added `gascity` and `annas-mcp` flake
  inputs; med-profile installs `gc`, `bd`, `dolt`, `tmux`,
  `lsof`, `procps`, `util-linux`, plus `annas` (Anna's Archive
  CLI built inline + gopass-wrapped)
- `CriomOS` — bumps criomos-home; deployed via `lojix-cli
  switch` on every change
- `philosophy-city` (`github:LiGoldragon/philosophy-city`) — a
  five-agent conversational ensemble we built as the case-study
  city
- `lore/gas-city/{basic-usage,vocabulary}.md` — daily-use docs

---

## 1 · Bugs found and root-caused

### 1.1 The 48-second `gc start` lock-acquire failure

**Symptom.** `gc start` hung for ~48 seconds, then failed with
*"could not acquire dolt start lock
(/home/li/philosophy-city/.gc/runtime/packs/dolt/dolt.lock)"*.
Reproduced cleanly across stop/start cycles. Mayor sessions died
along with it because dolt was unreachable.

**Wrong hypotheses we ran down.** Stale lock file. Concurrent
supervisor invocations racing. Dolt version drift (we saw nixpkgs
shipped dolt 1.86.2 vs gas-city's pinned 1.86.6). A real
flock-holder somewhere we hadn't found.

**Actual root cause.** Two compounding upstream bugs:

1. **bd-init script timing-out at 30s** — fixed in gas-city
   commit `46cf2724 fix(bd): drop slow 'bd config set' calls in
   init that overran 30s timeout (#1264)`. The script ran
   `bd config set issue_prefix` and `bd config set
   types.custom` on every init; on bd ≥ 1.0.3 each rejected
   call spent ~18s in auto-migrate. Total init time blew past
   the supervisor's hard 30s timeout. Landed 2026-05-01,
   **post v1.0.0**. Our binary was built from the v1.0.0 tag,
   so it shipped *without* the fix.

2. **`/bin/sh = mksh` on CriomOS, but the script is bash-flavored.**
   The bd-start script's shebang is `#!/bin/sh`. On most Linux
   systems `/bin/sh` is bash or dash; on CriomOS we set
   `environment.binsh = mksh + mksh.shellPath` deliberately
   ([CriomOS/modules/nixos/normalize.nix:74](../CriomOS/modules/nixos/normalize.nix#L74)). mksh interprets some
   of the script's idioms differently — specifically the
   flock + wait-for-concurrent-start path silently fell into a
   45s wait loop instead of acquiring cleanly. Reproduced by
   running the script under `mksh ./gc-beads-bd.sh start`
   (failed in 48s) vs `bash ./gc-beads-bd.sh start`
   (succeeded in 5s). Same script, same data, different shell.

**Workaround.** In our gascity-nix flake, `postPatch` rewrites
every `#!/bin/sh` shebang in `examples/` scripts to
`#!${pkgs.bash}/bin/bash` *before the Go embed step*. Plus we
bumped the source pin from `v1.0.0` to `origin/main` so the
PR #1264 fix is included.

**Status.** `gc start` now completes in ~3 seconds against a
clean state.

**Durable fix candidates.**
- File the mksh-shebang issue upstream; their `examples/bd/`
  scripts should declare `#!/usr/bin/env bash` if they require
  bash. Small, narrow, our local patch demonstrates the fix.
- Pin to a real release tag once a v1.0.1+ ships including the
  bd-init timeout fix; current `unstable-2026-05-02` is
  bleeding-edge main HEAD.

### 1.2 `git config --global beads.role` failing to write

**Symptom.** After fixing 1.1, `gc start` got further but
failed at: *"could not lock config file
/home/li/.config/git/config: Read-only file system"* during
bd-init's `ensure_beads_role` step.

**Root cause.** `~/.config/git/config` is a symlink into the
nix store via home-manager (`programs.git.settings`). Read-only.
The bd-init script tries `git config --global beads.role
maintainer` if unset, which writes to the global config file
location, which on our host is the home-manager-managed
read-only file.

**Workaround applied.** Declarative — in CriomOS-home's
[modules/home/profiles/min/default.nix:498](../CriomOS-home/modules/home/profiles/min/default.nix), added
`beads.role = "maintainer"` to `programs.git.settings`. The
bd-init script's *check* (`git config --global beads.role
>/dev/null`) returns success because the value is now baked in
declaratively, so it never attempts the write.

**Status.** Resolved. Git config writes triggered by other
gas-city / agent paths still fail the same way; this is a
class of issue, not a single fix.

**Durable fix candidates.** None needed for our case
specifically — `programs.git.settings` is the right home for
declarative knowledge. But: any time gas-city introduces a new
`git config --global ...` write at runtime, we'll hit this
again. Worth surfacing upstream that the bd-init script should
either prefer file paths under `.beads/config.yaml` (which
gas-city's PR #1264 already does for `types.custom`) or check
read-only-fs and skip gracefully when the value is already
present from another source.

### 1.3 `invalid issue type: convoy` on rig-level slings

**Symptom.** Slinging to a rig-scoped agent (e.g., `gc sling
library/librarian "..."`) failed at the auto-convoy creation
step: *"validation failed for issue : invalid issue type:
convoy"*. The slung bead was created routed; the auto-convoy
parent failed to create.

**Root cause.** The rig's `.beads/config.yaml` *did* have
`types.custom: molecule,convoy,message,...` listed. But bd
v1.0.0 (what nixpkgs ships) doesn't fall back to that YAML
when validating issue types — it reads the runtime *dolt
config table* for valid types, and on a fresh rig store that
table was empty. The YAML fallback was added in the same PR as
1.1 (PR #1264, `ensure_types_custom_in_yaml` helper), but bd's
validator side wasn't updated to read the YAML at validation
time.

**Workaround applied.** Explicit `bd config set types.custom
"..."` on each rig store, which writes to the runtime dolt
config table directly. From the city root:

```
cd library && bd config set types.custom \
  "molecule,convoy,message,event,gate,merge-request,agent,role,rig,session,spec,convergence"
cd ../research && bd config set types.custom \
  "..."
```

After this, `bd create --type=convoy` succeeds in the rig
stores; auto-convoys for rig-scoped slings work.

**Status.** Patched at runtime per-rig. Will need to redo on
any new rig.

**Durable fix candidates.**
- Upstream: bd's validator should honor the YAML fallback (the
  asymmetry between writer-side and reader-side handling of
  custom types is the bug).
- Local: the gas-city `gc rig add` flow should run the
  `bd config set types.custom` against the new rig as part of
  init. We could shim this into our `postPatch` if it becomes
  recurring pain, but right now it's a one-time per-rig manual
  step.

### 1.4 `[[named_session]]` syntax for rig-scoped agents

**Symptom.** Mayor (autonomously authoring rig-scoped agents)
tried three shapes and got cryptic validation errors:

- `template = "library/librarian"` → *regex doesn't allow `/`*
- `[named_session.binding] agent = ... rig = ...` → *unknown field*
- removing the named_session entirely → the agent never
  materialized for slings

**Root cause.** The schema, from
[gascity/internal/config/config.go:303](/tmp/gascity/internal/config/config.go#L303): the field that tells gas-city
"stamp this per rig" is `scope = "rig"`, not a slash in the
template name and not a binding sub-table. The `template`
field stays the bare agent name; `dir` optionally pins to one
specific rig if multiple rigs could otherwise stamp it.

```toml
[[named_session]]
template = "librarian"      # bare name
scope = "rig"               # the magic word
dir = "library"             # optional, only if disambiguation needed
mode = "on_demand"
```

This pattern is in the Gastown example
([examples/gastown/packs/gastown/pack.toml:47](/tmp/gascity/examples/gastown/packs/gastown/pack.toml#L47)) — witness, refinery,
polecat all use it — but isn't documented in any single place
operators would naturally find.

**Workaround applied.** Documented in mail to mayor
(`pc-wisp-d9k`); pattern now visible in
[lore/gas-city/vocabulary.md](../../lore/gas-city/vocabulary.md) §"Agents"
implicitly.

**Status.** Resolved via documentation. No code patch needed.

**Durable fix candidates.** Upstream gas-city docs should have
a clear section on rig-scoped agent declaration. Worth filing
as a docs issue if we hit this again.

### 1.5 Researcher / librarian prompts vs scope

**Symptom.** Mayor's mid-session-authored librarian and
researcher agents wouldn't pick up slung work. Slings created
the bead correctly with `gc.routed_to=<agent>`; the agent's
session spawned alive; the agent went idle without claiming
the bead.

**Root cause.** The agents' prompts (mayor-authored) said
`bd ready --rig <name>` — searching the rig-scoped beads
store. But the agents were declared *city-scoped* in
pack.toml (no `dir = "..."` field on their `[[agent]]`
blocks). Slings created beads in the *city's* beads store.
The rig-flag query returned empty; the agent had nothing to
work on.

**Workaround.** Dropped `--rig <name>` from both agent
prompts so they use the default `bd ready`, which is
rig-aware and returns routed-to-me beads regardless of which
store they live in.

**Status.** Resolved.

**Operational lesson.** When mayor (or any agent) authors a
new agent, the prompt's `bd ready` query and the agent's
declared scope must match. If `dir = "..."` is set on the
agent in pack.toml, the prompt can use `bd ready --rig <name>`
or even just `bd ready` (rig auto-detection). If `dir` is not
set, the prompt must use bare `bd ready` (no rig flag).

### 1.6 Mayor's autonomous city-lifecycle commands

**Symptom.** Mayor ran `gc stop` autonomously while Li was
attached to its tmux pane. Pane showed `[exited]`; on re-attach
Li hit "Dolt server unreachable at 127.0.0.1:0". Supervisor log
showed clean `Unregistered city 'philosophy-city', stopping...`
event. Repeated later when mayor used `gc restart` (we'd
forbidden `gc stop` but not `gc restart`, which is documented
as `stop + start`).

**Root cause.** Mayor's auto-injected prompt appendix lists
`core.gc-city — City lifecycle — status, start, stop, init`
as a skill. Combined with `--dangerously-skip-permissions`
(gas-city's claude provider default) and full shell access,
mayor has SDK-blessed *and* execution-blessed permission to
stop the city. Whenever mayor's reasoning concludes "the work
is done; let me clean up" or "let me restart for a fresh
slate", it has the means.

**Workaround applied.** Mayor's prompt template now contains a
"City lifecycle is Li's, not yours" hard-rule section listing
every variant: `gc stop`, `gc start`, `gc restart`,
`gc unregister`, `gc init`, `gc supervisor *`, plus the
HTTP-API equivalents. Allowed list explicit (sling, mail, bd,
session, rig, agent, formula, order, status, reload, prime,
handoff, service, skill).

**Status.** Working so far. If the prompt-level guard fails
again, the next fix is a real OS-level cage — bwrap-wrapping
mayor's claude binary so `gc` isn't on its `$PATH`. Designed
in [reports/126](126-gas-city-pivot-2026-05-01.md) §5; not yet built.

**Durable fix candidate.** Upstream: gas-city's auto-injected
skill appendix could be configurable per-agent (don't
advertise `core.gc-city` to non-operator agents). Worth a PR.

### 1.7 Dolt CPU at 25–38% steady-state

**Symptom.** Dolt at 25-38% CPU continuously, even when no
agents were doing work. System load avg over 13. Mayor's
attempt to reduce via `[daemon] patrol_interval = "5m"` had
no measurable effect.

**Root cause.** patrol_interval is the *controller's
reconciler* tick, which is not what's hitting dolt. The
hammer is the **per-rig control-dispatcher** sessions. Each
runs `gc convoy control --serve --follow <target>`, whose
loop is hardcoded in
[gascity/cmd/gc/dispatch_runtime.go:80-83](/tmp/gascity/cmd/gc/dispatch_runtime.go#L80-83):

```go
workflowServeWakeSweepInterval = 1 * time.Second
workflowServeMaxIdleSleep      = 30 * time.Second
```

1-second base tick, doubling to 30s when idle. Each tick fires
a 4-6 query shell script that spawns fresh `bd` processes
(each opening a TCP connection to dolt). With three
dispatchers running (city + library + research),
steady-state was 15+ bd-process spawns per second across the
trio.

**Workaround.** Mailed mayor (`pc-wisp-5ci`) instructing rig
suspension via `gc rig suspend library` and `gc rig suspend
research`. Dropping from 3 dispatchers to 1 should cut the
load by ~67%. Pending mayor's audit.

**Status.** Awaiting action.

**Durable fix candidates.**
- Upstream: make `workflowServeWakeSweepInterval` and
  `workflowServeMaxIdleSleep` configurable via city.toml's
  `[daemon]` section. Real PR.
- Operational: don't add rigs unless an agent actually pulls
  work from that rig's bead store. Conversational agents and
  city-scoped roles do not need rigs.

### 1.8 Tmux defaults that block claude-code features

Three separate symptoms, same family of cause:

| Feature | Tmux default that blocks | Symptom |
|---|---|---|
| Shift+Enter for newline | `extended-keys = off` | Shift+Enter submits instead of inserting newline |
| Image paste | `allow-passthrough = off` | Pasted image data stripped at tmux layer |
| Mouse scroll | `mouse off` (set by gas-city explicitly in [tmux.go:325](/tmp/gascity/internal/runtime/tmux/tmux.go#L325)) | No mouse-wheel scrollback inside agent panes |

The mouse-off is intentional — gas-city's comment explains
that mouse-tracking sequences leak into the agent CLI as junk
input. The other two are unintentional defaults gas-city
inherits from tmux.

**Workaround.** Runtime: `tmux -L philosophy-city set-option
-g extended-keys on` and `set-option -g allow-passthrough on`.
Both work but don't survive city restart (gas-city
re-creates the tmux server with defaults).

**Status.** Runtime-fixed; durable fix pending.

**Durable fix candidates.**
- *Path A — patch gas-city upstream.* Add `extended-keys on`
  and `allow-passthrough on` next to the existing `mouse off`
  call in [tmux.go:325](/tmp/gascity/internal/runtime/tmux/tmux.go#L325). Ship via our gascity-nix flake's
  `postPatch` (or as a real upstream PR).
- *Path B — `session_setup` on mayor.* Add to mayor's `[[agent]]`
  block in pack.toml:

  ```toml
  session_setup = [
    "tmux set-option -g extended-keys on",
    "tmux set-option -g allow-passthrough on",
    "tmux set-option -ga terminal-features '*:extkeys'",
  ]
  ```

  Mayor's setup runs once per session creation and these are
  server-global options, so one mayor spawn applies them for
  the whole tmux server's lifetime.

Path A is cleaner but bigger blast radius. Path B is local and
lower risk. **Recommend B for now**, file A as an upstream PR
in parallel.

### 1.9 `gc reload` reports "No config changes detected"

**Symptom.** Edits to prompt templates, agent option_defaults,
or new agent additions sometimes return *"No config changes
detected"* from `gc reload`. Operator can't tell if reload
actually applied or silently no-op'd.

**Root cause.** Gas-city's reload computes a *fingerprint* per
agent and reloads only if the fingerprint changed. The
fingerprint excludes the prompt template body (prompts are
delivered to claude at session-start, not pushed to live
sessions). It also excludes some structural changes.

**Behavior.**
- Prompt template edits: not in fingerprint → "no changes" but
  the *next* session spawn picks up the new prompt.
- New agent additions: usually picked up; visible in
  `gc config show`.
- option_defaults changes that match provider defaults: not in
  fingerprint (the *effective* config didn't change).

**Workaround.** Mental model: reload is for runtime-config
changes (provider, args, env, scaling); prompt changes need
a session restart (`gc session kill <name>`) to apply to a
running session.

**Status.** Documented behavior, not really a bug. Worth
clearer error messaging upstream — *"prompt template changed
but live session won't pick it up until next spawn"* would be
more useful than *"no changes detected"*.

### 1.10 Idle agents don't auto-check mail

**Symptom.** Mail sent to mayor's inbox (via `gc mail send`)
sat unread for ~10+ minutes despite mayor being "active".

**Root cause.** Gas-city's hooks fire *on agent turns*. When
claude is sitting at an idle prompt with no input, no turn
happens, no hooks fire, no mail check. Mail accumulates;
delivered as a system reminder *on the next turn that
naturally happens*.

**Operational pattern.** Send mail, then `gc session nudge
<agent> "..."` if you want immediate action. Or sling a bead
to the agent — slinging triggers a turn via the work pipeline.

**Status.** Structural to claude-code's request/response model;
not fixable at the gas-city layer without push-notification
support which claude-code doesn't accept.

---

## 2 · Workarounds applied (cheat sheet)

Quick reference for what's currently load-bearing and why:

| Layer | Workaround | What it fixes |
|---|---|---|
| `gascity-nix/flake.nix` postPatch | rewrite `#!/bin/sh` → bash for examples scripts | bd-init script under mksh |
| `gascity-nix/flake.nix` rev | track origin/main past v1.0.0 | bd-init 30s timeout fix (PR #1264) |
| `CriomOS-home` `programs.git.settings.beads.role = "maintainer"` | declarative pre-set | bd-init's git-config write failing |
| Per-rig `bd config set types.custom "..."` | explicit runtime write | convoy validation bug on rigs |
| Mayor's prompt (City lifecycle hard rule) | prompt-level prohibition | mayor running `gc stop` / `gc restart` autonomously |
| Mayor's prompt (Workspace boundary hard rule) | prompt-level prohibition | agents writing outside ~/philosophy-city/ |
| Mayor's prompt (Citing beads / mail / commits hard rule) | prompt-level requirement | mayor referencing bare hashes Li can't recognize |
| Runtime `tmux set-option -g extended-keys on` | server-side | Shift+Enter inserts newline |
| Runtime `tmux set-option -g allow-passthrough on` | server-side | image paste survives tmux |
| Runtime `tmux set-option -ga terminal-features '*:extkeys'` | server-side | newer terminal protocol passthrough |

The runtime tmux options don't survive city restart. Everything
else is durable.

---

## 3 · Durable fixes pending

Ordered by recommended priority:

### 3.1 (high) Add tmux fixes to gas-city's tmux setup

Either via our `postPatch` against
`internal/runtime/tmux/tmux.go` (where the existing `mouse off`
call lives at line 325) or via mayor's `session_setup` block.
The session_setup path is local and lower-risk; do it first,
file the upstream PR as a follow-up.

```toml
[[agent]]
name = "mayor"
session_setup = [
  "tmux set-option -g extended-keys on",
  "tmux set-option -g allow-passthrough on",
  "tmux set-option -ga terminal-features '*:extkeys'",
]
```

### 3.2 (high) bwrap cage for philosophy-city agents

Designed but not built. Currently the workspace boundary is
prompt-level only — agents could write outside
`~/philosophy-city/` if they decided to. The cage seam is
gas-city's `exec` provider script wrapping `bwrap` (per
[reports/126](126-gas-city-pivot-2026-05-01.md) §5). Bind-mount: `~/philosophy-city/` rw,
`~/git/` ro (so mayor can read but not write), `~/.nix-profile/`,
`/nix/store`, `/etc`, `/run` ro.

Defer until a prompt-level boundary actually fails. The
prompt-level guards have been holding so far.

### 3.3 (medium) gc reload behavior on prompt-only edits

Either upstream PR for clearer messaging (*"prompt template
changed; new sessions will use the updated prompt; existing
sessions retain their original prompt until next spawn"*), or
operational doc. Probably the latter — already documented in
[lore/gas-city/basic-usage.md](../../lore/gas-city/basic-usage.md), worth confirming and
extending.

### 3.4 (medium) Stylix → claude-code theme drift

Claude-code's theme is in user-managed `~/.claude/settings.json`.
Stylix doesn't write there, so when polarity flips the agent
panes drift from desktop. The right durable fix is a
home-manager module using `inputs.hexis.lib.mkManagedConfig`
(hexis is already a CriomOS-home flake input) to manage *just*
the `theme` key based on `config.stylix.polarity`, leaving the
rest of the file mutable for claude-code's own writes.

### 3.5 (medium) Pin to a real gas-city release

Currently tracking `origin/main` HEAD (`unstable-2026-05-02`
in the flake's `version` field). Bleeding-edge. Pin to v1.0.1+
once it ships including PR #1264. Until then, expect rebuilds
on each gas-city PR merge that touches anything we depend on.

### 3.6 (medium) Upstream PRs worth filing

Once the dust settles on our local patches and we've used the
patched build for a week or two without regression, file
upstream:

- mksh-shebang fix: examples scripts should declare `#!/usr/bin/env bash`.
- tmux defaults: `extended-keys` + `allow-passthrough` next to the existing `mouse off`.
- Convoy type validator should honor YAML `types.custom` fallback (the writer-side already does).
- Reload error messaging on prompt-only edits.
- Configurable `workflowServeWakeSweepInterval` for high-rig-count cities.
- Per-agent skill appendix configurability (don't advertise `core.gc-city` to non-operator agents).

### 3.7 (low) Linger for daemon cities

`loginctl enable-linger li` would keep gascity-supervisor
running across logout. Worth doing once philosophy-city moves
from "play with it for an afternoon" to "talk to it
throughout the week."

### 3.8 (low) Persistent runtime tmux options

If §3.1 isn't done via session_setup, the runtime
`extended-keys` / `allow-passthrough` options need to be
re-applied on every `gc start`. We could shim a startup hook
or wrap `gc start`, but cleaner to just do §3.1 and forget it.

---

## 4 · Operational idioms learned

These are patterns we wish we'd known on day one. Each one is
backed by a specific failure or wasted hour.

### 4.1 The minimum personality stanza

Long story in [reports/127](127-gas-city-hardcore-usage-2026-05-01.md) §9. The short version:
**don't smuggle taste-priors into agent prompts**. Name the
concern (one line), let the model bring substance. The Bitter
Lesson applies to prompt engineering too — encoded heuristics
get out-performed by general computation, and an agent
prompted with seven specific aesthetic priors will argue from
those priors instead of reasoning about the topic. A prompt of
"You hold the line on what beautiful engineering looks like.
Take a position. Defend it." plus the operational scaffolding
is enough.

### 4.2 The mayor lifecycle blocklist

Any city you author with an autonomous mayor under
`--dangerously-skip-permissions` needs the lifecycle
prohibition (`gc stop` / `start` / `restart` / `unregister` /
`init` / `supervisor *`). Without it, mayor *will* "tidy up"
by stopping the city. The auto-injected skill appendix
advertises the stop command — mayor knows how, finds reasons to
use it. See [philosophy-city/agents/mayor/prompt.template.md](../../philosophy-city/agents/mayor/prompt.template.md) for
the current shape.

### 4.3 Rigs cost — only add when you mean it

Each rig adds a control-dispatcher with a 1-second polling
loop firing 4-6 bd queries per tick. ~12-15% baseline dolt
load *per rig*. **Add a rig only when an agent actually pulls
work from that rig's bead store** (the polecat pattern). For
agents that just write into a directory, the directory is fine
without rig registration. The directories `library/` and
`research/` in philosophy-city were registered as rigs
prematurely — they're being suspended.

### 4.4 City-scoped vs rig-scoped agent declaration

If an agent's prompt searches `bd ready --rig <name>`, the
agent must have `dir = "<name>"` in its `[[agent]]` block.
Otherwise the prompt looks in one store while slings create
beads in another. Mismatch is silent — agent goes idle on every
sling, no error message, no hint. See §1.5.

### 4.5 Send-mail-then-nudge

Mail accumulates while claude is idle and is delivered on the
next turn. To get an idle agent to act on mail right now,
`gc session nudge <agent> "check mail"` after `gc mail send`.
The nudge gives claude an input → triggers a turn → hooks fire
→ mail surfaces. See §1.10.

### 4.6 Cite beads with descriptions, never bare hashes

A bare hash like `pc-q7e` is unreadable for a human reviewer.
Mayor's prompt now requires every reference to attach a 5-10
word description in parentheses: `pc-q7e (aesthete wholeness
research)`. This is in [philosophy-city/agents/mayor/prompt.template.md](../../philosophy-city/agents/mayor/prompt.template.md)
"Citing beads, mail, and commits" hard rule. Worth promoting to
a workspace-wide convention.

### 4.7 The dispatcher poll loop is the dolt CPU

When dolt CPU climbs, the question is "how many dispatchers".
patrol_interval is a smaller knob than it appears. See §1.7.

### 4.8 `gc reload` says "no changes" on prompt edits

Not a bug. The new prompt is delivered to the next session
spawn. To force on a running session, `gc session kill <name>`
— the reconciler respawns with the new prompt within seconds.
See §1.9.

### 4.9 The agent-as-config principle

There is no hardcoded "Mayor" or "Polecat" anywhere in
gas-city's Go source. Roles are pure configuration + prompt
templates. This is structural to gas-city's design (the ZFC
principle from upstream `AGENTS.md`), and it's the reason
authoring new agents at runtime works. When mayor (or you) adds
an agent, it's just adding a `[[agent]]` block + a prompt
template file — no compilation, no SDK extension, no plugin
system.

### 4.10 Sessions are mortal; the store is forever

The bead store is the load-bearing channel; sessions come and
go. Mail survives session restarts. Slung work survives session
crashes (whatever bead the dead session was claiming gets
re-claimed by the next session of the same template). This
isn't an error-handling bonus; it's the design. Agents
shouldn't hold references to other agents — they query the
store on each turn.

---

## 5 · Map of where it all lives

```
~/git/gascity-nix/                  # our nix flake; GH public
  flake.nix                         # buildGo125Module + postPatch shebang
  flake.lock
~/git/CriomOS-home/                 # GH public
  flake.nix                         # has gascity + annas-mcp inputs
  modules/home/profiles/med/
    cli-tools.nix                   # gc, bd, dolt, tmux, lsof, procps,
                                    # util-linux, annas (wrapped)
  modules/home/profiles/min/
    default.nix:498                 # programs.git.settings.beads.role
~/git/CriomOS/                      # GH public; deployed
  modules/nixos/normalize.nix:74    # binsh = mksh (root cause of §1.1)
~/git/philosophy-city/              # GH public; the running city
  pack.toml                         # 5+ agents, named_sessions
  city.toml                         # provider=claude, daemon settings
  agents/<name>/prompt.template.md  # the actual behavior
~/git/lore/gas-city/                # docs
  basic-usage.md                    # operating guide
  vocabulary.md                     # glossary
~/philosophy-city/                  # the city directory
  ~ same structure as philosophy-city repo,
    plus .gc/ runtime state (git-ignored),
    plus library/ + research/ rig dirs (suspension pending)
~/git/workspace/reports/
  126 — pivot decision
  127 — operator manual / hardcore usage
  128 — session handoff (gas-city adoption arc)
  130 — this report (operational findings)
```

---

## 6 · Open threads worth tracking

- **Library and research rigs** — created mid-session, dispatchers
  running but no agents pull from them. Mayor's audit
  (`pc-wisp-o19`, `pc-wisp-5ci`) pending. Default action: suspend
  both.
- **Mayor's ongoing engineering-design-guidelines task** — a real
  user-driven ask Li gave mayor early in the city's life. Should
  resume once the rig-suspension and durable-tmux-fix work
  settle.
- **Philosophy-city's eventual fate** — designed as a
  conversational sparring environment; once the engineering
  aesthetic stabilizes, the prompts and pack become the seed for
  a future criome-city that does real work. Tracked in
  [reports/127](127-gas-city-hardcore-usage-2026-05-01.md) §11–12.
- **Researcher's question about gas-city internals** (`pc-tftl`)
  — slung but not picked up before our session ended. Researcher
  is alive; should be addressable now.
- **The `gc rig suspend` / `gc rig resume` lifecycle pattern**
  — we've prescribed it, never run it yet. First test of
  whether suspension cleanly drops dispatcher load.
