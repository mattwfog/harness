"""Detector registration and metadata.

This module deliberately depends only on Python's standard library and plain
record dictionaries.  In particular, the detector contract must remain usable
without importing dispobench's core package.
"""

from __future__ import annotations

from collections.abc import Callable, Iterable, Iterator
from dataclasses import dataclass
from typing import Any, TypeAlias


Record: TypeAlias = dict[str, Any]
Detector: TypeAlias = Callable[[Record], bool | None]
ColumnHome: TypeAlias = str | Iterable[str]


@dataclass(frozen=True, slots=True)
class DetectorMetadata:
    """Stable metadata attached to a registered detector."""

    name: str
    column_home: str
    tags: tuple[str, ...]
    origin: str


@dataclass(frozen=True, slots=True)
class RegisteredDetector:
    """A detector paired with its matrix metadata."""

    metadata: DetectorMetadata
    detect: Detector

    @property
    def name(self) -> str:
        return self.metadata.name

    @property
    def column_home(self) -> str:
        return self.metadata.column_home

    @property
    def tags(self) -> tuple[str, ...]:
        return self.metadata.tags

    @property
    def origin(self) -> str:
        return self.metadata.origin

    def __call__(self, record: Record) -> bool | None:
        return self.detect(record)


class DetectorRegistry:
    """Insertion-ordered registry enforcing one column home per detector."""

    def __init__(self) -> None:
        self._registrations: dict[str, RegisteredDetector] = {}

    def register(
        self,
        detector: Detector,
        *,
        column_home: ColumnHome,
        name: str | None = None,
        tags: Iterable[str] | str = (),
        origin: str = "dispobench",
    ) -> RegisteredDetector:
        """Register ``detector`` or fail if its metadata violates C4.

        ``column_home`` accepts either a single string or a one-item iterable so
        that configuration-loaded lists can be validated at the registry
        boundary.  Empty and multi-item iterables are rejected.
        """

        if not callable(detector):
            raise TypeError("detector must be callable")

        detector_name = _non_empty_text(
            name if name is not None else getattr(detector, "__name__", None),
            "name",
        )
        home = _exactly_one_column_home(column_home)
        detector_origin = _non_empty_text(origin, "origin")
        detector_tags = _normalise_tags(tags)

        if detector_name in self._registrations:
            raise ValueError(f"detector already registered: {detector_name}")

        registration = RegisteredDetector(
            metadata=DetectorMetadata(
                name=detector_name,
                column_home=home,
                tags=detector_tags,
                origin=detector_origin,
            ),
            detect=detector,
        )
        self._registrations[detector_name] = registration
        return registration

    def get(self, name: str) -> RegisteredDetector:
        """Return a registration by name, raising ``KeyError`` if absent."""

        return self._registrations[name]

    def all(self) -> tuple[RegisteredDetector, ...]:
        """Return all registrations in deterministic insertion order."""

        return tuple(self._registrations.values())

    def by_column(self, column_home: str) -> tuple[RegisteredDetector, ...]:
        """Return registrations assigned to ``column_home`` in registry order."""

        return tuple(
            registration
            for registration in self._registrations.values()
            if registration.column_home == column_home
        )

    def __contains__(self, name: object) -> bool:
        return name in self._registrations

    def __iter__(self) -> Iterator[RegisteredDetector]:
        return iter(self._registrations.values())

    def __len__(self) -> int:
        return len(self._registrations)


def _non_empty_text(value: object, field: str) -> str:
    if not isinstance(value, str):
        raise TypeError(f"{field} must be a string")
    normalised = value.strip()
    if not normalised:
        raise ValueError(f"{field} must not be empty")
    return normalised


def _exactly_one_column_home(column_home: ColumnHome) -> str:
    if isinstance(column_home, str):
        homes: tuple[object, ...] = (column_home,)
    else:
        try:
            homes = tuple(column_home)
        except TypeError as exc:
            raise TypeError("column_home must be a string or iterable of strings") from exc

    if len(homes) != 1:
        raise ValueError(
            "detector must have exactly one column home "
            f"(received {len(homes)})"
        )
    return _non_empty_text(homes[0], "column_home")


def _normalise_tags(tags: Iterable[str] | str) -> tuple[str, ...]:
    values: Iterable[object] = (tags,) if isinstance(tags, str) else tags
    normalised: list[str] = []
    seen: set[str] = set()
    for tag in values:
        clean_tag = _non_empty_text(tag, "tag")
        if clean_tag not in seen:
            seen.add(clean_tag)
            normalised.append(clean_tag)
    return tuple(normalised)
