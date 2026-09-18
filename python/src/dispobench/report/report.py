"""Build and render the family-by-concern report grid."""

from __future__ import annotations

import json
import math
from collections.abc import Iterable, Mapping, Sequence
from typing import Any

Z_95 = 1.959963984540054


def wilson_interval(fires: int, n: int) -> tuple[float, float]:
    """Return the two-sided 95% Wilson score interval for a binomial rate."""

    if isinstance(fires, bool) or not isinstance(fires, int):
        raise TypeError("fires must be an integer")
    if isinstance(n, bool) or not isinstance(n, int):
        raise TypeError("n must be an integer")
    if n <= 0:
        raise ValueError("n must be positive")
    if not 0 <= fires <= n:
        raise ValueError("fires must be in [0, n]")

    proportion = fires / n
    z_squared = Z_95 * Z_95
    denominator = 1.0 + z_squared / n
    center = (proportion + z_squared / (2.0 * n)) / denominator
    half_width = (Z_95 / denominator) * math.sqrt(
        proportion * (1.0 - proportion) / n + z_squared / (4.0 * n * n)
    )
    return max(0.0, center - half_width), min(1.0, center + half_width)


def build_report(
    records: Iterable[dict[str, Any]],
    detector_results: Mapping[str, Mapping[str, bool | None]],
    rows: Sequence[str],
    column_groups: Mapping[str, Iterable[str]],
    *,
    worst_examples: int = 3,
) -> dict[str, Any]:
    """Build a deterministic full-grid report from records and verdicts.

    Each cell uses records, rather than individual detector invocations, as
    its statistical unit.  For one record and column group, any ``True``
    verdict is a fire; one or more ``False`` verdicts with no fire is a
    non-fire; and an all-``None`` or absent result is not applicable and is
    excluded from ``n``.

    Rows and column groups are sorted by name in the returned report.  Worst
    examples are fires ranked by descending number of firing detectors, then
    by record key.  The report references every applicable and firing record
    key so every aggregate can be audited against persisted records.
    """

    row_names = _normalize_names(rows, "row")
    groups, detector_homes = _normalize_column_groups(column_groups)
    limit = _validate_worst_examples(worst_examples)
    records_by_key = _index_records(records, row_names)
    results_by_key = _validate_results(
        detector_results, records_by_key, detector_homes
    )

    cells: list[dict[str, Any]] = []
    for row in row_names:
        row_records = [
            record
            for record in records_by_key.values()
            if record["family"] == row
        ]
        row_records.sort(key=lambda record: record["key"])

        for group_name, detector_names in groups:
            applicable_keys: list[str] = []
            fire_keys: list[str] = []
            ranked_fires: list[tuple[int, str, list[str]]] = []

            for record in row_records:
                record_key = record["key"]
                record_results = results_by_key.get(record_key, {})
                applicable_detectors = [
                    detector
                    for detector in detector_names
                    if record_results.get(detector) is not None
                ]
                if not applicable_detectors:
                    continue

                applicable_keys.append(record_key)
                fired_detectors = [
                    detector
                    for detector in detector_names
                    if record_results.get(detector) is True
                ]
                if fired_detectors:
                    fire_keys.append(record_key)
                    ranked_fires.append(
                        (len(fired_detectors), record_key, fired_detectors)
                    )

            n = len(applicable_keys)
            fires = len(fire_keys)
            if n:
                ci_low, ci_high = wilson_interval(fires, n)
                rate: float | None = fires / n
                ci95: dict[str, float] | None = {
                    "low": ci_low,
                    "high": ci_high,
                }
            else:
                rate = None
                ci95 = None

            ranked_fires.sort(key=lambda item: (-item[0], item[1]))
            worst = [
                {
                    "record_key": record_key,
                    "fired_detectors": fired_detectors,
                }
                for _, record_key, fired_detectors in ranked_fires[:limit]
            ]
            cells.append(
                {
                    "row": row,
                    "column_group": group_name,
                    "fires": fires,
                    "n": n,
                    "fire_rate": rate,
                    "ci95": ci95,
                    "record_keys": applicable_keys,
                    "fire_record_keys": fire_keys,
                    "worst_examples": worst,
                }
            )

    scored_keys = {
        record_key
        for cell in cells
        for record_key in cell["record_keys"]
    }
    return {
        "report_version": 1,
        "aggregation": "record_any_detector",
        "confidence_interval": "wilson_95",
        "rows": row_names,
        "column_groups": [
            {"name": group_name, "detectors": detector_names}
            for group_name, detector_names in groups
        ],
        "record_count": len(records_by_key),
        "unscored_record_keys": sorted(set(records_by_key) - scored_keys),
        "cells": cells,
    }


def render_json(report: Mapping[str, Any]) -> str:
    """Render a report as canonical, newline-terminated UTF-8 JSON text."""

    return json.dumps(
        report,
        ensure_ascii=False,
        allow_nan=False,
        indent=2,
        sort_keys=True,
    ) + "\n"


def render_markdown(report: Mapping[str, Any]) -> str:
    """Render a report as deterministic Markdown with cell provenance."""

    rows = report["rows"]
    groups = [group["name"] for group in report["column_groups"]]
    cells = {
        (cell["row"], cell["column_group"]): cell for cell in report["cells"]
    }

    lines = [
        "# dispobench report",
        "",
        (
            "Fire rate is the share of applicable records for which any detector "
            "in the column group fired. Intervals are Wilson 95% confidence "
            "intervals."
        ),
        "",
        f"Records: {report['record_count']}",
        "",
        "## Fire-rate grid",
        "",
        "| Row | " + " | ".join(_escape_table(group) for group in groups) + " |",
        "| --- | " + " | ".join("---" for _ in groups) + " |",
    ]
    for row in rows:
        rendered_cells = [
            _format_cell(cells[(row, group)]) for group in groups
        ]
        lines.append(
            "| "
            + _escape_table(row)
            + " | "
            + " | ".join(rendered_cells)
            + " |"
        )

    lines.extend(
        [
            "",
            "## Cell provenance",
            "",
            "| Row | Column group | Applicable record keys | Fire record keys |",
            "| --- | --- | --- | --- |",
        ]
    )
    for cell in report["cells"]:
        lines.append(
            "| "
            + " | ".join(
                [
                    _escape_table(cell["row"]),
                    _escape_table(cell["column_group"]),
                    _format_keys(cell["record_keys"]),
                    _format_keys(cell["fire_record_keys"]),
                ]
            )
            + " |"
        )

    lines.extend(
        [
            "",
            "## Worst examples",
            "",
            "| Row | Column group | Record key | Fired detectors |",
            "| --- | --- | --- | --- |",
        ]
    )
    example_count = 0
    for cell in report["cells"]:
        for example in cell["worst_examples"]:
            example_count += 1
            lines.append(
                "| "
                + " | ".join(
                    [
                        _escape_table(cell["row"]),
                        _escape_table(cell["column_group"]),
                        _escape_table(example["record_key"]),
                        _format_keys(example["fired_detectors"]),
                    ]
                )
                + " |"
            )
    if example_count == 0:
        lines.append("| — | — | — | — |")

    unscored = report.get("unscored_record_keys", [])
    lines.extend(
        [
            "",
            "## Unscored records",
            "",
            _format_keys(unscored),
            "",
        ]
    )
    return "\n".join(lines)


def _normalize_names(names: Sequence[str], kind: str) -> list[str]:
    if isinstance(names, (str, bytes)):
        raise TypeError(f"{kind}s must be a sequence of names")
    normalized = list(names)
    for name in normalized:
        if not isinstance(name, str) or not name:
            raise ValueError(f"{kind} names must be non-empty strings")
    if len(normalized) != len(set(normalized)):
        raise ValueError(f"duplicate {kind} name")
    if not normalized:
        raise ValueError(f"at least one {kind} is required")
    return sorted(normalized)


def _normalize_column_groups(
    column_groups: Mapping[str, Iterable[str]],
) -> tuple[list[tuple[str, list[str]]], dict[str, str]]:
    if not isinstance(column_groups, Mapping):
        raise TypeError("column_groups must be a mapping")
    if not column_groups:
        raise ValueError("at least one column group is required")

    groups: list[tuple[str, list[str]]] = []
    detector_homes: dict[str, str] = {}
    for group_name, raw_detectors in column_groups.items():
        if not isinstance(group_name, str) or not group_name:
            raise ValueError("column group names must be non-empty strings")
        if isinstance(raw_detectors, (str, bytes)):
            raise TypeError("a column group's detectors must be an iterable of names")
        detectors = list(raw_detectors)
        if not detectors:
            raise ValueError(f"column group {group_name!r} has no detectors")
        for detector in detectors:
            if not isinstance(detector, str) or not detector:
                raise ValueError("detector names must be non-empty strings")
            if detector in detector_homes:
                raise ValueError(
                    f"detector {detector!r} has multiple column homes: "
                    f"{detector_homes[detector]!r} and {group_name!r}"
                )
            detector_homes[detector] = group_name
        groups.append((group_name, sorted(detectors)))
    groups.sort(key=lambda item: item[0])
    return groups, detector_homes


def _validate_worst_examples(value: int) -> int:
    if isinstance(value, bool) or not isinstance(value, int):
        raise TypeError("worst_examples must be an integer")
    if value < 0:
        raise ValueError("worst_examples must be non-negative")
    return value


def _index_records(
    records: Iterable[dict[str, Any]], row_names: Sequence[str]
) -> dict[str, dict[str, Any]]:
    if isinstance(records, (str, bytes, Mapping)):
        raise TypeError("records must be an iterable of plain dictionaries")

    indexed: dict[str, dict[str, Any]] = {}
    known_rows = set(row_names)
    for record in records:
        if type(record) is not dict:
            raise TypeError("each record must be a plain dictionary")
        key = record.get("key")
        family = record.get("family")
        if not isinstance(key, str) or not key:
            raise ValueError("each record must have a non-empty string key")
        if not isinstance(family, str) or not family:
            raise ValueError(f"record {key!r} must have a non-empty string family")
        if family not in known_rows:
            raise ValueError(f"record {key!r} has undeclared family {family!r}")
        if key in indexed:
            raise ValueError(f"duplicate record key: {key!r}")
        indexed[key] = record
    return dict(sorted(indexed.items()))


def _validate_results(
    detector_results: Mapping[str, Mapping[str, bool | None]],
    records_by_key: Mapping[str, dict[str, Any]],
    detector_homes: Mapping[str, str],
) -> dict[str, dict[str, bool | None]]:
    if not isinstance(detector_results, Mapping):
        raise TypeError("detector_results must be a mapping")

    validated: dict[str, dict[str, bool | None]] = {}
    for record_key, verdicts in detector_results.items():
        if record_key not in records_by_key:
            raise ValueError(f"detector results reference unknown record {record_key!r}")
        if not isinstance(verdicts, Mapping):
            raise TypeError(f"detector results for {record_key!r} must be a mapping")
        validated_verdicts: dict[str, bool | None] = {}
        for detector, verdict in verdicts.items():
            if detector not in detector_homes:
                raise ValueError(f"result references ungrouped detector {detector!r}")
            if verdict is not True and verdict is not False and verdict is not None:
                raise TypeError(
                    f"detector result for {record_key!r}/{detector!r} "
                    "must be bool or None"
                )
            validated_verdicts[detector] = verdict
        validated[record_key] = dict(sorted(validated_verdicts.items()))
    return dict(sorted(validated.items()))


def _format_cell(cell: Mapping[str, Any]) -> str:
    if cell["n"] == 0:
        return "— (n=0)"
    return (
        f"{cell['fire_rate']:.1%} "
        f"({cell['fires']}/{cell['n']}; 95% CI "
        f"{cell['ci95']['low']:.1%}–{cell['ci95']['high']:.1%})"
    )


def _format_keys(values: Iterable[str]) -> str:
    rendered = [_escape_table(value) for value in values]
    return ", ".join(rendered) if rendered else "—"


def _escape_table(value: str) -> str:
    return (
        value.replace("\\", "\\\\")
        .replace("|", "\\|")
        .replace("\r\n", "<br>")
        .replace("\r", "<br>")
        .replace("\n", "<br>")
    )
