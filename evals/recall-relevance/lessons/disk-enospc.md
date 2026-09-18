+++
id = "disk-enospc"
status = "promoted"
matchers = ["disk", "build"]
origin_run = "eval"
created = "2026-01-01"
+++

A full disk during a large build or patch apply can delete source files. Check free space before starting a full release build.
