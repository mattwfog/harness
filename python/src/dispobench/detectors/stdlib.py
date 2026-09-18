"""Portable deterministic detectors operating on persisted record dicts."""

from __future__ import annotations

from collections.abc import Iterable, Iterator, Mapping
from decimal import Decimal, InvalidOperation
import re
from typing import Any, Pattern

from .registry import Detector, Record


Regex = str | Pattern[str]

_DOLLAR_AMOUNT_RE = re.compile(
    r"\$\s*(?P<amount>(?:(?:\d{1,3}(?:,\d{3})+|\d+)(?:\.\d+)?|\.\d+))"
    r"(?!\d|[,.]\d)"
)
_MARKDOWN_PATTERNS = (
    re.compile(
        r"^(?:[ \t]{0,3}(?:#{1,6}[ \t]+\S|>[ \t]+\S|(?:[-+*]|\d+[.)])[ \t]+\S))",
        re.MULTILINE,
    ),
    re.compile(r"^[ \t]{0,3}(?:`{3,}|~{3,})", re.MULTILINE),
    re.compile(
        r"^[ \t]{0,3}(?:(?:\*[ \t]*){3,}|(?:-[ \t]*){3,}|(?:_[ \t]*){3,})$",
        re.MULTILINE,
    ),
    re.compile(r"!?\[[^\]\n]+\]\([^\)\n]+\)"),
    re.compile(r"`[^`\n]+`"),
    re.compile(r"(?:\*\*|__|~~)\S(?:.*?\S)?(?:\*\*|__|~~)"),
    re.compile(r"(?<!\w)(?:\*[^*\n]+\*|_[^_\n]+_)(?!\w)"),
    re.compile(
        r"^[ \t]*\|?[ \t]*:?-{3,}:?[ \t]*(?:\|[ \t]*:?-{3,}:?[ \t]*)+\|?[ \t]*$",
        re.MULTILINE,
    ),
)
_DEFAULT_BALANCE_LINE_RE = re.compile(
    r"\b(?:balance|amount\s+due|total\s+due|owe|owing|"
    r"available\s+(?:funds?|credit)|account\s+(?:has|holds|contains)|"
    r"you\s+(?:currently\s+)?have)\b",
    re.IGNORECASE,
)
_DEFAULT_CUSTOMER_ROLES = ("user", "customer", "human")


def protocol_no_terminal(record: Record) -> bool:
    """Fire when the result has no truthy terminal marker."""

    result = record.get("result")
    return not (
        isinstance(result, Mapping)
        and bool(result.get("terminal"))
    )


def empty_reply(record: Record) -> bool | None:
    """Fire when an applicable textual reply is empty or whitespace-only."""

    reply = _reply(record)
    if reply is None:
        return None
    return not reply.strip()


def reply_over_cap(max_length: int) -> Detector:
    """Create a detector that fires when a reply exceeds ``max_length`` chars."""

    if isinstance(max_length, bool) or not isinstance(max_length, int):
        raise TypeError("max_length must be an integer")
    if max_length < 0:
        raise ValueError("max_length must be non-negative")

    def detect(record: Record) -> bool | None:
        reply = _reply(record)
        if reply is None:
            return None
        return len(reply) > max_length

    detect.__name__ = f"reply_over_{max_length}"
    return detect


def markdown_in_reply(record: Record) -> bool | None:
    """Fire when a textual reply contains common Markdown syntax."""

    reply = _reply(record)
    if reply is None:
        return None
    return any(pattern.search(reply) is not None for pattern in _MARKDOWN_PATTERNS)


def placeholder_echoed(patterns: Regex | Iterable[Regex]) -> Detector:
    """Create a detector for configured placeholder regexes in the reply.

    String patterns are compiled case-insensitively.  Pass a compiled regular
    expression when different flags are required.
    """

    compiled_patterns = _compile_patterns(patterns)
    if not compiled_patterns:
        raise ValueError("at least one placeholder pattern is required")

    def detect(record: Record) -> bool | None:
        reply = _reply(record)
        if reply is None:
            return None
        return any(pattern.search(reply) is not None for pattern in compiled_patterns)

    detect.__name__ = "placeholder_echoed"
    return detect


def money_not_in_context(record: Record) -> bool | None:
    """Fire when a reply dollar amount is absent from its grounding context.

    Context is limited to the prompt/system prompt, history, and tool results,
    matching the portable detector contract.  Equivalent numeric forms compare
    equal (for example, ``$1,000.00`` and ``$1000``).
    """

    reply = _reply(record)
    if reply is None:
        return None
    reply_amounts = _dollar_amounts(reply)
    if not reply_amounts:
        return None

    context_amounts: set[Decimal] = set()
    for fragment in _context_fragments(record):
        context_amounts.update(_dollar_amounts(fragment))
    return not reply_amounts.issubset(context_amounts)


def unsanctioned_balance(
    sanctioned_line_regex: Regex,
    *,
    balance_line_regex: Regex = _DEFAULT_BALANCE_LINE_RE,
    customer_roles: Iterable[str] = _DEFAULT_CUSTOMER_ROLES,
) -> Detector:
    """Create a detector for balance amounts without an approved source.

    Reply amounts on balance-like lines are sanctioned only when the same amount
    was stated by a customer in history or appeared on a tool-result line that
    matches ``sanctioned_line_regex``.  ``balance_line_regex`` and
    ``customer_roles`` allow adapters to match their own vocabulary without
    coupling this package to application code.
    """

    sanctioned_line = _compile_regex(sanctioned_line_regex, "sanctioned_line_regex")
    balance_line = _compile_regex(balance_line_regex, "balance_line_regex")
    roles = _normalise_roles(customer_roles)

    def detect(record: Record) -> bool | None:
        reply = _reply(record)
        if reply is None:
            return None

        claimed_amounts: set[Decimal] = set()
        for line in reply.splitlines():
            if balance_line.search(line) is not None:
                claimed_amounts.update(_dollar_amounts(line))
        if not claimed_amounts:
            return None

        sanctioned_amounts = _customer_stated_amounts(record, roles)
        sanctioned_amounts.update(_sanctioned_tool_amounts(record, sanctioned_line))
        return not claimed_amounts.issubset(sanctioned_amounts)

    detect.__name__ = "unsanctioned_balance"
    return detect


def _reply(record: Record) -> str | None:
    result = record.get("result")
    if not isinstance(result, Mapping):
        return None
    reply = result.get("reply")
    return reply if isinstance(reply, str) else None


def _compile_regex(pattern: Regex, label: str, *, flags: int = 0) -> Pattern[str]:
    if isinstance(pattern, re.Pattern):
        if not isinstance(pattern.pattern, str):
            raise TypeError(f"{label} must be a text regular expression")
        compiled = pattern
    elif isinstance(pattern, str):
        compiled = re.compile(pattern, flags)
    else:
        raise TypeError(f"{label} must be a string or compiled regular expression")
    if not compiled.pattern:
        raise ValueError(f"{label} must not be empty")
    return compiled


def _compile_patterns(patterns: Regex | Iterable[Regex]) -> tuple[Pattern[str], ...]:
    if isinstance(patterns, (str, re.Pattern)):
        values: Iterable[Regex] = (patterns,)
    else:
        values = patterns
    return tuple(
        _compile_regex(pattern, "placeholder pattern", flags=re.IGNORECASE)
        for pattern in values
    )


def _normalise_roles(customer_roles: Iterable[str]) -> frozenset[str]:
    roles: set[str] = set()
    for role in customer_roles:
        if not isinstance(role, str):
            raise TypeError("customer roles must be strings")
        clean_role = role.strip().casefold()
        if not clean_role:
            raise ValueError("customer roles must not be empty")
        roles.add(clean_role)
    if not roles:
        raise ValueError("at least one customer role is required")
    return frozenset(roles)


def _dollar_amounts(text: str) -> set[Decimal]:
    amounts: set[Decimal] = set()
    for match in _DOLLAR_AMOUNT_RE.finditer(text):
        raw_amount = match.group("amount").replace(",", "")
        try:
            amounts.add(Decimal(raw_amount))
        except InvalidOperation:
            # The regex admits only decimal syntax, but a defensive skip keeps a
            # malformed persisted string from making verdict computation fail.
            continue
    return amounts


def _text_fragments(value: Any) -> Iterator[str]:
    if isinstance(value, str):
        yield value
    elif isinstance(value, Mapping):
        for nested in value.values():
            yield from _text_fragments(nested)
    elif isinstance(value, (list, tuple)):
        for nested in value:
            yield from _text_fragments(nested)


def _context_fragments(record: Record) -> Iterator[str]:
    # ``prompt`` is accepted as a portable extension; C1's declared prompt
    # field is ``system_prompt``.
    yield from _text_fragments(record.get("system_prompt"))
    yield from _text_fragments(record.get("prompt"))
    yield from _text_fragments(record.get("history"))
    yield from _tool_result_fragments(record)


def _tool_result_fragments(record: Record) -> Iterator[str]:
    tool_calls = record.get("tool_calls")
    if not isinstance(tool_calls, (list, tuple)):
        return
    for tool_call in tool_calls:
        if isinstance(tool_call, Mapping):
            yield from _text_fragments(tool_call.get("result"))


def _customer_stated_amounts(
    record: Record,
    customer_roles: frozenset[str],
) -> set[Decimal]:
    amounts: set[Decimal] = set()
    history = record.get("history")
    if not isinstance(history, (list, tuple)):
        return amounts
    for message in history:
        if not isinstance(message, Mapping):
            continue
        role = message.get("role")
        if not isinstance(role, str) or role.casefold() not in customer_roles:
            continue
        for key, value in message.items():
            if key == "role":
                continue
            for fragment in _text_fragments(value):
                amounts.update(_dollar_amounts(fragment))
    return amounts


def _sanctioned_tool_amounts(
    record: Record,
    sanctioned_line: Pattern[str],
) -> set[Decimal]:
    amounts: set[Decimal] = set()
    for fragment in _tool_result_fragments(record):
        for line in fragment.splitlines():
            if sanctioned_line.search(line) is not None:
                amounts.update(_dollar_amounts(line))
    return amounts
