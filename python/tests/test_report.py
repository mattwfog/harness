from __future__ import annotations

import json

import pytest

from dispobench.report import (
    build_report,
    render_json,
    render_markdown,
    wilson_interval,
)


def _records() -> list[dict]:
    return [
        {"key": "sales-2", "family": "sales", "result": {"reply": "two"}},
        {"key": "support-1", "family": "support", "result": {"reply": "help"}},
        {"key": "sales-1", "family": "sales", "result": {"reply": "one"}},
        {"key": "sales-3", "family": "sales", "result": {"reply": "three"}},
    ]


def _results() -> dict[str, dict[str, bool | None]]:
    return {
        "sales-1": {"empty_reply": True, "no_terminal": False, "markdown": True},
        "sales-2": {"empty_reply": False, "no_terminal": False, "markdown": None},
        "sales-3": {"empty_reply": True, "no_terminal": True, "markdown": None},
        "support-1": {"empty_reply": None, "no_terminal": None, "markdown": None},
    }


def _report(*, worst_examples: int = 3) -> dict:
    return build_report(
        _records(),
        _results(),
        rows=["support", "empty", "sales"],
        column_groups={
            "format": ["markdown"],
            "protocol": ["no_terminal", "empty_reply"],
        },
        worst_examples=worst_examples,
    )


def test_wilson_interval_known_values_and_validation() -> None:
    low, high = wilson_interval(1, 2)
    assert low == pytest.approx(0.09453120573423074)
    assert high == pytest.approx(0.9054687942657693)

    with pytest.raises(ValueError, match="positive"):
        wilson_interval(0, 0)
    with pytest.raises(ValueError, match=r"\[0, n\]"):
        wilson_interval(3, 2)
    with pytest.raises(TypeError, match="integer"):
        wilson_interval(True, 2)


def test_build_report_makes_full_grid_and_uses_records_as_trials() -> None:
    report = _report()

    assert report["rows"] == ["empty", "sales", "support"]
    assert [group["name"] for group in report["column_groups"]] == [
        "format",
        "protocol",
    ]
    assert len(report["cells"]) == 6
    protocol = next(
        cell
        for cell in report["cells"]
        if cell["row"] == "sales" and cell["column_group"] == "protocol"
    )
    # Both protocol detectors firing still count as one Bernoulli trial for
    # sales-3; detector calls are not treated as independent observations.
    assert protocol["fires"] == 2
    assert protocol["n"] == 3
    assert protocol["fire_rate"] == pytest.approx(2 / 3)
    assert protocol["record_keys"] == ["sales-1", "sales-2", "sales-3"]
    assert protocol["fire_record_keys"] == ["sales-1", "sales-3"]
    assert protocol["ci95"] == {
        "low": pytest.approx(0.2076596008020477),
        "high": pytest.approx(0.9385080552796037),
    }

    empty_cell = report["cells"][0]
    assert empty_cell["row"] == "empty"
    assert empty_cell["n"] == 0
    assert empty_cell["fire_rate"] is None
    assert empty_cell["ci95"] is None
    assert report["unscored_record_keys"] == ["support-1"]


def test_build_report_ranks_and_limits_worst_examples() -> None:
    report = _report(worst_examples=1)
    protocol = next(
        cell
        for cell in report["cells"]
        if cell["row"] == "sales" and cell["column_group"] == "protocol"
    )
    assert protocol["worst_examples"] == [
        {
            "record_key": "sales-3",
            "fired_detectors": ["empty_reply", "no_terminal"],
        }
    ]


def test_build_report_rejects_data_that_would_be_silently_omitted() -> None:
    with pytest.raises(ValueError, match="duplicate record key"):
        build_report(
            [{"key": "same", "family": "row"}, {"key": "same", "family": "row"}],
            {},
            ["row"],
            {"group": ["detector"]},
        )
    with pytest.raises(ValueError, match="undeclared family"):
        build_report(
            [{"key": "key", "family": "other"}],
            {},
            ["row"],
            {"group": ["detector"]},
        )
    with pytest.raises(ValueError, match="ungrouped detector"):
        build_report(
            [{"key": "key", "family": "row"}],
            {"key": {"other_detector": False}},
            ["row"],
            {"group": ["detector"]},
        )
    with pytest.raises(ValueError, match="multiple column homes"):
        build_report(
            [],
            {},
            ["row"],
            {"one": ["detector"], "two": ["detector"]},
        )
    with pytest.raises(TypeError, match="bool or None"):
        build_report(
            [{"key": "key", "family": "row"}],
            {"key": {"detector": 1}},
            ["row"],
            {"group": ["detector"]},
        )


def test_render_json_is_canonical_and_round_trips() -> None:
    report = _report()
    rendered = render_json(report)

    assert rendered.endswith("\n")
    assert json.loads(rendered) == report
    assert '"aggregation": "record_any_detector"' in rendered


def test_render_markdown_includes_grid_provenance_and_worst_examples() -> None:
    rendered = render_markdown(_report())

    assert "| sales | 100.0% (1/1; 95% CI" in rendered
    assert "66.7% (2/3; 95% CI" in rendered
    assert "| empty | — (n=0) | — (n=0) |" in rendered
    assert "## Cell provenance" in rendered
    assert "sales-1, sales-2, sales-3" in rendered
    assert "## Worst examples" in rendered
    assert "sales-3" in rendered
    assert "empty_reply, no_terminal" in rendered
    assert rendered.endswith("\n")


def test_outputs_are_byte_identical_across_input_orderings() -> None:
    first = _report()
    second = build_report(
        list(reversed(_records())),
        dict(reversed(list(_results().items()))),
        rows=["sales", "empty", "support"],
        column_groups={
            "protocol": ["empty_reply", "no_terminal"],
            "format": ["markdown"],
        },
    )

    assert render_json(first).encode("utf-8") == render_json(second).encode("utf-8")
    assert render_markdown(first).encode("utf-8") == render_markdown(second).encode(
        "utf-8"
    )
