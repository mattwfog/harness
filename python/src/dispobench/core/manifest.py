from __future__ import annotations

import json
import os
import tempfile
from collections.abc import Mapping, Sequence
from dataclasses import dataclass, field
from pathlib import Path
from typing import Any

from ._validation import (
    SchemaError,
    normalize_json,
    require_datetime,
    require_exact_keys,
    require_int,
    require_mapping,
    require_sha256,
    require_str,
    require_string_tuple,
    strict_json_loads,
)
from .hashing import content_hash
from .schemas import SCHEMA_VERSION


@dataclass(frozen=True, slots=True)
class ModelEndpoint:
    model: str
    base_url: str
    provider: str = "custom"
    metadata: Mapping[str, Any] = field(default_factory=dict)

    def __post_init__(self) -> None:
        require_str(self.model, "model_endpoint.model")
        require_str(self.base_url, "model_endpoint.base_url", nonempty=False)
        require_str(self.provider, "model_endpoint.provider")
        object.__setattr__(
            self,
            "metadata",
            normalize_json(
                require_mapping(self.metadata, "model_endpoint.metadata"),
                "model_endpoint.metadata",
            ),
        )

    def to_dict(self) -> dict[str, Any]:
        return {
            "model": self.model,
            "base_url": self.base_url,
            "provider": self.provider,
            "metadata": normalize_json(self.metadata, "model_endpoint.metadata"),
        }

    @classmethod
    def from_dict(cls, value: Mapping[str, Any]) -> ModelEndpoint:
        data = require_mapping(value, "model_endpoint")
        require_exact_keys(
            data,
            required={"model", "base_url"},
            optional={"provider", "metadata"},
            path="model_endpoint",
        )
        return cls(
            model=data["model"],
            base_url=data["base_url"],
            provider=data.get("provider", "custom"),
            metadata=data.get("metadata", {}),
        )


@dataclass(frozen=True, slots=True)
class RunManifest:
    run_id: str
    created_at: str
    corpus_hash: str
    matrix_hash: str
    shaping_hash: str
    seed: int
    reps: int
    variants: Sequence[str]
    models: Sequence[ModelEndpoint]
    stand_ins: Sequence[str] = ()
    contamination_risks: Sequence[str] = ()
    metadata: Mapping[str, Any] = field(default_factory=dict)
    schema_version: str = SCHEMA_VERSION

    def __post_init__(self) -> None:
        require_str(self.run_id, "manifest.run_id")
        require_datetime(self.created_at, "manifest.created_at")
        require_sha256(self.corpus_hash, "manifest.corpus_hash")
        require_sha256(self.matrix_hash, "manifest.matrix_hash")
        require_sha256(self.shaping_hash, "manifest.shaping_hash")
        require_int(self.seed, "manifest.seed")
        require_int(self.reps, "manifest.reps", minimum=1)
        object.__setattr__(
            self,
            "variants",
            require_string_tuple(self.variants, "manifest.variants", nonempty=True),
        )
        if isinstance(self.models, (str, bytes)) or not isinstance(self.models, Sequence):
            raise SchemaError("manifest.models: must be an array")
        models = tuple(
            item if isinstance(item, ModelEndpoint) else ModelEndpoint.from_dict(item)
            for item in self.models
        )
        if not models:
            raise SchemaError("manifest.models: must not be empty")
        identities = [(model.provider, model.base_url, model.model) for model in models]
        if len(identities) != len(set(identities)):
            raise SchemaError("manifest.models: endpoints must be unique")
        object.__setattr__(self, "models", models)
        object.__setattr__(
            self,
            "stand_ins",
            require_string_tuple(self.stand_ins, "manifest.stand_ins"),
        )
        object.__setattr__(
            self,
            "contamination_risks",
            require_string_tuple(
                self.contamination_risks, "manifest.contamination_risks"
            ),
        )
        object.__setattr__(
            self,
            "metadata",
            normalize_json(
                require_mapping(self.metadata, "manifest.metadata"), "manifest.metadata"
            ),
        )
        if self.schema_version != SCHEMA_VERSION:
            raise SchemaError(
                f"manifest.schema_version: unsupported version {self.schema_version!r}; "
                f"expected {SCHEMA_VERSION!r}"
            )

    def to_dict(self) -> dict[str, Any]:
        return {
            "schema_version": self.schema_version,
            "run_id": self.run_id,
            "created_at": self.created_at,
            "corpus_hash": self.corpus_hash,
            "matrix_hash": self.matrix_hash,
            "shaping_hash": self.shaping_hash,
            "seed": self.seed,
            "reps": self.reps,
            "variants": list(self.variants),
            "models": [model.to_dict() for model in self.models],
            "stand_ins": list(self.stand_ins),
            "contamination_risks": list(self.contamination_risks),
            "metadata": normalize_json(self.metadata, "manifest.metadata"),
        }

    def to_json(self) -> str:
        return json.dumps(
            self.to_dict(), sort_keys=True, separators=(",", ":"), ensure_ascii=False
        )

    @property
    def manifest_ref(self) -> str:
        return content_hash(self)

    @classmethod
    def from_dict(cls, value: Mapping[str, Any]) -> RunManifest:
        data = require_mapping(value, "manifest")
        required = {
            "run_id",
            "created_at",
            "corpus_hash",
            "matrix_hash",
            "shaping_hash",
            "seed",
            "reps",
            "variants",
            "models",
        }
        require_exact_keys(
            data,
            required=required,
            optional={
                "schema_version",
                "stand_ins",
                "contamination_risks",
                "metadata",
            },
            path="manifest",
        )
        return cls(
            run_id=data["run_id"],
            created_at=data["created_at"],
            corpus_hash=data["corpus_hash"],
            matrix_hash=data["matrix_hash"],
            shaping_hash=data["shaping_hash"],
            seed=data["seed"],
            reps=data["reps"],
            variants=data["variants"],
            models=data["models"],
            stand_ins=data.get("stand_ins", ()),
            contamination_risks=data.get("contamination_risks", ()),
            metadata=data.get("metadata", {}),
            schema_version=data.get("schema_version", SCHEMA_VERSION),
        )

    @classmethod
    def from_json(cls, payload: str | bytes | bytearray) -> RunManifest:
        return cls.from_dict(strict_json_loads(payload, "manifest"))


def write_manifest(manifest: RunManifest, path: str | Path) -> str:
    """Atomically write a canonical manifest and return its content reference."""

    if not isinstance(manifest, RunManifest):
        raise SchemaError("manifest: must be a RunManifest")
    target = Path(path)
    target.parent.mkdir(parents=True, exist_ok=True)
    payload = manifest.to_json() + "\n"
    descriptor, temporary_name = tempfile.mkstemp(prefix=f".{target.name}.", dir=target.parent)
    try:
        with os.fdopen(descriptor, "w", encoding="utf-8", newline="\n") as handle:
            handle.write(payload)
            handle.flush()
            os.fsync(handle.fileno())
        os.replace(temporary_name, target)
    except BaseException:
        try:
            os.unlink(temporary_name)
        except FileNotFoundError:
            pass
        raise
    return manifest.manifest_ref


def read_manifest(path: str | Path) -> RunManifest:
    """Read and strictly validate a run manifest."""

    return RunManifest.from_json(Path(path).read_bytes())
