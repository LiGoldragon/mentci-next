# 092 — Cryptic naming in code: research + the rule

*Per Li 2026-04-27 — frustration with agents producing
cryptic abbreviated identifiers (`tok`, `ident`, `lex`, `de`,
`op`, `kd`, `pf`, `ctx`) that are unreadable to anyone who
isn't fluent in the in-group programmer dialect. This report
researches the roots, the cost, and lands a durable rule
into [`../AGENTS.md`](../AGENTS.md).*

---

## 1 · Historical roots — fossils from constraints that no longer apply

The cryptic-naming dialect is a fossil record. Each layer of
abbreviation was a rational response to a constraint that
no longer exists, but the layers calcified into culture
before the constraints lifted.

- **FORTRAN I (1957)**: identifiers capped at 6 characters by
  the BCD encoding on the IBM 704. FORTRAN 77 still capped
  at 6; FORTRAN 90 finally raised it to 31.
- **K&R C (1978)**: 6 significant characters guaranteed for
  external linker symbols; ANSI C (1989) raised to 6/31;
  C99 finally got to 31/63. This is why `strcpy`, `strncmp`,
  `fopen`, `fprintf`, `getc`, `sprintf` — each name a literal
  compromise with the linker.
- **Punched cards** (IBM 029, 80 columns, designed in 1928)
  and the **80-column terminal** (DEC VT100) put hard
  pressure on line width. Modern 80/100-col style rules are
  direct cultural inheritance from a card format from the
  1920s.
- **Teletype throughput** (ASR-33: 10 chars/second) made
  every keystroke cost wall-clock time. Ken Thompson on
  `creat`: "I'd spell it `creat` again." That joke ossified
  into an aesthetic. The Unix toolset (`ls`, `cp`, `mv`,
  `rm`, `cat`, `wc`, `tr`, `awk`, `sed`, `grep`) was
  optimized for the **command line as a high-frequency
  interactive surface** — but the aesthetic leaked into code.
- **Memory constraints**: symbol tables, debug-info, and
  link-time relocation records all stored full identifier
  strings. On a machine with 32K of core, identifier length
  had real cost.
- **Lisp's `car` and `cdr`** (McCarthy, 1958) come from the
  IBM 704 hardware itself ("Contents of the Address part
  of Register," "Contents of the Decrement part"). Direct
  hardware register references that survived as primitives
  after the hardware was gone.
- **Algorithms textbooks** (Knuth's TAOCP, 1968 onward; CLRS,
  1990) use single-letter names because they transcribe
  mathematics, where `n`, `i`, `j`, `f`, `g`, `x`, `y`
  carry domain-conventional meaning. Legitimate inside its
  scope; the harm comes from importing the convention into
  business logic.

**The persistence after the constraints lifted is the actual
mystery.** By 1995, identifier-length limits were gone,
terminals were 132 columns, typing was no longer the
bottleneck, memory was free. Yet the culture persisted —
because the people teaching the next generation had learned
the dialect and equated fluency-in-the-dialect with
competence. K&R itself, *Advanced Programming in the UNIX
Environment*, the *Camel Book* — each preserved the style
as the *normative* form of "real code."

---

## 2 · Cognitive science research — the literature is one-sided

- **Lawrie, Morrell, Field, Binkley (2006)**, "What's in a
  Name?" IWPC. 158 programmers asked to summarize functions
  with single-letter / abbreviated / full-word identifiers.
  **Full words yielded significantly better comprehension.**
  Effect larger for less-experienced programmers but present
  at every level.
- **Hofmeister, Siegmund, Holt (2017)**, "Shorter Identifier
  Names Take Longer to Comprehend," SANER. Words were
  **19% faster to comprehend** than letters. Direct evidence
  against the "short names are faster to read" intuition:
  short names are faster to *type* and *scan* but slower
  to *understand*.
- **Beniamini et al. (2017)**, "Meaningful Identifier Names:
  The Case of Single-Letter Variables," ICPC. Single-letter
  identifiers correlate with **higher bug density**
  controlling for complexity. Strongest effect for `l`, `o`,
  `s` (visually ambiguous) and inconsistent letters.
- **Avidan and Feitelson (2017)**, "Effects of Variable
  Names on Comprehension," ICPC. Renaming variables to
  *misleading* names hurt comprehension *more* than renaming
  to single letters — names carry meaning. Corollary:
  **a wrong abbreviation is worse than no name at all**.
- **Working-memory load**: every abbreviation imposes a
  *lookup* — the reader must mentally expand `de` to
  "deserializer" before reasoning about its role. Cowan's
  working-memory limit (~4 chunks) means a function with
  seven cryptic identifiers exceeds capacity, forcing
  re-reads — each re-read an opportunity for the wrong
  expansion.
- **The expertise gap**: experts pattern-match `ctx` →
  "context" without conscious effort because the
  abbreviation is *frozen* in their lexicon. Novices,
  non-native English speakers, dyslexic readers, and
  outsiders pay a conscious-expansion cost per occurrence.
  The expert experiences no cost and **cannot perceive the
  cost they impose on others** — the curse of knowledge
  (Camerer, Loewenstein, Weber 1989; Pinker, *The Sense
  of Style*, 2014).
- **Code is read more than written.** Knuth, *Literate
  Programming* (1984): "explaining to *human beings* what
  we want a computer to do." McConnell, *Code Complete*
  (2nd ed., 2004) §31.1: read:write ratio at least
  **10:1**, often higher. If reading dominates writing by
  10×, any optimization that saves writer-keystrokes at
  reader-cost has 10× negative ROI before bug costs are
  counted.

---

## 3 · Programming culture as in-group dialect

Cryptic naming is **a sociolect** — a dialect that signals
group membership.

- **APL** (Iverson, 1962), **K**, **J** (Whitney, 1990s)
  take terseness to its limit: a single ASCII or APL glyph
  per primitive, programs as one-liners. The community
  frames this as **virtuosity**: writing a fluid-dynamics
  simulation in 30 characters as a flex. The corollary is
  hostility to outsiders. The Wall-Street-quant culture
  around K and kdb+ explicitly uses unreadability as a moat.
- **Hacker-culture status**. Eric Raymond's *Jargon File*
  (1975 onward, codified as *The New Hacker's Dictionary*,
  1991) catalogs the lexicon and frames it as cultural
  identity. Implicit message: if you don't speak it, you
  are not one of us.
- **Gatekeeping**, intentional or not. Cryptic code is
  harder to onboard onto, harder for juniors to contribute
  to, harder for outside reviewers to audit. The senior who
  wrote it gains **information asymmetry**.

**Who gets excluded:**
- Beginners (no prior expansion lexicon)
- Non-native English speakers (`ctx` is decodable only if
  you know the English word "context")
- Dyslexic readers (abbreviated forms harder than full
  words)
- People crossing fields (a biologist auditing a
  bioinformatics pipeline written by ex-Unix-kernel hackers)
- AI agents reading code outside their training distribution

---

## 4 · What the named authorities actually say

The split between style guides tracks the audience, not the
truth. The people who've thought hardest about
software-as-communication (Knuth, McConnell, Martin) all
favor full descriptive names; the audiences who already
share the dialect (Linux kernel, K&R-influenced systems C)
tolerate brevity.

- **Robert C. Martin, *Clean Code* (2008)**, Ch. 2: "If a
  name requires a comment, then the name does not reveal
  its intent." Specifically attacks single-letter names
  outside trivially-tight scopes, encoded prefixes (`m_`),
  and unpronounceable names. **Length should match scope.**
- **Steve McConnell, *Code Complete* (2nd ed., 2004)**,
  Ch. 11. Cites empirical work showing comprehension peaks
  at **9-15 character identifiers**. "Make the name as long
  as needed." Explicitly attacks FORTRAN-era abbreviation
  conventions as cultural noise.
- **Knuth, *Literate Programming* (1984)**: TeX uses
  abbreviated identifiers but wraps them in expository
  English. The bargain: *if* your code is wrapped in prose,
  you may abbreviate aggressively. Most code isn't; the
  bargain doesn't apply.
- **Google style guides** (Java §5.3, C++): explicitly
  prohibit abbreviation except for "well-known" cases.
- **Microsoft Framework Design Guidelines** (Cwalina &
  Abrams, 2008): "**DO NOT use abbreviations or contractions
  as part of identifier names.**" Allowed acronyms only
  those that have passed into general English (HTML, XML,
  IO, UI).
- **PEP 8** (Python): "Avoid using ambiguous abbreviations."
  Strong cultural norm against `pf`-style novel
  abbreviations.
- **Rust API Guidelines**: public API names should be
  self-explanatory. Standard library follows: `HashMap`,
  `BinaryHeap`, `Iterator::collect`.
- **Linux kernel** (Linus): the famous *bounded* counter-
  example. Local short scopes can use `i`/`tmp`/`buf`;
  GLOBAL functions and variables MUST have descriptive
  names. The principle is right; generalizing the kernel's
  permissiveness to all code breaks the calibration.

The principle that threads the literature: **name length
proportional to scope, plus a strong external context the
reader can be assumed to share.** Outside those two
conditions, brevity is a tax on the reader.

---

## 5 · The counterargument — when short names work

Honesty requires naming where brevity is correct:

- **Loop counters in scopes <10 lines**: `for i in 0..n` is
  universally readable.
- **Mathematical contexts**: `x`, `y`, `z`, `theta`, `phi`,
  `lambda` when the math context is established.
- **Domain-standard symbols**: `n` for sample size in stats,
  `p` for probability — when the domain literature uses the
  symbol.
- **Generic type parameters**: `T`, `U`, `V`, `K`, `E` when
  the parameter is genuinely generic. Use a descriptive
  name when it has non-trivial semantic content.
- **Acronyms in general English**: `id`, `url`, `http`,
  `json`, `uuid`, `db`, `os`, `cpu`, `ram`, `io`, `ui`.
- **Inherited from std / well-known libraries**: `Vec`,
  `HashMap`, `Arc`, `Rc`, `Box`, `Cell`, `Mutex`, `mpsc`,
  `regex`. Do not extend the abbreviation pattern to your
  own types.

Outside these classes, brevity is a tax on the reader.

---

## 6 · The AI-agent-specific failure mode

The cryptic-naming culture is *worse* under LLM coding
assistants than under human authors:

1. **Training-corpus inheritance.** Models trained on the
   public corpus see ten million `ctx` and ten thousand
   `context`. The prior is locked toward the dialect.

2. **Pattern-matching on local context.** If the file
   already contains `lex`, the model continues with `lex`.
   The model doesn't *resist* the local dialect because
   resisting looks like style inconsistency, which the
   training signal punishes. **One cryptic identifier seeds
   an entire file of cryptic identifiers.**

3. **No cognitive-load feedback loop.** A human author who
   writes `de` and rereads it next week feels the friction
   of decoding their own abbreviation, and learns. The
   agent does not. It produces and moves on.

4. **The "looks like real code" trap.** Cryptic naming
   passes aesthetic muster precisely because it matches the
   appearance of professional code. The reviewer sees
   `let kd = pf.parse_kind_decl(tok)?;` and thinks "yes,
   that looks like real Rust" — because real Rust written
   in the dialect looks exactly like that.

5. **Throughput asymmetry.** An agent produces 500 lines of
   cryptically-named code in 90 seconds; a reviewer needs
   minutes per function to decode it. The historical
   rate-limiter (writer's time-cost) is gone.

The compounding effect: each agent-produced file becomes
training data for the next agent. Without an explicit
anti-dialect rule, the system runs away.

---

## 7 · Real-world cost

- **Onboarding**: 2-5× longer for juniors / outsiders to
  reach functional understanding.
- **Bug rate**: ~15% higher defect density in functions with
  single-letter / heavily-abbreviated locals (Beniamini
  2017), controlling for complexity.
- **Code review productivity**: reviewers either skip
  ("LGTM") or stall (decoding every name). Both fail.
- **Knowledge-transfer failure**: when the original author
  leaves, the next maintainer inherits a dialect they have
  to learn before they can change anything. This is the
  typical mechanism behind "we can't touch this module" in
  long-lived systems.
- **The asymmetry**: writer saves 5-10 keystrokes per
  identifier, ~30 seconds per file. Each reader, over the
  codebase's life, pays 5-30 seconds *per occurrence* in
  cognitive load. With read:write ≥ 10:1 and N readers ≥ 1,
  the ROI is deeply negative.

---

## 8 · The rule (lands in AGENTS.md)

The rule is positive-default with named exceptions, calibrated
to be enforceable without being absurd. Full block reproduced
here; identical text added to [`../AGENTS.md`](../AGENTS.md).

---

> ### Naming — full words by default
>
> Identifiers are read far more than they are written.
> Cryptic abbreviations optimize for the writer (a few
> keystrokes saved) at the reader's expense (one mental
> lookup per occurrence). The empirical literature is
> unanimous on this; the cultural inertia toward `ctx` /
> `tok` / `de` / `pf` is fossil from 6-char FORTRAN, 80-
> column cards, and 10-cps teletypes — none of which still
> apply.
>
> **Default: spell every identifier as full English words.**
>
> Examples (bad → good):
>
> | bad | good |
> |---|---|
> | `lex` | `lexer` |
> | `tok` | `token` |
> | `ident` | `identifier` |
> | `op` | `operation` (or specific: `assert_op`) |
> | `de` | `deserializer` |
> | `kd` | `kind_decl` (or `KindDecl`) |
> | `pf` | `pattern_field` |
> | `ctx` | `context` (or specific: `parse_context`) |
> | `cfg` | `config` (or `configuration`) |
> | `addr` | `address` |
> | `buf` | `buffer` |
> | `tmp` | `temporary` (or — better — name what it holds) |
> | `arr` | `array` (or — better — what it contains) |
> | `obj` | (name what it actually is) |
> | `params` | `parameters` |
> | `args` | `arguments` |
> | `vars` | `variables` |
> | `proc` | `procedure` or `process` |
> | `calc` | `calculate` |
> | `init` | `initialize` |
> | `repr` | `representation` |
> | `gen` | `generate` or `generator` |
> | `ser` / `deser` | `serialize` / `deserialize` |
> | `fn` (in identifier) | `function` (the `fn` *keyword* is fine) |
> | `impl` (in identifier) | `implementation` (the `impl` *keyword* is fine) |
>
> #### Permitted exceptions — tight, named, no others
>
> 1. **Loop counters in tight scopes (<10 lines).**
>    `for i in 0..n { ... }` is fine. Beyond ~10 lines or
>    nested, use descriptive names.
> 2. **Mathematical contexts** where the math itself uses
>    the symbol. `x`, `y`, `z`, `theta`, `phi`, `lambda`,
>    `n` for sample size, `p` for probability — only when
>    the surrounding code or comment establishes the math
>    context.
> 3. **Generic type parameters.** `T`, `U`, `V`, `K`, `E`.
>    Use a descriptive name when the parameter has
>    non-trivial semantic content.
> 4. **Acronyms that have passed into general English.**
>    `id`, `url`, `http`, `json`, `uuid`, `db`, `os`,
>    `cpu`, `ram`, `io`, `ui`, `tcp`, `udp`, `dns`. Spell
>    them when ambiguous in context.
> 5. **Names inherited from std / well-known libraries.**
>    `Vec`, `HashMap`, `Arc`, `Rc`, `Box`, `Cell`,
>    `RefCell`, `Mutex`, `mpsc`, `regex`. Do not rename
>    these; do *not* extend the abbreviation pattern to
>    your own types.
> 6. **Domain-standard short names already documented in an
>    ARCHITECTURE.md.** `slot`, `opus`, `node`, `frame` are
>    full words and need no exception. If a true short
>    form is load-bearing in the schema, name it in
>    ARCHITECTURE.md so the exception is explicit;
>    otherwise spell it out.
>
> #### Rule of thumb (Martin / Linus, combined)
>
> **Name length proportional to scope.** A 3-line loop
> counter can be `i`. A module-level type that appears
> across the codebase must spell itself out. A function
> parameter that lives for 50 lines must read as English.
>
> #### What this rule is NOT
>
> - Not "verbose names everywhere" —
>   `calculate_the_total_amount_of_items` is worse than
>   `total_items`. The goal is *clear*, not *long*.
> - Not "no acronyms ever" — see exception 4.
> - Not "rewrite std" — see exception 5.
>
> #### How to apply when generating code
>
> When generating new code: **spell identifiers as full
> English words by default.** When the surrounding code
> uses cryptic identifiers: do not propagate them into new
> code. Either rename (if rename is in scope) or use the
> full form for new identifiers and flag the inconsistency
> as a follow-up. Pattern-matching the local dialect is
> exactly the failure mode this rule exists to break.

---

## 9 · Notes on enforcement

This rule is *positive default + named exceptions* — the
shape that's enforceable. Reviewers can point at any
identifier outside the six exception classes and say "spell
this out." Agents producing code can be reminded by pointing
at the rule.

The rule does not need a linter to be effective; it needs
*reviewer enforcement*. The mechanism that breaks the AI-
runaway loop is human reviewers refusing to accept cryptic
identifiers, plus agents (per the explicit instruction in
"How to apply") not propagating the local dialect.

The rule lives in [`../AGENTS.md`](../AGENTS.md) — the
highest-priority file for agent behavior across all repos in
the workspace. Per the AGENTS.md / CLAUDE.md shim pattern,
Claude Code reads AGENTS.md (via the CLAUDE.md one-liner) and
will see this rule on every session start.

---

*End 092.*
