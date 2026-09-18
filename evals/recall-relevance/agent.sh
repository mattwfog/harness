#!/bin/sh
id=$(printf '%s' "$HARNESS_PROMPT" | /usr/bin/grep -o -E 'out/T[0-9]+\.txt' | head -1); mkdir -p out; printf '%s' "$HARNESS_PROMPT" > "$id"
