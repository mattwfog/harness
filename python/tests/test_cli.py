from __future__ import annotations

import json
from pathlib import Path

from dispobench.cli import main
from dispobench.core import (
    Corpus,
    Matrix,
    MatrixColumn,
    MatrixRow,
    Record,
    Result,
    Scenario,
    Usage,
    create_shaping_lock,
    write_shaping_lock,
)
from dispobench.detectors import DetectorRegistry, empty_reply, protocol_no_terminal


TEST_REGISTRY = DetectorRegistry()
TEST_REGISTRY.register(
    protocol_no_terminal,
    name="protocol.no_terminal",
    column_home="protocol",
)
TEST_REGISTRY.register(
    empty_reply,
    name="form.empty_reply",
    column_home="form",
)


def _corpus() -> Corpus:
    return Corpus(
        name="cli-fixture",
        leak_census=0,
        scenarios=(
            Scenario(
                scenario_id="alpha-1",
                family="alpha",
                history=({"role": "user", "content": "Alpha"},),
                reference={"reply": "Alpha"},
            ),
            Scenario(
                scenario_id="beta-1",
                family="beta",
                history=({"role": "user", "content": "Beta"},),
                reference={"reply": "Beta"},
            ),
        ),
    )


def _matrix() -> Matrix:
    return Matrix(
        name="cli-fixture",
        rows=(
            MatrixRow("alpha", ("alpha",)),
            MatrixRow("beta", ("beta",)),
        ),
        columns=(
            MatrixColumn("protocol", ("protocol.",)),
            MatrixColumn("form", ("form.",)),
        ),
    )


def _write_contracts(tmp_path: Path) -> tuple[Path, Path]:
    corpus_path = tmp_path / "corpus.json"
    matrix_path = tmp_path / "matrix.json"
    corpus_path.write_text(_corpus().to_json() + "\n", encoding="utf-8")
    matrix_path.write_text(_matrix().to_json() + "\n", encoding="utf-8")
    return corpus_path, matrix_path


def _valid_record() -> Record:
    return Record(
        key="alpha-1:r0:fixture",
        scenario_id="alpha-1",
        family="alpha",
        rep=0,
        variant="baseline",
        model="echo",
        base_url="echo://local",
        prompt_hash="a" * 64,
        system_prompt="",
        history=({"role": "user", "content": "Alpha"},),
        tool_calls=(),
        result=Result(terminal=True, action=None, reply="Alpha"),
        usage=Usage(input=0, cached=0, output=0),
        nudges=0,
        seed=0,
        wall_ms=0,
        finished_at="1970-01-01T00:00:00Z",
        manifest_ref="fixture",
    )


def test_smoke_then_full_run_persists_resumes_and_reports_summary(
    tmp_path: Path, capsys,
) -> None:
    corpus_path, _ = _write_contracts(tmp_path)
    records_path = tmp_path / "records.jsonl"
    common = [
        str(corpus_path),
        "--output",
        str(records_path),
        "--adapter",
        "echo",
        "--adapter-id",
        "cli-echo",
        "--model",
        "echo-v1",
    ]

    assert main(["smoke", *common, "--reps", "2"]) == 0
    smoke = json.loads(capsys.readouterr().out)
    assert smoke["mode"] == "smoke"
    assert smoke["complete"] is True
    assert smoke["planned"] == smoke["executed"] == 2
    assert Path(f"{records_path}.smoke.json").is_file()

    assert main(["run", *common, "--reps", "2"]) == 0
    full = json.loads(capsys.readouterr().out)
    assert full["mode"] == "full"
    assert full["complete"] is True
    assert full["planned"] == 4
    assert full["resumed"] == 2
    assert full["executed"] == 2
    assert len(records_path.read_text(encoding="utf-8").splitlines()) == 4


def test_matrix_and_report_use_registered_detectors(
    tmp_path: Path, capsys,
) -> None:
    corpus_path, matrix_path = _write_contracts(tmp_path)
    records_path = tmp_path / "records.jsonl"
    assert main(
        [
            "smoke",
            str(corpus_path),
            "--output",
            str(records_path),
            "--adapter",
            "echo",
        ]
    ) == 0
    capsys.readouterr()

    provider = "tests.test_cli:TEST_REGISTRY"
    assert main(
        ["matrix", str(matrix_path), str(corpus_path), "--detectors", provider]
    ) == 0
    rendered_matrix = json.loads(capsys.readouterr().out)
    assert rendered_matrix["name"] == "cli-fixture"

    assert main(
        [
            "report",
            str(records_path),
            str(matrix_path),
            "--detectors",
            provider,
            "--format",
            "json",
        ]
    ) == 0
    report = json.loads(capsys.readouterr().out)
    assert report["rows"] == ["alpha", "beta"]
    assert report["record_count"] == 2
    assert len(report["cells"]) == 4
    assert all(cell["fires"] == 0 for cell in report["cells"])
    assert all(cell["n"] == 1 for cell in report["cells"])


def test_report_accepts_detached_verdicts_and_writes_both_formats(
    tmp_path: Path, capsys,
) -> None:
    _, matrix_path = _write_contracts(tmp_path)
    records_path = tmp_path / "records.jsonl"
    records_path.write_text(
        json.dumps({"key": "alpha-1", "family": "alpha", "result": {"reply": ""}})
        + "\n",
        encoding="utf-8",
    )
    verdicts_path = tmp_path / "verdicts.json"
    verdicts_path.write_text(
        json.dumps(
            {
                "detectors": ["protocol.no_terminal", "form.empty_reply"],
                "detector_results": {
                    "alpha-1": {
                        "protocol.no_terminal": False,
                        "form.empty_reply": True,
                    }
                },
            }
        ),
        encoding="utf-8",
    )
    json_path = tmp_path / "report.json"
    markdown_path = tmp_path / "report.md"

    assert main(
        [
            "report",
            str(records_path),
            str(matrix_path),
            "--verdicts",
            str(verdicts_path),
            "--json-out",
            str(json_path),
            "--markdown-out",
            str(markdown_path),
        ]
    ) == 0
    assert capsys.readouterr().out == ""
    report = json.loads(json_path.read_text(encoding="utf-8"))
    form_cell = next(
        cell
        for cell in report["cells"]
        if cell["row"] == "alpha" and cell["column_group"] == "form"
    )
    assert form_cell["fires"] == form_cell["n"] == 1
    assert "# dispobench report" in markdown_path.read_text(encoding="utf-8")


def test_gate_passes_then_fails_when_shaping_surface_changes(
    tmp_path: Path, capsys,
) -> None:
    shaping = tmp_path / "prompt.txt"
    shaping.write_text("original", encoding="utf-8")
    lock_path = tmp_path / "shaping.lock"
    lock = create_shaping_lock(
        ["prompt.txt"], run="run-1", date="2026-09-01", root=tmp_path
    )
    write_shaping_lock(lock, lock_path)

    assert main(["gate", str(lock_path), "--root", str(tmp_path)]) == 0
    passed = capsys.readouterr()
    assert passed.out.startswith("PASS ")
    assert passed.err == ""

    shaping.write_text("changed", encoding="utf-8")
    assert main(["gate", str(lock_path), "--root", str(tmp_path)]) == 1
    failed = capsys.readouterr()
    assert failed.out == ""
    assert failed.err.startswith("FAIL ")


def test_validate_autodetects_contracts_and_strict_record_jsonl(
    tmp_path: Path, capsys,
) -> None:
    corpus_path, matrix_path = _write_contracts(tmp_path)
    record_path = tmp_path / "record.json"
    records_path = tmp_path / "records.jsonl"
    record_path.write_text(_valid_record().to_json() + "\n", encoding="utf-8")
    records_path.write_text(_valid_record().to_json() + "\n", encoding="utf-8")

    assert main(["validate", str(corpus_path), str(matrix_path)]) == 0
    output = capsys.readouterr().out
    assert "VALID corpus" in output
    assert "VALID matrix" in output

    assert main(["validate", str(record_path), "--kind", "record"]) == 0
    assert "VALID record" in capsys.readouterr().out
    assert main(["validate", str(records_path)]) == 0
    assert "VALID records (1)" in capsys.readouterr().out


def test_cli_returns_error_status_with_concise_diagnostic(
    tmp_path: Path, capsys,
) -> None:
    bad_corpus = tmp_path / "bad.json"
    bad_corpus.write_text("{}\n", encoding="utf-8")

    assert main(
        [
            "smoke",
            str(bad_corpus),
            "--output",
            str(tmp_path / "records.jsonl"),
            "--adapter",
            "echo",
        ]
    ) == 2
    captured = capsys.readouterr()
    assert captured.out == ""
    assert captured.err.startswith("dispobench: ")
