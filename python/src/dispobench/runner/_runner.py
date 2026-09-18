"""Deterministic selection and durable async benchmark execution."""

from __future__ import annotations

import asyncio
import hashlib
import json
import math
import os
from collections import defaultdict
from collections.abc import Awaitable, Callable, Iterable, Mapping, Sequence
from datetime import datetime, timezone
from email.utils import parsedate_to_datetime
from pathlib import Path
from typing import Any

from ._model import (
    AUTAdapter,
    Episode,
    Record,
    RunConfig,
    RunExecutionError,
    RunSummary,
    Scenario,
    SmokeRequiredError,
)
from ._store import JSONLRecordStore, RecordStoreError


Sleep = Callable[[float], Awaitable[None]]
Clock = Callable[[], datetime]


def _canonical_json(value: Any) -> str:
    try:
        return json.dumps(
            value,
            sort_keys=True,
            separators=(",", ":"),
            ensure_ascii=False,
            allow_nan=False,
        )
    except (TypeError, ValueError) as exc:
        raise ValueError(f"value is not canonical JSON: {exc}") from exc


def _scenario_id(scenario: Scenario) -> str:
    value = scenario.get("scenario_id")
    if not isinstance(value, str) or not value:
        raise ValueError("every scenario requires a non-empty string scenario_id")
    return value


def _family(scenario: Scenario) -> str:
    value = scenario.get("family")
    if not isinstance(value, str) or not value:
        raise ValueError("every scenario requires a non-empty string family")
    return value


def _validate_scenarios(scenarios: Iterable[Scenario]) -> list[Scenario]:
    materialized = list(scenarios)
    if not materialized:
        raise ValueError("at least one scenario is required")
    seen: set[str] = set()
    for scenario in materialized:
        if not isinstance(scenario, Mapping):
            raise ValueError("every scenario must be a mapping")
        scenario_id = _scenario_id(scenario)
        _family(scenario)
        if scenario_id in seen:
            raise ValueError(f"duplicate scenario_id: {scenario_id}")
        seen.add(scenario_id)
        _canonical_json(scenario)
    return materialized


def select_scenarios(
    scenarios: Iterable[Scenario], *, per_family: int, seed: int
) -> list[Scenario]:
    """Select exactly ``per_family`` scenarios from every family reproducibly.

    Selection is independent of corpus input order and of the presence or
    absence of other families.  An undersized family is rejected instead of
    silently producing an unbalanced run.
    """

    if (
        isinstance(per_family, bool)
        or not isinstance(per_family, int)
        or per_family < 1
    ):
        raise ValueError("per_family must be a positive integer")
    if isinstance(seed, bool) or not isinstance(seed, int):
        raise ValueError("seed must be an integer")
    grouped: dict[str, list[Scenario]] = defaultdict(list)
    for scenario in _validate_scenarios(scenarios):
        grouped[_family(scenario)].append(scenario)

    selected: list[Scenario] = []
    for family in sorted(grouped):
        candidates = grouped[family]
        if len(candidates) < per_family:
            raise ValueError(
                f"family {family!r} has {len(candidates)} scenarios; "
                f"{per_family} required"
            )
        ranked = sorted(
            candidates,
            key=lambda scenario: (
                hashlib.sha256(
                    (
                        f"dispobench-selection-v1\0{seed}\0{family}\0"
                        f"{_scenario_id(scenario)}"
                    ).encode("utf-8")
                ).digest(),
                _scenario_id(scenario),
            ),
        )
        selected.extend(ranked[:per_family])
    return selected


def make_record_key(
    scenario_id: str,
    *,
    rep: int,
    seed: int,
    variant: str,
    model_cfg: Mapping[str, Any],
    scenario_content: Mapping[str, Any] | None = None,
) -> str:
    """Build a stable, content- and configuration-sensitive record key."""

    if not scenario_id:
        raise ValueError("scenario_id must be non-empty")
    if isinstance(rep, bool) or not isinstance(rep, int) or rep < 0:
        raise ValueError("rep must be a non-negative integer")
    if isinstance(seed, bool) or not isinstance(seed, int):
        raise ValueError("seed must be an integer")
    if not isinstance(variant, str) or not variant:
        raise ValueError("variant must be a non-empty string")
    if not isinstance(model_cfg, Mapping):
        raise ValueError("model_cfg must be a mapping")
    identity = {
        "scenario_id": scenario_id,
        "scenario_content": scenario_content,
        "rep": rep,
        "seed": seed,
        "variant": variant,
        "model_cfg": model_cfg,
    }
    digest = hashlib.sha256(_canonical_json(identity).encode("utf-8")).hexdigest()
    return f"{scenario_id}:r{rep}:{digest[:20]}"


def plan_episodes(
    scenarios: Sequence[Scenario],
    *,
    k: int,
    seed: int,
    variant: str,
    model_cfg: Mapping[str, Any],
) -> list[Episode]:
    """Expand selected scenarios into deterministic k-repetition episodes."""

    if isinstance(k, bool) or not isinstance(k, int) or k < 1:
        raise ValueError("k must be a positive integer")
    materialized = _validate_scenarios(scenarios)
    return [
        Episode(
            scenario=scenario,
            rep=rep,
            key=make_record_key(
                _scenario_id(scenario),
                rep=rep,
                seed=seed,
                variant=variant,
                model_cfg=model_cfg,
                scenario_content=scenario,
            ),
        )
        for scenario in materialized
        for rep in range(k)
    ]


def configuration_fingerprint(
    scenarios: Iterable[Scenario],
    config: RunConfig,
    *,
    adapter_id: str,
) -> str:
    """Hash the corpus and non-depth AUT configuration used by smoke gating."""

    corpus = _validate_scenarios(scenarios)
    ordered_corpus = sorted(corpus, key=_scenario_id)
    identity = {
        "version": 1,
        "corpus": ordered_corpus,
        "seed": config.seed,
        "variant": config.variant,
        "model_cfg": config.model_cfg,
        "adapter_id": adapter_id,
    }
    return hashlib.sha256(_canonical_json(identity).encode("utf-8")).hexdigest()


def parse_retry_after(
    value: str | int | float | None,
    *,
    now: datetime | None = None,
) -> float | None:
    """Parse Retry-After delta-seconds or an RFC 7231 HTTP-date."""

    if value is None or isinstance(value, bool):
        return None
    if isinstance(value, (int, float)):
        seconds = float(value)
        return max(0.0, seconds) if math.isfinite(seconds) else None
    text = value.strip()
    if not text:
        return None
    try:
        seconds = float(text)
    except ValueError:
        try:
            retry_at = parsedate_to_datetime(text)
        except (TypeError, ValueError, OverflowError):
            return None
        if retry_at.tzinfo is None:
            retry_at = retry_at.replace(tzinfo=timezone.utc)
        current = now or datetime.now(timezone.utc)
        if current.tzinfo is None:
            current = current.replace(tzinfo=timezone.utc)
        return max(0.0, (retry_at - current).total_seconds())
    return max(0.0, seconds) if math.isfinite(seconds) else None


async def run_benchmark(
    adapter: AUTAdapter,
    scenarios: Iterable[Scenario],
    config: RunConfig,
    *,
    output_path: str | Path,
    smoke: bool = False,
    smoke_receipt_path: str | Path | None = None,
    sleep: Sleep = asyncio.sleep,
    clock: Clock = lambda: datetime.now(timezone.utc),
) -> RunSummary:
    """Select, execute, persist, and resume a benchmark run.

    Smoke mode forces one scenario per family and one repetition.  A complete
    smoke run writes a configuration-bound receipt; full runs refuse to start
    without that receipt unless ``RunConfig.require_smoke`` is false.
    """

    corpus = _validate_scenarios(scenarios)
    adapter_id = config.adapter_id or _adapter_id(adapter)
    fingerprint = configuration_fingerprint(corpus, config, adapter_id=adapter_id)
    receipt_path = (
        Path(smoke_receipt_path)
        if smoke_receipt_path is not None
        else Path(f"{Path(output_path)}.smoke.json")
    )
    store = JSONLRecordStore(output_path)
    if not smoke and config.require_smoke:
        _require_smoke_receipt(receipt_path, fingerprint, store)

    per_family = 1 if smoke else config.per_family
    k = 1 if smoke else config.k
    selected = select_scenarios(corpus, per_family=per_family, seed=config.seed)
    episodes = plan_episodes(
        selected,
        k=k,
        seed=config.seed,
        variant=config.variant,
        model_cfg=config.model_cfg,
    )
    resumed_records = [
        record
        for episode in episodes
        if (record := store.get(episode.key)) is not None
    ]
    resumed = len(resumed_records)
    completed = resumed
    executed = 0
    requests_used = resumed
    tokens_used = sum(_record_tokens(record) for record in resumed_records)
    stopped_reason: str | None = None
    completed_keys = {str(record["key"]) for record in resumed_records}

    for episode in episodes:
        if episode.key in completed_keys:
            continue
        if _request_cap_reached(config, requests_used):
            stopped_reason = "request_cap"
            break
        if _token_cap_reached(config, tokens_used):
            stopped_reason = "token_cap"
            break

        retries = 0
        while True:
            if _request_cap_reached(config, requests_used):
                stopped_reason = "request_cap"
                break
            requests_used += 1
            try:
                raw_record = await adapter.run(
                    _adapter_scenario(episode, config.seed),
                    config.variant,
                    config.model_cfg,
                )
            except Exception as exc:
                delay = _retry_delay(exc, now=clock())
                if delay is None or retries >= config.max_retries:
                    raise RunExecutionError(episode.key, exc) from exc
                if _request_cap_reached(config, requests_used):
                    stopped_reason = "request_cap"
                    break
                retries += 1
                await sleep(delay)
                continue
            record = _normalize_record(raw_record, episode, config)
            store.append(record)
            completed_keys.add(episode.key)
            completed += 1
            executed += 1
            tokens_used += _record_tokens(record)
            break
        if stopped_reason is not None:
            break

    summary = RunSummary(
        mode="smoke" if smoke else "full",
        selected=len(selected),
        planned=len(episodes),
        completed=completed,
        resumed=resumed,
        executed=executed,
        requests_used=requests_used,
        tokens_used=tokens_used,
        stopped_reason=stopped_reason,
        record_keys=tuple(
            episode.key for episode in episodes if episode.key in completed_keys
        ),
    )
    if smoke and summary.complete:
        _write_smoke_receipt(receipt_path, fingerprint, summary.record_keys)
    return summary


def _adapter_id(adapter: AUTAdapter) -> str:
    cls = type(adapter)
    return f"{cls.__module__}.{cls.__qualname__}"


def _adapter_scenario(episode: Episode, seed: int) -> dict[str, Any]:
    value = dict(episode.scenario)
    value["record_key"] = episode.key
    value["rep"] = episode.rep
    value["seed"] = _episode_seed(seed, _scenario_id(episode.scenario), episode.rep)
    return value


def _episode_seed(seed: int, scenario_id: str, rep: int) -> int:
    digest = hashlib.sha256(
        f"dispobench-episode-seed-v1\0{seed}\0{scenario_id}\0{rep}".encode("utf-8")
    ).digest()
    return int.from_bytes(digest[:8], "big")


def _normalize_record(raw: Any, episode: Episode, config: RunConfig) -> Record:
    if not isinstance(raw, Mapping):
        raise RecordStoreError(f"adapter returned a non-object for {episode.key}")
    record = dict(raw)
    expected = {
        "key": episode.key,
        "scenario_id": _scenario_id(episode.scenario),
        "family": _family(episode.scenario),
        "rep": episode.rep,
        "variant": config.variant,
    }
    for field, value in expected.items():
        if field in record and record[field] != value:
            raise RecordStoreError(
                f"record {episode.key} has mismatched {field}: {record[field]!r}"
            )
        record[field] = value
    _record_tokens(record)
    return record


def _record_tokens(record: Mapping[str, Any]) -> int:
    usage = record.get("usage", {})
    if not isinstance(usage, Mapping):
        raise RecordStoreError(
            f"record {record.get('key', '<unknown>')} usage is not an object"
        )
    total = 0
    for field in ("input", "output"):
        value = usage.get(field, 0)
        if isinstance(value, bool) or not isinstance(value, int) or value < 0:
            raise RecordStoreError(
                f"record {record.get('key', '<unknown>')} usage.{field} "
                "must be a non-negative integer"
            )
        total += value
    return total


def _request_cap_reached(config: RunConfig, requests_used: int) -> bool:
    cap = config.budgets.max_requests
    return cap is not None and requests_used >= cap


def _token_cap_reached(config: RunConfig, tokens_used: int) -> bool:
    cap = config.budgets.max_tokens
    return cap is not None and tokens_used >= cap


def _retry_delay(exc: Exception, *, now: datetime) -> float | None:
    value: Any = getattr(exc, "retry_after", None)
    response = getattr(exc, "response", None)
    headers = getattr(response, "headers", None)
    if headers is not None:
        header_value = headers.get("Retry-After")
        if header_value is not None:
            value = header_value
    return parse_retry_after(value, now=now)


def _write_smoke_receipt(
    path: Path, fingerprint: str, record_keys: Sequence[str]
) -> None:
    payload = {
        "version": 1,
        "configuration": fingerprint,
        "record_keys": list(record_keys),
    }
    encoded = (_canonical_json(payload) + "\n").encode("utf-8")
    path.parent.mkdir(parents=True, exist_ok=True)
    temporary = path.with_name(f".{path.name}.tmp")
    with temporary.open("wb") as handle:
        handle.write(encoded)
        handle.flush()
        os.fsync(handle.fileno())
    temporary.replace(path)


def _require_smoke_receipt(
    path: Path, fingerprint: str, store: JSONLRecordStore
) -> None:
    if not path.exists():
        raise SmokeRequiredError(
            f"full run requires a passing smoke run for this configuration: {path}"
        )
    try:
        receipt = json.loads(path.read_text(encoding="utf-8"))
    except (OSError, json.JSONDecodeError) as exc:
        raise SmokeRequiredError(f"smoke receipt is not parseable: {path}") from exc
    if not isinstance(receipt, dict) or receipt.get("configuration") != fingerprint:
        raise SmokeRequiredError("smoke receipt does not match this run configuration")
    keys = receipt.get("record_keys")
    if not isinstance(keys, list) or not keys:
        raise SmokeRequiredError("smoke receipt contains no record artifacts")
    if any(not isinstance(key, str) or store.get(key) is None for key in keys):
        raise SmokeRequiredError("a smoke record artifact is missing or invalid")
