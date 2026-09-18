# Integrating your agent with dispobench

dispobench evaluates your production turn entrypoint through a thin
`AUTAdapter`. Your adapter emits the common persisted record; deterministic
detectors and reports operate on that record without importing your
application.

The integration has four boundaries:

1. map a scrubbed copy of your conversations into a `Corpus`;
2. wrap the real agent turn in an `AUTAdapter`;
3. register pure detectors and give every detector exactly one matrix column;
4. write a shaping lock after an accepted run and check it before every push.

## Map your corpus

Create one scenario at every historical point where a human reference reply
exists. The scenario history ends immediately before that reply. Do not pass
the reference reply to the agent; it is provenance, not model input.

```python
from dispobench.core import Corpus, Scenario, content_hash


def map_conversation(conversation: dict) -> list[Scenario]:
    scenarios = []
    for index, message in enumerate(conversation["messages"]):
        if message["role"] != "human_agent":
            continue
        scenarios.append(
            Scenario(
                # Use a stable source ID and reply position, never Python hash().
                scenario_id=f"{conversation['conversation_id']}:{index}",
                family=map_mece_family(conversation, index),
                system_prompt=system_prompt_for(conversation),
                history=conversation["messages"][:index],
                reference={"reply": message["content"]},
                metadata={"source": "scrubbed-production"},
            )
        )
    return scenarios


corpus = Corpus(
    name="support-2026-09",
    scenarios=[
        scenario
        for conversation in scrubbed_conversations
        for scenario in map_conversation(conversation)
    ],
    # Set this to zero only after your separate scrub/leak census passes.
    leak_census=0,
)
print(content_hash(corpus))
```

Every scenario has exactly one `family`. Family labels must form a complete,
non-overlapping partition of the corpus. Keep IDs stable across exports and
store only JSON-compatible values. Pin the canonical `corpus.to_json()` bytes
used by a run.

The core contract verifies that `leak_census` is zero, but your integration is
responsible for performing the scrub and census. Remove credentials, personal
data, benchmark answers accidentally copied into prompts, and any data your
production agent is not allowed to see.

## Wrap the real agent

`AUTAdapter` is a structural protocol: your class does not need to inherit
from a dispobench base class. Its one method is:

```python
async def run(scenario, variant, model_cfg) -> dict:
    ...
```

The runner adds `record_key`, `rep`, and a deterministic episode `seed` to the
scenario passed to the adapter. Return those values unchanged. Call the same
production turn entrypoint that serving uses; substituting the agent with a
mock invalidates an agent evaluation. A declared model endpoint or sandbox
stand-in is allowed and belongs in the run manifest.

```python
from datetime import datetime, timezone
from time import perf_counter

from dispobench.core import Record, Result, ToolCall, Usage, content_hash


class SupportAUTAdapter:
    async def run(
        self,
        scenario: dict,
        variant: str,
        model_cfg: dict,
    ) -> dict:
        started = perf_counter()

        # Deliberately do not pass scenario["reference"], family, benchmark
        # metadata, or manifest_ref into the production agent.
        outcome = await agent_run_turn(
            system_prompt=scenario["system_prompt"],
            history=scenario["history"],
            variant=variant,
            model=model_cfg["model"],
            base_url=model_cfg["base_url"],
            seed=scenario["seed"],
        )

        record = Record(
            key=scenario["record_key"],
            scenario_id=scenario["scenario_id"],
            family=scenario["family"],
            rep=scenario["rep"],
            variant=variant,
            model=model_cfg["model"],
            base_url=model_cfg["base_url"],
            prompt_hash=content_hash(
                {
                    "system_prompt": scenario["system_prompt"],
                    "history": scenario["history"],
                }
            ),
            system_prompt=scenario["system_prompt"],
            history=scenario["history"],
            tool_calls=tuple(
                ToolCall(
                    name=call.name,
                    arguments=call.arguments,
                    result=call.result,
                    status=call.status,
                    duration_ms=call.duration_ms,
                )
                for call in outcome.tool_calls
            ),
            result=Result(
                terminal=outcome.terminal,
                action=outcome.action,
                reply=outcome.reply,
            ),
            usage=Usage(
                input=outcome.usage.input_tokens,
                cached=outcome.usage.cached_tokens,
                output=outcome.usage.output_tokens,
            ),
            nudges=outcome.nudge_count,
            seed=scenario["seed"],
            wall_ms=round((perf_counter() - started) * 1000),
            finished_at=datetime.now(timezone.utc).isoformat(),
            manifest_ref=scenario["manifest_ref"],
        )
        return record.to_dict()
```

Resolve dedicated benchmark credentials inside your application or from a
named environment variable. Never put a secret in `model_cfg`, a record, or a
manifest. Preserve tool arguments, results, status, and duration: detectors may
only use the persisted record, so missing provenance cannot be reconstructed
later.

When an endpoint asks the client to slow down, either let an exception carrying
`response.headers["Retry-After"]` escape or translate it to
`dispobench.runner.RetryAfterError`. The runner honors that delay and charges
every retry against the request budget. Other agent errors should escape so
the already-fsynced partial run remains available for diagnosis and resume.

## Define the matrix and register detectors

Rows say what can run. Columns say what is always scored. In the current
family-grid report, use one matrix row per family and make the row name equal
to the family label.

Detector names should carry a column prefix, while `column_home` names the
same column explicitly. A detector returns `True` for a violation, `False` for
an applicable pass, and `None` when it is not applicable. It must be a pure,
deterministic function of its record argument.

```python
from collections.abc import Mapping

from dispobench.core import Matrix, MatrixColumn, MatrixRow, validate_matrix
from dispobench.detectors import (
    DetectorRegistry,
    empty_reply,
    money_not_in_context,
    protocol_no_terminal,
)


def tool_error_exposed(record: dict) -> bool | None:
    result = record.get("result")
    if not isinstance(result, Mapping):
        return None
    reply = result.get("reply")
    if not isinstance(reply, str):
        return None
    for call in record.get("tool_calls", []):
        if not isinstance(call, Mapping) or call.get("status") != "error":
            continue
        tool_result = call.get("result")
        if isinstance(tool_result, str) and tool_result and tool_result in reply:
            return True
    return False


registry = DetectorRegistry()
registry.register(
    protocol_no_terminal,
    name="protocol.no_terminal",
    column_home="protocol",
    tags=("portable",),
    origin="dispobench",
)
registry.register(
    empty_reply,
    name="form.empty_reply",
    column_home="form",
    tags=("portable",),
    origin="dispobench",
)
registry.register(
    money_not_in_context,
    name="grounding.money_not_in_context",
    column_home="grounding",
    tags=("portable",),
    origin="dispobench",
)
registry.register(
    tool_error_exposed,
    name="grounding.tool_error_exposed",
    column_home="grounding",
    tags=("app-specific",),
    origin="acme-support",
)

matrix = Matrix(
    name="support",
    rows=tuple(
        MatrixRow(name=family, scenario_labels=(family,), origin="acme-support")
        for family in corpus.families
    ),
    columns=(
        MatrixColumn("protocol", ("protocol.",)),
        MatrixColumn("form", ("form.",)),
        MatrixColumn("grounding", ("grounding.",)),
    ),
)
validate_matrix(matrix, corpus, (detector.name for detector in registry))
```

`DetectorRegistry` rejects zero or multiple homes. `validate_matrix` separately
proves that row labels partition the corpus and detector-name prefixes
partition the detector set. Keep the explicit home and prefix consistent:
`grounding.tool_error_exposed` belongs to the `grounding` registry home and the
`grounding.` matrix prefix.

## Run, sweep, and report

Create the candidate shaping lock before the run so its hash can be included
in the manifest. Do not write the accepted lock yet.

```python
import asyncio
from datetime import date, datetime, timezone
from pathlib import Path

from dispobench.core import (
    ModelEndpoint,
    Record,
    RunManifest,
    content_hash,
    create_shaping_lock,
    write_manifest,
    write_shaping_lock,
)
from dispobench.report import build_report, render_json, render_markdown
from dispobench.runner import (
    BudgetCaps,
    JSONLRecordStore,
    RunConfig,
    run_benchmark,
)

root = Path.cwd()
run_id = "support-2026-09-01-001"
shaping_files = (
    "config/corpus.json",
    "config/matrix.json",
    "prompts/system.txt",
    "src/acme_agent/policy.py",
)
candidate_lock = create_shaping_lock(
    shaping_files,
    run=run_id,
    date=date.today(),
    root=root,
)
manifest = RunManifest(
    run_id=run_id,
    created_at=datetime.now(timezone.utc).isoformat(),
    corpus_hash=content_hash(corpus),
    matrix_hash=content_hash(matrix),
    shaping_hash=candidate_lock.sha256,
    seed=8128,
    reps=3,
    variants=("production",),
    models=(
        ModelEndpoint(
            model="bench-model-version",
            base_url="https://bench-endpoint.example/v1",
            provider="declared-provider",
        ),
    ),
    stand_ins=("dedicated benchmark model endpoint",),
    contamination_risks=(),
)
manifest_ref = write_manifest(manifest, root / "runs" / run_id / "manifest.json")

# The adapter records this reference but never sends it to the agent.
runner_scenarios = [
    scenario.to_dict() | {"manifest_ref": manifest_ref}
    for scenario in corpus.scenarios
]
config = RunConfig(
    seed=manifest.seed,
    per_family=10,
    k=manifest.reps,
    variant=manifest.variants[0],
    model_cfg={
        "model": manifest.models[0].model,
        "base_url": manifest.models[0].base_url,
    },
    budgets=BudgetCaps(max_requests=500, max_tokens=1_000_000),
    require_smoke=True,
    adapter_id="acme.support-agent.v1",
)
records_path = root / "runs" / run_id / "records.jsonl"
adapter = SupportAUTAdapter()

smoke = asyncio.run(
    run_benchmark(
        adapter,
        runner_scenarios,
        config,
        output_path=records_path,
        smoke=True,
    )
)
if not smoke.complete:
    raise SystemExit(f"smoke stopped: {smoke.stopped_reason}")

# Parse at least one persisted artifact before allowing paid full depth.
store = JSONLRecordStore(records_path)
if not store.records:
    raise SystemExit("smoke produced no parseable record")
Record.from_dict(store.records[0])

full = asyncio.run(
    run_benchmark(adapter, runner_scenarios, config, output_path=records_path)
)
if not full.complete:
    raise SystemExit(f"run stopped: {full.stopped_reason}")

records = JSONLRecordStore(records_path).records
for persisted_record in records:
    Record.from_dict(persisted_record)
verdicts = {
    record["key"]: {
        detector.name: detector(record) for detector in registry
    }
    for record in records
}
column_groups = {
    column.name: [
        detector.name for detector in registry.by_column(column.name)
    ]
    for column in matrix.columns
}
report = build_report(
    records,
    verdicts,
    rows=corpus.families,
    column_groups=column_groups,
)
(root / "runs" / run_id / "report.json").write_text(
    render_json(report), encoding="utf-8"
)
(root / "runs" / run_id / "report.md").write_text(
    render_markdown(report), encoding="utf-8"
)

# Apply your deterministic acceptance policy to the report first. Only an
# accepted, complete run is allowed to bless the current shaping surface.
write_shaping_lock(candidate_lock, root / "shaping.lock")
```

The runner appends and fsyncs each episode as it finishes. Relaunching the
same configuration at the same JSONL path resumes by record key. Keep partial
and failed artifacts; do not truncate them. Smoke is one scenario per family
at one repetition, and the full run requires its configuration-bound receipt.

The report sweep above is intentionally explicit. App detectors and portable
detectors have the same contract, and detector verdicts stay detached from the
immutable episode record.

## Gate every push

Track a hook such as `.githooks/pre-push` in the integrating repository:

```sh
#!/bin/sh
set -eu

dispobench_repo_root=$(git rev-parse --show-toplevel)
export DISPOBENCH_REPO_ROOT="$dispobench_repo_root"

python3 - <<'PY'
import os
from pathlib import Path

from dispobench.core import compare_shaping_lock, read_shaping_lock

root = Path(os.environ["DISPOBENCH_REPO_ROOT"])
lock = read_shaping_lock(root / "shaping.lock")
if not compare_shaping_lock(lock, root=root):
    raise SystemExit(
        "dispobench gate failed: shaping files changed; "
        "run fresh evidence before updating shaping.lock"
    )
print(f"dispobench gate passed: {lock.run} ({lock.sha256})")
PY
```

Enable the tracked hooks directory once per clone:

```sh
chmod +x .githooks/pre-push
git config core.hooksPath .githooks
```

If a pre-push hook already exists, add the gate to it instead of replacing
unrelated checks. CI should run the same comparison because local hooks can be
bypassed. Do not include `shaping.lock` itself in its declared file set, and do
not regenerate the lock merely to make the hook pass. A mismatch means the
declared shaping surface changed and fresh accepted evidence is required.

## Integration checklist

- The corpus is scrubbed, has a zero leak census, stable IDs, and one MECE
  family per scenario.
- The adapter calls the real production turn entrypoint and never exposes the
  stored reference reply to it.
- Every returned record validates against `dispobench.core.Record`; every tool
  result and stand-in needed for provenance is persisted.
- Every detector is deterministic, record-only, and has exactly one explicit
  column home plus exactly one matching matrix prefix.
- Smoke passes and emits a parseable artifact before a full run spends its
  budget.
- Repetitions, Wilson intervals, record keys, and worst examples remain in the
  report; no LLM judge contributes to a gate or headline number.
- The lock is written only after acceptance, and both pre-push and CI compare
  it against the same repository root.
