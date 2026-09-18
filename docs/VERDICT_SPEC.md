# dispobench — the reproducible, composable agent-eval platform

*(Working name. Successor-in-rigor to
[tellbench](https://github.com/mattwfog/tellbench) — different job: tellbench
measures model DISPOSITIONS on synthetic probes; dispobench measures a
PRODUCTION AGENT's behavior on its own real corpus. Extracted from the
benchmark harness of a production conversational agent, which becomes its
first adapter.)*

## Non-negotiable principles (every design choice traces to one)

P1 **Deterministic verdicts only.** A verdict is a pure function of the
   persisted record. LLM judges may exist as an optional, clearly-labeled
   annotation plugin; they are NEVER load-bearing, never gate anything,
   and never appear in a headline number.

P2 **MECE matrix, not lists.** Rows = what can be RUN (a strict partition
   of the corpus by scenario label). Columns = what is SCORED (a strict
   partition of the detector set by concern). Depth (reps, per-row count,
   variant, model) is orthogonal. Columns are always all computed; a run
   selects rows and depth only. Validation of both partitions is
   algorithmic and CI-enforced: a detector with zero homes or two homes is
   a build failure.

P3 **The real agent, never a mock.** The unit under test is the
   production agent's own turn entrypoint behind a thin adapter; the only
   permitted substitution is the model endpoint (base-url/key/model) and
   declared sandbox stand-ins, each recorded in the run manifest.

P4 **Reproducibility is a contract, not a hope.** Pinned corpus (content-
   hashed), seeded selection, per-record persistence with resume, a
   prompt_hash per record, and a SHAPING LOCK: the sha256 of the declared
   shaping surface is stamped into every accepted run; the release gate
   recomputes it — unchanged surface passes forever with zero token
   spend, changed surface demands fresh evidence. Model stochasticity is
   handled honestly: k reps + Wilson intervals, never single-shot.

P5 **Responsible spend.** The runner enforces a token/request budget and
   honors Retry-After; a smoke depth (1×1) must pass and one artifact
   must parse before any paid full run (artifact-first). Dedicated
   bench credentials, never serving credentials.

P6 **Provenance discipline (the tellbench bar).** Every reported number
   carries n, CI, and the exact records behind it; failed/partial passes
   are preserved, never deleted; every stand-in and contamination risk is
   declared in the run manifest.

## The five composable contracts (what makes it world-portable)

C1 **Record** (`record.schema.json`, versioned) — one JSON object per
   episode: `key, scenario_id, family (row), rep, variant, model,
   base_url, prompt_hash, system_prompt, history, tool_calls[{name,
   arguments, result, status, duration_ms}], result{terminal, action,
   reply}, usage{input, cached, output}, nudges, seed, wall_ms,
   finished_at, manifest_ref`. The record is the ONLY thing detectors and
   reports may read. Any agent that can emit this record can be evaluated.

C2 **Corpus** (`corpus.schema.json`) — scrubbed conversations with one
   MECE row label each + a machine-checkable scrub gate (leak census must
   read 0 before a corpus is accepted). Scenario derivation: every
   human-reference reply point becomes a scenario (input = history up to
   it, reference = what the human did).

C3 **Agent-under-test adapter** (`AUTAdapter` protocol) —
   `async run(scenario, variant, model_cfg) -> Record`. Ships with two:
   `EchoAdapter` (testing the platform itself) and, as the reference
   integration, a production-agent adapter (wraps the app's turn
   entrypoint; lives in the app's repo and imports dispobench —
   dispobench never imports the app).

C4 **Detector** — `def detect(record) -> bool | None` (None = not
   applicable), registered with metadata `{name, column_home, tags,
   origin}`. Registration REQUIRES exactly one column home (P2). A
   portable stdlib ships (protocol, form/length, markdown, placeholder
   leakage, money-not-in-context, unsanctioned-balance patterns as
   configurable rules); app-specific detectors register from the adapter
   side.

C5 **Matrix + Lock** (`matrix.schema.json`, `shaping.lock`) — the two
   partitions with tags/origin metadata per column group; the lock =
   {hash of the declared shaping-file set, run, date}; a gate CLI
   (`dispobench gate`) suitable for any repo's pre-push hook.

## Architecture (package = Codex work-package boundary)

```
src/dispobench/
  core/        C1/C2/C5 schemas, validation, manifest, lock, hashing
  runner/      seeded selection, k-reps, per-record persist+resume,
               Retry-After pacing, budget caps, smoke gate
  detectors/   C4 framework + portable stdlib + registry (one-home rule)
  report/      full-grid renderer: family × column-group, Wilson CIs,
               per-cell drill-down to records, markdown + json outputs
  cli.py       dispobench {run, report, gate, matrix, validate, smoke}
tests/         one suite per package; determinism tests (same records →
               byte-identical report); MECE enforcement tests
docs/          this spec, per-contract reference, integration guide
```

Stdlib-only + `httpx` allowed; no framework. Python ≥3.12. Every package
carries its own tests; `pytest` green is the merge bar.

## What "better than tellbench" means, concretely

tellbench's rigor (determinism-first, provenance, preserved failures,
declared contamination) PLUS: a live production agent as the subject, a
content-hash release gate wired to CI, per-record resume economics, a
strict MECE structure validated in CI, and adapter-level composability so
any team can point it at their agent + corpus in a day.

## Explicitly out of scope for v1

Multi-turn conversation simulation, prompt-mutation search, hosted UI,
non-Python adapters, any LLM-judge verdict path.
