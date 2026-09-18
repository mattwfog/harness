"""Command-line wiring for dispobench's portable contracts.

The CLI intentionally keeps application code outside dispobench.  Agent
adapters and detector registries are loaded from ``module:attribute``
references, with ``echo`` available as an explicit platform-test adapter.
"""

from __future__ import annotations

import argparse
import asyncio
from collections.abc import Iterable, Mapping, Sequence
from dataclasses import asdict
import importlib
import inspect
import json
import os
from pathlib import Path
import sys
import tempfile
from typing import Any

from dispobench.core import (
    Corpus,
    Matrix,
    Record,
    RunManifest,
    ShapingLock,
    compare_shaping_lock,
    read_manifest,
    read_shaping_lock,
    validate_matrix,
)
from dispobench.detectors import DetectorRegistry, RegisteredDetector
from dispobench.report import build_report, render_json, render_markdown
from dispobench.runner import BudgetCaps, EchoAdapter, RunConfig, run_benchmark


__all__ = ["main"]

_VERSION = "0.1.0"
_VALIDATION_KINDS = ("auto", "corpus", "matrix", "record", "records", "manifest", "lock")


def _positive_int(value: str) -> int:
    try:
        parsed = int(value)
    except ValueError as exc:
        raise argparse.ArgumentTypeError("must be an integer") from exc
    if parsed < 1:
        raise argparse.ArgumentTypeError("must be a positive integer")
    return parsed


def _non_negative_int(value: str) -> int:
    try:
        parsed = int(value)
    except ValueError as exc:
        raise argparse.ArgumentTypeError("must be an integer") from exc
    if parsed < 0:
        raise argparse.ArgumentTypeError("must be a non-negative integer")
    return parsed


def _add_execution_arguments(parser: argparse.ArgumentParser) -> None:
    parser.add_argument("corpus", type=Path, help="validated corpus JSON")
    parser.add_argument("-o", "--output", type=Path, required=True, help="append-only record JSONL")
    parser.add_argument(
        "--adapter",
        required=True,
        help="AUT adapter as module:attribute, or the explicit 'echo' test adapter",
    )
    parser.add_argument("--seed", type=int, default=0, help="selection seed (default: 0)")
    parser.add_argument(
        "--per-family",
        type=_positive_int,
        default=1,
        help="scenarios selected per family for a full run (default: 1)",
    )
    parser.add_argument(
        "-k",
        "--reps",
        type=_positive_int,
        default=1,
        help="repetitions per selected scenario for a full run (default: 1)",
    )
    parser.add_argument("--variant", default="baseline", help="agent variant name")
    parser.add_argument(
        "--model-config",
        help="model configuration as a JSON object, a JSON file, or @FILE",
    )
    parser.add_argument("--model", help="override model_config.model")
    parser.add_argument("--base-url", help="override model_config.base_url")
    parser.add_argument("--max-requests", type=_non_negative_int)
    parser.add_argument("--max-tokens", type=_non_negative_int)
    parser.add_argument("--max-retries", type=_non_negative_int, default=3)
    parser.add_argument("--adapter-id", help="stable adapter identity used by smoke gating")
    parser.add_argument(
        "--smoke-receipt",
        type=Path,
        help="receipt path (default: OUTPUT.smoke.json)",
    )
    parser.add_argument(
        "--no-require-smoke",
        action="store_true",
        help="allow a full run without a matching smoke receipt",
    )


def _build_parser() -> argparse.ArgumentParser:
    parser = argparse.ArgumentParser(
        prog="dispobench",
        description="Reproducible, composable evaluation for production agents.",
    )
    parser.add_argument("--version", action="version", version=f"%(prog)s {_VERSION}")
    commands = parser.add_subparsers(dest="command", required=True)

    run_parser = commands.add_parser("run", help="run a full, resumable benchmark")
    _add_execution_arguments(run_parser)
    run_parser.set_defaults(handler=_command_run, smoke=False)

    smoke_parser = commands.add_parser(
        "smoke", help="run one scenario per family once and write a smoke receipt"
    )
    _add_execution_arguments(smoke_parser)
    smoke_parser.set_defaults(handler=_command_run, smoke=True)

    report_parser = commands.add_parser(
        "report", help="score persisted records and render the complete matrix"
    )
    report_parser.add_argument("records", type=Path, help="record JSONL")
    report_parser.add_argument("matrix", type=Path, help="matrix JSON")
    scoring = report_parser.add_mutually_exclusive_group(required=True)
    scoring.add_argument(
        "--detectors",
        help="DetectorRegistry (or factory) as module:attribute",
    )
    scoring.add_argument(
        "--verdicts",
        "--detector-results",
        dest="verdicts",
        type=Path,
        help="detached detector-verdict JSON",
    )
    report_parser.add_argument(
        "--detector",
        action="append",
        default=[],
        help="declare a detector name absent from a verdict file (repeatable)",
    )
    report_parser.add_argument(
        "--format", choices=("markdown", "json"), default="markdown"
    )
    report_parser.add_argument("-o", "--output", type=Path)
    report_parser.add_argument("--json-out", type=Path)
    report_parser.add_argument("--markdown-out", type=Path)
    report_parser.add_argument("--worst-examples", type=_non_negative_int, default=3)
    report_parser.set_defaults(handler=_command_report)

    gate_parser = commands.add_parser(
        "gate", help="recompute and compare a shaping lock"
    )
    gate_parser.add_argument(
        "lock", nargs="?", type=Path, default=Path("shaping.lock"), help="shaping lock JSON"
    )
    gate_parser.add_argument(
        "--root", type=Path, default=Path("."), help="root for declared shaping files"
    )
    gate_parser.set_defaults(handler=_command_gate)

    matrix_parser = commands.add_parser(
        "matrix", help="validate the corpus and detector MECE partitions"
    )
    matrix_parser.add_argument("matrix", type=Path, help="matrix JSON")
    matrix_parser.add_argument("corpus", type=Path, help="corpus JSON")
    detector_source = matrix_parser.add_mutually_exclusive_group(required=True)
    detector_source.add_argument(
        "--detectors", help="DetectorRegistry (or factory) as module:attribute"
    )
    detector_source.add_argument(
        "--detector",
        action="append",
        dest="detector_names",
        help="registered detector name (repeatable)",
    )
    matrix_parser.set_defaults(handler=_command_matrix)

    validate_parser = commands.add_parser(
        "validate", help="strictly validate persisted dispobench artifacts"
    )
    validate_parser.add_argument("paths", nargs="+", type=Path)
    validate_parser.add_argument("--kind", choices=_VALIDATION_KINDS, default="auto")
    validate_parser.add_argument(
        "--corpus", type=Path, help="corpus used for cross-validating a matrix"
    )
    validation_detectors = validate_parser.add_mutually_exclusive_group()
    validation_detectors.add_argument(
        "--detectors", help="DetectorRegistry (or factory) as module:attribute"
    )
    validation_detectors.add_argument(
        "--detector",
        action="append",
        dest="detector_names",
        help="detector name used to cross-validate a matrix (repeatable)",
    )
    validate_parser.set_defaults(handler=_command_validate)
    return parser


def _read_corpus(path: Path) -> Corpus:
    return Corpus.from_json(path.read_bytes())


def _read_matrix(path: Path) -> Matrix:
    return Matrix.from_json(path.read_bytes())


def _read_json(path: Path) -> Any:
    try:
        return json.loads(path.read_text(encoding="utf-8"), parse_constant=_reject_constant)
    except json.JSONDecodeError as exc:
        raise ValueError(f"invalid JSON at {path}: {exc}") from exc


def _reject_constant(value: str) -> None:
    raise ValueError(f"invalid numeric constant {value}")


def _read_records(path: Path) -> list[dict[str, Any]]:
    records: list[dict[str, Any]] = []
    with path.open("r", encoding="utf-8") as handle:
        for line_number, line in enumerate(handle, start=1):
            if not line.strip():
                continue
            try:
                value = json.loads(line, parse_constant=_reject_constant)
            except (json.JSONDecodeError, ValueError) as exc:
                raise ValueError(f"invalid JSONL at {path}:{line_number}: {exc}") from exc
            if type(value) is not dict:
                raise ValueError(f"record at {path}:{line_number} is not an object")
            records.append(value)
    return records


def _model_config(value: str | None, *, model: str | None, base_url: str | None) -> dict[str, Any]:
    if value is None:
        config: Any = {}
    else:
        source = value[1:] if value.startswith("@") else value
        candidate = Path(source)
        if value.startswith("@") or candidate.is_file():
            payload = candidate.read_text(encoding="utf-8")
        else:
            payload = value
        try:
            config = json.loads(payload, parse_constant=_reject_constant)
        except (json.JSONDecodeError, ValueError) as exc:
            raise ValueError(f"model configuration is not valid JSON: {exc}") from exc
    if not isinstance(config, dict):
        raise ValueError("model configuration must be a JSON object")
    if model is not None:
        config["model"] = model
    if base_url is not None:
        config["base_url"] = base_url
    return config


def _load_reference(reference: str) -> Any:
    if ":" not in reference:
        raise ValueError("Python references must use module:attribute syntax")
    module_name, attribute_path = reference.split(":", 1)
    if not module_name or not attribute_path:
        raise ValueError("Python references must use module:attribute syntax")
    try:
        value: Any = importlib.import_module(module_name)
    except ImportError as exc:
        raise ValueError(f"cannot import {module_name!r}: {exc}") from exc
    for part in attribute_path.split("."):
        if not part:
            raise ValueError("Python reference contains an empty attribute")
        try:
            value = getattr(value, part)
        except AttributeError as exc:
            raise ValueError(f"Python reference {reference!r} does not exist") from exc
    return value


def _load_adapter(reference: str) -> Any:
    if reference == "echo":
        return EchoAdapter()
    candidate = _load_reference(reference)
    if inspect.isclass(candidate):
        candidate = candidate()
    elif not callable(getattr(candidate, "run", None)) and callable(candidate):
        candidate = candidate()
    run = getattr(candidate, "run", None)
    if not callable(run) or not inspect.iscoroutinefunction(run):
        raise ValueError("adapter must provide an async run(scenario, variant, model_cfg) method")
    return candidate


def _load_registrations(reference: str) -> tuple[RegisteredDetector, ...]:
    candidate = _load_reference(reference)
    if callable(candidate) and not isinstance(candidate, DetectorRegistry):
        candidate = candidate()
    if isinstance(candidate, DetectorRegistry):
        registrations = candidate.all()
    elif isinstance(candidate, Iterable) and not isinstance(candidate, (str, bytes, Mapping)):
        registrations = tuple(candidate)
    else:
        raise ValueError("detector provider must be a DetectorRegistry, factory, or iterable")
    if not registrations:
        raise ValueError("detector provider contains no detectors")
    if any(not isinstance(item, RegisteredDetector) for item in registrations):
        raise ValueError("detector provider contains an unregistered detector")
    names = [item.name for item in registrations]
    if len(names) != len(set(names)):
        raise ValueError("detector provider contains duplicate names")
    return registrations


def _registrations_and_names(args: argparse.Namespace) -> tuple[tuple[RegisteredDetector, ...], list[str]]:
    if getattr(args, "detectors", None):
        registrations = _load_registrations(args.detectors)
        return registrations, [item.name for item in registrations]
    return (), list(getattr(args, "detector_names", None) or [])


def _detector_column(matrix: Matrix, detector_name: str) -> str:
    homes = [
        column.name
        for column in matrix.columns
        if any(detector_name.startswith(prefix) for prefix in column.detector_prefixes)
    ]
    if len(homes) != 1:
        qualifier = "no" if not homes else "multiple"
        raise ValueError(f"detector {detector_name!r} has {qualifier} matrix column homes")
    return homes[0]


def _column_groups(matrix: Matrix, detector_names: Sequence[str]) -> dict[str, list[str]]:
    groups = {column.name: [] for column in matrix.columns}
    for detector_name in detector_names:
        groups[_detector_column(matrix, detector_name)].append(detector_name)
    empty = sorted(name for name, names in groups.items() if not names)
    if empty:
        raise ValueError(f"matrix columns contain no detectors: {', '.join(empty)}")
    return groups


def _check_registration_homes(
    matrix: Matrix, registrations: Sequence[RegisteredDetector]
) -> None:
    for registration in registrations:
        matrix_home = _detector_column(matrix, registration.name)
        if registration.column_home != matrix_home:
            raise ValueError(
                f"detector {registration.name!r} declares column_home "
                f"{registration.column_home!r}, but the matrix assigns {matrix_home!r}"
            )


def _row_mapping(matrix: Matrix) -> dict[str, str]:
    mapping: dict[str, str] = {}
    for row in matrix.rows:
        for label in row.scenario_labels:
            existing = mapping.get(label)
            if existing is not None and existing != row.name:
                raise ValueError(f"scenario label {label!r} has multiple matrix rows")
            mapping[label] = row.name
    return mapping


def _records_in_matrix_rows(
    records: Sequence[dict[str, Any]], matrix: Matrix
) -> list[dict[str, Any]]:
    mapping = _row_mapping(matrix)
    row_names = {row.name for row in matrix.rows}
    normalized: list[dict[str, Any]] = []
    for record in records:
        family = record.get("family")
        if not isinstance(family, str) or not family:
            raise ValueError(f"record {record.get('key', '<unknown>')!r} has no family")
        row_name = mapping.get(family)
        if row_name is None and family in row_names:
            row_name = family
        if row_name is None:
            raise ValueError(f"record family {family!r} has no matrix row")
        normalized.append(dict(record) | {"family": row_name})
    return normalized


def _detached_verdicts(path: Path) -> tuple[dict[str, Mapping[str, bool | None]], list[str]]:
    payload = _read_json(path)
    declared: list[str] = []
    if isinstance(payload, dict) and "detector_results" in payload:
        raw_results = payload["detector_results"]
        raw_declared = payload.get("detectors", [])
        if not isinstance(raw_declared, list) or any(not isinstance(item, str) for item in raw_declared):
            raise ValueError("verdicts.detectors must be an array of strings")
        declared.extend(raw_declared)
    else:
        raw_results = payload
    if not isinstance(raw_results, dict):
        raise ValueError("detector verdicts must be an object keyed by record key")
    results: dict[str, Mapping[str, bool | None]] = {}
    for record_key, verdicts in raw_results.items():
        if not isinstance(record_key, str) or not isinstance(verdicts, dict):
            raise ValueError("detector verdicts must map record keys to objects")
        results[record_key] = verdicts
        declared.extend(name for name in verdicts if name not in declared)
    return results, declared


def _score_records(
    records: Sequence[dict[str, Any]], registrations: Sequence[RegisteredDetector]
) -> dict[str, dict[str, bool | None]]:
    results: dict[str, dict[str, bool | None]] = {}
    for record in records:
        key = record.get("key")
        if not isinstance(key, str) or not key:
            raise ValueError("every record requires a non-empty string key")
        results[key] = {registration.name: registration(record) for registration in registrations}
    return results


def _write_text(path: Path, payload: str) -> None:
    path.parent.mkdir(parents=True, exist_ok=True)
    descriptor, temporary_name = tempfile.mkstemp(prefix=f".{path.name}.", dir=path.parent)
    try:
        with os.fdopen(descriptor, "w", encoding="utf-8", newline="\n") as handle:
            handle.write(payload)
            handle.flush()
            os.fsync(handle.fileno())
        os.replace(temporary_name, path)
    except BaseException:
        try:
            os.unlink(temporary_name)
        except FileNotFoundError:
            pass
        raise


def _command_run(args: argparse.Namespace) -> int:
    corpus = _read_corpus(args.corpus)
    adapter = _load_adapter(args.adapter)
    config = RunConfig(
        seed=args.seed,
        per_family=args.per_family,
        k=args.reps,
        variant=args.variant,
        model_cfg=_model_config(args.model_config, model=args.model, base_url=args.base_url),
        budgets=BudgetCaps(max_requests=args.max_requests, max_tokens=args.max_tokens),
        max_retries=args.max_retries,
        require_smoke=not args.no_require_smoke,
        adapter_id=args.adapter_id,
    )
    scenarios = [scenario.to_dict() for scenario in corpus.scenarios]
    summary = asyncio.run(
        run_benchmark(
            adapter,
            scenarios,
            config,
            output_path=args.output,
            smoke=args.smoke,
            smoke_receipt_path=args.smoke_receipt,
        )
    )
    payload = asdict(summary)
    payload["complete"] = summary.complete
    sys.stdout.write(json.dumps(payload, sort_keys=True, separators=(",", ":")) + "\n")
    return 0 if summary.complete else 1


def _command_report(args: argparse.Namespace) -> int:
    records = _read_records(args.records)
    matrix = _read_matrix(args.matrix)
    if args.detectors:
        registrations = _load_registrations(args.detectors)
        _check_registration_homes(matrix, registrations)
        detector_names = [registration.name for registration in registrations]
        verdicts = _score_records(records, registrations)
    else:
        verdicts, detector_names = _detached_verdicts(args.verdicts)
        detector_names.extend(name for name in args.detector if name not in detector_names)
    groups = _column_groups(matrix, detector_names)
    normalized_records = _records_in_matrix_rows(records, matrix)
    report = build_report(
        normalized_records,
        verdicts,
        [row.name for row in matrix.rows],
        groups,
        worst_examples=args.worst_examples,
    )
    json_text = render_json(report)
    markdown_text = render_markdown(report)
    if args.json_out is not None:
        _write_text(args.json_out, json_text)
    if args.markdown_out is not None:
        _write_text(args.markdown_out, markdown_text)
    selected = json_text if args.format == "json" else markdown_text
    if args.output is not None:
        _write_text(args.output, selected)
    elif args.json_out is None and args.markdown_out is None:
        sys.stdout.write(selected)
    return 0


def _command_gate(args: argparse.Namespace) -> int:
    lock = read_shaping_lock(args.lock)
    if compare_shaping_lock(lock, root=args.root):
        sys.stdout.write(f"PASS {args.lock}: shaping surface matches {lock.sha256}\n")
        return 0
    sys.stderr.write(f"FAIL {args.lock}: shaping surface changed or a declared file is missing\n")
    return 1


def _command_matrix(args: argparse.Namespace) -> int:
    matrix = _read_matrix(args.matrix)
    corpus = _read_corpus(args.corpus)
    registrations, detector_names = _registrations_and_names(args)
    if registrations:
        _check_registration_homes(matrix, registrations)
    validate_matrix(matrix, corpus, detector_names)
    sys.stdout.write(matrix.to_json() + "\n")
    return 0


def _infer_kind(value: Any, path: Path) -> str:
    if isinstance(value, list):
        return "records"
    if not isinstance(value, dict):
        raise ValueError(f"cannot infer dispobench artifact type for {path}")
    keys = set(value)
    if {"scenarios", "leak_census"} <= keys:
        return "corpus"
    if {"rows", "columns"} <= keys:
        return "matrix"
    if {"key", "scenario_id", "result", "usage"} <= keys:
        return "record"
    if {"run_id", "corpus_hash", "matrix_hash", "shaping_hash"} <= keys:
        return "manifest"
    if {"sha256", "files", "run", "date"} <= keys:
        return "lock"
    if path.suffix.casefold() == ".jsonl":
        return "records"
    raise ValueError(f"cannot infer dispobench artifact type for {path}")


def _validate_records(path: Path) -> int:
    count = 0
    with path.open("rb") as handle:
        for line_number, line in enumerate(handle, start=1):
            if not line.strip():
                continue
            try:
                Record.from_json(line)
            except ValueError as exc:
                raise ValueError(f"{path}:{line_number}: {exc}") from exc
            count += 1
    if count == 0:
        raise ValueError(f"record JSONL is empty: {path}")
    return count


def _validation_detector_names(args: argparse.Namespace) -> list[str] | None:
    if args.detectors:
        registrations = _load_registrations(args.detectors)
        return [registration.name for registration in registrations]
    if args.detector_names:
        return list(args.detector_names)
    return None


def _command_validate(args: argparse.Namespace) -> int:
    if args.corpus is not None and len(args.paths) != 1:
        raise ValueError("--corpus matrix cross-validation accepts exactly one path")
    detector_names = _validation_detector_names(args)
    if (args.corpus is None) != (detector_names is None):
        raise ValueError("matrix cross-validation requires both --corpus and detectors")

    for path in args.paths:
        kind = args.kind
        value: Any = None
        if kind == "auto":
            if path.suffix.casefold() == ".jsonl":
                kind = "records"
            else:
                value = _read_json(path)
                kind = _infer_kind(value, path)
        if kind == "corpus":
            _read_corpus(path)
            detail = "corpus"
        elif kind == "matrix":
            matrix = _read_matrix(path)
            if args.corpus is not None and detector_names is not None:
                validate_matrix(matrix, _read_corpus(args.corpus), detector_names)
            detail = "matrix"
        elif kind == "record":
            Record.from_json(path.read_bytes())
            detail = "record"
        elif kind == "records":
            detail = f"records ({_validate_records(path)})"
        elif kind == "manifest":
            read_manifest(path)
            detail = "manifest"
        elif kind == "lock":
            read_shaping_lock(path)
            detail = "lock"
        else:  # pragma: no cover - argparse and _infer_kind constrain this.
            raise ValueError(f"unknown validation kind: {kind}")
        sys.stdout.write(f"VALID {detail} {path}\n")
    return 0


def main(argv: Sequence[str] | None = None) -> int:
    """Run the dispobench command line and return its process exit status."""

    parser = _build_parser()
    args = parser.parse_args(argv)
    try:
        return int(args.handler(args))
    except (ImportError, OSError, RuntimeError, TypeError, ValueError) as exc:
        sys.stderr.write(f"dispobench: {exc}\n")
        return 2


if __name__ == "__main__":  # pragma: no cover - exercised by the process entrypoint.
    raise SystemExit(main())
