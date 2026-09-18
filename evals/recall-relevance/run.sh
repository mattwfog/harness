#!/bin/sh
# Relevance eval for judged lesson recall.
#
# Twelve promoted lessons with deliberately broad matchers, twelve tasks, and a
# hand-labelled answer key (labels.json: task id -> lessons that really apply).
# Runs every task through the harness with --recall-judge jev, then scores the
# substring baseline and the judged selection at several thresholds from the
# probabilities recorded in the journal. One judge call per task.
#
# Usage: evals/recall-relevance/run.sh [path-to-harness-binary]
# Needs TYPESAFE_API_KEY (or ~/.config/typesafe/api_key); roughly 9k tokens.
set -eu
HERE=$(cd "$(dirname "$0")" && pwd)
HARNESS=${1:-$HERE/../../_build/default/runtime/bin/main.exe}
WORK=$(mktemp -d)
trap 'rm -rf "$WORK"' EXIT
cd "$WORK"
git init -q -b main
git config user.email eval@example.com
git config user.name eval
git commit -q --allow-empty -m root
cp -R "$HERE/lessons" lessons
cp "$HERE"/tasks/*.md .
cp "$HERE/agent.sh" agent.sh
chmod +x agent.sh
mkdir -p out
"$HARNESS" run --repo "$WORK" --runner "cmd:$WORK/agent.sh" \
  --recall-judge jev --run-id eval T*.md > /dev/null
python3 "$HERE/score.py" "$HERE/labels.json" "$WORK/.harness/journal/eval.jsonl"
