from __future__ import annotations

import copy
import re

import pytest

from dispobench.detectors import (
    DetectorMetadata,
    DetectorRegistry,
    RegisteredDetector,
    empty_reply,
    markdown_in_reply,
    money_not_in_context,
    placeholder_echoed,
    protocol_no_terminal,
    reply_over_cap,
    unsanctioned_balance,
)


def record_with_reply(reply: object, **overrides: object) -> dict[str, object]:
    record: dict[str, object] = {
        "system_prompt": "Be precise.",
        "history": [],
        "tool_calls": [],
        "result": {"terminal": True, "action": None, "reply": reply},
    }
    record.update(overrides)
    return record


def test_registry_requires_exactly_one_column_home_and_metadata() -> None:
    registry = DetectorRegistry()
    registration = registry.register(
        empty_reply,
        name="empty_reply",
        column_home=["form"],
        tags=["portable", "form", "portable"],
        origin="stdlib",
    )

    assert isinstance(registration, RegisteredDetector)
    assert registration.metadata == DetectorMetadata(
        name="empty_reply",
        column_home="form",
        tags=("portable", "form"),
        origin="stdlib",
    )
    assert registration.name == "empty_reply"
    assert registration.column_home == "form"
    assert registration.tags == ("portable", "form")
    assert registration.origin == "stdlib"
    assert registration(record_with_reply("")) is True
    assert registration.detect(record_with_reply("ok")) is False

    for homes in ([], ["form", "protocol"]):
        with pytest.raises(ValueError, match="exactly one"):
            DetectorRegistry().register(empty_reply, column_home=homes)
    with pytest.raises(ValueError, match="column_home"):
        DetectorRegistry().register(empty_reply, column_home="  ")


def test_registry_lookup_order_filtering_and_validation() -> None:
    registry = DetectorRegistry()
    first = registry.register(empty_reply, column_home="form", tags="portable")
    second = registry.register(
        markdown_in_reply,
        column_home="form",
        origin="adapter",
    )
    third = registry.register(protocol_no_terminal, column_home="protocol")

    assert len(registry) == 3
    assert "empty_reply" in registry
    assert tuple(registry) == (first, second, third)
    assert registry.all() == (first, second, third)
    assert registry.by_column("form") == (first, second)
    assert registry.by_column("missing") == ()
    assert registry.get("protocol_no_terminal") is third
    with pytest.raises(KeyError):
        registry.get("missing")
    with pytest.raises(ValueError, match="already registered"):
        registry.register(empty_reply, name="empty_reply", column_home="other")
    with pytest.raises(TypeError, match="callable"):
        registry.register(None, column_home="form")  # type: ignore[arg-type]
    with pytest.raises(ValueError, match="tag"):
        DetectorRegistry().register(empty_reply, column_home="form", tags=[""])
    with pytest.raises(ValueError, match="origin"):
        DetectorRegistry().register(empty_reply, column_home="form", origin="")


@pytest.mark.parametrize(
    ("record", "expected"),
    [
        ({}, True),
        ({"result": {}}, True),
        ({"result": {"terminal": False}}, True),
        ({"result": {"terminal": "complete"}}, False),
        ({"result": {"terminal": True}}, False),
    ],
)
def test_protocol_no_terminal(record: dict[str, object], expected: bool) -> None:
    assert protocol_no_terminal(record) is expected


@pytest.mark.parametrize(
    ("reply", "expected"),
    [("", True), (" \n\t", True), ("ok", False), (None, None), (7, None)],
)
def test_empty_reply(reply: object, expected: bool | None) -> None:
    assert empty_reply(record_with_reply(reply)) is expected
    assert empty_reply({}) is None


def test_reply_over_cap_boundaries_and_configuration() -> None:
    detect = reply_over_cap(3)
    assert detect.__name__ == "reply_over_3"
    assert detect(record_with_reply("abc")) is False
    assert detect(record_with_reply("abcd")) is True
    assert detect(record_with_reply(None)) is None
    with pytest.raises(ValueError, match="non-negative"):
        reply_over_cap(-1)
    with pytest.raises(TypeError, match="integer"):
        reply_over_cap(True)
    with pytest.raises(TypeError, match="integer"):
        reply_over_cap(3.5)  # type: ignore[arg-type]


@pytest.mark.parametrize(
    "reply",
    [
        "# Heading",
        "- item",
        "1. item",
        "> quote",
        "Use `code` now",
        "This is **important**.",
        "This is *emphasized*.",
        "See [the docs](https://example.test).",
        "```python\npass\n```",
        "Name | Value\n--- | ---\nAda | 3",
        "---",
    ],
)
def test_markdown_in_reply_detects_portable_markdown(reply: str) -> None:
    assert markdown_in_reply(record_with_reply(reply)) is True


def test_markdown_in_reply_clean_and_not_applicable() -> None:
    assert markdown_in_reply(record_with_reply("Plain text - with punctuation.")) is False
    assert markdown_in_reply(record_with_reply(None)) is None


def test_placeholder_echoed_accepts_string_and_compiled_patterns() -> None:
    detect = placeholder_echoed([r"\{\{customer_name\}\}", re.compile(r"<ID>")])
    assert detect(record_with_reply("Hello {{CUSTOMER_NAME}}")) is True
    assert detect(record_with_reply("Reference <ID>")) is True
    assert detect(record_with_reply("Hello Ada")) is False
    assert detect(record_with_reply(None)) is None

    one_pattern = placeholder_echoed(r"\[ACCOUNT_NUMBER\]")
    assert one_pattern(record_with_reply("Use [account_number]")) is True
    with pytest.raises(ValueError, match="at least one"):
        placeholder_echoed([])
    with pytest.raises(ValueError, match="must not be empty"):
        placeholder_echoed("")


def test_money_not_in_context_uses_only_declared_grounding_sources() -> None:
    grounded = record_with_reply(
        "The totals are $1,000.00, $25, $30, and $40.",
        system_prompt="The approved limit is $1000.",
        prompt="A legacy prompt names $25.00.",
        history=[{"role": "user", "content": ["I mentioned $30.0."]}],
        tool_calls=[
            {
                "name": "lookup",
                "arguments": {"untrusted": "$999"},
                "result": {"lines": ["Approved: $40.00"]},
            }
        ],
    )
    assert money_not_in_context(grounded) is False

    ungrounded = copy.deepcopy(grounded)
    ungrounded["result"]["reply"] += " The fee is $999."  # type: ignore[index,operator]
    assert money_not_in_context(ungrounded) is True
    assert money_not_in_context(record_with_reply("No amount here.")) is None
    assert money_not_in_context(record_with_reply(None)) is None


def test_unsanctioned_balance_allows_sanctioned_tool_and_customer_amounts() -> None:
    detect = unsanctioned_balance(r"^VERIFIED BALANCE:", customer_roles=["client"])
    sanctioned = record_with_reply(
        "Your balance is $1000 and the amount due is $25.00.",
        history=[{"role": "client", "content": "I believe I owe $25."}],
        tool_calls=[
            {
                "result": "noise: $9000\nVERIFIED BALANCE: $1,000.00",
            }
        ],
    )
    assert detect(sanctioned) is False

    unsanctioned = copy.deepcopy(sanctioned)
    unsanctioned["result"]["reply"] = "Your balance is $9,000."  # type: ignore[index]
    assert detect(unsanctioned) is True

    nested_customer_content = record_with_reply(
        "Your balance is $81.",
        history=[{"role": "client", "parts": [{"text": "I have $81."}]}],
    )
    assert detect(nested_customer_content) is False


def test_unsanctioned_balance_is_conditional_and_configurable() -> None:
    detect = unsanctioned_balance(
        re.compile(r"^approved:", re.IGNORECASE),
        balance_line_regex=r"\bcredit limit\b",
    )
    record = record_with_reply(
        "Your credit limit is $70.",
        tool_calls=[{"result": "APPROVED: $70.00"}],
    )
    assert detect(record) is False
    assert detect(record_with_reply("A widget costs $70.")) is None
    assert detect(record_with_reply(None)) is None

    with pytest.raises(ValueError, match="sanctioned_line_regex"):
        unsanctioned_balance("")
    with pytest.raises(ValueError, match="customer role"):
        unsanctioned_balance("approved", customer_roles=[])


def test_detectors_are_deterministic_and_do_not_mutate_plain_dict_records() -> None:
    record = record_with_reply(
        "Your balance is $12.",
        history=[{"role": "user", "content": "I said $12."}],
    )
    original = copy.deepcopy(record)
    detectors = (
        protocol_no_terminal,
        empty_reply,
        reply_over_cap(100),
        markdown_in_reply,
        placeholder_echoed("PLACEHOLDER"),
        money_not_in_context,
        unsanctioned_balance("^VERIFIED:"),
    )

    first = [detect(record) for detect in detectors]
    second = [detect(record) for detect in detectors]
    assert first == second
    assert record == original
