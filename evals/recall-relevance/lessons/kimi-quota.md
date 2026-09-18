+++
id = "kimi-quota"
status = "promoted"
matchers = ["kimi"]
origin_run = "eval"
created = "2026-01-01"
+++

The kimi runner has a weekly usage limit. When it returns a 403 quota error, every run dispatched to it fails until the window resets; switch to another runner.
