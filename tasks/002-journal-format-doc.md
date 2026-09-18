+++
id = "002"
title = "docs: journal format spec"
owns = ["docs/JOURNAL_FORMAT.md"]
acceptance = "test -s docs/JOURNAL_FORMAT.md && grep -q 'ref_seq' docs/JOURNAL_FORMAT.md && grep -q 'denied' docs/JOURNAL_FORMAT.md && grep -q 'request' docs/JOURNAL_FORMAT.md && grep -q 'tool_exec' docs/JOURNAL_FORMAT.md"
commit_type = "docs"
+++

## Goal

Write `docs/JOURNAL_FORMAT.md`: the specification of the effect-journal
JSONL format, derived from the actual code.

## Sources of truth (read these; do not invent)

- `runtime/src/journal.ml` — entry envelope: seq, ts, phase, kind, data, ref_seq.
- `runtime/src/handler_capture.ml` — which effects are journaled, request/result
  pairing, output caps, what a denial looks like.
- `runtime/src/effects.ml` — the canonical request encodings per effect kind.
- `runtime/src/handler_replay.ml` — how replay consumes the format (ordering
  contract, divergence rules).

## Requirements

- Document the envelope fields, the four phases (request/result/denied/
  note), request/result pairing via ref_seq, per-kind data payloads
  (tool_exec, file_read, file_exists, file_write, git_commit, notes), the
  200KB truncation rule and log_path escape hatch, and the ordering
  contract replay relies on.
- Include one short real-looking example entry per phase.
- Factual only; where the code caps or truncates, name the constant.
