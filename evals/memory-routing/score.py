"""Score distill --verify routing against hand labels."""

import json
import sys


def main(labels_path: str, out_dir: str) -> None:
    labels = json.load(open(labels_path, encoding="utf-8"))
    routed: dict[str, tuple[str, dict[str, float]]] = {}
    tokens = 0
    for session in ("s1", "s2", "s3", "s4", "s5"):
        for line in open(f"{out_dir}/{session}/.harness/journal/distill-{session}.jsonl", encoding="utf-8"):
            entry = json.loads(line)
            kind, data = entry.get("kind"), entry.get("data", {})
            if kind in ("memory_kept", "memory_denied") and data["candidate"] in labels:
                layer = data["verdict"] if kind == "memory_kept" else "deny"
                routed[data["candidate"]] = (layer, data.get("probabilities", {}))
            elif kind == "judge" and entry.get("phase") == "result":
                tokens += data["input_tokens"] + data["output_tokens"]
    agree = 0
    print(f"{'id':<5}{'label':<11}{'routed':<11}{'sup':>5}{'con':>5}{'dur':>5}{'harm':>6}")
    for cid in sorted(labels):
        layer, p = routed.get(cid, ("missing", {}))
        ok = layer in labels[cid].split("|")
        agree += ok
        print(
            f"{cid:<5}{labels[cid]:<11}{layer:<11}"
            f"{p.get('supported', 0):>5.2f}{p.get('contradicted', 0):>5.2f}"
            f"{p.get('durable', 0):>5.2f}{p.get('harmful', 0):>6.2f}  {'' if ok else '<-- differs'}"
        )
    print(f"\nagreement with labels: {agree}/{len(labels)}   judge tokens: {tokens}")


if __name__ == "__main__":
    main(sys.argv[1], sys.argv[2])
