# horos/hooks/lib.sh — shared helpers for the discipline hooks.
# Sourced by each hook. Reading order: caller sets `hook_event`, then sources this.
# On source it consumes the hook JSON from stdin into $INPUT.
#
# Design contracts:
#  - warn mode  : never blocks; notifies the human via systemMessage + logs. (observation stage)
#  - block mode : actually denies (PreToolUse) / continues the turn (Stop) + logs.
#  - JSON is parsed/emitted with python3 stdlib only (portable across the user's M1/Intel macs).

if [ -n "${CLAUDE_PROJECT_DIR:-}" ]; then
  HOROS_ROOT="$CLAUDE_PROJECT_DIR"
else
  HOROS_ROOT="$(cd "$(dirname "${BASH_SOURCE[0]}")/.." && pwd)"
fi
HOROS_STATE="$HOROS_ROOT/.horos"
mkdir -p "$HOROS_STATE" 2>/dev/null || true

INPUT="$(cat)"

# json_field <dotted.path> -> value on stdout ("" if missing; JSON-encoded if container)
json_field() {
  HOROS_INPUT="$INPUT" python3 - "$1" <<'PY'
import json, os, sys
try:
    d = json.loads(os.environ.get("HOROS_INPUT") or "{}")
except Exception:
    d = {}
cur = d
for p in sys.argv[1].split('.'):
    if isinstance(cur, dict) and p in cur:
        cur = cur[p]
    else:
        cur = None
        break
if cur is None:
    cur = ""
if isinstance(cur, (dict, list)):
    cur = json.dumps(cur, ensure_ascii=False)
sys.stdout.write(str(cur))
PY
}

horos_mode() {
  # robust to an absent mode file (fresh project): a bare `< file` redirection fails
  # before 2>/dev/null applies, leaking a shell error — so guard with -f first. (D7)
  local m=""
  [ -f "$HOROS_STATE/mode" ] && m="$(tr -d '[:space:]' < "$HOROS_STATE/mode" 2>/dev/null)"
  [ -n "$m" ] && printf '%s' "$m" || printf 'warn'
}

log_violation() { # rule detail
  printf '%s\t%s\t%s\t%s\n' "$(date -u +%FT%TZ)" "${hook_event:-?}" "$1" "$2" \
    >> "$HOROS_STATE/violations.log" 2>/dev/null || true
}

# warn: human-facing notice only, action proceeds
warn_emit() { # message
  HOROS_MSG="$1" python3 - <<'PY'
import json, os
print(json.dumps({"systemMessage": "[horos:warn] " + os.environ["HOROS_MSG"]}))
PY
}

# block for a PreToolUse hook (deny the tool call)
deny_pretool() { # reason
  HOROS_MSG="$1" python3 - <<'PY'
import json, os
print(json.dumps({"hookSpecificOutput": {
    "hookEventName": "PreToolUse",
    "permissionDecision": "deny",
    "permissionDecisionReason": "[horos:block] " + os.environ["HOROS_MSG"]}}))
PY
}

# block for a Stop hook (prevent the stop, continue the turn)
block_stop() { # reason
  HOROS_MSG="$1" python3 - <<'PY'
import json, os
print(json.dumps({"decision": "block", "reason": "[horos:block] " + os.environ["HOROS_MSG"]}))
PY
}

# inject non-blocking context (UserPromptSubmit etc.)
inject_context() { # event text
  HOROS_EV="$1" HOROS_MSG="$2" python3 - <<'PY'
import json, os
print(json.dumps({"hookSpecificOutput": {
    "hookEventName": os.environ["HOROS_EV"],
    "additionalContext": os.environ["HOROS_MSG"]}}))
PY
}

pass() { exit 0; }

# enforce_pretool rule detail reason : act per mode, then exit 0
enforce_pretool() {
  log_violation "$1" "$2"
  if [ "$(horos_mode)" = block ]; then deny_pretool "$3"; else warn_emit "$3"; fi
  exit 0
}

# enforce_stop rule detail reason : act per mode, then exit 0
enforce_stop() {
  log_violation "$1" "$2"
  if [ "$(horos_mode)" = block ]; then block_stop "$3"; else warn_emit "$3"; fi
  exit 0
}
