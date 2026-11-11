#!/usr/bin/env bash
# parent-bridge.sh (D11) — let horos's own hooks enforce horos work even when the harness's
# project root is an ANCESTOR of horos (a multi-project workspace). Registered in the ancestor's
# .claude/settings.json. Supports Edit/Write/MultiEdit/NotebookEdit + apply_patch, realpath '..'
# normalization, and UTF-8 byte output (# D18, # D22, # D28, # D29).
set -uo pipefail
HOROS_DIR="$(cd "$(dirname "${BASH_SOURCE[0]}")/.." 2>/dev/null && pwd)" || exit 0
[ -n "${HOROS_DIR:-}" ] && [ -d "$HOROS_DIR/hooks" ] || exit 0
event="${1:-}"
input="$(cat 2>/dev/null || true)"

delegate() {  # <hook.sh> -> run the real horos hook with this stdin + CLAUDE_PROJECT_DIR pinned to horos
  printf '%s' "$input" | CLAUDE_PROJECT_DIR="$HOROS_DIR" "$HOROS_DIR/hooks/$1" 2>/dev/null || true
}

should_delegate() {  # <mode: pre-edit|pre-bash|stop> -> exit 0 iff this payload touches HOROS_DIR
  PYTHONPATH="$HOROS_DIR/hooks" HB_DIR="$HOROS_DIR" HB_MODE="$1" HB_IN="$input" python3 - <<'PY' 2>/dev/null
import json, os, sys
try:
    import horos_core
except Exception:
    horos_core = None

horos_dir = os.path.realpath(os.environ["HB_DIR"]).rstrip("/")
mode = os.environ["HB_MODE"]
try:
    d = json.loads(os.environ.get("HB_IN") or "{}")
except Exception:
    sys.exit(1)
if not isinstance(d, dict):
    sys.exit(1)

def under(fp):
    if not fp:
        return False
    if horos_core:
        inside, _ = horos_core.normalize_relpath(fp, horos_dir)
        return inside
    rp = os.path.realpath(fp)
    return rp == horos_dir or rp.startswith(horos_dir + "/")

if mode == "pre-edit":
    tool = str(d.get("tool_name") or "")
    inp = d.get("tool_input")
    if tool == "apply_patch" and horos_core:
        paths = [p for p, _ in horos_core.extract_apply_patch_entries(inp) if p]
    elif isinstance(inp, dict):
        paths = [str(inp.get("file_path") or inp.get("notebook_path") or "")]
    else:
        paths = []
    sys.exit(0 if any(under(p) for p in paths if p) else 1)

if mode == "pre-bash":
    cwd = str(d.get("cwd") or "")
    inp = d.get("tool_input")
    cmd = str(inp.get("command") or "") if isinstance(inp, dict) else ""
    raw_dir = os.environ["HB_DIR"].rstrip("/")
    hit = under(cwd) or (raw_dir in cmd) or (horos_dir in cmd)
    sys.exit(0 if hit else 1)

if mode == "stop":
    tp = str(d.get("transcript_path") or "")
    if not tp or not os.path.isfile(tp):
        sys.exit(1)
    with open(tp, encoding="utf-8") as fh:
        for line in fh:
            line = line.strip()
            if not line:
                continue
            try:
                o = json.loads(line)
            except Exception:
                continue
            if not isinstance(o, dict) or o.get("type") != "assistant":
                continue
            for b in ((o.get("message") or {}).get("content") or []):
                if not (isinstance(b, dict) and b.get("type") == "tool_use"):
                    continue
                tname = b.get("name")
                inp = b.get("input")
                if tname in ("Edit", "Write", "MultiEdit", "NotebookEdit") and isinstance(inp, dict):
                    fp = str(inp.get("file_path") or inp.get("notebook_path") or "")
                    if fp and fp.startswith("/") and under(fp):
                        sys.exit(0)
                elif tname == "apply_patch" and horos_core:
                    for p, _ in horos_core.extract_apply_patch_entries(inp):
                        if p and p.startswith("/") and under(p):
                            sys.exit(0)
    sys.exit(1)
sys.exit(1)
PY
}

case "$event" in
  pre-edit)
    should_delegate pre-edit && delegate scope-guard.sh
    exit 0 ;;
  pre-bash)
    should_delegate pre-bash && delegate reversibility-guard.sh
    exit 0 ;;
  stop)
    should_delegate stop || exit 0
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
if blocks:
    sys.stdout.buffer.write((json.dumps({"decision": "block", "reason": " | ".join(b for b in blocks if b)}, ensure_ascii=False) + "\n").encode("utf-8"))
elif warns:
    sys.stdout.buffer.write((json.dumps({"systemMessage": " | ".join(w for w in warns if w)}, ensure_ascii=False) + "\n").encode("utf-8"))' 2>/dev/null || true
    exit 0 ;;
  *) exit 0 ;;
esac
