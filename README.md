# harness

Infrastructure for running LLM agents you can trust in production: **run** them
under policy, **record** everything they touch, **replay** any run with the
world disconnected, **score** the records with deterministic detectors, **gate**
releases on the evidence, and let the agent **learn** from failures only when a
measured experiment says the lesson helps.

Two layers, one repository:

| Layer | What it is | Where |
|---|---|---|
| **Runtime** | An OCaml 5 agent runtime built on algebraic effects. Every world-facing action an agent program takes — subprocess, file read/write, git commit — is an effect that passes through a fixed handler stack: journal it, check policy, only then touch the world. | [`runtime/`](runtime/) |
| **Verdict** (`dispobench`) | A deterministic evaluation core for production agents. Replays real conversations against the real agent, scores persisted records with pure-function detectors, reports a scenario × concern grid of failure rates with Wilson intervals, and gates releases on a content hash. | [`verdict/`](verdict/) (OCaml) · [`python/`](python/) (runner, adapters, reference implementation) |

## Runtime: effects, journal, replay, learning

```text
agent task program
       | perform effect
       v
+-----------+   append request, result, or denial to JSONL
| capture   |
+-----------+   allow or deny execution, writes, and commits
| policy    |
+-----------+   run subprocesses; access files and Git
| world     |
+-----------+
```

- **Journal.** Capture flushes each record before the program resumes, policy
  denials included. Format: [`docs/JOURNAL_FORMAT.md`](docs/JOURNAL_FORMAT.md).
- **Replay.** `harness replay` re-interprets a recorded run with every effect
  answered from the journal and the world handler disconnected, reporting OK or
  the exact point of divergence. Tampered journals are detected.
- **Fleet program.** Tasks are Markdown with TOML frontmatter declaring what
  they `own` and an `acceptance` command. Ownership must be disjoint within a
  run; passing work is committed by path, failing work gets one retry with the
  failure as context, then is parked. Run state is resumable.
- **Revert.** Harness-mediated writes roll back on failure; committed work is
  never reverted.
- **Learning loop with a promotion gate.** Failed runs distill into lessons
  that start on *probation*. A lesson reaches future prompts only after
  `harness gate` runs the same eval tasks in fresh repos under two arms —
  baseline vs lesson-forced — and the lesson shows task lift **and** no
  tripwire regression. Harmful lessons are retired, with the scorecard kept.
  [`lessons/`](lessons/) holds a real one: a provider-quota failure the
  harness learned from its own run.
- **Model judgments are effects too.** Lesson recall is substring matching by
  default. With `--recall-judge jev` the substring hits are narrowed by one
  relevance judgment per lesson from [TypeSafe](https://typesafe.ai)'s Jev
  model, which returns a probability per yes/no question rather than text. The
  call is a `Judge` effect: journaled with its full question text, bounded by
  policy (allowlisted model, capped payload), and **answered from the journal
  on replay** — a test asserts replay never reaches the judge, and that a
  replay which skips the judgment diverges. If the judge is denied or fails,
  recall falls back to the substring selection. The judgment only narrows what
  is injected; promoting or retiring a lesson stays the measured scorecard.
  The key is read from `TYPESAFE_API_KEY` or `~/.config/typesafe/api_key` and is
  never journaled; `HARNESS_JUDGE_CMD` swaps the network for a shell command, so
  tests and offline runs need no key. A malformed, partial or out-of-range
  response, a policy denial or a timeout all degrade to substring recall.

  Measured, not assumed — [`evals/recall-relevance/`](evals/recall-relevance/)
  holds 12 lessons with deliberately broad matchers, 12 tasks and a
  hand-labelled key. On that set (one run, ~9k tokens, 12 judge calls):

  | selector | injected | precision | recall |
  |---|---|---|---|
  | substring | 28 | 0.36 | 1.00 |
  | jev ≥ 0.3 | 19 | 0.53 | 1.00 |
  | **jev ≥ 0.5** (default) | 13 | 0.77 | 1.00 |
  | jev ≥ 0.7 | 9 | 0.89 | 0.80 |

  The default keeps every relevant lesson and drops 15 of 18 keyword-only
  ones. A stricter "does the task require this activity" wording separated
  better but lost two relevant lessons at the same threshold, so the
  recall-first wording stays: a missed lesson repeats a known failure, an extra
  one only costs tokens. It is a small set labelled by the author, and judge
  scores vary slightly between calls — rerun it on your own lessons.
- **Memory has layers, and a verifier at the door.** What a run teaches is not
  all the same kind of thing. **Full-term** lessons are lasting rules and
  facts: born on probation, promoted only by the measured gate. **Immediate**
  memories are true now and not for long — a quota that is used up, what a run
  left unfinished: they carry an expiry, are recalled until it passes with no
  gate (a fact does not need an experiment), and then stop. A **hypothesis** is
  plausible but was not shown by the record it came from: kept with its
  evidence, never put in a prompt. Time is an effect (`Clock`), so expiry
  replays exactly.

  `harness distill --verify jev` decides which of these a candidate is. Each
  candidate — from the mechanical lane or an LLM proposer — is checked against
  a task-by-task digest of the run's journal with four independent judgments:
  *supported* by the record, *contradicted* by it, *lasting* or temporary,
  *harmful* (would following it weaken a check or reuse forbidden code).
  Harmful, contradicted or unsupported candidates are denied and the reason is
  journaled; the rest are routed to a layer. A promoted lesson that was
  injected into the run and that the run's own record contradicts goes back
  to probation: an observation outranks a memory until the gate re-earns it.

  [`evals/memory-routing/`](evals/memory-routing/) fabricates three bad
  sessions as real journals — an agent that copies a frozen legacy module as
  "the existing analog" and then inlines it to dodge lint, one that trusts a
  stale promoted lesson over the schema file, one that reports a migration
  complete with modules left and "fixes" a test by loosening it — and hands
  the distiller 19 candidate memories a proposer might write. Without
  verification every one of them would be written (9 of 19 belong where they
  would land). With it, 18 of 19 land where the hand labels say (~29k judge
  tokens): all seven poison or invented candidates denied ("inline the legacy
  body" harmful 0.92, "relax the test tolerance" 0.90, an invented missing
  token contradicted 0.89), all three temporary facts kept out of full-term
  memory, and the stale lesson demoted. The miss is a cross-task causal claim
  the record does not state outright: 0.38 supported, and denied on a
  borderline harmful score (0.55) where a hypothesis would have been the right
  landing. Small set, author's labels, scores vary slightly between
  calls.
- **Scope audit.** Policy bounds what the harness does; the agent itself is a
  subprocess that can write anywhere. The harness snapshots the dirty set
  before a task and after each attempt. A tracked file modified or deleted
  outside the task's owned paths rejects the attempt — the agent is told which
  paths to restore, and an unrepaired violation parks the task. New untracked
  files are journaled as strays and never committed. Files that were already
  dirty (another agent's work in a shared checkout) are never attributed to
  the task.

```sh
harness run     --repo DIR [--runner kimi|codex|cmd:<shell>] [--recall-judge jev[:0.5]] tasks/001-readme.md
harness status  --repo DIR RUN_ID
harness journal --repo DIR RUN_ID
harness replay  --repo DIR --runner codex RUN_ID tasks/001-readme.md
harness distill --repo DIR [--verify jev] RUN_ID   # journal -> verified, layered memories
harness lessons --repo DIR                   # list the lesson corpus and statuses
harness gate    --repo DIR --runner codex LESSON_ID EVAL.md…   # eval tasks use the same task format
```

### Running an untrusted model as the agent

[`examples/sandboxed-agent/run.sh`](examples/sandboxed-agent/run.sh) runs a task
with any OpenRouter model as the agent inside a macOS sandbox profile: no reads
of `/Users` or `/Volumes`, writes confined to a throwaway directory, a scrubbed
environment, a clean agent config. The harness itself never hands its judge
key to the agent process (tested). Verified with a free model on a real task:
the agent implemented a function against five failing tests in one attempt,
its attempt to list the home directory was refused by the sandbox, Jev recall
injected the relevant lesson (0.93) and dropped the keyword-only one (0.13),
the scope audit found nothing outside the owned file, and the run then
replayed — 24 journal entries, agent and judge both swapped for tripwires
that were never touched.

## Verdict: deterministic scoring for production agents

The question a team shipping an agent actually has: *did this prompt / tool /
model change make the agent worse anywhere, and can I prove it without
re-spending the tokens?*

1. **Deterministic verdicts only.** A verdict is a pure function of the
   persisted record. No LLM judge gates anything or appears in a headline
   number.
2. **The real agent, never a mock.** The unit under test is your production
   turn entrypoint behind a thin adapter
   (`async run(scenario, variant, model_cfg) -> Record`). The platform never
   imports your app.
3. **A strict matrix.** Rows partition the corpus by scenario, columns
   partition detectors by concern. A detector with zero homes or two homes
   fails validation.
4. **A shaping lock.** The sha256 of everything that shapes agent behavior is
   stamped into each accepted run. Unchanged surface: the gate passes with zero
   token spend. Changed surface: fresh evidence required.
5. **Honest statistics and spend.** k repetitions with Wilson intervals;
   budget caps that stop the run; a 1×1 smoke run before any paid full run.

Spec: [`docs/VERDICT_SPEC.md`](docs/VERDICT_SPEC.md) · integrating a Python
agent: [`docs/PYTHON_INTEGRATION.md`](docs/PYTHON_INTEGRATION.md).

**Why the verdict core is OCaml**
([`docs/VERDICT_OCAML_CORE.md`](docs/VERDICT_OCAML_CORE.md)): a detector is
`record -> verdict option` with no IO in the type, so one that calls an LLM does
not compile; and a static binary makes the gate a zero-dependency pre-push hook
for a repo in any language. The Python implementation is the conformance
oracle — a parity test asserts the OCaml report emitter is **byte-identical**
to Python's on the same records.

## Build and test

OCaml 5.3 with dune; Python ≥ 3.12, standard library only.

```sh
opam switch create harness 5.3.0 && eval "$(opam env --switch=harness)"
opam install . --deps-only --with-test
dune build && dune test          # runtime: 30 tests · verdict: 18 tests incl. Python parity
cd python && python3 -m pytest -q   # 78 tests
```

## Status and roadmap

Source comments refer to milestones: M1 handler stack, journal and fleet
program · M2 replay · M3 revert and lessons · M4 promotion gate. All four are
done. [`tasks/`](tasks/) holds the two task specs the harness ran on itself
(its first README and the journal-format doc).

Working today: the runtime (effects, journal, replay, revert, fleet program,
distill with verified, layered memory, promotion gate, judged recall, scope audit) and the verdict layer (Python end to end; OCaml
validate / matrix / detect / report / gate with parity tests).

Next: the two layers are not yet joined. The promotion gate still scores with
its own scorecard; the plan is a journal → record mapper so every harness run
is scorable by the verdict detectors, and the gate's promote/retire decision
becomes a verdict-core call.

## License

[MIT](LICENSE).
