from __future__ import annotations

from collections.abc import Iterable

from ._validation import SchemaError, require_str
from .schemas import Corpus, Matrix


def validate_matrix(
    matrix: Matrix,
    corpus: Corpus | Iterable[str],
    detector_names: Iterable[str],
) -> Matrix:
    """Validate that rows and columns are strict, exhaustive partitions.

    ``corpus`` may be a :class:`Corpus` or the complete set of scenario
    family labels. Detector homes are selected by string prefix. Prefixes
    are required to be disjoint, so each detector has exactly one home.
    The validated matrix is returned for convenient load-and-validate flows.
    """

    if not isinstance(matrix, Matrix):
        raise SchemaError("matrix: must be a Matrix")

    if isinstance(corpus, Corpus):
        corpus_labels = corpus.families
    else:
        if isinstance(corpus, (str, bytes)):
            raise SchemaError("corpus labels: must be an iterable of strings")
        corpus_labels = tuple(corpus)
    labels = tuple(require_str(label, "corpus label") for label in corpus_labels)
    if not labels:
        raise SchemaError("corpus labels: must not be empty")
    if len(labels) != len(set(labels)):
        raise SchemaError("corpus labels: must not contain duplicates")

    row_homes: dict[str, list[str]] = {}
    for row in matrix.rows:
        for label in row.scenario_labels:
            row_homes.setdefault(label, []).append(row.name)

    expected_labels = set(labels)
    declared_labels = set(row_homes)
    missing_labels = expected_labels - declared_labels
    extra_labels = declared_labels - expected_labels
    duplicate_labels = {
        label: homes for label, homes in row_homes.items() if len(homes) != 1
    }
    problems: list[str] = []
    if missing_labels:
        problems.append(f"scenario labels without a row: {', '.join(sorted(missing_labels))}")
    if extra_labels:
        problems.append(f"row labels absent from corpus: {', '.join(sorted(extra_labels))}")
    if duplicate_labels:
        rendered = ", ".join(
            f"{label} ({'/'.join(homes)})" for label, homes in sorted(duplicate_labels.items())
        )
        problems.append(f"scenario labels with multiple rows: {rendered}")
    if problems:
        raise SchemaError("matrix.rows: " + "; ".join(problems))

    prefixes: list[tuple[str, str]] = [
        (prefix, column.name)
        for column in matrix.columns
        for prefix in column.detector_prefixes
    ]
    for index, (left, left_home) in enumerate(prefixes):
        for right, right_home in prefixes[index + 1 :]:
            if left.startswith(right) or right.startswith(left):
                raise SchemaError(
                    "matrix.columns: detector prefixes overlap: "
                    f"{left!r} ({left_home}) and {right!r} ({right_home})"
                )

    if isinstance(detector_names, (str, bytes)):
        raise SchemaError("detector_names: must be an iterable of strings")
    detectors = tuple(require_str(name, "detector name") for name in detector_names)
    if not detectors:
        raise SchemaError("detector_names: must not be empty")
    if len(detectors) != len(set(detectors)):
        raise SchemaError("detector_names: must not contain duplicates")

    no_home: list[str] = []
    multiple_homes: dict[str, list[str]] = {}
    for detector in detectors:
        homes = [
            column.name
            for column in matrix.columns
            if any(detector.startswith(prefix) for prefix in column.detector_prefixes)
        ]
        if not homes:
            no_home.append(detector)
        elif len(homes) > 1:
            multiple_homes[detector] = homes
    if no_home or multiple_homes:
        problems = []
        if no_home:
            problems.append(f"detectors without a column: {', '.join(sorted(no_home))}")
        if multiple_homes:
            rendered = ", ".join(
                f"{name} ({'/'.join(homes)})"
                for name, homes in sorted(multiple_homes.items())
            )
            problems.append(f"detectors with multiple columns: {rendered}")
        raise SchemaError("matrix.columns: " + "; ".join(problems))

    return matrix
