+++
id = "runner-kimi-quota"
status = "probation"
matchers = ["kimi"]
origin_run = "run-20260901-050207"
created = "2026-09-01"
+++

The kimi runner has hit its provider usage limit (observed: exit 1: error: failed to run prompt: provider.api_error: 403 You've reached your weekly (7-day) usage limit. Your quota will reset when the current 7-day window ends. To continue now, purchase extra usage or upgrade your plan: https://www.kimi.com/membership/subscription?tab=quota). Runs dispatched to it will fail until the quota window resets; use a different --runner for now.
