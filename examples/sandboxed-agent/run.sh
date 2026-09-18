#!/bin/sh
# Run a harness task with an UNTRUSTED model as the agent, confined by a macOS
# sandbox profile instead of trusting the agent runtime's own sandbox.
#
#   - the agent (and everything it spawns) cannot read /Users or /Volumes
#   - writes are confined to a throwaway run directory and the system temp dirs
#   - the process gets a scrubbed environment: PATH, a temp HOME, a clean
#     CODEX_HOME with only the OpenRouter provider, and the one API key
#   - the harness never passes its judge key to the agent process
#
# codex applies its own sandbox-exec to each command, and macOS refuses a
# nested sandbox, so codex runs with its inner sandbox off: the outer profile
# is the single, stricter layer. Network stays open (the agent runtime needs
# the model API); with nothing private readable there is nothing to send.
#
# Usage: OPENROUTER_API_KEY=... examples/sandboxed-agent/run.sh MODEL REPO TASK.md
#   MODEL  an OpenRouter model id with tool support, e.g. a ":free" one
#   REPO   a git repository OUTSIDE /Users (copy it under /private/tmp first)
# macOS only (sandbox-exec).
set -eu
MODEL=$1; REPO=$(cd "$2" && pwd); TASK=$3
HERE=$(cd "$(dirname "$0")" && pwd)
HARNESS_BIN=${HARNESS_BIN:-$HERE/../../_build/default/runtime/bin/main.exe}
RUN=$(mktemp -d /private/tmp/harness-sandboxed.XXXXXX)
mkdir -p "$RUN/home" "$RUN/codex-home" "$RUN/bin"
cp "$HARNESS_BIN" "$RUN/bin/harness"

cat > "$RUN/codex-home/config.toml" <<TOML
model_provider = "openrouter"
model = "$MODEL"

[model_providers.openrouter]
name = "OpenRouter"
base_url = "https://openrouter.ai/api/v1"
env_key = "OPENROUTER_API_KEY"
wire_api = "responses"
TOML

cat > "$RUN/sandbox.sb" <<SB
(version 1)
(allow default)
(deny file-read* (subpath "/Users") (subpath "/Volumes"))
(deny file-write* (subpath "/"))
(allow file-write* (subpath "$RUN") (subpath "$REPO") (subpath "/private/tmp") (subpath "/private/var/folders") (subpath "/dev"))
SB

cat > "$RUN/agent.sh" <<AGENT
#!/bin/sh
exec codex exec -m "$MODEL" --sandbox danger-full-access --skip-git-repo-check -C "$REPO" "\$HARNESS_PROMPT" < /dev/null
AGENT
chmod +x "$RUN/agent.sh"

echo "run directory: $RUN"
# The current directory must be readable inside the sandbox.
cd "$RUN"
exec env -i PATH="/opt/homebrew/bin:/usr/local/bin:/usr/bin:/bin:/usr/sbin:/sbin" \
  HOME="$RUN/home" CODEX_HOME="$RUN/codex-home" \
  OPENROUTER_API_KEY="$OPENROUTER_API_KEY" \
  ${TYPESAFE_API_KEY:+TYPESAFE_API_KEY="$TYPESAFE_API_KEY"} \
  sandbox-exec -f "$RUN/sandbox.sb" \
  "$RUN/bin/harness" run --repo "$REPO" --runner "cmd:$RUN/agent.sh" \
  ${TYPESAFE_API_KEY:+--recall-judge jev} --timeout 900 "$TASK"
