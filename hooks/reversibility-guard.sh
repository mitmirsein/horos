#!/usr/bin/env bash
# Philosophy 4 — prefer reversibility.
# PreToolUse(Bash): put friction in front of destructive / irreversible commands (# D4, # D30).
set -euo pipefail
hook_event=PreToolUse
. "$(dirname "${BASH_SOURCE[0]}")/lib.sh"

vfile="$(mktemp)"; trap 'rm -f "$vfile"' EXIT
PYTHONPATH="$HOROS_HERE" HOROS_IN="$INPUT" python3 - > "$vfile" 2>/dev/null <<'PY' || { log_event HOROS-TEL-PYFAIL reversibility-guard; pass; }
import json, os, horos_core

try:
    d = json.loads(os.environ.get("HOROS_IN") or "{}")
except Exception:
    d = {}
if not isinstance(d, dict) or d.get("tool_name") != "Bash":
    print("OK"); raise SystemExit

inp = d.get("tool_input")
cmd = str(inp.get("command") or "") if isinstance(inp, dict) else ""
if not cmd:
    print("OK"); raise SystemExit

label = horos_core.scan_destructive_command(cmd)
if label:
    flat_cmd = cmd.replace("\n", " ").replace("\t", " ")
    print("HIT\t" + label + "\t" + flat_cmd)
else:
    print("OK")
PY

verdict="$(cat "$vfile")"
if [ -z "$verdict" ]; then log_event HOROS-TEL-PYFAIL reversibility-guard; pass; fi
if [ "${verdict%%	*}" = OK ]; then pass; fi

match="$(printf '%s' "$verdict" | cut -f2)"
cmd="$(printf '%s' "$verdict" | cut -f3)"
short="$(printf '%s' "$cmd" | cut -c1-120)"
enforce_pretool HOROS-REV-DESTRUCT "reversibility" "$cmd" \
  "비가역·파괴 작업 감지: ${match}. 갈아엎기 전에 dry-run/백업/별도 커밋으로 가역성을 확보하고, 의도한 작업이면 확인 후 진행하세요. Action: create a restore point first (dry-run, backup, or a separate commit), then rerun if intended. 예: git stash push -u  (명령: ${short})"
