from __future__ import annotations

import asyncio
from datetime import date
from pathlib import Path
from typing import Any

import pytest

from dispobench.core import (
    Corpus,
    Matrix,
    MatrixColumn,
    MatrixRow,
    Scenario,
    compare_shaping_lock,
    create_shaping_lock,
    read_shaping_lock,
    validate_matrix,
    write_shaping_lock,
)
from dispobench.detectors import (
    DetectorRegistry,
    empty_reply,
    markdown_in_reply,
    money_not_in_context,
    placeholder_echoed,
    protocol_no_terminal,
    reply_over_cap,
    unsanctioned_balance,
)
from dispobench.report import build_report, render_json, render_markdown
from dispobench.runner import (
    EchoAdapter,
    JSONLRecordStore,
    RunConfig,
    run_benchmark,
    select_scenarios,
)


@pytest.fixture
def fixture_corpus() -> Corpus:
    scenarios = [
        Scenario(
            scenario_id=f"billing-{index}",
            family="billing",
            system_prompt="Reply with the customer's latest message.",
            history=[
                {
                    "role": "user",
                    "content": (
                        f"My balance is ${10 + index}. "
                        "Hello {{customer_name}}."
                    ),
                }
            ],
            reference={"source": "scrubbed-human-reply"},
        )
        for index in range(4)
    ]
    scenarios.extend(
        Scenario(
            scenario_id=f"support-{index}",
            family="support",
            system_prompt="Reply with the customer's latest message.",
            history=[
                {"role": "user", "content": f"# Support request {index}"}
            ],
            reference={"source": "scrubbed-human-reply"},
        )
        for index in range(4)
    )
    return Corpus(
        name="echo-conformance",
        scenarios=scenarios,
        leak_census=0,
        metadata={"fixture": True},
    )


@pytest.fixture
def detector_registry() -> DetectorRegistry:
    registry = DetectorRegistry()
    registry.register(
        protocol_no_terminal,
        name="protocol.no_terminal",
        column_home="protocol",
        tags=("portable",),
    )
    registry.register(
        empty_reply,
        name="form.empty_reply",
        column_home="form",
        tags=("portable",),
    )
    registry.register(
        reply_over_cap(24),
        name="form.reply_over_cap",
        column_home="form",
        tags=("portable",),
    )
    registry.register(
        markdown_in_reply,
        name="form.markdown_in_reply",
        column_home="form",
        tags=("portable",),
    )
    registry.register(
        placeholder_echoed(r"\{\{customer_name\}\}"),
        name="leakage.placeholder_echoed",
        column_home="leakage",
        tags=("portable",),
    )
    registry.register(
        money_not_in_context,
        name="grounding.money_not_in_context",
        column_home="grounding",
        tags=("portable",),
    )
    registry.register(
        unsanctioned_balance(r"^VERIFIED BALANCE:"),
        name="grounding.unsanctioned_balance",
        column_home="grounding",
        tags=("portable",),
    )
    return registry


@pytest.fixture
def fixture_matrix() -> Matrix:
    return Matrix(
        name="echo-conformance",
        rows=(
            MatrixRow("billing", ("billing",)),
            MatrixRow("support", ("support",)),
        ),
        columns=(
            MatrixColumn("protocol", ("protocol.",)),
            MatrixColumn("form", ("form.",)),
            MatrixColumn("leakage", ("leakage.",)),
            MatrixColumn("grounding", ("grounding.",)),
        ),
    )


def _run(coroutine: Any) -> Any:
    return asyncio.run(coroutine)


def _sweep(
    records: tuple[dict[str, Any], ...], registry: DetectorRegistry
) -> dict[str, dict[str, bool | None]]:
    return {
        record["key"]: {
            detector.name: detector(record) for detector in registry
        }
        for record in records
    }


def _column_groups(
    matrix: Matrix, registry: DetectorRegistry
) -> dict[str, list[str]]:
    return {
        column.name: [
            detector.name for detector in registry.by_column(column.name)
        ]
        for column in matrix.columns
    }


def test_end_to_end_echo_conformance_is_reproducible(
    tmp_path: Path,
    fixture_corpus: Corpus,
    fixture_matrix: Matrix,
    detector_registry: DetectorRegistry,
) -> None:
    detector_names = tuple(detector.name for detector in detector_registry)
    assert (
        validate_matrix(fixture_matrix, fixture_corpus, detector_names)
        is fixture_matrix
    )

    scenarios = [scenario.to_dict() for scenario in fixture_corpus.scenarios]
    seed = 20260901
    first_selection = select_scenarios(scenarios, per_family=2, seed=seed)
    second_selection = select_scenarios(
        reversed(scenarios), per_family=2, seed=seed
    )
    assert [scenario["scenario_id"] for scenario in first_selection] == [
        scenario["scenario_id"] for scenario in second_selection
    ]

    config = RunConfig(
        seed=seed,
        per_family=2,
        k=2,
        variant="conformance",
        model_cfg={"model": "echo-v1", "base_url": "echo://conformance"},
        require_smoke=False,
        adapter_id="dispobench.echo.conformance",
    )
    first_path = tmp_path / "first" / "records.jsonl"
    second_path = tmp_path / "second" / "records.jsonl"
    first_summary = _run(
        run_benchmark(
            EchoAdapter(), scenarios, config, output_path=first_path
        )
    )
    second_summary = _run(
        run_benchmark(
            EchoAdapter(), reversed(scenarios), config, output_path=second_path
        )
    )

    assert first_summary.complete and second_summary.complete
    assert first_summary.record_keys == second_summary.record_keys
    first_records = JSONLRecordStore(first_path).records
    second_records = JSONLRecordStore(second_path).records
    assert first_records == second_records
    assert first_path.read_bytes() == second_path.read_bytes()

    first_verdicts = _sweep(first_records, detector_registry)
    second_verdicts = _sweep(second_records, detector_registry)
    assert first_verdicts == second_verdicts
    assert all(
        set(verdicts) == set(detector_names)
        for verdicts in first_verdicts.values()
    )

    column_groups = _column_groups(fixture_matrix, detector_registry)
    first_report = build_report(
        first_records,
        first_verdicts,
        rows=fixture_corpus.families,
        column_groups=column_groups,
    )
    second_report = build_report(
        second_records,
        second_verdicts,
        rows=reversed(fixture_corpus.families),
        column_groups=dict(reversed(tuple(column_groups.items()))),
    )

    assert first_report["record_count"] == 8
    assert any(cell["fires"] for cell in first_report["cells"])
    assert render_json(first_report).encode("utf-8") == render_json(
        second_report
    ).encode("utf-8")
    assert render_markdown(first_report).encode("utf-8") == render_markdown(
        second_report
    ).encode("utf-8")

    shaping_root = tmp_path / "repository"
    shaping_root.mkdir()
    corpus_path = shaping_root / "corpus.json"
    matrix_path = shaping_root / "matrix.json"
    corpus_path.write_text(fixture_corpus.to_json() + "\n", encoding="utf-8")
    matrix_path.write_text(fixture_matrix.to_json() + "\n", encoding="utf-8")
    lock = create_shaping_lock(
        ("matrix.json", "corpus.json"),
        run="echo-conformance-run",
        date=date(2026, 9, 1),
        root=shaping_root,
    )
    lock_path = shaping_root / "shaping.lock"
    write_shaping_lock(lock, lock_path)

    persisted_lock = read_shaping_lock(lock_path)
    assert persisted_lock == lock
    assert lock_path.read_bytes() == (lock.to_json() + "\n").encode("utf-8")
    assert compare_shaping_lock(persisted_lock, root=shaping_root)

    corpus_path.write_bytes(corpus_path.read_bytes() + b" ")
    assert not compare_shaping_lock(persisted_lock, root=shaping_root)
