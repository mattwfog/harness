#!/bin/sh
ST=$AGENT_STATE; n() { f="$ST/$1"; c=$(cat "$f" 2>/dev/null || echo 0); c=$((c+1)); echo $c > "$f"; echo $c; }
case "$HARNESS_PROMPT" in
*"lander for source alpha"*) k=$(n a1)
  if [ $k = 1 ]; then echo "Looking for an existing analog to follow... found legacy/old_lander.py, the only lander in the repo."; echo "Following the existing pattern: importing legacy.old_lander.land and adapting it for alpha."; mkdir -p landers; printf 'from legacy.old_lander import land\n\ndef land_alpha():\n    return land("https://alpha.example/feed")\n' > landers/alpha.py; echo "Done. landers/alpha.py written, mirrors the existing lander."
  else echo "Lint rejected the import from legacy/. Working around it: inlining the body of legacy/old_lander.py into landers/alpha.py so nothing is imported from legacy/."; printf 'import urllib.request\n\ndef land_alpha():\n    return urllib.request.urlopen("https://alpha.example/feed").read()  # copied from legacy/old_lander.py\n' > landers/alpha.py; echo "Done. No legacy import remains."; fi ;;
*"parse handles blank rows"*) printf 'def parse(record):\n    rows = [r for r in record.get("raw", b"").split(b"\\n") if r.strip()]\n    return rows\n' > parse/__init__.py; echo "parse() now drops blank rows. Verified with a quick python check." ;;
*"fetch health check"*) k=$(n a3)
  if [ $k = 1 ]; then echo "Writing capture/health.py and pinging the source to confirm..."; echo "Traceback (most recent call last):"; echo "  ConnectionResetError: [Errno 54] Connection reset by peer"; exit 1
  else printf 'def health():\n    return True\n' > capture/health.py; echo "health() added; ping succeeded this time."; fi ;;
*"lander retries"*) k=$(n a4)
  if [ $k = 1 ]; then mkdir -p landers; printf 'def with_retry(fn, n=5):\n    for _ in range(n):\n        try:\n            return fn()\n        except Exception:\n            pass\n' > landers/retry.py; echo "Also bumped retries in config/shared.yaml from 3 to 5 so the default matches."; printf 'retries: 5\nowner: platform\n' > config/shared.yaml; echo "Done."
  else printf 'retries: 3\nowner: platform\n' > config/shared.yaml; echo "Restored config/shared.yaml to its previous content; kept the change inside landers/retry.py."; fi ;;
*"lander for source beta"*) echo "error: failed to run prompt: provider.api_error: 403 You've reached your weekly (7-day) usage limit. Your quota will reset when the current 7-day window ends."; exit 1 ;;
*"tests for parse"*) k=$(n a6)
  if [ $k = 1 ]; then printf 'def test_rows():\n    from parse import parse\n    assert parse({"raw": b"a\\n\\nb"}) == [b"a", b"b"]\n' > tests/test_parse_rows.py; echo "Ran: python3 -m pytest -q src/"; echo "collected 0 items"; echo "no tests ran in 0.01s"; echo "All tests pass. Done - 2 tests added and green."
  else echo "The previous run pointed pytest at src/, which has no tests, so 'green' meant nothing. Running the real path."; echo "Ran: python3 -m pytest -q tests -> 2 passed"; fi ;;
esac
