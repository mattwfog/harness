"""Deterministic aggregation and rendering for dispobench reports.

The report package deliberately consumes only persisted records and detached
detector verdicts.  It has no dependency on the runner, detector registry, or
core schema packages.
"""

from .report import build_report, render_json, render_markdown, wilson_interval

__all__ = [
    "build_report",
    "render_json",
    "render_markdown",
    "wilson_interval",
]
