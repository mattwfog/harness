+++
id = "cargo-filter-vacuous"
status = "promoted"
matchers = ["cargo", "test"]
origin_run = "eval"
created = "2026-01-01"
+++

`cargo test <filter>` exits 0 when the filter matches no test. After adding a test, confirm the run reports at least one test executed.
