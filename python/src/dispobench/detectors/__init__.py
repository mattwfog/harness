"""The C4 detector registry and portable deterministic detector library."""

from .registry import (
    Detector,
    DetectorMetadata,
    DetectorRegistry,
    Record,
    RegisteredDetector,
)
from .stdlib import (
    empty_reply,
    markdown_in_reply,
    money_not_in_context,
    placeholder_echoed,
    protocol_no_terminal,
    reply_over_cap,
    unsanctioned_balance,
)

__all__ = [
    "Detector",
    "DetectorMetadata",
    "DetectorRegistry",
    "Record",
    "RegisteredDetector",
    "empty_reply",
    "markdown_in_reply",
    "money_not_in_context",
    "placeholder_echoed",
    "protocol_no_terminal",
    "reply_over_cap",
    "unsanctioned_balance",
]
