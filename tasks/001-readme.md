+++
id = "001"
title = "docs: repo README"
owns = ["README.md"]
acceptance = "test -s README.md && grep -qi 'effect' README.md && grep -qi 'harness' README.md && grep -qi 'journal' README.md"
commit_type = "docs"
+++

## Goal

Write `README.md` for this repository (the `harness` project) — currently it
has none.

## Context (read these first)

- The thesis: every agent action is an algebraic effect;
  the harness is the handler stack (capture → policy → world); journaled,
  policy-checked, replayable.
- `runtime/src/` — the OCaml implementation (effects.ml, stack.ml, fleet.ml are the
  spine).

## Requirements

- ~60–100 lines of tight markdown: what the project is (one paragraph),
  the handler-stack diagram, the fleet-task contract (TOML frontmatter:
  id/title/owns/acceptance), a build-and-test section (opam switch
  `harness`, OCaml 5.3.0; `dune build && dune test`), a CLI usage section
  for `harness run | status | journal`, and the milestone table M1–M4 with
  M1 marked done.
- Factual claims must match the design notes and the actual
  code — do not invent features that don't exist yet; mark M2+ as planned.
- No marketing fluff. No first person.
