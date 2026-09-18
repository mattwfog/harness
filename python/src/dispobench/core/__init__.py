"""Versioned, deterministic data contracts for dispobench."""

from ._validation import SchemaError
from .hashing import canonical_json, content_hash, hash_file, hash_files
from .lock import (
    ShapingLock,
    compare_shaping_lock,
    create_shaping_lock,
    read_shaping_lock,
    write_shaping_lock,
)
from .manifest import ModelEndpoint, RunManifest, read_manifest, write_manifest
from .schemas import (
    SCHEMA_VERSION,
    Corpus,
    Matrix,
    MatrixColumn,
    MatrixRow,
    Record,
    Result,
    Scenario,
    ToolCall,
    Usage,
)
from .validation import validate_matrix

__all__ = [
    "SCHEMA_VERSION",
    "Corpus",
    "Matrix",
    "MatrixColumn",
    "MatrixRow",
    "ModelEndpoint",
    "Record",
    "Result",
    "RunManifest",
    "Scenario",
    "SchemaError",
    "ShapingLock",
    "ToolCall",
    "Usage",
    "canonical_json",
    "compare_shaping_lock",
    "content_hash",
    "create_shaping_lock",
    "hash_file",
    "hash_files",
    "read_manifest",
    "read_shaping_lock",
    "validate_matrix",
    "write_manifest",
    "write_shaping_lock",
]
