#!/usr/bin/env bash
# parent-bridge.sh (D11) — let horos's own hooks enforce horos work even when Claude Code's
# project root is an ANCESTOR of horos (a multi-project workspace). Registered in the ANCESTOR's
# .claude/settings.json. For each event it (1) reads the hook JSON, (2) decides if the operation
# concerns the horos subtree, (3) if so re-invokes the real horos hook(s) with CLAUDE_PROJECT_DIR
# pinned to horos; otherwise passes (exit 0). Other projects in the workspace are untouched.
#
# Fail-open: any error exits 0 — a bridge bug must never hold unrelated work hostage.
# Stop is a single entry that runs finish/decision/claim and merges their verdicts, so a
# non-horos session pays just one transcript scan.
set -uo pipefail
HOROS_DIR="$(cd "$(dirname "${BASH_SOURCE[0]}")/.." 2>/dev/null && pwd)" || exit 0
[ -n "${HOROS_DIR:-}" ] && [ -d "$HOROS_DIR/hooks" ] || exit 0
event="${1:-}"
input="$(cat 2>/dev/null || true)"

field() {  # <dotted.path> -> string value from the hook JSON ("" if missing)
  printf '%s' "$input" | HB_P="$1" python3 -c 'import sys, json, os
try: d = json.load(sys.stdin)
except Exception: sys.exit(0)
cur = d
for k in os.environ["HB_P"].split("."):
    cur = cur.get(k) if isinstance(cur, dict) else None
print(cur if isinstance(cur, str) else "")' 2>/dev/null || true
}

under_horos() { case "$1" in "$HOROS_DIR"|"$HOROS_DIR"/*) return 0 ;; *) return 1 ;; esac; }

touched_horos() {  # true iff the transcript shows an Edit/Write/MultiEdit on a file under horos
  local tp; tp="$(field transcript_path)"
  [ -n "$tp" ] && [ -f "$tp" ] || return 1
  HB_DIR="$HOROS_DIR" python3 - "$tp" <<'PY' 2>/dev/null
import sys, json, os
d = os.environ["HB_DIR"].rstrip('/')
for line in open(sys.argv[1]):
    line = line.strip()
    if not line: continue
    try: o = json.loads(line)
    except Exception: continue
    if o.get("type") != "assistant": continue
    for b in (o.get("message", {}) or {}).get("content", []) or []:
        if isinstance(b, dict) and b.get("type") == "tool_use" and b.get("name") in ("Edit", "Write", "MultiEdit"):
            fp = (b.get("input", {}) or {}).get("file_path", "") or ""
            if fp == d or fp.startswith(d + '/'):
                sys.exit(0)
sys.exit(1)
PY
}

delegate() {  # <hook.sh> -> run the real horos hook with this stdin + CLAUDE_PROJECT_DIR pinned to horos
  printf '%s' "$input" | CLAUDE_PROJECT_DIR="$HOROS_DIR" "$HOROS_DIR/hooks/$1" 2>/dev/null || true
}

case "$event" in
  pre-edit)
    under_horos "$(field tool_input.file_path)" && delegate scope-guard.sh
    exit 0 ;;
  pre-bash)
    cmd="$(field tool_input.command)"
    if under_horos "$(field cwd)" || case "$cmd" in *"$HOROS_DIR"*) true ;; *) false ;; esac; then
      delegate reversibility-guard.sh
    fi
    exit 0 ;;
  stop)
    touched_horos || exit 0
    { delegate finish-the-work.sh; delegate decision-guard.sh; delegate claim-guard.sh; } \
      | python3 -c 'import sys, json
blocks = []; warns = []
for line in sys.stdin:
    line = line.strip()
    if not line: continue
    try: o = json.loads(line)
    except Exception: continue
    if o.get("decision") == "block": blocks.append(o.get("reason", ""))
    elif "systemMessage" in o: warns.append(o["systemMessage"])
if blocks: print(json.dumps({"decision": "block", "reason": " | ".join(b for b in blocks if b)}))
elif warns: print(json.dumps({"systemMessage": " | ".join(w for w in warns if w)}))' 2>/dev/null || true
    exit 0 ;;
  *) exit 0 ;;
esac
