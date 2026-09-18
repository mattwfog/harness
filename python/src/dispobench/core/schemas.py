from __future__ import annotations

import json
from collections.abc import Mapping, Sequence
from dataclasses import dataclass, field
from typing import Any, ClassVar

from ._validation import (
    SchemaError,
    normalize_json,
    require_bool,
    require_datetime,
    require_exact_keys,
    require_int,
    require_mapping,
    require_sha256,
    require_str,
    require_string_tuple,
    strict_json_loads,
)


SCHEMA_VERSION = "1"


def _schema_version(data: Mapping[str, Any], path: str) -> str:
    version = require_str(data.get("schema_version", SCHEMA_VERSION), f"{path}.schema_version")
    if version != SCHEMA_VERSION:
        raise SchemaError(
            f"{path}.schema_version: unsupported version {version!r}; expected {SCHEMA_VERSION!r}"
        )
    return version


@dataclass(frozen=True, slots=True)
class ToolCall:
    name: str
    arguments: Any
    result: Any
    status: str
    duration_ms: int

    def __post_init__(self) -> None:
        require_str(self.name, "tool_call.name")
        require_str(self.status, "tool_call.status")
        require_int(self.duration_ms, "tool_call.duration_ms")
        object.__setattr__(
            self, "arguments", normalize_json(self.arguments, "tool_call.arguments")
        )
        object.__setattr__(self, "result", normalize_json(self.result, "tool_call.result"))

    def to_dict(self) -> dict[str, Any]:
        return {
            "name": self.name,
            "arguments": normalize_json(self.arguments, "tool_call.arguments"),
            "result": normalize_json(self.result, "tool_call.result"),
            "status": self.status,
            "duration_ms": self.duration_ms,
        }

    @classmethod
    def from_dict(cls, value: Mapping[str, Any]) -> ToolCall:
        data = require_mapping(value, "tool_call")
        require_exact_keys(
            data,
            required={"name", "arguments", "result", "status", "duration_ms"},
            path="tool_call",
        )
        return cls(
            name=data["name"],
            arguments=data["arguments"],
            result=data["result"],
            status=data["status"],
            duration_ms=data["duration_ms"],
        )


@dataclass(frozen=True, slots=True)
class Result:
    terminal: bool
    action: str | None
    reply: str | None

    def __post_init__(self) -> None:
        require_bool(self.terminal, "result.terminal")
        if self.action is not None:
            require_str(self.action, "result.action", nonempty=False)
        if self.reply is not None:
            require_str(self.reply, "result.reply", nonempty=False)

    def to_dict(self) -> dict[str, Any]:
        return {"terminal": self.terminal, "action": self.action, "reply": self.reply}

    @classmethod
    def from_dict(cls, value: Mapping[str, Any]) -> Result:
        data = require_mapping(value, "result")
        require_exact_keys(data, required={"terminal", "action", "reply"}, path="result")
        return cls(terminal=data["terminal"], action=data["action"], reply=data["reply"])


@dataclass(frozen=True, slots=True)
class Usage:
    input: int
    cached: int
    output: int

    def __post_init__(self) -> None:
        require_int(self.input, "usage.input")
        require_int(self.cached, "usage.cached")
        require_int(self.output, "usage.output")
        if self.cached > self.input:
            raise SchemaError("usage.cached: must not exceed usage.input")

    def to_dict(self) -> dict[str, int]:
        return {"input": self.input, "cached": self.cached, "output": self.output}

    @classmethod
    def from_dict(cls, value: Mapping[str, Any]) -> Usage:
        data = require_mapping(value, "usage")
        require_exact_keys(data, required={"input", "cached", "output"}, path="usage")
        return cls(input=data["input"], cached=data["cached"], output=data["output"])


@dataclass(frozen=True, slots=True)
class Record:
    key: str
    scenario_id: str
    family: str
    rep: int
    variant: str
    model: str
    base_url: str
    prompt_hash: str
    system_prompt: str
    history: Sequence[Mapping[str, Any]]
    tool_calls: Sequence[ToolCall]
    result: Result
    usage: Usage
    nudges: int
    seed: int
    wall_ms: int
    finished_at: str
    manifest_ref: str
    schema_version: str = SCHEMA_VERSION

    _FIELDS: ClassVar[set[str]] = {
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

    def __post_init__(self) -> None:
        for name in ("key", "scenario_id", "family", "variant", "model", "manifest_ref"):
            require_str(getattr(self, name), f"record.{name}")
        require_str(self.base_url, "record.base_url", nonempty=False)
        require_sha256(self.prompt_hash, "record.prompt_hash")
        require_str(self.system_prompt, "record.system_prompt", nonempty=False)
        require_int(self.rep, "record.rep")
        require_int(self.nudges, "record.nudges")
        require_int(self.seed, "record.seed")
        require_int(self.wall_ms, "record.wall_ms")
        require_datetime(self.finished_at, "record.finished_at")
        if self.schema_version != SCHEMA_VERSION:
            raise SchemaError(
                f"record.schema_version: unsupported version {self.schema_version!r}; "
                f"expected {SCHEMA_VERSION!r}"
            )

        if isinstance(self.history, (str, bytes)) or not isinstance(self.history, Sequence):
            raise SchemaError("record.history: must be an array of JSON objects")
        history: list[dict[str, Any]] = []
        for index, message in enumerate(self.history):
            mapping = require_mapping(message, f"record.history[{index}]")
            history.append(normalize_json(mapping, f"record.history[{index}]"))
        object.__setattr__(self, "history", tuple(history))

        if isinstance(self.tool_calls, (str, bytes)) or not isinstance(self.tool_calls, Sequence):
            raise SchemaError("record.tool_calls: must be an array")
        calls = tuple(
            item if isinstance(item, ToolCall) else ToolCall.from_dict(item)
            for item in self.tool_calls
        )
        object.__setattr__(self, "tool_calls", calls)

        if not isinstance(self.result, Result):
            object.__setattr__(self, "result", Result.from_dict(self.result))
        if not isinstance(self.usage, Usage):
            object.__setattr__(self, "usage", Usage.from_dict(self.usage))

    def to_dict(self) -> dict[str, Any]:
        return {
            "schema_version": self.schema_version,
            "key": self.key,
            "scenario_id": self.scenario_id,
            "family": self.family,
            "rep": self.rep,
            "variant": self.variant,
            "model": self.model,
            "base_url": self.base_url,
            "prompt_hash": self.prompt_hash,
            "system_prompt": self.system_prompt,
            "history": normalize_json(self.history, "record.history"),
            "tool_calls": [call.to_dict() for call in self.tool_calls],
            "result": self.result.to_dict(),
            "usage": self.usage.to_dict(),
            "nudges": self.nudges,
            "seed": self.seed,
            "wall_ms": self.wall_ms,
            "finished_at": self.finished_at,
            "manifest_ref": self.manifest_ref,
        }

    def to_json(self) -> str:
        return json.dumps(
            self.to_dict(), sort_keys=True, separators=(",", ":"), ensure_ascii=False
        )

    @classmethod
    def from_dict(cls, value: Mapping[str, Any]) -> Record:
        data = require_mapping(value, "record")
        require_exact_keys(
            data,
            required=cls._FIELDS,
            optional={"schema_version"},
            path="record",
        )
        return cls(
            **{name: data[name] for name in cls._FIELDS},
            schema_version=_schema_version(data, "record"),
        )

    @classmethod
    def from_json(cls, payload: str | bytes | bytearray) -> Record:
        return cls.from_dict(strict_json_loads(payload, "record"))


@dataclass(frozen=True, slots=True)
class Scenario:
    scenario_id: str
    family: str
    history: Sequence[Mapping[str, Any]]
    reference: Any
    system_prompt: str = ""
    metadata: Mapping[str, Any] = field(default_factory=dict)

    def __post_init__(self) -> None:
        require_str(self.scenario_id, "scenario.scenario_id")
        require_str(self.family, "scenario.family")
        require_str(self.system_prompt, "scenario.system_prompt", nonempty=False)
        if isinstance(self.history, (str, bytes)) or not isinstance(self.history, Sequence):
            raise SchemaError("scenario.history: must be an array of JSON objects")
        history: list[dict[str, Any]] = []
        for index, message in enumerate(self.history):
            history.append(
                normalize_json(
                    require_mapping(message, f"scenario.history[{index}]"),
                    f"scenario.history[{index}]",
                )
            )
        object.__setattr__(self, "history", tuple(history))
        object.__setattr__(self, "reference", normalize_json(self.reference, "scenario.reference"))
        object.__setattr__(
            self,
            "metadata",
            normalize_json(
                require_mapping(self.metadata, "scenario.metadata"), "scenario.metadata"
            ),
        )

    def to_dict(self) -> dict[str, Any]:
        return {
            "scenario_id": self.scenario_id,
            "family": self.family,
            "system_prompt": self.system_prompt,
            "history": normalize_json(self.history, "scenario.history"),
            "reference": normalize_json(self.reference, "scenario.reference"),
            "metadata": normalize_json(self.metadata, "scenario.metadata"),
        }

    @classmethod
    def from_dict(cls, value: Mapping[str, Any]) -> Scenario:
        data = require_mapping(value, "scenario")
        require_exact_keys(
            data,
            required={"scenario_id", "family", "history", "reference"},
            optional={"system_prompt", "metadata"},
            path="scenario",
        )
        return cls(
            scenario_id=data["scenario_id"],
            family=data["family"],
            system_prompt=data.get("system_prompt", ""),
            history=data["history"],
            reference=data["reference"],
            metadata=data.get("metadata", {}),
        )


@dataclass(frozen=True, slots=True)
class Corpus:
    scenarios: Sequence[Scenario]
    leak_census: int
    name: str = "corpus"
    metadata: Mapping[str, Any] = field(default_factory=dict)
    schema_version: str = SCHEMA_VERSION

    def __post_init__(self) -> None:
        require_str(self.name, "corpus.name")
        require_int(self.leak_census, "corpus.leak_census")
        if self.leak_census != 0:
            raise SchemaError("corpus.leak_census: must be 0 before a corpus is accepted")
        if self.schema_version != SCHEMA_VERSION:
            raise SchemaError(
                f"corpus.schema_version: unsupported version {self.schema_version!r}; "
                f"expected {SCHEMA_VERSION!r}"
            )
        if isinstance(self.scenarios, (str, bytes)) or not isinstance(self.scenarios, Sequence):
            raise SchemaError("corpus.scenarios: must be an array")
        scenarios = tuple(
            item if isinstance(item, Scenario) else Scenario.from_dict(item)
            for item in self.scenarios
        )
        if not scenarios:
            raise SchemaError("corpus.scenarios: must not be empty")
        ids = [scenario.scenario_id for scenario in scenarios]
        if len(ids) != len(set(ids)):
            raise SchemaError("corpus.scenarios: scenario_id values must be unique")
        object.__setattr__(self, "scenarios", scenarios)
        object.__setattr__(
            self,
            "metadata",
            normalize_json(require_mapping(self.metadata, "corpus.metadata"), "corpus.metadata"),
        )

    @property
    def families(self) -> tuple[str, ...]:
        return tuple(sorted({scenario.family for scenario in self.scenarios}))

    def to_dict(self) -> dict[str, Any]:
        return {
            "schema_version": self.schema_version,
            "name": self.name,
            "leak_census": self.leak_census,
            "scenarios": [scenario.to_dict() for scenario in self.scenarios],
            "metadata": normalize_json(self.metadata, "corpus.metadata"),
        }

    def to_json(self) -> str:
        return json.dumps(
            self.to_dict(), sort_keys=True, separators=(",", ":"), ensure_ascii=False
        )

    @classmethod
    def from_dict(cls, value: Mapping[str, Any]) -> Corpus:
        data = require_mapping(value, "corpus")
        require_exact_keys(
            data,
            required={"scenarios", "leak_census"},
            optional={"schema_version", "name", "metadata"},
            path="corpus",
        )
        return cls(
            scenarios=data["scenarios"],
            leak_census=data["leak_census"],
            name=data.get("name", "corpus"),
            metadata=data.get("metadata", {}),
            schema_version=_schema_version(data, "corpus"),
        )

    @classmethod
    def from_json(cls, payload: str | bytes | bytearray) -> Corpus:
        return cls.from_dict(strict_json_loads(payload, "corpus"))


@dataclass(frozen=True, slots=True)
class MatrixRow:
    name: str
    scenario_labels: Sequence[str]
    tags: Sequence[str] = ()
    origin: str = "portable"

    def __post_init__(self) -> None:
        require_str(self.name, "matrix_row.name")
        object.__setattr__(
            self,
            "scenario_labels",
            require_string_tuple(
                self.scenario_labels, "matrix_row.scenario_labels", nonempty=True
            ),
        )
        object.__setattr__(self, "tags", require_string_tuple(self.tags, "matrix_row.tags"))
        require_str(self.origin, "matrix_row.origin")

    def to_dict(self) -> dict[str, Any]:
        return {
            "name": self.name,
            "scenario_labels": list(self.scenario_labels),
            "tags": list(self.tags),
            "origin": self.origin,
        }

    @classmethod
    def from_dict(cls, value: Mapping[str, Any]) -> MatrixRow:
        data = require_mapping(value, "matrix_row")
        require_exact_keys(
            data,
            required={"name", "scenario_labels"},
            optional={"tags", "origin"},
            path="matrix_row",
        )
        return cls(
            name=data["name"],
            scenario_labels=data["scenario_labels"],
            tags=data.get("tags", ()),
            origin=data.get("origin", "portable"),
        )


@dataclass(frozen=True, slots=True)
class MatrixColumn:
    name: str
    detector_prefixes: Sequence[str]
    tags: Sequence[str] = ()
    origin: str = "portable"

    def __post_init__(self) -> None:
        require_str(self.name, "matrix_column.name")
        object.__setattr__(
            self,
            "detector_prefixes",
            require_string_tuple(
                self.detector_prefixes, "matrix_column.detector_prefixes", nonempty=True
            ),
        )
        object.__setattr__(self, "tags", require_string_tuple(self.tags, "matrix_column.tags"))
        require_str(self.origin, "matrix_column.origin")

    def to_dict(self) -> dict[str, Any]:
        return {
            "name": self.name,
            "detector_prefixes": list(self.detector_prefixes),
            "tags": list(self.tags),
            "origin": self.origin,
        }

    @classmethod
    def from_dict(cls, value: Mapping[str, Any]) -> MatrixColumn:
        data = require_mapping(value, "matrix_column")
        require_exact_keys(
            data,
            required={"name", "detector_prefixes"},
            optional={"tags", "origin"},
            path="matrix_column",
        )
        return cls(
            name=data["name"],
            detector_prefixes=data["detector_prefixes"],
            tags=data.get("tags", ()),
            origin=data.get("origin", "portable"),
        )


@dataclass(frozen=True, slots=True)
class Matrix:
    rows: Sequence[MatrixRow]
    columns: Sequence[MatrixColumn]
    name: str = "matrix"
    schema_version: str = SCHEMA_VERSION

    def __post_init__(self) -> None:
        require_str(self.name, "matrix.name")
        if self.schema_version != SCHEMA_VERSION:
            raise SchemaError(
                f"matrix.schema_version: unsupported version {self.schema_version!r}; "
                f"expected {SCHEMA_VERSION!r}"
            )
        if isinstance(self.rows, (str, bytes)) or not isinstance(self.rows, Sequence):
            raise SchemaError("matrix.rows: must be an array")
        if isinstance(self.columns, (str, bytes)) or not isinstance(self.columns, Sequence):
            raise SchemaError("matrix.columns: must be an array")
        rows = tuple(
            item if isinstance(item, MatrixRow) else MatrixRow.from_dict(item)
            for item in self.rows
        )
        columns = tuple(
            item if isinstance(item, MatrixColumn) else MatrixColumn.from_dict(item)
            for item in self.columns
        )
        if not rows:
            raise SchemaError("matrix.rows: must not be empty")
        if not columns:
            raise SchemaError("matrix.columns: must not be empty")
        if len({row.name for row in rows}) != len(rows):
            raise SchemaError("matrix.rows: names must be unique")
        if len({column.name for column in columns}) != len(columns):
            raise SchemaError("matrix.columns: names must be unique")
        object.__setattr__(self, "rows", rows)
        object.__setattr__(self, "columns", columns)

    def to_dict(self) -> dict[str, Any]:
        return {
            "schema_version": self.schema_version,
            "name": self.name,
            "rows": [row.to_dict() for row in self.rows],
            "columns": [column.to_dict() for column in self.columns],
        }

    def to_json(self) -> str:
        return json.dumps(
            self.to_dict(), sort_keys=True, separators=(",", ":"), ensure_ascii=False
        )

    @classmethod
    def from_dict(cls, value: Mapping[str, Any]) -> Matrix:
        data = require_mapping(value, "matrix")
        require_exact_keys(
            data,
            required={"rows", "columns"},
            optional={"schema_version", "name"},
            path="matrix",
        )
        return cls(
            rows=data["rows"],
            columns=data["columns"],
            name=data.get("name", "matrix"),
            schema_version=_schema_version(data, "matrix"),
        )

    @classmethod
    def from_json(cls, payload: str | bytes | bytearray) -> Matrix:
        return cls.from_dict(strict_json_loads(payload, "matrix"))
