# Effect journal JSONL format

The effect journal is an append-only JSON Lines file at
`<journal-dir>/<run-id>.jsonl`. Each line is one compact JSON object followed by
a newline. The writer flushes the channel after every line, before the captured
continuation is resumed. There is no header or schema version record.

This document describes the format emitted by `Journal` and
`Handler_capture`, the canonical request payloads in `Effects`, and the
ordering consumed by `Handler_replay`.

## Entry envelope

Every entry has these fields:

| Field | JSON type | Meaning |
|---|---|---|
| `seq` | integer | Emission sequence number. A newly opened `Journal.t` starts its counter at zero and increments it before each entry, so its first emitted entry is 1. |
| `ts` | string | UTC emission time in `YYYY-MM-DDTHH:MM:SS.mmmZ` form. |
| `phase` | string | One of `request`, `result`, `denied`, or `note`. |
| `kind` | string | Effect kind for requests and outcomes; the caller-supplied label for notes. |
| `data` | JSON value | Phase- and kind-specific payload. |
| `ref_seq` | integer | Present on `result` and `denied` entries. It is the `seq` of the corresponding request. It is absent from requests and notes. |

`Journal.open_journal` opens the file in append mode. The in-memory `seq`
counter is nevertheless initialized to zero; it is not recovered from existing
lines.

## Phases and examples

### `request`

Capture writes a request immediately before forwarding an effect to the next
handler. It has no `ref_seq`.

```json
{"seq":8,"ts":"2026-09-01T12:00:00.014Z","phase":"request","kind":"tool_exec","data":{"argv":["dune","test"],"cwd":"/work/harness","timeout_s":900,"env_extra":[]}}
```

### `result`

Capture writes a result after the forwarded effect returns successfully and
before resuming the program. `ref_seq` points to the request.

```json
{"seq":9,"ts":"2026-09-01T12:00:01.102Z","phase":"result","kind":"tool_exec","data":{"exit_code":0,"output":"","output_truncated":false,"log_path":"/work/harness/.harness/logs/002.test.log","duration_ms":1088},"ref_seq":8}
```

### `failed`

An effect the world could not carry out — a `git add` that matched nothing, a
judge transport error. `data` is `{"reason":"..."}` and `ref_seq` names the
request. It is distinct from `denied`: policy had no objection; reality did.
Replay re-raises the recorded failure.

### `denied`

Capture writes a denial when the forwarded effect raises `Policy_denied`, or
when it raises any other exception. A policy denial records the policy's
reason; another exception records `Printexc.to_string` of that exception. The
payload is always an object containing `reason`, and `ref_seq` points to the
request.

```json
{"seq":11,"ts":"2026-09-01T12:00:02.004Z","phase":"denied","kind":"tool_exec","data":{"reason":"empty argv"},"ref_seq":10}
```

### `note`

A `Note (label, data)` effect produces one note entry: `kind` is `label`, and
`data` is the caller-provided JSON value. Notes do not have separate request or
result entries and do not have `ref_seq`.

```json
{"seq":12,"ts":"2026-09-01T12:00:02.005Z","phase":"note","kind":"attempt_start","data":{"task":"002","attempt":1}}
```

## Request/result pairing

For `tool_exec`, `file_read`, `file_exists`, `file_write`, `git_commit`, and
`judge`, a
request is followed by exactly one outcome: either `result` or `denied`. The
capture handler passes the request's returned `seq` to the outcome writer as
`ref_seq`. A denied effect has no result entry.

Notes are single entries and are not paired. The capture handler also forwards
the `Note` effect after journaling it, but it does not journal an outcome for
the note.

## Data payloads by kind

Request field names and construction order are the canonical encodings used by
both capture and replay. The result fields below are the schemas emitted by
capture and decoded by replay.

### `tool_exec`

Request `data`:

| Field | JSON type | Meaning |
|---|---|---|
| `argv` | array of strings | Program and arguments; no implicit shell is added. |
| `cwd` | string | Working directory. |
| `timeout_s` | integer | Timeout in seconds. |
| `env_extra` | array of objects | One `{"name","md5"}` per extra environment variable. Values are never journaled (they may be secrets); the digest makes a changed value — such as a drifted prompt handed to a `cmd:` runner through `HARNESS_PROMPT` — diverge on replay. |

The effect request also contains `log_hint`, but its canonical journal
encoding omits that field.

Successful result `data`:

| Field | JSON type | Meaning |
|---|---|---|
| `exit_code` | integer | Process exit status. |
| `output` | string | Combined stdout and stderr, possibly capped. |
| `output_truncated` | boolean | Whether `output` was longer than the capture cap. |
| `log_path` | string | Path to the uncapped full-output log. |
| `duration_ms` | integer | Process duration in milliseconds. |

### `file_read`

Request `data` is `{"path":"..."}`.

Successful result `data` contains:

| Field | JSON type | Meaning |
|---|---|---|
| `bytes` | integer | Length of the full string returned by the world handler, before capping. |
| `content` | string | File content, possibly capped. |
| `content_truncated` | boolean | Whether the returned content exceeded the capture cap. |

### `file_exists`

Request `data` is `{"path":"..."}`. Successful result `data` is
`{"exists":true}` or `{"exists":false}`.

### `file_write`

Request `data` contains:

| Field | JSON type | Meaning |
|---|---|---|
| `path` | string | Destination path. |
| `bytes` | integer | Length of the content string. |
| `md5` | string | Lowercase hexadecimal OCaml `Digest` (MD5) of the content. |

The content itself is not journaled. Successful result `data` is the empty
object `{}`.

### `git_commit`

Request `data` contains `repo` (string), `message` (string), and `paths`
(array of strings). Successful result `data` is `{"sha":"..."}`.

### `judge`

A model judgment: yes/no questions about a JSON state, answered with one
probability per question and no generated text. Request `data` contains
`model` (string), `state` (any JSON value), and `questions` (array of objects
with `qid`, `instructions`, `yes`, `no`). The full question text is part of the
request so that a reworded question diverges on replay. Successful result
`data` contains `probabilities` (object: `qid` to a number in 0..1),
`model_used` (string), `input_tokens` and `output_tokens` (integers). The API
credential never appears in a request, a result, or a log. Replay answers a
`judge` request from this recorded result, so a probabilistic service does not
make a recorded run non-reproducible.

### `clock`

Request `data` is `{}`; result `data` is `{"epoch": <UTC seconds>}`. Recall reads
the clock only when an immediate memory's expiry has to be checked, and distill
reads it to date and expire what it writes, so both replay with the recorded
time.

### Notes

Notes have phase `note`, use their arbitrary label as `kind`, and preserve the
caller-provided JSON value as `data`. They therefore have no fixed data schema.

Notes the fleet program emits include `recall` (lessons injected),
`recall_judged` (per-lesson probabilities and the threshold),
`recall_judge_unavailable` (the judge was denied or failed; substring recall
was used), `scope_violation` (tracked files changed outside the task's owned
paths, with the paths) and `scope_strays` (new untracked files outside them).
Distill emits `memory_kept` and `memory_denied` (candidate id, verdict — a layer,
or `harmful` / `contradicted` / `unsupported` — and the four probabilities),
`memory_unverified` (the judge was unavailable; the proposer's own layer hint
was used) and `lesson_contradicted` (a promoted lesson sent back to probation).

### Denials for any paired kind

A denied `tool_exec`, `file_read`, `file_exists`, `file_write`, `git_commit`, or
`judge` uses `{"reason":"..."}` as `data`. Policy currently checks `tool_exec`,
`file_write`, `git_commit`, and `judge` (allowlisted model, bounded question
count and state size); reads and existence checks pass through policy,
although an exception from any forwarded paired effect is still recorded with
phase `denied`.

## The 200 KB capture cap

The cap is the code constant `Handler_capture.output_cap`, whose value is
`200_000` bytes. It applies independently to `tool_exec.data.output` and
`file_read.data.content`. Truncation occurs only when `String.length` is greater
than `200_000`; the journal stores the first `200_000` bytes and sets the
corresponding `*_truncated` flag to `true`.

For `tool_exec`, `log_path` is the escape hatch: the subprocess output is tee'd
to that file without the journal cap, so the path identifies the complete
combined stdout/stderr log. `file_read` has no `log_path` escape hatch. Replay
raises `Unreplayable` if a file-read result says `content_truncated: true` (or
if the result lacks `content`, as in journals predating content capture).

## Replay ordering and divergence

Replay reads the JSONL entries in file order and never consults the world
handler. For each performed paired effect it:

1. Consumes the next entry and requires phase `request` and the expected
   `kind`.
2. Serializes the recorded `data` and the effect's canonical request encoding
   with `Yojson.Safe.to_string` and requires the strings to be equal.
3. Consumes the immediately following entry and requires its phase to be
   `result` or `denied`.
4. Decodes result `data`, or reconstructs `Policy_denied` from denial `data`.

Thus adjacency is part of the ordering contract. The current replay matcher
does not validate the outcome entry's `ref_seq` or `kind`; producers must still
write both as specified above, and the journal helpers do so. A note consumes
exactly the next entry and requires phase `note`, the same label in `kind`, and
the same serialized `data`.

Replay raises `Divergence` at the relevant sequence point for an exhausted
journal when another effect is performed, a phase or kind mismatch, a changed
canonical request payload, an unexpected outcome phase, or a mismatched note.
If the replayed program finishes while entries remain, `Fleet.run_replay`
reports the replay as incomplete; successful replay requires
`Handler_replay.fully_consumed`.
