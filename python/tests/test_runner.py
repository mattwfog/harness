from __future__ import annotations

import asyncio
import json
from dataclasses import replace
from datetime import datetime, timezone
from pathlib import Path
from typing import Any

import pytest

from dispobench.runner import (
    AUTAdapter,
    BudgetCaps,
    EchoAdapter,
    JSONLRecordStore,
    RecordStoreError,
    RetryAfterError,
    RunConfig,
    RunExecutionError,
    SmokeRequiredError,
    configuration_fingerprint,
    make_record_key,
    parse_retry_after,
    plan_episodes,
    run_benchmark,
    select_scenarios,
)


def _corpus(per_family: int = 3) -> list[dict[str, Any]]:
    return [
        {
            "scenario_id": f"{family}-{index}",
            "family": family,
            "system_prompt": "Be exact.",
            "history": [{"role": "user", "content": f"{family} {index}"}],
        }
        for family in ("alpha", "beta")
        for index in range(per_family)
    ]


def _config(**changes: Any) -> RunConfig:
    values: dict[str, Any] = {
        "seed": 17,
        "per_family": 2,
        "k": 2,
        "variant": "control",
        "model_cfg": {"model": "echo-1", "base_url": "echo://test"},
        "require_smoke": False,
    }
    values.update(changes)
    return RunConfig(**values)


def _run(coro: Any) -> Any:
    return asyncio.run(coro)


def test_seeded_selection_is_balanced_order_independent_and_seeded() -> None:
    corpus = _corpus(8)
    first = select_scenarios(corpus, per_family=3, seed=123)
    again = select_scenarios(reversed(corpus), per_family=3, seed=123)
    different = select_scenarios(corpus, per_family=3, seed=124)

    assert [item["scenario_id"] for item in first] == [
        item["scenario_id"] for item in again
    ]
    assert [item["scenario_id"] for item in first] != [
        item["scenario_id"] for item in different
    ]
    assert [item["family"] for item in first].count("alpha") == 3
    assert [item["family"] for item in first].count("beta") == 3


def test_selection_rejects_undersized_duplicate_and_invalid_corpora() -> None:
    with pytest.raises(ValueError, match="required"):
        select_scenarios(_corpus(1), per_family=2, seed=1)
    with pytest.raises(ValueError, match="duplicate scenario_id"):
        select_scenarios([_corpus(1)[0], _corpus(1)[0]], per_family=1, seed=1)
    with pytest.raises(ValueError, match="family"):
        select_scenarios([{"scenario_id": "missing-family"}], per_family=1, seed=1)
    with pytest.raises(ValueError, match="positive"):
        select_scenarios(_corpus(1), per_family=0, seed=1)


def test_record_keys_and_k_rep_plan_are_stable_and_config_sensitive() -> None:
    selected = select_scenarios(_corpus(1), per_family=1, seed=4)
    episodes = plan_episodes(
        selected, k=3, seed=4, variant="a", model_cfg={"model": "m"}
    )

    assert len(episodes) == 6
    assert [episode.rep for episode in episodes[:3]] == [0, 1, 2]
    assert len({episode.key for episode in episodes}) == 6
    assert episodes[0].key == make_record_key(
        str(episodes[0].scenario["scenario_id"]),
        rep=0,
        seed=4,
        variant="a",
        model_cfg={"model": "m"},
        scenario_content=episodes[0].scenario,
    )
    assert episodes[0].key != make_record_key(
        str(episodes[0].scenario["scenario_id"]),
        rep=0,
        seed=4,
        variant="b",
        model_cfg={"model": "m"},
        scenario_content=episodes[0].scenario,
    )
    changed_content = dict(episodes[0].scenario) | {"system_prompt": "Changed"}
    changed_episode = plan_episodes(
        [changed_content], k=1, seed=4, variant="a", model_cfg={"model": "m"}
    )[0]
    assert episodes[0].key != changed_episode.key


def test_config_validation_and_smoke_fingerprint_excludes_depth() -> None:
    with pytest.raises(ValueError, match="per_family"):
        _config(per_family=0)
    with pytest.raises(ValueError, match="max_requests"):
        BudgetCaps(max_requests=-1)
    with pytest.raises(ValueError, match="max_tokens"):
        BudgetCaps(max_tokens=1.5)  # type: ignore[arg-type]
    with pytest.raises(ValueError, match="max_retries"):
        _config(max_retries="three")

    config = _config()
    changed_depth = replace(config, per_family=3, k=7)
    first = configuration_fingerprint(_corpus(), config, adapter_id="adapter")
    second = configuration_fingerprint(
        reversed(_corpus()), changed_depth, adapter_id="adapter"
    )
    changed_model = configuration_fingerprint(
        _corpus(), replace(config, model_cfg={"model": "other"}), adapter_id="adapter"
    )
    assert first == second
    assert first != changed_model


def test_echo_adapter_implements_protocol_and_emits_complete_record() -> None:
    adapter = EchoAdapter()
    assert isinstance(adapter, AUTAdapter)
    scenario = _corpus(1)[0] | {"rep": 2, "seed": 99, "record_key": "record-1"}
    record = _run(
        adapter.run(
            scenario,
            "variant-a",
            {"model": "echo-model", "base_url": "echo://unit"},
        )
    )

    from dispobench.core import Record

    Record.from_dict(record)  # the echo record must satisfy the Record contract
    assert record["key"] == "record-1"
    assert record["rep"] == 2
    assert record["seed"] == 99
    assert record["result"]["reply"] == "alpha 0"
    assert record["usage"] == {"input": 0, "cached": 0, "output": 0}
    assert len(record["prompt_hash"]) == 64
    assert set(record) == {
        "key",
        "scenario_id",
        "family",
        "rep",
        "variant",
        "model",
        "base_url",
        "prompt_hash",
        "system_prompt",
        "history",
        "tool_calls",
        "result",
        "usage",
        "nudges",
        "seed",
        "wall_ms",
        "finished_at",
        "manifest_ref",
    }


def test_jsonl_store_persists_loads_copies_and_rejects_bad_records(
    tmp_path: Path,
) -> None:
    path = tmp_path / "nested" / "records.jsonl"
    store = JSONLRecordStore(path)
    store.append({"key": "one", "usage": {"input": 1, "output": 2}})
    returned = store.get("one")
    assert returned is not None
    returned["key"] = "mutated"

    loaded = JSONLRecordStore(path)
    assert loaded.get("one") == {
        "key": "one",
        "usage": {"input": 1, "output": 2},
    }
    assert loaded.records == (loaded.get("one"),)
    assert path.read_text(encoding="utf-8").endswith("\n")
    with pytest.raises(RecordStoreError, match="duplicate"):
        loaded.append({"key": "one"})
    with pytest.raises(RecordStoreError, match="requires"):
        loaded.append({"usage": {}})

    bad_path = tmp_path / "bad.jsonl"
    bad_path.write_text("not json\n", encoding="utf-8")
    with pytest.raises(RecordStoreError, match="invalid JSONL"):
        JSONLRecordStore(bad_path)


def test_runner_persists_records_and_resumes_every_key(tmp_path: Path) -> None:
    class CountingEcho(EchoAdapter):
        def __init__(self) -> None:
            self.calls = 0

        async def run(self, scenario: Any, variant: str, model_cfg: Any) -> Any:
            self.calls += 1
            return await super().run(scenario, variant, model_cfg)

    path = tmp_path / "records.jsonl"
    first_adapter = CountingEcho()
    first = _run(
        run_benchmark(first_adapter, _corpus(), _config(), output_path=path)
    )
    assert first.complete
    assert first.planned == 8
    assert first.executed == 8
    assert first.requests_used == 8
    assert first_adapter.calls == 8
    assert len(path.read_text(encoding="utf-8").splitlines()) == 8

    resumed_adapter = CountingEcho()
    resumed = _run(
        run_benchmark(resumed_adapter, reversed(_corpus()), _config(), output_path=path)
    )
    assert resumed.complete
    assert resumed.resumed == 8
    assert resumed.executed == 0
    assert resumed_adapter.calls == 0
    assert resumed.record_keys == first.record_keys


def test_partial_results_are_durable_when_a_later_episode_fails(
    tmp_path: Path,
) -> None:
    class FailSecond(EchoAdapter):
        def __init__(self) -> None:
            self.calls = 0

        async def run(self, scenario: Any, variant: str, model_cfg: Any) -> Any:
            self.calls += 1
            if self.calls == 2:
                raise RuntimeError("agent failed")
            return await super().run(scenario, variant, model_cfg)

    path = tmp_path / "partial.jsonl"
    with pytest.raises(RunExecutionError, match="agent failed") as raised:
        _run(
            run_benchmark(
                FailSecond(),
                _corpus(1),
                _config(per_family=1, k=1),
                output_path=path,
            )
        )
    assert raised.value.record_key
    assert isinstance(raised.value.cause, RuntimeError)
    assert len(JSONLRecordStore(path).records) == 1


def test_retry_after_is_honored_and_retries_count_against_requests(
    tmp_path: Path,
) -> None:
    class FlakyEcho(EchoAdapter):
        def __init__(self) -> None:
            self.calls = 0

        async def run(self, scenario: Any, variant: str, model_cfg: Any) -> Any:
            self.calls += 1
            if self.calls == 1:
                raise RetryAfterError("2.5")
            return await super().run(scenario, variant, model_cfg)

    sleeps: list[float] = []

    async def fake_sleep(delay: float) -> None:
        sleeps.append(delay)

    summary = _run(
        run_benchmark(
            FlakyEcho(),
            [_corpus(1)[0]],
            _config(per_family=1, k=1),
            output_path=tmp_path / "retry.jsonl",
            sleep=fake_sleep,
        )
    )
    assert summary.complete
    assert summary.requests_used == 2
    assert summary.executed == 1
    assert sleeps == [2.5]


def test_retry_after_parser_handles_seconds_dates_and_invalid_values() -> None:
    now = datetime(2015, 10, 21, 7, 27, 0, tzinfo=timezone.utc)
    assert parse_retry_after("12", now=now) == 12.0
    assert parse_retry_after("Wed, 21 Oct 2015 07:28:00 GMT", now=now) == 60.0
    assert parse_retry_after(-3, now=now) == 0.0
    assert parse_retry_after("not-a-date", now=now) is None
    assert parse_retry_after(None, now=now) is None


def test_request_and_token_budgets_stop_before_another_episode(
    tmp_path: Path,
) -> None:
    request_limited = _run(
        run_benchmark(
            EchoAdapter(),
            _corpus(),
            _config(budgets=BudgetCaps(max_requests=3)),
            output_path=tmp_path / "requests.jsonl",
        )
    )
    assert not request_limited.complete
    assert request_limited.stopped_reason == "request_cap"
    assert request_limited.completed == request_limited.requests_used == 3

    class TokenEcho(EchoAdapter):
        async def run(self, scenario: Any, variant: str, model_cfg: Any) -> Any:
            record = await super().run(scenario, variant, model_cfg)
            record["usage"] = {"input": 3, "cached": 1, "output": 2}
            return record

    token_limited = _run(
        run_benchmark(
            TokenEcho(),
            _corpus(),
            _config(budgets=BudgetCaps(max_tokens=5)),
            output_path=tmp_path / "tokens.jsonl",
        )
    )
    assert not token_limited.complete
    assert token_limited.stopped_reason == "token_cap"
    assert token_limited.completed == 1
    assert token_limited.tokens_used == 5


def test_retry_does_not_cross_request_cap(tmp_path: Path) -> None:
    class AlwaysPaced:
        def __init__(self) -> None:
            self.calls = 0

        async def run(self, scenario: Any, variant: str, model_cfg: Any) -> Any:
            self.calls += 1
            raise RetryAfterError(10)

    adapter = AlwaysPaced()
    sleeps: list[float] = []

    async def fake_sleep(delay: float) -> None:
        sleeps.append(delay)

    summary = _run(
        run_benchmark(
            adapter,
            [_corpus(1)[0]],
            _config(
                per_family=1,
                k=1,
                max_retries=5,
                budgets=BudgetCaps(max_requests=1),
            ),
            output_path=tmp_path / "retry-cap.jsonl",
            sleep=fake_sleep,
        )
    )
    assert summary.stopped_reason == "request_cap"
    assert summary.completed == 0
    assert summary.requests_used == adapter.calls == 1
    assert sleeps == []


def test_smoke_is_one_by_one_and_gates_matching_full_run(tmp_path: Path) -> None:
    path = tmp_path / "gated.jsonl"
    config = replace(_config(), require_smoke=True, adapter_id="echo-test")

    with pytest.raises(SmokeRequiredError, match="requires"):
        _run(run_benchmark(EchoAdapter(), _corpus(), config, output_path=path))

    smoke = _run(
        run_benchmark(EchoAdapter(), _corpus(), config, output_path=path, smoke=True)
    )
    assert smoke.complete
    assert smoke.mode == "smoke"
    assert smoke.selected == smoke.planned == smoke.executed == 2
    receipt_path = Path(f"{path}.smoke.json")
    receipt = json.loads(receipt_path.read_text(encoding="utf-8"))
    assert receipt["record_keys"] == list(smoke.record_keys)

    full = _run(run_benchmark(EchoAdapter(), _corpus(), config, output_path=path))
    assert full.complete
    assert full.mode == "full"
    assert full.planned == 8
    assert full.resumed == 2
    assert full.executed == 6

    changed = replace(config, variant="changed")
    with pytest.raises(SmokeRequiredError, match="does not match"):
        _run(run_benchmark(EchoAdapter(), _corpus(), changed, output_path=path))


def test_budget_stopped_smoke_does_not_authorize_full_run(tmp_path: Path) -> None:
    path = tmp_path / "failed-smoke.jsonl"
    config = _config(
        require_smoke=True,
        adapter_id="echo-test",
        budgets=BudgetCaps(max_requests=1),
    )
    smoke = _run(
        run_benchmark(EchoAdapter(), _corpus(), config, output_path=path, smoke=True)
    )
    assert not smoke.complete
    assert not Path(f"{path}.smoke.json").exists()
    with pytest.raises(SmokeRequiredError):
        _run(run_benchmark(EchoAdapter(), _corpus(), config, output_path=path))
