"""Score substring recall against judged recall from a harness journal."""

import json
import sys


def main(labels_path: str, journal_path: str) -> None:
    labels = json.load(open(labels_path, encoding="utf-8"))
    probabilities: dict[str, dict[str, float]] = {}
    tokens = 0
    unavailable = 0
    for line in open(journal_path, encoding="utf-8"):
        entry = json.loads(line)
        kind, data = entry.get("kind"), entry.get("data", {})
        if kind == "recall_judged":
            probabilities[data["task"]] = data["probabilities"]
        elif kind == "recall_judge_unavailable":
            unavailable += 1
        elif kind == "judge" and entry.get("phase") == "result":
            tokens += data["input_tokens"] + data["output_tokens"]
    print(f"judge calls: {len(probabilities)}  tokens: {tokens}  fallbacks: {unavailable}")
    print(f"{'selector':<12}{'TP':>4}{'FP':>4}{'FN':>4}{'injected':>10}{'precision':>11}{'recall':>8}")
    for name, threshold in (("substring", -1.0), ("jev>=0.3", 0.3), ("jev>=0.5", 0.5), ("jev>=0.7", 0.7)):
        tp = fp = fn = 0
        for task, relevant in labels.items():
            chosen = {l for l, p in probabilities.get(task, {}).items() if p >= threshold}
            tp += len(chosen & set(relevant))
            fp += len(chosen - set(relevant))
            fn += len(set(relevant) - chosen)
        precision = tp / (tp + fp) if tp + fp else 1.0
        recall = tp / (tp + fn) if tp + fn else 1.0
        print(f"{name:<12}{tp:>4}{fp:>4}{fn:>4}{tp + fp:>10}{precision:>11.2f}{recall:>8.2f}")
    print()
    for task in sorted(labels):
        ranked = sorted(probabilities.get(task, {}).items(), key=lambda item: -item[1])
        row = ", ".join(f"{l}={p:.2f}{'*' if l in labels[task] else ''}" for l, p in ranked)
        print(f"{task} | {row or '(no substring hits: judge not called)'}")
    print("\n* = labelled relevant")


if __name__ == "__main__":
    main(sys.argv[1], sys.argv[2])
