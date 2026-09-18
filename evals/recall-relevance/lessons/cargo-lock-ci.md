+++
id = "cargo-lock-ci"
status = "promoted"
matchers = ["cargo"]
origin_run = "eval"
created = "2026-01-01"
+++

CI builds with --locked. Any change to a Cargo.toml dependency must be committed together with the updated Cargo.lock or CI fails.
