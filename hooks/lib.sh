# horos/hooks/lib.sh — shared helpers for the discipline hooks.
# Sourced by each hook. Reading order: caller sets `hook_event`, then sources this.
# On source it consumes the hook JSON from stdin into $INPUT before resolving HOROS_ROOT (# D28).
#
# Design contracts:
#  - warn mode  : never blocks; notifies the human via systemMessage (or stderr) + logs.
#  - block mode : actually denies (PreToolUse) / continues the turn (Stop) + logs.
#  - strict mode: block + the warn-tier MISSING paths also block + loop threshold 2->4. (D18)
#  - JSON is parsed/emitted with python3 stdlib only (portable, no platform-specific deps).
#  - HOROS_HARNESS=claude (default JSON stdout, exit 0) | exitcode (stderr + exit 2 on block, D28).
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

HOROS_HERE="$(cd "$(dirname "${BASH_SOURCE[0]}")" && pwd)"
HOROS_HARNESS="${HOROS_HARNESS:-claude}"
INPUT="$(cat)"

# D28: resolve HOROS_ROOT after reading INPUT so Codex CLI / generic harnesses without
# CLAUDE_PROJECT_DIR bind to the active workspace (via HOROS_PROJECT_DIR, payload cwd, or git root)
# instead of silently falling back to central horos/. Fast bash path when env var is set.
if [ -n "${HOROS_PROJECT_DIR:-}" ]; then
  HOROS_ROOT="${HOROS_PROJECT_DIR%/}"
  [ -n "$HOROS_ROOT" ] || HOROS_ROOT="/"
elif [ -n "${CLAUDE_PROJECT_DIR:-}" ]; then
  HOROS_ROOT="${CLAUDE_PROJECT_DIR%/}"
  [ -n "$HOROS_ROOT" ] || HOROS_ROOT="/"
else
  HOROS_FB="$(cd "$HOROS_HERE/.." && pwd)"
  HOROS_ROOT="$(PYTHONPATH="$HOROS_HERE" HOROS_IN="$INPUT" HOROS_FB="$HOROS_FB" python3 -c \
    'import os, horos_core; print(horos_core.resolve_root(os.environ.get("HOROS_IN",""), os.environ, os.environ["HOROS_FB"]))' \
    2>/dev/null || printf '%s' "$HOROS_FB")"
fi
HOROS_STATE="$HOROS_ROOT/.horos"
mkdir -p "$HOROS_STATE" 2>/dev/null || true

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
  # Unknown values clamp to warn (weakest), so a corrupted mode file cannot over-enforce.
  local m=""
  [ -f "$HOROS_STATE/mode" ] && m="$(tr -d '[:space:]' < "$HOROS_STATE/mode" 2>/dev/null)"
  case "$m" in warn|block|strict) printf '%s' "$m" ;; *) printf 'warn' ;; esac
}

# blocking_mode : does the current mode actually deny/block? (strict acts like block, D18)
blocking_mode() { case "$(horos_mode)" in block|strict) return 0 ;; *) return 1 ;; esac; }

# loop_threshold : nudges per session before a Stop gate goes quiet (strict gets more, D18)
loop_threshold() { if [ "$(horos_mode)" = strict ]; then printf 4; else printf 2; fi; }

log_violation() { # rule detail [code]  — code is the 5th tab column (append-only, flock-safe, D15/D27)
  local line
  line="$(printf '%s\t%s\t%s\t%s\t%s' "$(date -u +%FT%TZ)" "${hook_event:-?}" "$1" "$2" "${3:-}")"
  PYTHONPATH="$HOROS_HERE" HOROS_VLOG="$HOROS_STATE/violations.log" HOROS_VLINE="$line" python3 -c \
    'import os, horos_core; horos_core.locked_append(os.environ["HOROS_VLOG"], os.environ["HOROS_VLINE"])' \
    2>/dev/null || printf '%s\n' "$line" >> "$HOROS_STATE/violations.log" 2>/dev/null || true
}

# log_event code detail : telemetry trace (D16) — fail-open stays, but every silent pass
# (malformed drop, stale-drop, loop-guard silence, python failure) must leave a line here,
# so `horos doctor` can surface what the gates quietly let through.
log_event() { log_violation "telemetry" "$2" "$1"; }

# Session-keyed flock loop-guard helpers (# D27): concurrent sessions share one JSON map file
# without clobbering each other's counters; legacy 'sid count' text files auto-migrate.
guard_check_or_pass() { # <guard-file> <sid>
  local res
  res="$(PYTHONPATH="$HOROS_HERE" HG_PATH="$1" HG_SID="$2" HG_THR="$(loop_threshold)" python3 -c \
    'import os, horos_core; print(horos_core.guard_op(os.environ["HG_PATH"], os.environ["HG_SID"], "check", int(os.environ["HG_THR"])))' \
    2>/dev/null || printf 'RUN:0')"
  if [ "$res" = SILENCE ]; then pass; fi
}

guard_bump() { # <guard-file> <sid> -> echoes new count
  PYTHONPATH="$HOROS_HERE" HG_PATH="$1" HG_SID="$2" python3 -c \
    'import os, horos_core; print(horos_core.guard_op(os.environ["HG_PATH"], os.environ["HG_SID"], "bump"))' \
    2>/dev/null || printf '1'
}

guard_reset() { # <guard-file> <sid>
  PYTHONPATH="$HOROS_HERE" HG_PATH="$1" HG_SID="$2" python3 -c \
    'import os, horos_core; horos_core.guard_op(os.environ["HG_PATH"], os.environ["HG_SID"], "reset")' \
    >/dev/null 2>&1 || true
}

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

# D22: emit as UTF-8 BYTES via buffer, not print(). D28: when HOROS_HARNESS=exitcode, write
# plain human/model-readable text to stderr so POSIX exit-code harnesses work without adapters.
warn_emit() { # message
  HOROS_MSG="$1" HOROS_H="$HOROS_HARNESS" python3 - <<'PY'
import json, os, sys
msg = "[horos:warn] " + os.environ["HOROS_MSG"]
if os.environ.get("HOROS_H") == "exitcode":
    sys.stderr.buffer.write((msg + "\n").encode("utf-8"))
else:
    sys.stdout.buffer.write((json.dumps({"systemMessage": msg}, ensure_ascii=False) + "\n").encode("utf-8"))
PY
}

# block for a PreToolUse hook (deny the tool call)
deny_pretool() { # reason
  HOROS_MSG="$1" HOROS_H="$HOROS_HARNESS" python3 - <<'PY'
import json, os, sys
msg = "[horos:block] " + os.environ["HOROS_MSG"]
if os.environ.get("HOROS_H") == "exitcode":
    sys.stderr.buffer.write((msg + "\n").encode("utf-8"))
else:
    sys.stdout.buffer.write((json.dumps({"hookSpecificOutput": {
        "hookEventName": "PreToolUse",
        "permissionDecision": "deny",
        "permissionDecisionReason": msg}}, ensure_ascii=False) + "\n").encode("utf-8"))
PY
}

# block for a Stop hook (prevent the stop, continue the turn)
block_stop() { # reason
  HOROS_MSG="$1" HOROS_H="$HOROS_HARNESS" python3 - <<'PY'
import json, os, sys
msg = "[horos:block] " + os.environ["HOROS_MSG"]
if os.environ.get("HOROS_H") == "exitcode":
    sys.stderr.buffer.write((msg + "\n").encode("utf-8"))
else:
    sys.stdout.buffer.write((json.dumps({"decision": "block", "reason": msg}, ensure_ascii=False) + "\n").encode("utf-8"))
PY
}

# inject non-blocking context (UserPromptSubmit etc.)
inject_context() { # event text
  HOROS_EV="$1" HOROS_MSG="$2" HOROS_H="$HOROS_HARNESS" python3 - <<'PY'
import json, os, sys
if os.environ.get("HOROS_H") == "exitcode":
    sys.stdout.buffer.write((os.environ["HOROS_MSG"] + "\n").encode("utf-8"))
else:
    sys.stdout.buffer.write((json.dumps({"hookSpecificOutput": {
        "hookEventName": os.environ["HOROS_EV"],
        "additionalContext": os.environ["HOROS_MSG"]}}, ensure_ascii=False) + "\n").encode("utf-8"))
PY
}

pass() { exit 0; }

# enforce_pretool code rule detail reason : act per mode; exit 2 under HOROS_HARNESS=exitcode (D15/D28)
enforce_pretool() {
  log_violation "$2" "$3" "$1"
  if blocking_mode; then
    deny_pretool "$1 $4"
    [ "$HOROS_HARNESS" = exitcode ] && exit 2
  else
    warn_emit "$1 $4"
  fi
  exit 0
}

# enforce_stop code rule detail reason : act per mode; exit 2 under HOROS_HARNESS=exitcode (D15/D28)
enforce_stop() {
  log_violation "$2" "$3" "$1"
  if blocking_mode; then
    block_stop "$1 $4"
    [ "$HOROS_HARNESS" = exitcode ] && exit 2
  else
    warn_emit "$1 $4"
  fi
  exit 0
}
