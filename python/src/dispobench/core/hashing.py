from __future__ import annotations

import hashlib
import json
from collections.abc import Iterable
from dataclasses import is_dataclass
from pathlib import Path
from typing import Any

from ._validation import normalize_json


def _jsonable(value: Any) -> Any:
    to_dict = getattr(value, "to_dict", None)
    if callable(to_dict):
        return to_dict()
    if is_dataclass(value):
        raise TypeError(
            f"{type(value).__name__} must define to_dict() before it can be content-hashed"
        )
    return value


def canonical_json(value: Any) -> str:
    """Serialize a JSON value deterministically, without insignificant space."""

    normalized = normalize_json(_jsonable(value))
    return json.dumps(
        normalized,
        ensure_ascii=False,
        allow_nan=False,
        sort_keys=True,
        separators=(",", ":"),
    )


def content_hash(value: Any) -> str:
    """Return the sha256 of a value's canonical UTF-8 JSON representation."""

    return hashlib.sha256(canonical_json(value).encode("utf-8")).hexdigest()


def hash_file(path: str | Path) -> str:
    """Return the sha256 of a file's exact bytes."""

    digest = hashlib.sha256()
    with Path(path).open("rb") as handle:
        for block in iter(lambda: handle.read(1024 * 1024), b""):
            digest.update(block)
    return digest.hexdigest()


def _declared_file_entries(
    paths: Iterable[str | Path], *, root: str | Path
) -> tuple[dict[str, str], ...]:
    root_path = Path(root).resolve(strict=True)
    if not root_path.is_dir():
        raise NotADirectoryError(root_path)

    entries: list[dict[str, str]] = []
    seen: set[str] = set()
    for raw_path in paths:
        declared = Path(raw_path)
        candidate = declared if declared.is_absolute() else root_path / declared
        resolved = candidate.resolve(strict=True)
        try:
            relative = resolved.relative_to(root_path)
        except ValueError as exc:
            raise ValueError(f"declared file is outside root: {raw_path}") from exc
        if not resolved.is_file():
            raise ValueError(f"declared path is not a file: {raw_path}")
        label = relative.as_posix()
        if label in seen:
            raise ValueError(f"duplicate declared file: {label}")
        seen.add(label)
        entries.append({"path": label, "sha256": hash_file(resolved)})

    if not entries:
        raise ValueError("at least one declared file is required")
    return tuple(sorted(entries, key=lambda entry: entry["path"]))


def hash_files(paths: Iterable[str | Path], *, root: str | Path = ".") -> str:
    """Hash a declared file set by stable relative path and exact file content."""

    return content_hash(_declared_file_entries(paths, root=root))
