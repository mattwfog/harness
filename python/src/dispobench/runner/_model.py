"""Runner-owned structural contracts.

The core package owns the eventual concrete Record and Corpus dataclasses.  The
runner deliberately depends only on these small mapping-shaped contracts so it
can be developed and used without importing core.
"""

from __future__ import annotations

from dataclasses import dataclass, field
from typing import Any, Mapping, Protocol, TypeAlias, runtime_checkable


Scenario: TypeAlias = Mapping[str, Any]
ModelConfig: TypeAlias = Mapping[str, Any]
Record: TypeAlias = dict[str, Any]


@runtime_checkable
class AUTAdapter(Protocol):
    """Thin async adapter around an agent-under-test turn entrypoint."""

    async def run(
        self,
        scenario: Scenario,
        variant: str,
        model_cfg: ModelConfig,
    ) -> Record:
        """Run one scenario and return a JSON-serializable episode record."""


@dataclass(frozen=True, slots=True)
class BudgetCaps:
    """Maximum budget attributable to a run, including resumed records."""

    max_requests: int | None = None
    max_tokens: int | None = None

    def __post_init__(self) -> None:
        for name, value in (
            ("max_requests", self.max_requests),
            ("max_tokens", self.max_tokens),
        ):
            if value is not None and (
                isinstance(value, bool) or not isinstance(value, int) or value < 0
            ):
                raise ValueError(f"{name} must be a non-negative integer or None")


@dataclass(frozen=True, slots=True)
class RunConfig:
    """Deterministic selection, depth, endpoint, retry, and budget settings."""

    seed: int
    per_family: int
    k: int
    variant: str
    model_cfg: ModelConfig = field(default_factory=dict)
    budgets: BudgetCaps = field(default_factory=BudgetCaps)
    max_retries: int = 3
    require_smoke: bool = True
    adapter_id: str | None = None

    def __post_init__(self) -> None:
        if isinstance(self.seed, bool) or not isinstance(self.seed, int):
            raise ValueError("seed must be an integer")
        if (
            isinstance(self.per_family, bool)
            or not isinstance(self.per_family, int)
            or self.per_family < 1
        ):
            raise ValueError("per_family must be a positive integer")
        if isinstance(self.k, bool) or not isinstance(self.k, int) or self.k < 1:
            raise ValueError("k must be a positive integer")
        if not isinstance(self.variant, str) or not self.variant:
            raise ValueError("variant must be a non-empty string")
        if (
            isinstance(self.max_retries, bool)
            or not isinstance(self.max_retries, int)
            or self.max_retries < 0
        ):
            raise ValueError("max_retries must be a non-negative integer")
        if self.adapter_id is not None and (
            not isinstance(self.adapter_id, str) or not self.adapter_id
        ):
            raise ValueError("adapter_id must be non-empty when provided")
        if not isinstance(self.model_cfg, Mapping):
            raise ValueError("model_cfg must be a mapping")
        if not isinstance(self.budgets, BudgetCaps):
            raise ValueError("budgets must be BudgetCaps")
        if not isinstance(self.require_smoke, bool):
            raise ValueError("require_smoke must be a boolean")


@dataclass(frozen=True, slots=True)
class Episode:
    """One selected scenario repetition with its stable record key."""

    scenario: Scenario
    rep: int
    key: str


@dataclass(frozen=True, slots=True)
class RunSummary:
    """Accounting and completion status for a runner invocation."""

    mode: str
    selected: int
    planned: int
    completed: int
    resumed: int
    executed: int
    requests_used: int
    tokens_used: int
    stopped_reason: str | None
    record_keys: tuple[str, ...]

    @property
    def complete(self) -> bool:
        """Whether every planned episode finished without a budget stop."""

        return self.stopped_reason is None and self.completed == self.planned


class RunnerError(RuntimeError):
    """Base class for runner failures."""


class SmokeRequiredError(RunnerError):
    """Raised when a full run lacks a valid smoke receipt."""


class RunExecutionError(RunnerError):
    """Raised when an adapter call cannot complete after permitted retries."""

    def __init__(self, record_key: str, cause: Exception) -> None:
        super().__init__(f"adapter failed for {record_key}: {cause}")
        self.record_key = record_key
        self.cause = cause


class RetryAfterError(RunnerError):
    """Portable adapter error carrying a Retry-After value."""

    def __init__(self, retry_after: str | int | float, message: str = "retry later"):
        super().__init__(message)
        self.retry_after = retry_after
