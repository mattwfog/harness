from __future__ import annotations

import json
import math
import re
from collections.abc import Mapping, Sequence
from datetime import date, datetime
from typing import Any, NoReturn


SHA256_RE = re.compile(r"^[0-9a-f]{64}$")


class SchemaError(ValueError):
    """Raised when persisted data does not satisfy a core contract."""


def fail(path: str, message: str) -> NoReturn:
    raise SchemaError(f"{path}: {message}")


def require_mapping(value: Any, path: str) -> Mapping[str, Any]:
    if not isinstance(value, Mapping):
        fail(path, "must be an object")
    if any(not isinstance(key, str) for key in value):
        fail(path, "object keys must be strings")
    return value


def require_exact_keys(
    value: Mapping[str, Any],
    *,
    required: set[str],
    optional: set[str] = frozenset(),
    path: str,
) -> None:
    keys = set(value)
    missing = required - keys
    unknown = keys - required - optional
    if missing:
        fail(path, f"missing fields: {', '.join(sorted(missing))}")
    if unknown:
        fail(path, f"unknown fields: {', '.join(sorted(unknown))}")


def require_str(value: Any, path: str, *, nonempty: bool = True) -> str:
    if not isinstance(value, str):
        fail(path, "must be a string")
    if nonempty and not value.strip():
        fail(path, "must not be empty")
    return value


def require_int(value: Any, path: str, *, minimum: int = 0) -> int:
    if isinstance(value, bool) or not isinstance(value, int):
        fail(path, "must be an integer")
    if value < minimum:
        fail(path, f"must be at least {minimum}")
    return value


def require_bool(value: Any, path: str) -> bool:
    if not isinstance(value, bool):
        fail(path, "must be a boolean")
    return value


def require_sha256(value: Any, path: str) -> str:
    text = require_str(value, path)
    if SHA256_RE.fullmatch(text) is None:
        fail(path, "must be a lowercase sha256 hex digest")
    return text


def require_datetime(value: Any, path: str) -> str:
    text = require_str(value, path)
    candidate = text[:-1] + "+00:00" if text.endswith("Z") else text
    try:
        parsed = datetime.fromisoformat(candidate)
    except ValueError:
        fail(path, "must be an ISO 8601 datetime")
    if parsed.tzinfo is None:
        fail(path, "must include a UTC offset")
    return text


def require_date(value: Any, path: str) -> str:
    text = require_str(value, path)
    try:
        parsed = date.fromisoformat(text)
    except ValueError:
        fail(path, "must be an ISO 8601 date")
    if parsed.isoformat() != text:
        fail(path, "must use YYYY-MM-DD format")
    return text


def require_string_tuple(value: Any, path: str, *, nonempty: bool = False) -> tuple[str, ...]:
    if isinstance(value, (str, bytes)) or not isinstance(value, Sequence):
        fail(path, "must be an array of strings")
    result = tuple(require_str(item, f"{path}[{index}]") for index, item in enumerate(value))
    if nonempty and not result:
        fail(path, "must not be empty")
    if len(result) != len(set(result)):
        fail(path, "must not contain duplicates")
    return result


def normalize_json(value: Any, path: str = "value") -> Any:
    if value is None or isinstance(value, (str, bool, int)):
        return value
    if isinstance(value, float):
        if not math.isfinite(value):
            fail(path, "must not contain NaN or infinity")
        return value
    if isinstance(value, Mapping):
        normalized: dict[str, Any] = {}
        for key, item in value.items():
            if not isinstance(key, str):
                fail(path, "object keys must be strings")
            normalized[key] = normalize_json(item, f"{path}.{key}")
        return normalized
    if isinstance(value, Sequence) and not isinstance(value, (str, bytes, bytearray)):
        return [normalize_json(item, f"{path}[{index}]") for index, item in enumerate(value)]
    fail(path, f"contains non-JSON value {type(value).__name__}")


def strict_json_loads(payload: str | bytes | bytearray, path: str = "json") -> Any:
    def reject_constant(value: str) -> NoReturn:
        fail(path, f"invalid numeric constant {value}")

    def unique_object(pairs: list[tuple[str, Any]]) -> dict[str, Any]:
        result: dict[str, Any] = {}
        for key, value in pairs:
            if key in result:
                fail(path, f"duplicate object key {key!r}")
            result[key] = value
        return result

    try:
        return json.loads(
            payload,
            parse_constant=reject_constant,
            object_pairs_hook=unique_object,
        )
    except (json.JSONDecodeError, UnicodeDecodeError) as exc:
        fail(path, f"invalid JSON: {exc}")
