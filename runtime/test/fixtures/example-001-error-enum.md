+++
id = "001"
title = "graphdb-types: workspace error type"
owns = ["crates/graphdb-types/src"]
acceptance = "cargo test -p graphdb-types error 2>&1 | grep -Eq 'test result: ok\\. [1-9][0-9]* passed'"
packages = ["graphdb-types"]
commit_type = "feat"
+++

## Goal

Create the workspace-wide error type in `crates/graphdb-types/src/error.rs`
and re-export it from `lib.rs`.

## Requirements

- `pub enum GraphError` using `thiserror`, with these variants (grow later):
  - `Io(#[from] std::io::Error)`
  - `Corrupt { context: String }` — invalid bytes on disk (bad magic, bad CRC)
  - `VersionMismatch { file_version: u32, min_reader_version: u32, supported: u32 }`
    — file newer than this binary understands; the Display message must name
    all three numbers and tell the user to upgrade graphdb
    (see docs/FORMAT.md "Compatibility rules" rule 4)
  - `InvalidArgument { context: String }`
  - `NotFound { what: String }`
- `pub type GraphResult<T> = Result<T, GraphError>;`
- Every variant has a clear, user-facing `#[error(...)]` message.
- `lib.rs`: add `mod error;` + `pub use` of both items, keep existing crate
  docs intact.
- Unit tests in `error.rs` (`#[cfg(test)] mod tests`): at least the
  VersionMismatch Display message (asserts all three numbers appear) and the
  `From<std::io::Error>` conversion.

## Context

- `docs/ARCHITECTURE.md` — graphdb-types is the dependency root; no engine
  logic here.
- `docs/FORMAT.md` — the VersionMismatch wording requirement comes from
  compatibility rule 4.
