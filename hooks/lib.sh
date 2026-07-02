# horos/hooks/lib.sh — shared helpers for the discipline hooks.
# Sourced by each hook. Reading order: caller sets `hook_event`, then sources this.
# On source it consumes the hook JSON from stdin into $INPUT.
#
# Design contracts:
#  - warn mode  : never blocks; notifies the human via systemMessage + logs. (observation stage)
#  - block mode : actually denies (PreToolUse) / continues the turn (Stop) + logs.
#  - JSON is parsed/emitted with python3 stdlib only (portable, no platform-specific deps).
#
# Code registry (D15) — every verdict/telemetry line carries ONE stable mnemonic code so any
# model (or grep) can act on it without parsing Korean prose. Message contract for verdicts:
#   [horos:block|warn] <CODE> <한국어 문장>. Action: <one English imperative>. 예: <one filled command>
# (FIN codes may omit the 예-example: their action is "use tools now", not a specific command.)
#   Verdicts   HOROS-SCOPE-OUT       edit outside declared scope        (scope-guard)
#              HOROS-REV-DESTRUCT    destructive/irreversible command   (reversibility-guard)
#              HOROS-FIN-PROMISE     turn ended on a promise, no tools  (finish-the-work)
#              HOROS-FIN-NOEVIDENCE  completion claimed, zero tool use  (finish-the-work)
#              HOROS-DEC-BROKEN      commented [DA]-ref missing/incomplete in ledger (decision-guard)
#              HOROS-DEC-MISSING     significant change, no [DA]-ref    (decision-guard, warn-tier)
#              HOROS-CLM-BROKEN      deposited claim fails structure    (claim-guard)
#              HOROS-CLM-MISSING     significant change, no fresh claim (claim-guard, warn-tier)
#   CLI        HOROS-CLI-BADID DUPID BADKIND BADFLAG BADREF NOREF NOFILE ROOT   (hooks/horos, D14)
#   Telemetry  HOROS-TEL-MALFORMED STALE-DROP LOOPGUARD PYFAIL                  (silent-pass tracing, D16)

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

log_violation() { # rule detail [code]  — code is the 5th tab column (append-only, D15)
  printf '%s\t%s\t%s\t%s\t%s\n' "$(date -u +%FT%TZ)" "${hook_event:-?}" "$1" "$2" "${3:-}" \
    >> "$HOROS_STATE/violations.log" 2>/dev/null || true
}

# log_event code detail : telemetry trace (D16) — fail-open stays, but every silent pass
# (malformed drop, stale-drop, loop-guard silence, python failure) must leave a line here,
# so `horos doctor` can surface what the gates quietly let through.
log_event() { log_violation "telemetry" "$2" "$1"; }

# drain_tel <verdict-file> : tempfile verdict protocol (D16). The judge python may print
# zero or more "TEL\t<code>\t<detail>" lines BEFORE its final verdict line; log each TEL,
# echo only the verdict (the last non-TEL line). Malformed TEL lines degrade to verdicts,
# which the callers' case-statements ignore safely (fail-open).
drain_tel() {
  local line last=""
  while IFS= read -r line || [ -n "$line" ]; do
    case "$line" in
      TEL*) log_event "$(printf '%s' "$line" | cut -f2)" "$(printf '%s' "$line" | cut -f3)" ;;
      *)    last="$line" ;;
    esac
  done < "$1"
  printf '%s' "$last"
}

# warn: human-facing notice only, action proceeds
warn_emit() { # message
  HOROS_MSG="$1" python3 - <<'PY'
import json, os
print(json.dumps({"systemMessage": "[horos:warn] " + os.environ["HOROS_MSG"]}, ensure_ascii=False))
PY
}

# block for a PreToolUse hook (deny the tool call)
deny_pretool() { # reason
  HOROS_MSG="$1" python3 - <<'PY'
import json, os
print(json.dumps({"hookSpecificOutput": {
    "hookEventName": "PreToolUse",
    "permissionDecision": "deny",
    "permissionDecisionReason": "[horos:block] " + os.environ["HOROS_MSG"]}}, ensure_ascii=False))
PY
}

# block for a Stop hook (prevent the stop, continue the turn)
block_stop() { # reason
  HOROS_MSG="$1" python3 - <<'PY'
import json, os
print(json.dumps({"decision": "block", "reason": "[horos:block] " + os.environ["HOROS_MSG"]}, ensure_ascii=False))
PY
}

# inject non-blocking context (UserPromptSubmit etc.)
inject_context() { # event text
  HOROS_EV="$1" HOROS_MSG="$2" python3 - <<'PY'
import json, os
print(json.dumps({"hookSpecificOutput": {
    "hookEventName": os.environ["HOROS_EV"],
    "additionalContext": os.environ["HOROS_MSG"]}}, ensure_ascii=False))
PY
}

pass() { exit 0; }

# enforce_pretool code rule detail reason : act per mode, then exit 0 (D15: leading code arg)
enforce_pretool() {
  log_violation "$2" "$3" "$1"
  if [ "$(horos_mode)" = block ]; then deny_pretool "$1 $4"; else warn_emit "$1 $4"; fi
  exit 0
}

# enforce_stop code rule detail reason : act per mode, then exit 0 (D15: leading code arg)
enforce_stop() {
  log_violation "$2" "$3" "$1"
  if [ "$(horos_mode)" = block ]; then block_stop "$1 $4"; else warn_emit "$1 $4"; fi
  exit 0
}
