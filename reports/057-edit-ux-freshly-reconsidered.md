---
title: Edit UX freshly reconsidered under Li's ratified invariants
author: Claude Opus 4.7
date: 2026-04-24
status: research synthesis; supersedes 052 where the sharper invariants change it
feeds: reports/031 §P1.1; reports/013 grammar
supersedes: reports/052 §3 LLM-translator recommendation; reports/052 §7.2 Rust→nexus translator as Phase-1
---

# 057 — Edit UX freshly reconsidered under Li's ratified invariants

*Claude Opus 4.7 / 2026-04-24. Report 052 worked through edit UX
the moment Invariant A ("Rust is only an output") landed. Li then
sharpened: Invariant B (nexus is a request language; records are
rkyv; there are no "nexus records"), and Invariant C (sema is the
only concern; everything orbits it). Report 054 ratified the
triangle. This report re-reasons from the new invariants, lets go
of 052's "translator as Phase-1 hedge" (which leaned on the idea
that Rust→nexus is still interesting enough to bless as tooling),
and asks afresh: how do humans and LLMs actually interact with
sema when every action is a request?*

---

## Part 1 — The interaction model (revised)

The canonical unit of interaction is the **request**. Every click,
every keystroke-that-commits, every agent tool call resolves to
one of:

- a read request (`Query`, `Subscribe`, or their Pascal-named
  relatives), or
- a write request (`Assert`, `Mutate`, `Retract`, `Patch`, or a
  `{|| ||}` batch of them).

There are no "open a file, edit, save" moments. There is no
buffer that accumulates unsent changes in the engine's model.
What the user *sees* is the state of sema as of some query reply,
possibly live-updated by a subscription. What the user *does* is
send one more request.

This is not quite an IDE, not quite a REPL, not quite a
database-client console. It is closest to the last:

- **Like a DB client**: the user composes statements, sends, gets
  a reply; state lives server-side; every change is auditable as
  a discrete commit.
- **Unlike a DB client**: the objects being edited are code-
  shaped (functions, types, opera), not row-shaped, and the
  natural display is a tree-view or projected source, not a
  tabular result-set.

A cleaner label: **request-composing shell**. The user's tool —
CLI, TUI, structural editor, or agent harness — exists to help
them compose requests and interpret replies. Everything flows
through this compose/send/observe/iterate loop. Report 052 used
"REPL" loosely for this; the request-composing-shell framing is
more accurate because the loop is not "read-eval-print" — it's
"read-reply, compose-request, send-request, read-reply." The
eval is server-side; what the client does is envelope formation.

One consequence this sharpens: **"saving" has no meaning.** A
user who stops typing and walks away has, by definition, sent
nothing. A user who wants a change durable sends a request.
Editors that auto-save files misapply here; the right analogue
is a shell that auto-submits on Enter — and that is a choice,
not a default.

Another consequence: **undo is a request, not a client feature.**
To undo the last commit, the user issues a `Retract` targeting
the records last asserted (or a patch that reverts a previous
patch). The client can make this ergonomic — "press U, I will
compose the retraction for you" — but the undo itself crosses
the wire like everything else, is validated, and can be
rejected (e.g., if downstream records now depend on the thing
being retracted). Client-side "undo buffers" are a confusion of
levels.

This framing is what was latent in 052 and 054; the invariants
force it explicit.

---

## Part 2 — Reading sema (how users see records)

When a user wants to see "the current `resolve_pattern` function,"
they issue a `Query`. Criomed replies with records (as rkyv over
the wire; nexusd re-expresses as nexus text for the client unless
the client is the agent harness, in which case it gets the
structured form directly).

The client then has to *display* those records. Three candidate
surfaces, from 052, revisited:

**(a) Raw nexus syntax of the records.** The reply arrives as
rkyv; nexusd serialises to nexus text; the client prints that
text. Structurally honest. Readable for small replies (one record,
ten records). Unreadable for a full function body (60–120 records
of nested `Expr` / `Pattern` / `Type`).

**(b) rsc-projected `.rs`.** The client asks rsc to project the
reply (or the opus containing it) to Rust text. Shows the user
something they already know how to read. Costs a little —
runs rsc — but rsc runs all the time anyway for rustc's sake.

**(c) Structured tree-view in the UI.** A TUI (or VS Code pane)
renders the records as a navigable tree: function name, params,
body as a foldable subtree of statements. Per-record click
reveals fields. No translation layer; what you see is what
criomed holds.

Under Invariant A, (b) is explicitly fine: rsc's output is "for
humans and rustc to read," and both are downstream consumers.
rsc-projected text is *never input* to sema, so using it as a
display surface does not dilute the nexus-only invariant.

Under Invariant C (sema-centric), (c) is the most sema-faithful —
the tree-view shows the records as they live, not a translation.
This matters when a user's question is "what records does this
opus contain?" vs "what Rust would this opus look like?"

The right answer is that **(b) and (c) are both first-class, for
different questions**. Report 052 leaned (b); under the sharper
Invariant C, I would now say:

- **For "what does this do" questions**, (b) is the natural
  answer — users read Rust fluently, and asking "does
  `resolve_pattern` handle the empty-pattern case?" is cheapest
  to answer from Rust-shaped text.
- **For "how is this structured in sema" questions**, (c) is
  the natural answer — an experienced sema-user asking "what
  `Binding` records does this function emit" wants the records,
  not their Rust projection.
- **For "give me the raw commit form" questions**, (a) is the
  natural answer — rare, but useful for debugging the engine
  itself and for teaching new contributors what records look
  like on the wire.

LLMs are a special case: LLMs read Rust fluently from the training
distribution, and (b) is the highest-bandwidth surface for an
LLM to understand existing sema. An LLM also benefits from (a) —
not because it reads nexus fluently, but because (a) tells it
exactly what shape its own `Assert` needs to mirror when
authoring something similar. Exposing both to the agent harness
(as two different tool calls) is cheap and worthwhile.

**Revision from 052**: 052 leaned (b) as the primary display
surface. The sharper Invariant C pushes me toward "(c) is the
primary surface for day-to-day sema navigation; (b) is the
primary surface for code-reading tasks." Both are needed;
neither is dominant; the client picks based on the user's
current task.

---

## Part 3 — Writing sema (the 4 verbs + patch paths)

The four write verbs are:

- **`Assert`** — introduce a new record into sema. Used for
  fresh authoring: a new function, a new type, a new module.
- **`Mutate`** — change a top-level record (rebind a name,
  swap out a subtree wholesale).
- **`Retract`** — remove a record. Cascades follow the sema
  rules (a retracted type may require retracting its
  references, or may be rejected if references are live).
- **`Patch`** — edit a sub-record at a path. Proposed in
  report 013 §Phase-2; promoted to MVP in report 052 and still
  MVP-essential here.

**Which is the primary edit path?** It depends on the granularity
of the change, not on the user's preference:

- A **new thing** is always an `Assert` (possibly inside a
  `{|| ||}` batch with its supporting records).
- A **surgical change to an existing thing** is a `Patch` —
  "the tail expression of the body of `double` is now `x * 3`"
  is one `Patch` targeting one path.
- A **bulk rewrite of a thing** is a `Mutate` — "replace the
  entire body of `double` with this new body" is one `Mutate`.
  `Mutate` is a special case of `Patch` where the path is the
  record's root; keeping them as separate verbs is a clarity
  choice for the user and the audit log.
- A **deletion** is a `Retract`. If the thing being retracted
  has dependents, criomed rejects; the user must batch the
  retraction with the dependents' retractions (or replacements)
  inside `{|| ||}`.

**Editing a function body** is therefore one of:

1. A single `Patch` if the edit is local ("change the literal
   2 to 3 on line 5").
2. A `Mutate` of the whole `Fn` record if the edit is pervasive
   ("rewrite the whole body").
3. A `{|| ||}` batch of `Patch`es for coordinated multi-site
   edits ("rename this parameter everywhere it appears").

The `{|| ||}` atomic-batch wrapper is heavily used. It is the
natural way to express "these edits are one logical change; if
any fail, roll them all back." Criomed's validation acts on the
batch as a unit.

**`Patch` grammar, restated** (from 043 §P1.1, 052 §7.4, still
valid):

```nexus
(Patch
  (At (OpusRoot my-opus)
      (Field fns)
      (Key (| Fn (Ident double) |))
      (Field body)
      (Field tail))
  (BinaryExpr Mul (Var #param-x) (Lit (LitInt 3 None))))
```

The path expression is itself a record; it composes with the
grammar cleanly; no new sigil, no new delimiter.

**What's new under Invariant C** (beyond 052): `Mutate` and
`Patch` are separate verbs even though `Mutate` is a degenerate
`Patch`, because **the audit log reads more naturally when the
verb announces its granularity**. A reader scanning history for
"when did this Fn get rewritten wholesale" searches for `Mutate`;
a reader scanning for "what small tweaks has this Fn seen"
searches for `Patch`. Collapsing the two would save grammar but
cost cognitive distinction; keep them separate.

---

## Part 4 — Human UX: MVP, Phase-1, Phase-2+

### 4.1 — MVP (to-solstice)

The MVP human workflow is deliberately austere. Li is the
primary (likely only) human user; agents do the bulk authoring;
the tooling has to exist only enough to unblock the self-host
loop.

- **`nexus-cli` interactive mode (a REPL-adjacent shell).** A
  prompt that accepts one nexus request, sends it, displays the
  reply. Backed by nexusd over UDS. Minimal line-editing (arrow
  keys, history, basic completion on top-level verb names).
  Implementation cost: thin; already in report 003 §M4 as
  `nexus-cli`, now in interactive shape rather than one-shot.
- **`nexus-cli view <opus-id>`** — one command that issues a
  blanket Query for an opus, receives records, runs rsc to
  project to `.rs`, displays via `less` (or writes to a
  scratch file in `target/sema-projection/` the user can open
  in their editor of choice). Read-only path; the file is
  ephemeral.
- **`Patch` verb + path grammar**, MVP-essential per 052.
- **`{|| ||}` atomic batch** grammar, MVP-essential per 013.
- **Plain-text editor composition**. Li types nexus into a
  `.nxs` scratch file in his favourite editor, `:w` to save,
  `nexus-cli send scratch.nxs` to submit. This is the honest
  MVP authoring story. It is not ergonomic for bulk work; it
  is ergonomic enough for the small, targeted edits that make
  up most self-host progress once agents are doing the heavy
  lifting.
- **Agent-mediated authoring**. For anything larger than a few
  records, Li delegates to an agent (see Part 5). The agent
  authors the nexus requests; Li reviews the diff (rsc
  projection of the before/after) and approves.

**What's explicitly not in MVP**: structural editor, TUI
browser, Rust→nexus translator. Each is Phase-1 or later; MVP
ships without them and relies on the combination of (a) Li
writing small patches by hand and (b) agents writing everything
else.

### 4.2 — Phase 1 (post-solstice, first 2–4 months)

Once the self-host loop closes and Li has a real workflow he
wants to optimise, the Phase-1 layer lands:

- **A nexus-aware structural editor** (Paredit-analogue) for
  Li's daily editor. Navigation by record; structural edits
  (slurp/barf/wrap/raise); on-save emits `Patch` / `Mutate` /
  `Retract` verbs as the diff between the in-editor tree and
  the last-fetched state. Delimiter-family matrix from 013
  makes the parser trivial.
- **TUI record-tree browser** with inline edit verbs. The
  primary *read* surface for exploring an opus; doubles as a
  composition UI for small edits ("navigate to this field,
  press `e` to edit, type new value, commit"). Scales to
  "explore the whole engine's sema" in a way that raw-text
  projection doesn't.
- **Query-ergonomic helpers**: `nexus-cli query --pretty`,
  path-of helpers, pattern-template snippets for common
  queries. Reduces the pain of writing well-formed patterns
  by hand.
- **`Subscribe` support in the client**. A command that opens
  a stream, holds it, redraws the TUI as records arrive.
  First consumer: "show me live what the agent is doing to
  my opus."

Notably **dropped from 052's Phase-1 list**: the Rust→nexus
translator. Li's stance in report 054 leans away from blessing
such a tool (`"we don't care at all to read it"` implies we
don't want to build tools that rely on reading it either).
Under Invariant C — sema is the concern — investing engineering
effort in a rust-analyzer-backed translator is orthogonal to
sema's maturation. If the community builds one externally,
fine; we don't ship it. LLMs learn nexus through the agent
harness and corpus accumulation. I now read 052's Phase-1
translator recommendation as a hedge that the sharper
invariants make unnecessary.

### 4.3 — Phase 2+

- **Template / macro records.** Pascal-named records
  (e.g., `(Template shapeFn :params [name body] …)`) expanded
  at commit time by criomed. Nexus-grammar snippets for
  repeated shapes.
- **Projectional editor** (Hazel/Lamdu style). Research-grade;
  probably never needed if Paredit + TUI + agents cover the
  surface.
- **Multi-modal display projections.** rsc emits markdown
  outlines, graphviz callgraphs, LaTeX for documentation, etc.
  All downstream of sema; all read-only. Only if user pressure
  justifies the engineering.

---

## Part 5 — LLM UX: agent harness, system prompts, tool-use

### 5.1 — The minimum tool set

An LLM in an agent harness needs four tool families. Under the
sharpened invariants, these look like:

- **`nexus.query(pattern)` → records.** Accepts a nexus query
  pattern (`(| Fn @name=resolve_pattern |)` style), returns the
  matching records as structured JSON (for the model's reading)
  with their nexus-text form attached. Model uses this to
  inspect sema.
- **`nexus.read_projection(opus-id)` → rust_text.** Calls rsc
  on the server, returns the projected `.rs`. Model uses this
  to *read* code; the projection is lossy (doesn't show all
  record fields) but idiomatic for the model.
- **`nexus.send(request)` → reply.** Accepts a nexus text
  request (one verb, or a `{|| ||}` batch), sends to nexusd,
  returns criomed's reply. Reply is either `CommitReceipt` on
  success or `Diagnostics` on rejection.
- **`nexus.subscribe(pattern)` → stream.** Used by the harness
  to keep an open channel for change-watching; the model
  itself rarely initiates subscriptions, but harness code
  does (e.g., to stream diagnostics as a compile runs).

A fifth helper is worth adding:

- **`nexus.path_of(natural-description)` → path_expression.**
  "The body of the function called foo" → path expression the
  model can drop into a `Patch`. Implemented server-side (via
  Query + heuristics) to spare the model from computing path
  expressions itself. Reduces the per-edit token cost
  substantially.

### 5.2 — System prompt scaffolding

The agent harness needs a system-prompt section teaching the
model:

- **The triangle** (Invariants A/B/C, restated succinctly).
- **The four verbs** with one worked example each.
- **The path-expression grammar** (record-shaped, five hop
  kinds).
- **The schema for the specific opus the model is editing** —
  this is the big ticket. `nexus-schema` has N record kinds; a
  task touching a subset of them needs that subset's shapes in
  the prompt. The harness computes "what record kinds might
  this task touch" and includes their definitions.
- **A diagnostic vocabulary** — the common rejection shapes,
  so the model can recognise "oh, criomed says my path didn't
  resolve; let me re-query to find the right path" without
  hand-holding on each rejection.
- **One worked turn**: a trivial Assert, a Patch, a Retract,
  a batch, shown as "model output" examples.

Total cost: 4–8k tokens of scaffolding. Stable across model
versions (minor edits when Anthropic ships a new model); fully
cacheable via prompt cache. Per-session marginal cost
negligible.

### 5.3 — Realism today

**GPT-4-class and Claude-class models today** can emit novel
DSLs they've never seen with ~4-shot prompting, provided the
DSL is regular and the tool-use loop gives feedback on
rejections. Nexus qualifies: first-token-decidable, ~10 atoms,
every "operator" is a Pascal-named record rather than a
keyword (so the model's "what vocabulary am I allowed" answer
comes from the nexus-schema section of the prompt, not from
training data). Diagnostics feed back errors in records (Part
6 below), which the model parses naturally.

The risk is *rate of error*: on first attempts, a fresh
model will compose malformed nexus ~30% of the time and
criomed-rejected-but-well-formed nexus another ~20%. That's
5 retries on a typical edit, each burning ~2k tokens. Too
expensive for casual use, tolerable for self-hosting work
where each successful edit represents meaningful progress.

**Fine-tuning** (mentioned in 052 §3.3) remains the cost-
reduction path for Phase 2+, **if** prompt-scaffolded tool-use
proves too token-expensive. Current evidence is ambiguous:
tool-use loops are expensive but not prohibitively so at
Claude's pricing for the MVP-era use-case (Li + agents,
moderate throughput). Defer fine-tuning until data says we
need it.

### 5.4 — The translator-as-agent-tool idea, reconsidered

Report 052 §3.4 proposed a Rust→nexus translator as a user-
space accelerator: LLM emits Rust (fluent); translator
produces nexus; harness submits. I argued there this was
structurally different from the banned engine-internal
ingester.

Under Invariants B+C, I now think this was the wrong optimum.
Reasons:

- **Invariant C (sema-centric) deprioritises Rust fluency as
  an input format.** We don't want users (including LLM users)
  reasoning in Rust-shapes and having their Rust translated
  to sema-shapes behind the scenes; that's an impedance
  mismatch that ossifies Rust's ontology into sema's, with
  every subtle mismatch becoming an engineering problem.
  Better: teach LLMs nexus, keep sema's ontology primary.
- **Invariant B (nexus is only a messaging language)** means
  the translator's output is nexus text, which is just a
  wire-format. The translator doesn't violate the invariant,
  but neither does it simplify anything; the LLM could
  equally emit nexus text directly, and doing so keeps the
  LLM's mental model aligned with sema's.
- **The compute cost of a rust-analyzer-backed translator is
  nontrivial**: weeks of engineering, ongoing maintenance as
  rust-analyzer evolves, edge cases around macros and
  proc-macros. Under sema-centric prioritisation, that
  engineering goes into sema-side things (richer schema,
  better diagnostics, structural editor) instead.

**Revised position**: the translator is not a blessed tool.
The LLM emits nexus, full stop. If throughput becomes a real
problem, we fine-tune or we improve the schema-scaffolding
prompt. If someone in the community wants a translator, that's
their project; we won't build it, we won't ship it, we won't
test against it.

This is a real supersede of 052 §4 and §7.2.

---

## Part 6 — Validation feedback: Diagnostics as UX

Criomed rejects invalid requests with a reply containing
**`Diagnostic` records**. Reports 033 and 043 sketched these;
the shape I'd commit to:

```nexus
(Diagnostic
  :kind MalformedPathExpression
  :severity Error
  :message "No record matches path expression; the record at
            (Field fns Key (| Fn (Ident double) |)) does not
            exist."
  :span (RecordRef #request-record-42)
  :hint "Query '(| Fn @name=double |)' to confirm the function
         exists before patching."
  :code "CRIOME-E0217")
```

Fields (candidate list; schema bikeshed):

- `kind` — Pascal-named diagnostic category. Machine-readable.
- `severity` — `Error` | `Warning` | `Info`.
- `message` — human-readable explanation.
- `span` — reference into the offending request (a record-ref
  or a slot-path pointing at the specific sub-record that
  violated).
- `hint` — suggested next action.
- `code` — stable identifier for documentation cross-ref.

**Why records (not strings)**:

- **LLMs parse them structurally.** Model gets "span points
  at record 42" and can correlate with its own emitted
  request; no NLP over an error string.
- **Humans filter them.** "Show me only `Error`-severity";
  "group by `kind`." Records enable the UI.
- **The audit log captures them.** Every rejected request
  stores its Diagnostics; history analysis ("what has been
  failing lately") reads them as data.

**Pointing at specific record IDs / slot refs**: yes, crucial.
The `span` field of a Diagnostic references either a record
in the submitted batch or a slot-path into an existing record.
The client — CLI, TUI, agent harness — uses the span to show
the user *where* the problem is, not just *what*. Without
span, diagnostics are prose; with span, they are actionable.

**The feedback loop**:

1. User sends request.
2. Criomed rejects with `[Diagnostic, Diagnostic, …]`.
3. Client renders the diagnostics (TUI: inline highlights;
   CLI: formatted list; agent: structured JSON).
4. User (or LLM) iterates: reads the `span` + `hint`, amends
   the request, re-sends.
5. Repeat until accepted.

This is the same loop as `cargo check` → fix → `cargo check`,
except the state-of-truth is sema not `.rs`, the verbs are
nexus not edits, and the diagnostics are records not strings.
Developers already know how to work this loop; users get it
for free.

---

## Part 7 — The MVP minimum tooling

Restating 052 §7.1 with post-054 corrections:

- **`nexus-cli` with interactive mode.** Submit one request,
  read one reply. History, arrow keys, completion on top-level
  verbs. Already planned.
- **`Patch` verb + path grammar in nexus-schema and nexusd.**
  Promoted to MVP by 052; still MVP here.
- **`{|| ||}` atomic batch** in grammar + execution.
- **rsc projection for display.** `nexus-cli view <opus-id>`
  emits to scratch file; user opens in their editor.
- **Diagnostic record shape** finalised and returned on
  rejection. Criomed's validation emits these.
- **Agent system-prompt template.** Worked examples of the
  four verbs for the common record kinds. Stored in the
  harness, updated per model release.
- **Read projections (`.rs` via rsc) and record projections
  (raw nexus) both exposed to the agent harness.** Two tools,
  not one.

**Dropped from 052's MVP list (or never there)**:

- Rust→nexus translator (dropped from 052's Phase-1; now also
  explicitly not Phase-2).
- Structural editor (still Phase-1, unchanged).
- TUI browser (still Phase-1, unchanged).

**New** compared to 052:

- Explicit `nexus.path_of` tool for the agent harness. Makes
  LLM edits 2–3× cheaper in tokens.
- Explicit "record view" tool (tree/raw nexus) alongside "Rust
  projection" tool — both exposed to humans and agents.

Total MVP engineering budget for edit UX: small. Most of the
list is already-planned work (nexus-cli, rsc projection, verbs
+ grammar). The new-to-MVP items are the Diagnostic-record
schema (one half-day of schema design + implementation in
criomed's validation) and the agent system-prompt template
(one day of prompt engineering + examples).

---

## Part 8 — Open questions

1. **Granularity of `Diagnostic.span`.** Record-ref is easy;
   slot-path into an existing record needs the path-expression
   grammar to be symmetric (can point into the client's
   submitted batch as well as into sema). Needs one session
   of schema design.

2. **Batch partial-success reservation.** Report 013 §3.4
   reserved `{# #}` for partial-success semantics. Under the
   nexus-only invariant, some clients will want partial-commit
   shapes ("assert these 200 records; skip any that conflict
   with existing sema"). MVP is rollback-on-any-failure; `{# #}`
   can arrive Phase-1+ if demand surfaces. No decision needed
   for MVP.

3. **How does an LLM handle "I need to invent a new kind of
   record"?** Adding to `nexus-schema` itself is a meta-edit —
   the LLM would assert a new record-kind record. This closes
   the self-host loop but is beyond typical LLM reach today.
   Probably a human-mediated path in practice; worth
   articulating but not blocking MVP.

4. **`Subscribe` semantics for live-editing UX.** If Li opens a
   TUI and the agent is also editing, does Li's view update
   live (via subscription) or does it snapshot? Probably live
   with a configurable debounce. Phase-1 question, not MVP.

5. **Permission-denied UX before BLS exists.** For MVP, criomed
   accepts all writes (single-operator mode). Should it still
   *format* its replies as if going through a permission check
   (so the client learns the shape)? Probably yes, with a
   trivial "single-operator: allowed" diagnostic on every
   write. Costs nothing; makes the Phase-2 BLS transition
   trivial.

6. **Cold-start bootstrapping the engine's sema from existing
   `.rs`.** Report 052 §8 called this the "strongest case for
   translator work." Under the revised stance here (no
   translator), the alternative is: Li + agents author the
   engine's sema records by hand-and-model, using the existing
   `.rs` as reference material. Slower than a translator; more
   aligned with Invariants B+C. This is a decision to affirm
   in a session focused on bootstrap strategy — not here.

7. **What about editors that submit on every keystroke?** A
   structural editor could, in principle, send a request per
   structural edit (slurp, barf, wrap). That generates huge
   commit churn. Phase-1 convention: the editor buffers a
   local edit tree and only submits on an explicit commit
   keystroke (Ctrl-S analogue). Audit log stays clean.

8. **Agent rate-limiting at criomed.** An LLM in an iteration
   loop can fire requests faster than criomed wants to validate
   them under some workloads. Not an MVP concern; flag for the
   performance pass.

9. **Format of the reply when a Query matches many records.**
   Streaming via `Subscribe` is one option; paginated Query
   with `(Limit 100)` is another; the client decides which to
   use. Schema choice, not invariant choice. Report 013 handles.

---

*End report 057.*
