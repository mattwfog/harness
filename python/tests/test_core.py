from __future__ import annotations

from datetime import date

import pytest

from dispobench.core import (
    Corpus,
    Matrix,
    MatrixColumn,
    MatrixRow,
    ModelEndpoint,
    Record,
    Result,
    RunManifest,
    Scenario,
    SchemaError,
    ShapingLock,
    ToolCall,
    Usage,
    canonical_json,
    compare_shaping_lock,
    content_hash,
    create_shaping_lock,
    hash_file,
    hash_files,
    read_manifest,
    read_shaping_lock,
    validate_matrix,
    write_manifest,
    write_shaping_lock,
)


DIGEST_A = "a" * 64
DIGEST_B = "b" * 64
DIGEST_C = "c" * 64


def make_scenario(scenario_id: str = "s-1", family: str = "billing") -> Scenario:
    return Scenario(
        scenario_id=scenario_id,
        family=family,
        system_prompt="Be useful.",
        history=[{"role": "user", "content": "Where is my invoice?"}],
        reference={"reply": "I can help."},
        metadata={"source": "scrubbed"},
    )


def make_record() -> Record:
    return Record(
        key="s-1:baseline:model:0",
        scenario_id="s-1",
        family="billing",
        rep=0,
        variant="baseline",
        model="test-model",
        base_url="http://localhost/v1",
        prompt_hash=DIGEST_A,
        system_prompt="Be useful.",
        history=[{"role": "user", "content": "Where is my invoice?"}],
        tool_calls=[
            ToolCall(
                name="lookup_invoice",
                arguments={"customer": 7},
                result={"invoice": "inv-1"},
                status="ok",
                duration_ms=12,
            )
        ],
        result=Result(terminal=True, action="reply", reply="Here it is."),
        usage=Usage(input=20, cached=5, output=4),
        nudges=0,
        seed=42,
        wall_ms=18,
        finished_at="2026-09-01T12:30:00Z",
        manifest_ref=DIGEST_B,
    )


def make_corpus() -> Corpus:
    return Corpus(
        scenarios=(
            make_scenario(),
            make_scenario("s-2", "shipping"),
        ),
        leak_census=0,
        name="support-v1",
    )


def make_matrix() -> Matrix:
    return Matrix(
        name="support",
        rows=(
            MatrixRow("billing", ("billing",), tags=("money",), origin="app"),
            MatrixRow("shipping", ("shipping",), origin="app"),
        ),
        columns=(
            MatrixColumn("protocol", ("protocol.",), tags=("format",)),
            MatrixColumn("content", ("content.",), origin="app"),
        ),
    )


def make_manifest() -> RunManifest:
    return RunManifest(
        run_id="run-001",
        created_at="2026-09-01T12:00:00+00:00",
        corpus_hash=DIGEST_A,
        matrix_hash=DIGEST_B,
        shaping_hash=DIGEST_C,
        seed=42,
        reps=3,
        variants=("baseline",),
        models=(
            ModelEndpoint(
                model="test-model",
                base_url="http://localhost/v1",
                metadata={"endpoint_role": "stand-in"},
            ),
        ),
        stand_ins=("local model endpoint",),
        contamination_risks=("scenario authors saw the rubric",),
        metadata={"budget": {"requests": 10}},
    )


def test_record_contract_round_trip_is_canonical() -> None:
    record = make_record()

    restored = Record.from_json(record.to_json())

    assert restored == record
    assert Record.from_dict(record.to_dict()) == record
    assert restored.tool_calls[0] == ToolCall.from_dict(record.tool_calls[0].to_dict())
    assert restored.result == Result.from_dict(record.result.to_dict())
    assert restored.usage == Usage.from_dict(record.usage.to_dict())
    assert record.to_json() == canonical_json(record)


@pytest.mark.parametrize(
    ("change", "message"),
    [
        (lambda data: data.update(prompt_hash="not-a-hash"), "prompt_hash"),
        (lambda data: data.update(rep=-1), "record.rep"),
        (lambda data: data["usage"].update(cached=21), "usage.cached"),
        (lambda data: data.update(finished_at="2026-09-01T12:00:00"), "UTC offset"),
        (lambda data: data.update(extra=True), "unknown fields"),
    ],
)
def test_record_rejects_invalid_persisted_data(change, message: str) -> None:
    data = make_record().to_dict()
    change(data)

    with pytest.raises(SchemaError, match=message):
        Record.from_dict(data)


def test_record_rejects_duplicate_json_keys_and_non_json_values() -> None:
    with pytest.raises(SchemaError, match="duplicate object key"):
        Record.from_json('{"key":"one","key":"two"}')
    with pytest.raises(SchemaError, match="non-JSON"):
        ToolCall("bad", object(), None, "error", 0)


def test_corpus_contract_round_trip_and_families() -> None:
    corpus = make_corpus()

    restored = Corpus.from_json(corpus.to_json())

    assert restored == corpus
    assert Corpus.from_dict(corpus.to_dict()) == corpus
    assert restored.families == ("billing", "shipping")
    assert Scenario.from_dict(corpus.scenarios[0].to_dict()) == corpus.scenarios[0]


def test_corpus_enforces_scrub_gate_and_unique_ids() -> None:
    with pytest.raises(SchemaError, match="must be 0"):
        Corpus(scenarios=(make_scenario(),), leak_census=1)
    with pytest.raises(SchemaError, match="scenario_id values must be unique"):
        Corpus(scenarios=(make_scenario(), make_scenario()), leak_census=0)
    with pytest.raises(SchemaError, match="must not be empty"):
        Corpus(scenarios=(), leak_census=0)


def test_matrix_contract_round_trip_and_complete_partition() -> None:
    matrix = make_matrix()

    restored = Matrix.from_json(matrix.to_json())

    assert restored == matrix
    assert Matrix.from_dict(matrix.to_dict()) == matrix
    assert MatrixRow.from_dict(matrix.rows[0].to_dict()) == matrix.rows[0]
    assert MatrixColumn.from_dict(matrix.columns[0].to_dict()) == matrix.columns[0]
    assert validate_matrix(
        restored,
        make_corpus(),
        ("protocol.no_terminal", "content.money_not_in_context"),
    ) is restored


@pytest.mark.parametrize(
    ("matrix", "labels", "detectors", "message"),
    [
        (
            Matrix(
                rows=(MatrixRow("only", ("billing",)),),
                columns=(MatrixColumn("protocol", ("protocol.",)),),
            ),
            ("billing", "shipping"),
            ("protocol.empty",),
            "without a row",
        ),
        (
            Matrix(
                rows=(MatrixRow("one", ("billing",)), MatrixRow("two", ("billing",))),
                columns=(MatrixColumn("protocol", ("protocol.",)),),
            ),
            ("billing",),
            ("protocol.empty",),
            "multiple rows",
        ),
        (
            Matrix(
                rows=(MatrixRow("billing", ("billing",)),),
                columns=(MatrixColumn("protocol", ("protocol.",)),),
            ),
            ("billing",),
            ("content.money",),
            "without a column",
        ),
        (
            Matrix(
                rows=(MatrixRow("billing", ("billing",)),),
                columns=(
                    MatrixColumn("broad", ("protocol.",)),
                    MatrixColumn("narrow", ("protocol.reply.",)),
                ),
            ),
            ("billing",),
            ("protocol.reply.empty",),
            "prefixes overlap",
        ),
    ],
)
def test_validate_matrix_rejects_non_mece_partitions(
    matrix: Matrix,
    labels: tuple[str, ...],
    detectors: tuple[str, ...],
    message: str,
) -> None:
    with pytest.raises(SchemaError, match=message):
        validate_matrix(matrix, labels, detectors)


def test_hashing_is_stable_and_sensitive_to_path_and_content(tmp_path) -> None:
    first = tmp_path / "a.txt"
    second = tmp_path / "nested" / "b.txt"
    second.parent.mkdir()
    first.write_bytes(b"alpha\n")
    second.write_bytes(b"beta\n")

    assert canonical_json({"z": 1, "a": "é"}) == '{"a":"é","z":1}'
    assert content_hash({"z": 1, "a": 2}) == content_hash({"a": 2, "z": 1})
    assert hash_file(first) != hash_file(second)
    original = hash_files((second, first), root=tmp_path)
    assert original == hash_files(("a.txt", "nested/b.txt"), root=tmp_path)

    second.write_bytes(b"changed\n")
    assert hash_files((first, second), root=tmp_path) != original


def test_hash_files_rejects_ambiguous_or_out_of_root_sets(tmp_path) -> None:
    declared = tmp_path / "declared.txt"
    declared.write_text("data", encoding="utf-8")
    outside = tmp_path.parent / "outside-shaping-file.txt"
    outside.write_text("outside", encoding="utf-8")
    try:
        with pytest.raises(ValueError, match="duplicate"):
            hash_files((declared, "declared.txt"), root=tmp_path)
        with pytest.raises(ValueError, match="outside root"):
            hash_files((outside,), root=tmp_path)
        with pytest.raises(ValueError, match="at least one"):
            hash_files((), root=tmp_path)
    finally:
        outside.unlink()


def test_manifest_round_trip_write_and_reference(tmp_path) -> None:
    manifest = make_manifest()
    path = tmp_path / "runs" / "manifest.json"

    reference = write_manifest(manifest, path)

    assert reference == manifest.manifest_ref == content_hash(manifest)
    assert read_manifest(path) == manifest
    assert RunManifest.from_json(manifest.to_json()) == manifest
    assert RunManifest.from_dict(manifest.to_dict()) == manifest
    assert ModelEndpoint.from_dict(manifest.models[0].to_dict()) == manifest.models[0]
    assert path.read_text(encoding="utf-8") == manifest.to_json() + "\n"
    assert "api_key" not in path.read_text(encoding="utf-8")


def test_manifest_rejects_unversioned_secrets_and_invalid_hashes() -> None:
    data = make_manifest().to_dict()
    data["api_key"] = "do-not-persist"
    with pytest.raises(SchemaError, match="unknown fields"):
        RunManifest.from_dict(data)

    data = make_manifest().to_dict()
    data["corpus_hash"] = "short"
    with pytest.raises(SchemaError, match="sha256"):
        RunManifest.from_dict(data)


def test_shaping_lock_round_trip_compare_and_change_detection(tmp_path) -> None:
    prompt = tmp_path / "prompts" / "system.txt"
    policy = tmp_path / "policy.json"
    prompt.parent.mkdir()
    prompt.write_text("system prompt\n", encoding="utf-8")
    policy.write_text("{}\n", encoding="utf-8")

    lock = create_shaping_lock(
        (policy, prompt),
        run="run-001",
        date=date(2026, 9, 1),
        root=tmp_path,
    )
    lock_path = tmp_path / "shaping.lock"
    write_shaping_lock(lock, lock_path)

    assert lock.files == ("policy.json", "prompts/system.txt")
    assert read_shaping_lock(lock_path) == lock
    assert ShapingLock.from_json(lock.to_json()) == lock
    assert ShapingLock.from_dict(lock.to_dict()) == lock
    assert compare_shaping_lock(lock, root=tmp_path)

    prompt.write_text("changed prompt\n", encoding="utf-8")
    assert not compare_shaping_lock(lock, root=tmp_path)
    prompt.unlink()
    assert not compare_shaping_lock(lock, root=tmp_path)


def test_shaping_lock_rejects_unsorted_files_and_bad_dates() -> None:
    with pytest.raises(SchemaError, match="must be sorted"):
        ShapingLock(DIGEST_A, ("z.txt", "a.txt"), "run", "2026-09-01")
    with pytest.raises(SchemaError, match="ISO 8601 date"):
        ShapingLock(DIGEST_A, ("a.txt",), "run", "September 1")
    with pytest.raises(SchemaError, match="unknown fields"):
        ShapingLock.from_dict(
            {
                "sha256": DIGEST_A,
                "files": ["a.txt"],
                "run": "run",
                "date": "2026-09-01",
                "extra": True,
            }
        )
