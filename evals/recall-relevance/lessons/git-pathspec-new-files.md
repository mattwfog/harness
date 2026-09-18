+++
id = "git-pathspec-new-files"
status = "promoted"
matchers = ["git", "commit"]
origin_run = "eval"
created = "2026-01-01"
+++

A directory pathspec commit silently skips untracked files. When a task creates new files, name each new file explicitly when committing.
