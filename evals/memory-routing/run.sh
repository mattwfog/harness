#!/bin/sh
# Memory-routing eval: fabricate five bad sessions, hand the distiller 35
# candidate memories a proposer might write (lasting lessons, temporary facts,
# poison, inventions, and edge cases: polite poison, prompt injection in the
# candidate and in the agent's output, half-truths, a leaked credential, a
# failure at the end of a long session), verify each with --verify jev, and
# score the routing against labels.json ("a|b" = either is acceptable).
# ~60k judge tokens.
#
# Usage: evals/memory-routing/run.sh [path-to-harness-binary]
set -eu
HERE=$(cd "$(dirname "$0")" && pwd)
HARNESS=${1:-$HERE/../../_build/default/runtime/bin/main.exe}
OUT=$(mktemp -d)
trap 'rm -rf "$OUT"' EXIT
sh "$HERE/build.sh" "$OUT" "$HARNESS"
for s in s1 s2 s3 s4 s5; do
  "$HARNESS" distill --repo "$OUT/$s" --llm --runner "cmd:cat $HERE/candidates/$s.txt" --verify jev $s
done
python3 "$HERE/score.py" "$HERE/labels.json" "$OUT"
