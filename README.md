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

```sh
harness run     --repo DIR [--runner kimi|codex|cmd:<shell>] tasks/001-readme.md
harness status  --repo DIR RUN_ID
harness journal --repo DIR RUN_ID
harness replay  --repo DIR --runner codex RUN_ID tasks/001-readme.md
harness distill --repo DIR RUN_ID            # journal -> probationary lessons
harness lessons --repo DIR                   # list the lesson corpus and statuses
harness gate    --repo DIR --runner codex LESSON_ID EVAL.md…   # eval tasks use the same task format
```

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
dune build && dune test          # runtime: 16 tests · verdict: 18 tests incl. Python parity
cd python && python3 -m pytest -q   # 78 tests
```

## Status and roadmap

Source comments refer to milestones: M1 handler stack, journal and fleet
program · M2 replay · M3 revert and lessons · M4 promotion gate. All four are
done. [`tasks/`](tasks/) holds the two task specs the harness ran on itself
(its first README and the journal-format doc).

Working today: the runtime (effects, journal, replay, revert, fleet program,
distill, promotion gate) and the verdict layer (Python end to end; OCaml
validate / matrix / detect / report / gate with parity tests).

Next: the two layers are not yet joined. The promotion gate still scores with
its own scorecard; the plan is a journal → record mapper so every harness run
is scorable by the verdict detectors, and the gate's promote/retire decision
becomes a verdict-core call.
