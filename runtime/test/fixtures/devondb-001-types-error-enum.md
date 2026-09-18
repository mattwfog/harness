+++
id = "001"
title = "devondb-types: workspace error type"
owns = ["crates/devondb-types/src"]
acceptance = "cargo test -p devondb-types error 2>&1 | grep -Eq 'test result: ok\\. [1-9][0-9]* passed'"
packages = ["devondb-types"]
commit_type = "feat"
+++

## Goal

Create the workspace-wide error type in `crates/devondb-types/src/error.rs`
and re-export it from `lib.rs`.

## Requirements

- `pub enum DevonError` using `thiserror`, with these variants (grow later):
  - `Io(#[from] std::io::Error)`
  - `Corrupt { context: String }` — invalid bytes on disk (bad magic, bad CRC)
  - `VersionMismatch { file_version: u32, min_reader_version: u32, supported: u32 }`
    — file newer than this binary understands; the Display message must name
    all three numbers and tell the user to upgrade devondb
    (see docs/FORMAT.md "Compatibility rules" rule 4)
  - `InvalidArgument { context: String }`
  - `NotFound { what: String }`
- `pub type DevonResult<T> = Result<T, DevonError>;`
- Every variant has a clear, user-facing `#[error(...)]` message.
- `lib.rs`: add `mod error;` + `pub use` of both items, keep existing crate
  docs intact.
- Unit tests in `error.rs` (`#[cfg(test)] mod tests`): at least the
  VersionMismatch Display message (asserts all three numbers appear) and the
  `From<std::io::Error>` conversion.

## Context

- `docs/ARCHITECTURE.md` — devondb-types is the dependency root; no engine
  logic here.
- `docs/FORMAT.md` — the VersionMismatch wording requirement comes from
  compatibility rule 4.
