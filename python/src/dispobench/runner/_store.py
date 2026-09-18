"""Durable append-only JSONL record storage."""

from __future__ import annotations

import json
import os
from pathlib import Path
from typing import Any, Mapping

from ._model import Record, RunnerError


class RecordStoreError(RunnerError):
    """Raised for malformed, duplicate, or non-serializable records."""


class JSONLRecordStore:
    """Append-only JSONL store indexed by record key for exact resume."""

    def __init__(self, path: str | Path) -> None:
        self.path = Path(path)
        self._records: list[Record] = []
        self._by_key: dict[str, Record] = {}
        self._load()

    @property
    def records(self) -> tuple[Record, ...]:
        """Return records in their persisted order."""

        return tuple(dict(record) for record in self._records)

    def get(self, key: str) -> Record | None:
        """Return a copy of the record for key, if one is persisted."""

        record = self._by_key.get(key)
        return dict(record) if record is not None else None

    def append(self, record: Mapping[str, Any]) -> None:
        """Validate, append, flush, and fsync one finished record."""

        normalized = dict(record)
        key = normalized.get("key")
        if not isinstance(key, str) or not key:
            raise RecordStoreError("a persisted record requires a non-empty string key")
        if key in self._by_key:
            raise RecordStoreError(f"duplicate record key: {key}")
        try:
            payload = json.dumps(
                normalized,
                sort_keys=True,
                separators=(",", ":"),
                ensure_ascii=False,
                allow_nan=False,
            ).encode("utf-8") + b"\n"
        except (TypeError, ValueError) as exc:
            raise RecordStoreError(f"record {key} is not valid JSON: {exc}") from exc

        self.path.parent.mkdir(parents=True, exist_ok=True)
        flags = os.O_APPEND | os.O_CREAT | os.O_WRONLY
        descriptor = os.open(self.path, flags, 0o644)
        try:
            written = 0
            while written < len(payload):
                chunk_size = os.write(descriptor, payload[written:])
                if chunk_size == 0:
                    raise RecordStoreError(f"short write while persisting record {key}")
                written += chunk_size
            os.fsync(descriptor)
        finally:
            os.close(descriptor)
        self._records.append(normalized)
        self._by_key[key] = normalized

    def _load(self) -> None:
        if not self.path.exists():
            return
        with self.path.open("r", encoding="utf-8") as handle:
            for line_number, line in enumerate(handle, start=1):
                if not line.strip():
                    continue
                try:
                    value = json.loads(line)
                except json.JSONDecodeError as exc:
                    raise RecordStoreError(
                        f"invalid JSONL at {self.path}:{line_number}: {exc.msg}"
                    ) from exc
                if not isinstance(value, dict):
                    raise RecordStoreError(
                        f"record at {self.path}:{line_number} is not an object"
                    )
                key = value.get("key")
                if not isinstance(key, str) or not key:
                    raise RecordStoreError(
                        f"record at {self.path}:{line_number} has no string key"
                    )
                if key in self._by_key:
                    raise RecordStoreError(
                        f"duplicate record key {key} at {self.path}:{line_number}"
                    )
                self._records.append(value)
                self._by_key[key] = value
