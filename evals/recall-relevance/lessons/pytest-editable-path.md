+++
id = "pytest-editable-path"
status = "promoted"
matchers = ["pytest", "test"]
origin_run = "eval"
created = "2026-01-01"
+++

The Python venv's editable install can point at a stale path; run the Python tests with PYTHONPATH=src so the local package is the one imported.
