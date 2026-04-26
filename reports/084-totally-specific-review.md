# 084 — Totally-specific design audit (criome / signal / nexus)

*2026-04-26 · Walkthrough of `/home/li/git/{criome,nexus,signal,nota}` against the principles distilled this session. Surfaces inconsistencies and bit-rot the main thread might have missed. Research-only — no edits applied.*

---

## Headline

The largest single source of inconsistency is the **nexus repo `src/`**: it is wholesale a v1/v2 design (client-msg framing with `Heartbeat` / `Cancel` / `Resume` / `Ack` / `Working` / `Done` / `Failed` / fallback-file delivery). Reports 082 and 083 + the rewritten `spec/grammar.md` describe a daemon that does *none* of that, but the source has not yet been rewritten. The README and ARCHITECTURE.md in nexus describe the stale design, not the spec.

The second largest source of bit-rot is **`signal/`**: README + ARCHITECTURE.md + several source comments still reference `Patch` and `TxnBatch` (deleted variants) and `signal/src/edit.rs` no longer matches its own README. Inside `signal/src/edit.rs` itself the code is correct; the prose around it is not.

The third concrete code-level issue is **`Frame.correlation_id`**: principle 9 says replies pair to requests by **position only — no correlation IDs**, but the wire envelope still carries one and even claims (in the doctype comment) that "server echoes the value from a request frame onto its reply frame." That contradicts the locked design.

---

## 1 · Per-file findings

Severity legend: **MUST** = blocks new code; **SHOULD** = land before next milestone; **NICE** = cosmetic.

### 1.1 — `signal/src/frame.rs`

**FRAME-1 (MUST)** — `correlation_id: u64` field on `Frame` violates principle 9.

- Lines 22–36 declare the field; line 25's docstring calls it "Request/reply pairing. Server echoes the value from a request frame onto its reply frame."
- Lines 76–84 (test) and the rest of the codebase build frames with hard-coded `correlation_id: 1`.
- Per `reports/083` and `nexus/spec/grammar.md` lines 220–276, replies pair to requests by **position on the connection (FIFO)**. No correlation IDs.
- **Suggested fix:** delete the field. Remove the docstring claim. If a transitional period is wanted, mark it `#[deprecated]` and stop reading it on the criome side, but the spec is unambiguous: it should go.
- Knock-on: `nexus/ARCHITECTURE.md` lines 70–78 describe nexus as "stateless modulo correlations" with "in-flight `correlation_id` ↔ pending-reply mappings" — same change.

**FRAME-2 (SHOULD)** — `principal_hint` and `auth_proof` belong inside the request, not on the envelope.

- Principle 2 (records are self-contained — identity, kind, data all in the record's bytes) rhymes with: the auth proof for a request is part of *that* request's content, not a separate envelope field. Today both fields are `Option<…>` on `Frame` (lines 28–34) which means a frame on its own carries metadata that isn't part of any record.
- Not as load-bearing as FRAME-1; the principle was stated about records, and frames aren't records. Flag for Li to confirm.

### 1.2 — `signal/src/flow.rs`

**FLOW-1 (MUST)** — `Node.id: String` is in tension with the slot/content-ref principle.

- Lines 30–33: `Node { id: String, label: String }`.
- The slot system says records identify each other by content (hash) or by the slot the index assigns (principle 7 — slots are an internal storage index; user-facing identity is content-derived). The `Node.id` field functions as a *user-facing handle* (`(Node user User)`, `(Edge 100 101 ...)` referring to that Node by slot 100). So the `id` field is doing nothing — the slot serves that purpose, and the example file (`flow-graph.nexus` line 32: `(Edge 100 101 …)`) confirms by referring to nodes by slot, not by `id`.
- **Suggested fix:** delete `Node.id`. A `Node` is `{ label: String }`. The slot is its identity in sema; the content-hash is its identity at the binary level. `id` is dead vocabulary.
- Caveat: Li may want a stable per-instance handle for human reading. If so, the field should be `name: String` and the design rule should be stated: it's content for display, never an identity. As written, "id" reads as identity.

**FLOW-2 (SHOULD)** — `Edge.label: Option<String>` is one of the few `Option` fields in the schema.

- Principle 2 says records are self-contained; Optional fields blur that. If we want to allow unlabelled edges, two cleaner options:
  - Closed enum: `EdgeLabel { None, Named(String) }` — explicit kind for the absence.
  - Two record kinds: `Edge { from: Slot, to: Slot }` and `LabeledEdge { from: Slot, to: Slot, label: String }` — tracks the principle that the schema, not optionality, encodes intent.
- The example file uses `(Edge 102 104 writes)` and `(Edge 102 103 lojix-schema)` for labelled edges — there's no example of an unlabelled one, and the comment block (lines 30–32) explains the `Option`. If unlabelled edges are not a use-case, drop the Option and require label.
- **Suggested fix:** if Li doesn't actually need unlabelled edges in v0.0.1, change to `pub label: String`. Otherwise prefer the closed enum.

**FLOW-3 (NICE)** — comment hierarchy on Ok mentions Li and a date.

- Lines 59–60: `/// Per Li 2026-04-26 ((messages are records, records are delimited, ...))` — useful as session context but per principle 13 (no version-history narration) and principle 14 (ARCHITECTURE.md durable, reports non-durable), the conversational citation belongs in a report, not in long-lived code.
- **Suggested fix:** keep the design statement, drop the attribution. The fact that messages are records is a design rule; the date is gloss.

**FLOW-4 (SHOULD)** — `KNOWN_KINDS = &["Node", "Edge", "Graph"]` (line 68) is a string-list dispatch.

- Lines 18–20 say "the validator's schema-check matches incoming `RawRecord.kind_name` against `'Node' | 'Edge' | 'Graph'`."
- Principle 6 (clarification): schema-level enums *are* encouraged. A typed `enum Kind { Node, Edge, Graph }` (or a `KindKind` if you want to leave room for `Ok` and `Diagnostic`) would be cleaner than parallel string-tagged systems. The validator dispatch becomes a typed `match` rather than a `KNOWN_KINDS.contains(&kind_name.as_str())` check. The string `kind_name` field stays on the wire (signal-side) for forward-compatibility; the *daemon* converts it to the typed `Kind` enum at the wire boundary.
- **Suggested fix:** add `pub enum FlowKind { Node, Edge, Graph }` next to `KNOWN_KINDS`; have the validator `parse_kind(s) -> Result<FlowKind, Diagnostic>` rather than a string presence check. Keep the string list for a `to_str` round-trip helper.

### 1.3 — `signal/src/edit.rs`

**EDIT-1 (MUST)** — `AssertOp.assigned_slot: Option<Slot>` couples genesis-seeding into the normal request shape.

- Lines 22–26: `pub assigned_slot: Option<Slot>` carries "during genesis seeding; otherwise criome assigns the slot internally."
- Per `criome/ARCHITECTURE.md` §3 (lines 174–181), "genesis runs the same flow" via the same nexus parsing path. If genesis-seeding is the only producer of `assigned_slot`, the field doesn't belong on `AssertOp` — genesis is one of N possible request sources, and the nexus daemon cannot author this field from text (no syntax exists). The field is a hidden control channel.
- Two cleaner shapes:
  - Drop the field. Genesis runs the *same* `(Record …)` syntax; criome assigns slots normally. If genesis needs deterministic slot numbers, the genesis runner runs an `(AssertWithSlot N (Record …))` or pre-allocates the seed range and threads it.
  - Keep the field but mark it as a separate `GenesisAssertOp` request variant — explicit channel, separate from user-authored asserts.
- **Suggested fix:** drop the field; change genesis to use the normal flow. If that fails on a real constraint, separate the variant.

**EDIT-2 (MUST)** — `expected_rev: Option<Revision>` on every edit op.

- Lines 22–26 (AssertOp), 32–37 (MutateOp), 41–45 (RetractOp): all use `Option<Revision>`.
- Per principle 4 (nexus is a request language; each top-level expression is one self-describing request with literal values), an `Option` revision makes the request shape inconsistent — sometimes it's a CAS, sometimes it isn't, and the wire alone can't tell why.
- For Mutate and Retract, the request operates on existing data: a CAS revision is usable. For Assert (introducing a new record), CAS doesn't apply — only `Some(0)` makes sense ("fail if any record exists at this slot"), and even that overloads with `assigned_slot`.
- **Suggested fix:** review per-verb. AssertOp probably should not have `expected_rev` at all (asserting a slot that already has content is its own validator failure); MutateOp/RetractOp should consider whether CAS is mandatory or whether non-CAS edits are first-class. Each `Option<Revision>` is two design decisions packed into the type — the wire deserves whichever the engine actually wants.

**EDIT-3 (SHOULD)** — comment line 6 says "the pattern-based form that subsumes per-field Patch."

- The phrase "subsumes per-field Patch" is v1/v2 vocabulary. The principle is just "Mutate replaces a record." Mentioning Patch perpetuates the `Patch` vocabulary — see EDIT-5.
- **Suggested fix:** replace the parenthetical with "the pattern-based form is `~(\| pat \|) (NewRecord …)` — same MutateOp shape per match."

**EDIT-4 (NICE)** — `BatchOp` is a 3-variant enum (Assert/Mutate/Retract) but the file has no doc explaining "why no Subscribe/Query in a batch?"

- The answer is "edits only," but a one-line doc on the enum makes that intentional rather than incidental.

**EDIT-5 (SHOULD)** — `Patch` and `TxnBatch` references are still scattered through signal's *non-source* files.

- `signal/README.md` line 18: `Edit verbs (Assert / Mutate / Retract / Patch / TxnBatch); query verbs (Query / Subscribe / Unsubscribe); read-only Validate.`
- `signal/README.md` line 47: `compose AssertOp / MutateOp / TxnBatch in rkyv directly`.
- `signal/ARCHITECTURE.md` line 53: `AssertOp / MutateOp / RetractOp / PatchOp / TxnBatch`.
- `signal/ARCHITECTURE.md` lines 134–135: code-map block lists `PatchOp, TxnBatch, TxnOp` — none of which exist in `src/edit.rs`.
- `signal/src/value.rs` line 1: `// Wire-record values — what travels inside Assert/Mutate/Patch ops`.
- `signal/src/slot.rs` lines 15, 23: still references `Mutate` and `Patch`.
- **Suggested fix:** sweep `Patch` and `TxnBatch` from comments and prose. Replace with `Assert/Mutate/Retract/AtomicBatch`.

### 1.4 — `signal/src/request.rs`

**REQ-1 (NICE)** — `ValidateOp.op: Box<BatchOp>` is the only place `Box<BatchOp>` appears.

- Lines 44–47: `pub struct ValidateOp { pub op: Box<BatchOp>, }`.
- `BatchOp` is already a 3-variant enum; the box adds a heap allocation for what's already a one-of-three discriminator. If the discriminator is the only thing being validated, just use `BatchOp` directly.
- **Suggested fix:** drop the `Box`. (Possibly `Box` is in there because someone thought `BatchOp` would grow without bound — it won't.)

**REQ-2 (SHOULD)** — Request enum has good comments but doesn't enforce the principle 6 framing in code.

- The enum (lines 18–40) is well-structured. The comments mention the principle indirectly ("there is no Goodbye, Cancel, Resume, Heartbeat, or Unsubscribe verb") — that *is* the principle 6 framing — good. But that's negative-context (per the `feedback_no_negative_context` memory). State the rule positively: "Connection lifecycle is socket-level; subscriptions die with their connection." No need to enumerate the rejected verbs in the comment.

### 1.5 — `signal/src/reply.rs`

**REPLY-1 (MUST)** — Top of file (line 14) refers to `Event` and "the M2+ shape".

- Lines 13–15: `Subscribe: connection enters streaming mode; each event is a record arriving on the connection (not a Reply variant — see Event below for the M2+ shape).`
- There's no `Event` symbol in this file. Either it was deleted or never added. The reference is dangling.
- **Suggested fix:** drop the "see Event below" sentence. The streaming-mode behavior is fully described by reports/083 §6 (subscription replies are uniformly single records reusing request-side sigil discipline).

**REPLY-2 (SHOULD)** — `Bindings` struct (lines 55–56) is unused as far as I can see, and not re-referenced from `Reply`.

- The Reply enum has `Records(Vec<RawRecord>)` — query results. No reply variant carries `Bindings`. The struct exists but isn't wired into anything.
- **Suggested fix:** if pattern-bound query results need to carry `(name, value)` pairs, decide where they go (probably inside RawRecord as a special "binding-result" kind, or as a separate `Reply::QueryWithBinds` variant). Either way, the lone struct without a use site is dead code.

**REPLY-3 (SHOULD)** — `OutcomeMessage::Ok(Ok)` re-exports the `Ok` kind from `flow.rs`.

- Line 49: `Ok(Ok)`. The `Ok` kind is defined in `flow.rs` as a sema record; the OutcomeMessage enum then carries it. That's fine but creates a vocabulary clash with Rust's `Result::Ok` — readability suffers. The flow.rs comment (line 64) even says "`Ok` and `Diagnostic` are message kinds (reply-only) and do not appear here [in KNOWN_KINDS]" — so they're not really sema-storable records, just message records. Putting them in `flow.rs` (which is "the first sema record category criomed handles end-to-end") muddles the categorisation.
- **Suggested fix:** move `Ok` (and consider re-homing `Diagnostic`) to `signal/src/message.rs` or `signal/src/reply.rs`. Keep `flow.rs` for the actual sema kinds. Renaming `Ok` to `Ack` was rejected (per reports/083 §"What's not in this protocol") but moving the type to a new module doesn't change the wire form.

**REPLY-4 (NICE)** — `Reply::Outcome(OutcomeMessage)` vs `Reply::Outcomes(Vec<OutcomeMessage>)` is a small wart.

- Per reports/083, every reply position carries either an outcome or a sequence of outcomes (or a sequence of records for a Query). The two variants `Outcome` / `Outcomes` differ by container. A cleaner shape might be a single `Reply::Outcomes(Vec<OutcomeMessage>)` that's always a Vec — sometimes length-1, sometimes length-N. Saves the dispatch.

### 1.6 — `signal/src/slot.rs`

**SLOT-1 (SHOULD)** — line 8 references `criome-types` and "nexus-schema re-exports."

- `nexus-schema` was shelved (per `mentci/docs/workspace-manifest.md` and the report-078/0ee4ebe commit). Slot/Revision now live in signal permanently.
- **Suggested fix:** drop lines 6–8: "When `criome-types` lands, these move there and nexus-schema re-exports."

**SLOT-2 (SHOULD)** — line 15 still references `Patch` (per EDIT-5 above).

### 1.7 — `signal/src/value.rs`

**VAL-1 (SHOULD)** — line 1 references `Assert/Mutate/Patch ops`. See EDIT-5.

**VAL-2 (NICE)** — `RawValue::Bytes(Vec<u8>)` (line 50) and `RawLiteral::Bytes(Vec<u8>)` (line 63) duplicate.

- Two ways to put bytes into a value tree: as `RawValue::Bytes` directly, or as `RawValue::Lit(RawLiteral::Bytes(...))`. Pick one. The `Lit` path is more uniform; the bare `RawValue::Bytes` is probably an early-design artifact.
- **Suggested fix:** drop `RawValue::Bytes(Vec<u8>)`. Force everything through `Lit(RawLiteral::Bytes(...))`.

**VAL-3 (NICE)** — `RawLiteral::Slot(Slot)` and `RawValue::SlotRef(Slot)` are similarly redundant. Lines 47 and 65.

- The comment on `RawValue::SlotRef` (lines 38–39) says: "Bare integers in nexus text become `SlotRef` when the target field is `Slot`-typed." So `SlotRef` is the wire form and `Lit(Slot)` is the literal form, and they're disambiguated by whether the parser knows the field type. Worth documenting why both exist — or simplifying to one.

### 1.8 — `signal/src/handshake.rs`

**HS-1 (NICE)** — `client_name: String` (line 45) is free-form metadata in the wire envelope.

- Principle 5 (comments carry no load-bearing data — typed home in schema). The `client_name` is documented as "free-form ... not authoritative." That's borderline OK because it's typed (it's not a comment), but a free-form string with no semantic role is the same anti-pattern: information without a typed home.
- **Suggested fix:** if the daemon needs to know "this is nexus-cli" for any decision, type it: `client_kind: ClientKind { NexusCli, EditorLsp, Service, Other(String) }`. If it's purely for logs, drop it from the wire and have the client send a `Diagnostic`-shaped log entry separately.

### 1.9 — `signal/src/auth.rs`

**AUTH-1 (NICE)** — `BlsSig` and `QuorumProof` skeletons live alongside `SingleOperator` (lines 17–30).

- Principle: skeleton-as-design (per `criome/ARCHITECTURE.md` §10 / project-wide rules). The skeletons are appropriate. No issue, just confirming they're not dead code waiting to be deleted.

### 1.10 — `signal/src/effect.rs`

**EFFECT-MISSING** — File doesn't exist (read returned File-does-not-exist) but `signal/ARCHITECTURE.md` line 131 lists `effect.rs`: "effect.rs — Effect, OkReply, RejectedReply, QueryHitReply".

- `OkReply`, `RejectedReply`, `QueryHitReply` are v1/v2 vocabulary that the new reply protocol replaces with `(Ok)` and `(Diagnostic …)` records.
- **Suggested fix:** delete the line from `signal/ARCHITECTURE.md`. Confirm `signal/Cargo.toml` doesn't reference effect.rs as a missing module.

### 1.11 — `signal/ARCHITECTURE.md`

**SARCH-1 (MUST)** — line 38 still claims `Frame` envelope carries `correlation_id, principal_hint, auth_proof, body`.

- Same as FRAME-1. Drop `correlation_id`.

**SARCH-2 (SHOULD)** — line 53 lists "AssertOp / MutateOp / RetractOp / PatchOp / TxnBatch" — Patch and TxnBatch are gone.

**SARCH-3 (SHOULD)** — line 73 says "Frames are length-prefixed (4-byte big-endian)" — the actual `Frame::encode` (frame.rs:51) returns bare rkyv bytes with no length prefix. The signal/README.md (line 70) is also inconsistent: "The frame schema *is* the framing — both parties know the rkyv schema. No length-prefix layer outside rkyv."

- The two ARCH docs disagree with the README and with the code. Pick one and write it down.
- **Suggested fix:** the actual code-correct framing is what's in nexus-cli / the daemon's transport layer (probably tokio LengthDelimitedCodec wrapping each frame, per reports/078). Either document that as the daemon's responsibility (signal types remain length-agnostic), or implement length-prefix in `Frame::encode`. Right now the docs say one thing, the code does another, and a future implementer will pick wrong.

**SARCH-4 (SHOULD)** — line 132 mentions `effect.rs — Effect, OkReply, RejectedReply, QueryHitReply`. Per EFFECT-MISSING, these don't exist.

**SARCH-5 (SHOULD)** — lines 134–135 mention `PatchOp` and `TxnOp`. Same as EDIT-5.

### 1.12 — `signal/README.md`

**SREADME-1 (SHOULD)** — full sweep needed.

- Line 18–19: edit verbs list includes `Patch / TxnBatch` and query verbs include `Unsubscribe`. None of those exist.
- Line 23–24: lists `Effect, OkReply, RejectedReply, QueryHitReply`. None exist.
- Line 28–30: claims Language IR "lives in `nexus-schema`." nexus-schema was shelved; types are in signal now (per the 0ee4ebe commit and signal/ARCHITECTURE.md).
- Line 47: `compose AssertOp / MutateOp / TxnBatch`.
- **Suggested fix:** rewrite the README to reflect current state.

### 1.13 — `nexus/spec/grammar.md`

**GRAM-1 (NICE)** — line 110 says "Patch is expressed as Mutate-with-pattern that preserves the unchanged fields:"

- The vocabulary is still Patch, but the spec now describes it correctly as Mutate-with-pattern. Two ways to interpret this:
  - User has used "Patch" in past sessions, and the spec gives a backward-readability nod to that.
  - The word "Patch" should be retired everywhere.
- Per `feedback_no_negative_context`, do the silent-omission: just describe the Mutate-with-pattern form without saying "Patch is expressed as." The example is self-contained.
- **Suggested fix:** change "Patch is expressed as Mutate-with-pattern that preserves the unchanged fields:" to "Mutate-with-pattern preserves the unchanged fields:".

**GRAM-2 (SHOULD)** — line 24's `;;` line comments comment is good but contradicts the example file.

- Spec line 22–25: comments carry no load-bearing data, parser discards them.
- `flow-graph.nexus` lines 1–17 use comments as the *only* documentation of the schema (which fields are which positions). The example reader needs to read comments to understand which value is `id` vs `label`.
- This is fine in an example file — comments are explanatory. The principle is about the *production system* not relying on comments. The example file isn't violating the principle.
- But: there is a real tension here. If the schema is the typed home, the example shouldn't *need* comments to explain field positions. A new reader without comments has no way to know `(Node user User)` means `id="user", label="User"`.
- **Suggested fix:** the example file's comments are fine. But add a one-line note in grammar.md (around line 28 or in the records section) saying: "Reading positional records requires the schema. Tools may emit field-name comments above each value during display; those comments never round-trip."

**GRAM-3 (SHOULD)** — line 29 references identifier classes including kebab-case "(titles / tags)" but doesn't say what tags are.

- A bystander reading the grammar wouldn't know what kebab-case is *for*. Quick fix or omit.

**GRAM-4 (NICE)** — Verbs table (lines 95–108) doesn't show Constrain `{| |}`. The grammar mentions Constrain in §"Constraining multiple patterns" but it's missing from the verbs table.

- Constrain isn't a top-level verb (it's a query composition operator), but the table claims to be exhaustive. Either add a row or add a note that Constrain is a query operator, not a top-level verb.

### 1.14 — `nexus/spec/examples/flow-graph.nexus`

**EX1-1 (SHOULD)** — line 30–32 comment block describes `Edge.label: Option<String>` semantics.

- The line `(Edge 102 104 writes)` correctly emits a bare-ident string for `Some(s)`. But the comment "None is written as the literal None" demonstrates none of the examples — there's no `(Edge 102 105 None)` example. If unlabelled edges aren't a use case, drop the Option (FLOW-2). Otherwise add an example.

**EX1-2 (NICE)** — line 32 `(Edge 102 104 writes)` — "writes" is fine as a bare ident, but is this actually data the example was intending? Reading it, the relationship "criome writes to sema" is what's being asserted. That's a relation type — exactly the use case for the future `RelationKind` enum that the principle-6 clarification calls out. The example is implicitly arguing for a typed relation enum.

### 1.15 — `nexus/spec/examples/patterns-and-edits.nexus`

**EX2-1 (MUST)** — line 45 says "The first reply is the snapshot of current matches; subsequent replies stream as the match-set changes."

- This contradicts `nexus/spec/grammar.md` line 260: "There is **no initial snapshot** in the subscribe reply — issue a separate `(\| pat \|)` Query first if the client wants current state."
- The example was written before the snapshot-vs-events race resolution in reports/083 §"Problem 5." The example is wrong.
- **Suggested fix:** rewrite the comment block: "`*` opens a continuous query. Events stream as matches change; no initial snapshot. Issue a `(| Node @id @label |)` Query first for current state."

**EX2-2 (SHOULD)** — line 9 `(| Edge @from=@to @label |)` uses bind aliasing.

- This is fine and correct per spec. But the example doesn't explain *what* the alias does in *Edge*-self-edge terms — a reader has to deduce from the schema (Edge has `from: Slot, to: Slot`). A one-line addition: ";; matches edges whose `from` slot equals the `to` slot" would help.

### 1.16 — `criome/ARCHITECTURE.md`

**CARC-1 (MUST)** — line 398: "User issues nexus requests (Assert / Mutate / Patch) that change code records in sema."

- Patch is gone. Should be "Assert / Mutate / Retract" or just "edit requests."

**CARC-2 (SHOULD)** — §1 lines 38–41: "(`Assert`, `Mutate`, `Retract`, `Query`, `Compile`, `Subscribe`, …)"

- `Compile` is not in `signal/src/request.rs`. The Request enum has Handshake, Assert, Mutate, Retract, AtomicBatch, Query, Subscribe, Validate. No Compile.
- Per `criome/ARCHITECTURE.md` §7 lines 396–425, Compile is a *user-facing nexus expression* `(Compile (Opus :slot N))` that the daemon dispatches. The signal-level treatment is unclear: does criome receive `Request::Compile(…)` or does the daemon synthesize a sequence of Asserts? Spec needs to align.
- Also note: `(Compile (Opus :slot N))` uses `:slot` syntax which is v1/v2 keyword-arg syntax (per `project_criomev3` memory: "`:keyword` field syntax (e.g. `:slot 100 :name "Alice"`) — does not exist; v3 nexus is positional only").
- **Suggested fix:** rewrite the example to v3 syntax (`(Compile <opus-slot-as-bare-int>)` or `(Compile (Opus 5))`). Decide whether `Compile` is a signal-level Request or a higher-level synthesis. Update §7 accordingly.

**CARC-3 (SHOULD)** — Multiple `:` colon-keyword examples in the doc:

- Line 357: `(Query (Fn :name :resolve_pattern))` — v1/v2 keyword syntax.
- Line 376: `(Mutate (Fn :slot 42 :body (Block …)))` — same.
- Line 398: `(Assert / Mutate / Patch)` — Patch gone.
- Line 405: `(Compile (Opus :slot N))`.
- All these are example code and should use v3 positional syntax.

**CARC-4 (NICE)** — §3 line 152 lists "(`CriomeRequest::Assert / Mutate / Retract / Query / Compile / Subscribe / …`)". The actual enum is `Request` not `CriomeRequest`. Cosmetic.

**CARC-5 (NICE)** — §10 line 504: `**Sigil budget is closed.** Six total: ;;` — but per nexus/spec/grammar.md the count is 7 (`;;` + `#` + `~` + `!` + `?` + `*` + `@`, plus `=` as a narrow-use token). The criome arch doc was last updated before `?` and `*` were added in the delimiter rewrite (report 082).

- Lines 503–504 list `;;`, `#`, `~`, `@`, `!`, `=` — six sigils, predates the addition of `?` (validate) and `*` (subscribe).
- Per the "freeze" framing, sigils were never "frozen at six"; they grew. The framing needs updating.
- **Suggested fix:** update §10's sigil-budget claim. Match nexus/spec/grammar.md which now lists 7 sigils + 1 narrow-use token.

**CARC-6 (NICE)** — §9 lines 484–490: "delimiter-family matrix" describes 4 families: round, curly, square, *and* `< >` flow.

- Per report 082, `< >` was removed entirely. Reserved for future comparison operators.
- **Suggested fix:** drop the `< >` family from the description; align with grammar.md.

### 1.17 — `nexus/ARCHITECTURE.md` and `nexus/README.md`

**NARC-1 (MUST)** — these docs describe a daemon with `client_msg` (Heartbeat / Cancel / Resume / fallback file) framing.

- Per principle 9 (positional pairing, no correlation IDs) and principle 4 (no cross-request state on the daemon), the entire `client_msg` layer is deleted in the new design. Cancel = close socket. Heartbeat = unnecessary (UDS kernel handles liveness). Resume = "durable work belongs in sema as a record" (per reports/083).
- The whole nexus daemon `src/` tree is v1/v2 design. README.md, ARCHITECTURE.md, and src/ all describe this.
- **Suggested fix:** wholesale rewrite. Per reports/083 implementation-impact section, "Already needs rewriting (per earlier audit) — describe it as the thin text-shuttle it is, no client_msg framing."

**NARC-2 (SHOULD)** — `nexus/ARCHITECTURE.md` lines 70–78 ("Stateless modulo correlations") needs to change to "stateless except for one: each open subscription holds an event stream."

### 1.18 — `nexus/src/`

**NSRC-1 (MUST)** — `client_msg/` module, including `request.rs` (Request: Send/Heartbeat/Cancel/Resume), `reply.rs` (Reply: Ack/Working/Done/Failed/Cancelled/ResumedReply/etc.), `frame.rs` (RequestId), `fallback.rs` (FallbackSpec/FallbackFormat).

- All v1/v2. Doesn't match the new design.
- **Suggested fix:** delete the `client_msg/` module entirely. The daemon takes nexus text on the socket (length-delimited, per reports/078), parses it via nota-serde-core, builds signal Request frames, sends to criome, reads signal Reply frames, renders to nexus text, writes back. No client_msg envelope.

**NSRC-2 (MUST)** — `nexus/src/lib.rs` re-exports `client_msg`. Delete.

### 1.19 — `nota/README.md`

**NOTA-1 (NICE)** — clean and aligned. Line 4 says "no keywords" — that's the broad statement of principle 6. Line 105 mentions reserved keywords `true`, `false`, `None`. These are *parser-level* keywords (specifically literal keywords for bool and Option::None). The framing is consistent — nota's "no keywords" means no syntactic/semantic dispatch keywords beyond the small fixed literal set.

- No fix needed but worth noting for the principle-6 audit below.

---

## 2 · Principle 6 clarification check

The principle: **No nexus-syntax keywords** = no privileged kind names that the parser or daemon dispatches on. Schema-level enums (RelationKind etc.) are encouraged.

### Where the rule is stated

| Location | Phrasing | Risk of broad reading |
|---|---|---|
| `nota/README.md` line 4 | "Two delimiter pairs, two string forms, two sigils, no keywords." | Low — clearly about parser-level keywords; nota has no dispatch-on-name semantics. |
| `nota/README.md` line 200 | "These tokens have meaning only in nexus (the messaging superset) and are syntax errors in pure nota" | Low — naming reserved tokens, not enums. |
| `criome/ARCHITECTURE.md` §10 line 589 | "**Sigils as last resort.** New features are delimiter-matrix slots or Pascal-named records — **never new sigils**." | **Medium** — "Pascal-named records" is correct; the framing nudges agents toward "use a record kind, not a sigil," which is right. But it doesn't explicitly say schema-level enums are encouraged. |
| `criome/ARCHITECTURE.md` §9 line 504 | "Sigil budget is closed. Six total… New features land as delimiter-matrix slots or Pascal-named records — **never new sigils**." | Same as above. |
| `reports/082` line 23 | "Verbs (all expressed by sigil × delimiter composition, **no privileged kind names**): Assert, Mutate, Retract, Validate, Query, Subscribe, Constrain, Atomic-batch." | **High risk** — "no privileged kind names" without qualification reads as "don't add kind names that mean something special to the parser." A confused agent could read it as "don't add kind enums." |
| `reports/082` line 109 | "**No new privileged kinds at the validator.** Every verb is a sigil + delimiter composition. `Together` / `Ack` / `EndOfReply` etc. were rejected during design and never made it to implementation." | **High risk** — same. "No new privileged kinds at the validator" is correct in context (don't add `Together` as a parser-dispatch kind name) but reads as "no new schema kinds period." |
| `reports/083` line 103 | "Position pairs to the request. **No correlation IDs, no new keyword kinds.**" | **Medium risk** — "no new keyword kinds" is correct (`Ack`/`EndOfReply`/`Cancelled` were rejected) but the phrasing could be misread. |
| `reports/083` line 210 | "no `(Cancel)` verb (rejected — would introduce a privileged kind name and a per-request correlation system we don't otherwise need)" | Low — the privileged-kind framing is in context. |
| `reports/083` line 353 | "Privileged reply kinds (`Ack`, `EndOfReply`, `Subscription`, `Event`, …) | Replies use existing sigil discipline; no new kinds" | **Medium risk** — "no new kinds" without "of this category" could mislead. |
| `signal/ARCHITECTURE.md` | Doesn't state principle 6 at all. | **High risk** — silence is worse than vague phrasing. The document that owns the schema-of-replies should be where this is stated clearly. |
| `nexus/spec/grammar.md` | Doesn't state principle 6 explicitly; the verbs table demonstrates the pattern (every verb = sigil × delimiter), but doesn't say "schema enums are encouraged." | **Medium risk** — implicit-only. |

### Suggested clarifying language

A single paragraph belongs in **`signal/ARCHITECTURE.md`** (most load-bearing place; the schema lives there) and **`criome/ARCHITECTURE.md` §9** (the grammar-shape section). Suggest:

> **Verbs are sigil × delimiter compositions; record kinds are data.** The set of verbs is closed (Assert, Mutate, Retract, Validate, Query, Subscribe, Atomic-batch), each authored by a delimiter and optional sigil. New verbs require new sigils or delimiters; the budget is fixed. Conversely, **record kinds — including schema-level enums like `RelationKind { DependsOn, Contains, … }` — are pure data**. Adding a typed record kind to the schema is what signal is for; it never expands the verb set or changes the parser. The "no privileged kind names" rule is about *parser/daemon dispatch*: there is no kind name that the parser treats specially (like `Together`, `Ack`, `EndOfReply`). Asserting `(RelationKind DependsOn)` is normal business; defining `enum RelationKind { … }` and registering it in `KNOWN_KINDS` is normal business.

Reports 082 and 083 don't need to be edited (they're non-durable per `feedback_arch_docs_durable_reports_not`), but the durable architecture docs do.

---

## 3 · Cross-cutting observations

### 3.1 — The nexus daemon is the single biggest piece of bit-rot.

The spec was rewritten in report 082 and the reply protocol was designed in report 083, but the implementation didn't get the memo. This is the kind of code-vs-spec drift that the `feedback_arch_docs_durable_reports_not` rule is meant to prevent — but only by writing the new design into nexus's ARCHITECTURE.md and then letting the source rot in the open. Either the source has to track the spec, or the spec needs a banner saying "the daemon hasn't been updated yet." Per the project rule "no banners; delete wrong code instead," the right move is to delete `client_msg/` and rewrite.

### 3.2 — `correlation_id` pre-dates the positional-pairing decision.

Frame.correlation_id was added when the design assumed Datomic-style request IDs. Reports 082/083 and the locked grammar removed correlation IDs in favor of FIFO + position. The wire envelope didn't follow. This is the *most subtle* bug because it works fine with `correlation_id: 1` hard-coded — until someone tries to use it for actual correlation and discovers there's no agreed convention.

### 3.3 — Tension between "skeleton-as-design" and rapid principle changes.

The skeleton-as-design rule (criome/ARCHITECTURE.md §10) says: write code to make the design compiler-checked. But this session changed enough principles that the existing code is now stale relative to the principles, and skeleton-as-design now means "the skeleton lies about what the design is." The alternative (write only prose) was rejected for good reason. The path through is: keep the skeleton, but commit to "every principle change is followed by a skeleton edit before the session ends." Right now there's drift between the grammar spec, the reports, and the skeleton.

### 3.4 — `Ok` and `Diagnostic` are halfway between sema-records and protocol-records.

Reports 083 says they're message kinds (records, but reply-only). flow.rs says `Ok` is a record but not in `KNOWN_KINDS`. They cross-cut: typed enough to be records, but not part of the schema-resolution path. There's no clear home: they're not flow-graph kinds (they're protocol replies), they're not sema records (the validator doesn't dispatch on their kind name), they're not pure language IR (they have a wire form). Pick a home. Probably `signal/src/message.rs` with a short doc on what makes a message kind distinct from a sema kind.

### 3.5 — `Slot` as a content reference in `Edge` works, but blurs principle 7.

Principle 7 says slots are an internal storage index, never user-facing. But Edge stores `from: Slot, to: Slot` — and at the wire level (RawValue::SlotRef), the *user* is referring to records by slot. The example file's comment on lines 28–29 calls out: "Slots above were assigned 100..104 by criome at write time; we reference them as bare integers here."

That's user-facing slot use. The principle as stated would forbid it. Either:
- Principle 7 needs softening: "slots are *primarily* an internal index; the wire allows slot literals for cross-record refs but the semantics are 'whatever record currently lives at this slot'."
- Or: Edge should reference content-hash, not slot. But content-hash references break under mutation (the referenced record's hash changes; the Edge becomes stale).

This is real design tension that might deserve its own report.

### 3.6 — "Patch" is dead but still mentioned everywhere.

The verb is gone (Mutate-with-pattern subsumes it). Several files still mention it. The systematic sweep (EDIT-5, SLOT-2, VAL-1, SREADME-1, CARC-1, GRAM-1) is straightforward.

### 3.7 — `nexus-schema` shelving is incomplete in code comments.

Several files reference `nexus-schema` as the home of types that now live in signal. Catch-all sweep needed.

---

## 4 · Triage prioritisation

### Must fix before any code lands

1. **NSRC-1 / NSRC-2** — delete `nexus/src/client_msg/`. The implementation is wholesale wrong relative to the spec. Until this happens, anyone implementing against the spec will hit a wall.
2. **NARC-1** — rewrite `nexus/ARCHITECTURE.md` and `nexus/README.md` to match the spec.
3. **FRAME-1 / SARCH-1** — drop `Frame.correlation_id`. No-op for current code (always `1`), but locks in the wrong design if left.
4. **EDIT-1** — drop or split `AssertOp.assigned_slot`. The genesis-as-special-case channel violates "genesis runs the same flow."
5. **EDIT-2** — review `expected_rev` per-verb. `Option<Revision>` on AssertOp is incoherent.
6. **REPLY-1** — drop dangling reference to `Event` in reply.rs comment.
7. **EX2-1** — fix snapshot-claim in patterns-and-edits.nexus.
8. **CARC-1, CARC-2, CARC-3** — sweep `Patch` and `:keyword` examples from criome/ARCHITECTURE.md.

### Should fix before next milestone

9. **FLOW-1** — drop or rename `Node.id`.
10. **FLOW-2** — reconsider `Edge.label: Option<String>`.
11. **FLOW-4** — typed `enum FlowKind` alongside `KNOWN_KINDS`.
12. **EDIT-5 + SREADME-1 + SARCH-2/3/4/5 + SLOT-2 + VAL-1** — wholesale Patch/TxnBatch/effect.rs/nexus-schema sweep across signal's prose.
13. **REPLY-2** — wire up or remove `Bindings`.
14. **REPLY-3** — re-home `Ok` (and consider `Diagnostic`) to a `message.rs` module.
15. **SARCH-3** — resolve length-prefix vs no-length-prefix contradiction between ARCHITECTURE.md / README.md / frame.rs.
16. **SLOT-1** — drop "criome-types/nexus-schema" stale comment.
17. **EFFECT-MISSING** — clean up effect.rs reference in signal/ARCHITECTURE.md.
18. **GRAM-1** — drop the word "Patch" from grammar.md.
19. **GRAM-2** — note that records require schema knowledge to read (or accept that example comments are explanatory).
20. **CARC-5 / CARC-6** — update sigil count and delimiter family list in criome arch.
21. **Principle 6 paragraph** — add the clarifying paragraph to `signal/ARCHITECTURE.md` and `criome/ARCHITECTURE.md` §9.

### Cosmetic cleanup

22. **REQ-1** — drop `Box<BatchOp>` in ValidateOp.
23. **REQ-2** — restate `Request` enum docstring positively.
24. **REPLY-4** — collapse `Outcome`/`Outcomes` into one Vec variant.
25. **VAL-2 / VAL-3** — deduplicate `RawValue::Bytes` and `RawLiteral::Bytes` (and Slot/SlotRef).
26. **HS-1** — type or drop `HandshakeRequest.client_name`.
27. **FLOW-3** — drop "Per Li 2026-04-26" attribution in flow.rs.
28. **EX1-1** — add `(Edge … None)` example or remove the Option.
29. **EX1-2** — note the implicit RelationKind direction in flow-graph.nexus.
30. **EX2-2** — explain bind-aliasing's role in the Edge example.
31. **CARC-4** — `CriomeRequest` → `Request` in §3.
32. **EDIT-3, EDIT-4** — wording cleanups in edit.rs.
33. **GRAM-3, GRAM-4** — minor grammar.md wording fixes.

---

## 5 · Five-bullet headline of worst-smelling inconsistencies

- **`nexus/src/client_msg/`** — entire daemon source tree implements the dead v1/v2 client-msg envelope (Heartbeat / Cancel / Resume / Ack / Working / Done / fallback file). Spec says none of that exists. Delete and rewrite.
- **`Frame.correlation_id`** — wire envelope still carries a correlation id and docstring still says "server echoes the value onto its reply." Locked design says replies pair to requests by FIFO position, no correlation IDs.
- **`Patch` and `TxnBatch` zombie references** — variants are deleted from `signal/src/edit.rs` but the names persist in signal/README.md, signal/ARCHITECTURE.md, signal/src/value.rs, signal/src/slot.rs, criome/ARCHITECTURE.md, nexus/spec/grammar.md, and nexus example files. Vocabulary cleanup needed.
- **`AssertOp.assigned_slot: Option<Slot>`** — backdoor for genesis seeding violates "genesis runs the same flow." Drop, or split out as a separate Request variant.
- **Principle 6 framing in reports 082/083** — "no privileged kind names" / "no new keyword kinds" needs a positive clarifying paragraph in the *durable* arch docs (signal/ARCHITECTURE.md and criome/ARCHITECTURE.md §9) saying schema-level enums are encouraged. Reports phrase the rule narrowly enough that an agent could misread it as forbidding new kinds altogether.
