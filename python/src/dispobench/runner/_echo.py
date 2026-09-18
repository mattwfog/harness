"""A deterministic adapter for exercising the dispobench platform itself."""

from __future__ import annotations

import hashlib
import json
from typing import Any

from ._model import ModelConfig, Record, Scenario


def _canonical_json(value: Any) -> str:
    return json.dumps(
        value,
        sort_keys=True,
        separators=(",", ":"),
        ensure_ascii=False,
        allow_nan=False,
    )


class EchoAdapter:
    """Return a complete deterministic record without making a model call."""

    async def run(
        self,
        scenario: Scenario,
        variant: str,
        model_cfg: ModelConfig,
    ) -> Record:
        scenario_id = str(scenario["scenario_id"])
        family = str(scenario["family"])
        rep = int(scenario.get("rep", 0))
        seed = int(scenario.get("seed", 0))
        history = list(scenario.get("history", []))
        system_prompt = str(scenario.get("system_prompt", ""))
        reply = scenario.get("echo_reply")
        if reply is None:
            reply = _last_content(history) or str(scenario.get("prompt", ""))
        prompt_hash = hashlib.sha256(
            _canonical_json(
                {"system_prompt": system_prompt, "history": history}
            ).encode("utf-8")
        ).hexdigest()
        key = str(
            scenario.get(
                "record_key",
                f"{scenario_id}:r{rep}:echo-{prompt_hash[:12]}",
            )
        )
        return {
            "key": key,
            "scenario_id": scenario_id,
            "family": family,
            "rep": rep,
            "variant": variant,
            "model": str(model_cfg.get("model", "echo")),
            "base_url": str(model_cfg.get("base_url", "echo://local")),
            "prompt_hash": prompt_hash,
            "system_prompt": system_prompt,
            "history": history,
            "tool_calls": [],
            "result": {"terminal": True, "action": None, "reply": str(reply)},
            "usage": {"input": 0, "cached": 0, "output": 0},
            "nudges": 0,
            "seed": seed,
            "wall_ms": 0,
            "finished_at": "1970-01-01T00:00:00Z",
            "manifest_ref": str(scenario.get("manifest_ref", "echo")),
        }


def _last_content(history: list[Any]) -> str:
    for message in reversed(history):
        if isinstance(message, dict) and message.get("content") is not None:
            return str(message["content"])
    return ""
