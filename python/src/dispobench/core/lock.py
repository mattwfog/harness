from __future__ import annotations

import json
import os
import tempfile
from collections.abc import Iterable, Mapping, Sequence
from dataclasses import dataclass
from datetime import date as Date
from pathlib import Path
from typing import Any

from ._validation import (
    SchemaError,
    require_date,
    require_exact_keys,
    require_mapping,
    require_sha256,
    require_str,
    require_string_tuple,
    strict_json_loads,
)
from .hashing import _declared_file_entries, content_hash, hash_files
from .schemas import SCHEMA_VERSION


@dataclass(frozen=True, slots=True)
class ShapingLock:
    sha256: str
    files: Sequence[str]
    run: str
    date: str
    schema_version: str = SCHEMA_VERSION

    def __post_init__(self) -> None:
        require_sha256(self.sha256, "shaping_lock.sha256")
        object.__setattr__(
            self,
            "files",
            require_string_tuple(self.files, "shaping_lock.files", nonempty=True),
        )
        if tuple(sorted(self.files)) != self.files:
            raise SchemaError("shaping_lock.files: must be sorted")
        require_str(self.run, "shaping_lock.run")
        require_date(self.date, "shaping_lock.date")
        if self.schema_version != SCHEMA_VERSION:
            raise SchemaError(
                f"shaping_lock.schema_version: unsupported version {self.schema_version!r}; "
                f"expected {SCHEMA_VERSION!r}"
            )

    def to_dict(self) -> dict[str, Any]:
        return {
            "schema_version": self.schema_version,
            "sha256": self.sha256,
            "files": list(self.files),
            "run": self.run,
            "date": self.date,
        }

    def to_json(self) -> str:
        return json.dumps(
            self.to_dict(), sort_keys=True, separators=(",", ":"), ensure_ascii=False
        )

    @classmethod
    def from_dict(cls, value: Mapping[str, Any]) -> ShapingLock:
        data = require_mapping(value, "shaping_lock")
        require_exact_keys(
            data,
            required={"sha256", "files", "run", "date"},
            optional={"schema_version"},
            path="shaping_lock",
        )
        return cls(
            sha256=data["sha256"],
            files=data["files"],
            run=data["run"],
            date=data["date"],
            schema_version=data.get("schema_version", SCHEMA_VERSION),
        )

    @classmethod
    def from_json(cls, payload: str | bytes | bytearray) -> ShapingLock:
        return cls.from_dict(strict_json_loads(payload, "shaping_lock"))


def create_shaping_lock(
    files: Iterable[str | Path],
    *,
    run: str,
    date: str | Date,
    root: str | Path = ".",
) -> ShapingLock:
    """Create a lock from a declared, root-relative set of shaping files."""

    date_text = date.isoformat() if isinstance(date, Date) else date
    entries = _declared_file_entries(files, root=root)
    return ShapingLock(
        sha256=content_hash(entries),
        files=tuple(entry["path"] for entry in entries),
        run=run,
        date=date_text,
    )


def write_shaping_lock(lock: ShapingLock, path: str | Path) -> None:
    """Atomically write a shaping lock in canonical JSON form."""

    if not isinstance(lock, ShapingLock):
        raise SchemaError("shaping_lock: must be a ShapingLock")
    target = Path(path)
    target.parent.mkdir(parents=True, exist_ok=True)
    descriptor, temporary_name = tempfile.mkstemp(prefix=f".{target.name}.", dir=target.parent)
    try:
        with os.fdopen(descriptor, "w", encoding="utf-8", newline="\n") as handle:
            handle.write(lock.to_json() + "\n")
            handle.flush()
            os.fsync(handle.fileno())
        os.replace(temporary_name, target)
    except BaseException:
        try:
            os.unlink(temporary_name)
        except FileNotFoundError:
            pass
        raise


def read_shaping_lock(path: str | Path) -> ShapingLock:
    """Read and strictly validate a shaping lock."""

    return ShapingLock.from_json(Path(path).read_bytes())


def compare_shaping_lock(lock: ShapingLock, *, root: str | Path = ".") -> bool:
    """Return whether every declared shaping file still matches the lock."""

    if not isinstance(lock, ShapingLock):
        raise SchemaError("shaping_lock: must be a ShapingLock")
    try:
        current = hash_files(lock.files, root=root)
    except (FileNotFoundError, NotADirectoryError, ValueError):
        return False
    return current == lock.sha256
