#!/usr/bin/env bash
# agy-adapter.sh (D23, D25, D26, D31) — run horos's judges UNCHANGED under Antigravity 2.0 (agy).
#
# Translates Antigravity hook I/O to/from the shapes horos guards speak:
#   pre-tool       (agy PreToolUse)   -> scope-guard (file writes) | reversibility-guard (run_command)
#   session-start  (agy SessionStart) -> session-brief, injected via nested systemMessage (# D31)
#   stop           (agy Stop)         -> finish-the-work + decision-guard + claim-guard (# D25/D26/D31)
#
# Antigravity 2.0 contract (builtin skills/agy-customizations/docs/hooks.md):
#   INPUT  (stdin, camelCase): { toolCall:{name,args}, conversationId, workspacePaths,
#                               transcriptPath, terminationReason, stepIdx }
#   OUTPUT (stdout):
#     PreToolUse   -> {"decision":"allow|deny|ask","reason":...}   (no opinion = empty stdout, D24)
#     SessionStart -> {"injectSteps":[{"systemMessage":{"systemMessage":"..."}}]} (# D31)
#     Stop         -> {"decision":"continue","reason":...}         (allow stop = empty stdout)
# Fail-open throughout: an adapter bug must never wedge the agent.
set -uo pipefail
HERE="$(cd "$(dirname "${BASH_SOURCE[0]}")" 2>/dev/null && pwd)" || exit 0
event="${1:-}"
input="$(cat 2>/dev/null || true)"

emit() { printf '%s\n' "$1"; exit 0; }
noop() { exit 0; }

# Project root = agy workspacePaths[0] (fallback cwd)
root="$(HB_IN="$input" python3 - <<'PY' 2>/dev/null || true
import os, json
try: d = json.loads(os.environ.get("HB_IN") or "{}")
except Exception: d = {}
wp = d.get("workspacePaths") if isinstance(d, dict) else None
print(wp[0] if (isinstance(wp, list) and wp and isinstance(wp[0], str) and wp[0].strip()) else os.getcwd())
PY
)"
[ -n "$root" ] || root="$(pwd)"

# Activation gate (opt-in marker .horos/)
if [ ! -d "$root/.horos" ]; then
  case "$event" in session-start) emit '{"injectSteps":[]}' ;; *) noop ;; esac
fi

case "$event" in
  session-start)
    # D31: emit Antigravity 2.0 standard nested systemMessage step (replaces deprecated ephemeralMessage).
    card="$(printf '%s' "$input" | CLAUDE_PROJECT_DIR="$root" "$HERE/session-brief.sh" 2>/dev/null || true)"
    [ -n "$card" ] || emit '{"injectSteps":[]}'
    HB_CARD="$card" python3 - <<'PY' 2>/dev/null || emit '{"injectSteps":[]}'
import json, os, sys
payload = {"injectSteps": [{"systemMessage": {"systemMessage": os.environ["HB_CARD"]}}]}
sys.stdout.buffer.write((json.dumps(payload, ensure_ascii=False) + "\n").encode("utf-8"))
PY
    exit 0 ;;

  pre-tool)
    # line1: guard basename; line2: Claude-shaped JSON; line3: safe convId; line4: JSON accum record
    plan="$(HB_IN="$input" python3 - <<'PY' 2>/dev/null || true
import json, os, re
try: d = json.loads(os.environ.get("HB_IN") or "{}")
except Exception: d = {}
if not isinstance(d, dict):
    d = {}
tc = d.get("toolCall") if isinstance(d.get("toolCall"), dict) else {}
name = str(tc.get("name") or "").lower()
args = tc.get("args") if isinstance(tc.get("args"), dict) else {}

def first_val(keys):
    for k in keys:
        for kk in (k, k.lower(), k[:1].upper() + k[1:]):
            if kk in args and args[kk] is not None and args[kk] != "":
                return args[kk]
    return None

def line_count(s):
    if not isinstance(s, str):
        return 0
    if not s:
        return 0
    return s.count("\n") + (0 if s.endswith("\n") else 1)

SHELL = {"run_command", "run_terminal_command", "command", "bash"}
MUTATE = {
    "write_file", "write_to_file", "create_file", "edit_file", "replace_file_content",
    "multi_replace_file_content", "edit_notebook", "code_action", "file_change", "write_blob",
}
if name in SHELL:
    cmd = str(first_val(["CommandLine", "Command", "command"]) or "")
    print("reversibility-guard.sh")
    print(json.dumps({"tool_name": "Bash", "tool_input": {"command": cmd}}, ensure_ascii=False))
elif name in MUTATE or (name.endswith("_file") and name not in ("view_file", "read_file")):
    fp = str(first_val(["AbsolutePath", "TargetFile", "FilePath", "Path", "file_path", "NotebookPath"]) or "")
    # D31: compute exact added line count from mutation payload when present so 1-line edits on
    # large files do not inflate significance thresholds at Stop.
    added = None
    chunks = first_val(["ReplacementChunks", "Replacements", "edits"])
    if isinstance(chunks, list):
        added = 0
        for ch in chunks:
            if isinstance(ch, dict):
                for ck in ("ReplacementContent", "Replacement", "new_string", "content"):
                    if isinstance(ch.get(ck), str):
                        added += line_count(ch[ck])
                        break
    else:
        body = first_val(["Replacement", "ReplacementContent", "Content", "CodeContent", "new_string", "content"])
        if isinstance(body, str):
            added = line_count(body)
    conv = re.sub(r"[^A-Za-z0-9._-]", "", str(d.get("conversationId") or "default")) or "default"
    print("scope-guard.sh")
    print(json.dumps({"tool_name": "Write", "tool_input": {"file_path": fp}}, ensure_ascii=False))
    print(conv)
    print(json.dumps({"path": fp, "added_lines": added}, ensure_ascii=False) if fp else "")
else:
    print("")
    print("")
PY
)"
    guard="$(printf '%s' "$plan" | sed -n '1p')"
    cinput="$(printf '%s' "$plan" | sed -n '2p')"
    [ -n "$guard" ] || noop
    verdict="$(printf '%s' "$cinput" | CLAUDE_PROJECT_DIR="$root" "$HERE/$guard" 2>/dev/null || true)"
    # D25/D27/D31: record allowed mutation with flock safety
    if [ "$guard" = scope-guard.sh ]; then
      conv="$(printf '%s' "$plan" | sed -n '3p')"; [ -n "$conv" ] || conv=default
      accline="$(printf '%s' "$plan" | sed -n '4p')"
      case "$verdict" in
        *'"permissionDecision": "deny"'*) : ;;
        *)
          if [ -n "$accline" ]; then
            PYTHONPATH="$HERE" HA_P="$root/.horos/agy_changed.$conv" HA_L="$accline" python3 -c \
              'import os, horos_core; horos_core.locked_append(os.environ["HA_P"], os.environ["HA_L"])' \
              2>/dev/null || printf '%s\n' "$accline" >> "$root/.horos/agy_changed.$conv" 2>/dev/null || true
          fi ;;
      esac
    fi
    out="$(HB_V="$verdict" python3 - <<'PY' 2>/dev/null || true
import json, os, sys
v = os.environ.get("HB_V") or ""
try: o = json.loads(v) if v.strip() else {}
except Exception: o = {}
hso = o.get("hookSpecificOutput") or {}
if hso.get("permissionDecision") == "deny":
    sys.stdout.buffer.write((json.dumps({"decision": "deny", "reason": hso.get("permissionDecisionReason", "")}, ensure_ascii=False) + "\n").encode("utf-8"))
elif "systemMessage" in o:
    sys.stdout.buffer.write((json.dumps({"decision": "allow", "reason": o["systemMessage"]}, ensure_ascii=False) + "\n").encode("utf-8"))
PY
)"
    [ -n "$out" ] && printf '%s\n' "$out"
    exit 0 ;;

  stop)
    # D31: inspect terminationReason first — never force continuation on USER_CANCELED, ERROR,
    # MAX_INVOCATIONS, MAX_TOKEN_BUDGET_EXCEEDED, or TERMINAL_* aborts.
    meta="$(HB_IN="$input" python3 - <<'PY' 2>/dev/null || true
import json, os, re
try: d = json.loads(os.environ.get("HB_IN") or "{}")
except Exception: d = {}
if not isinstance(d, dict):
    d = {}
tr = str(d.get("terminationReason") or "").strip()
if tr and tr not in ("NO_TOOL_CALL", "model_stop"):
    print("ABORT")
    raise SystemExit
conv = re.sub(r"[^A-Za-z0-9._-]", "", str(d.get("conversationId") or "default")) or "default"
tp = str(d.get("transcriptPath") or "")
print("RUN")
print(conv)
print(tp)
PY
)"
    status="$(printf '%s' "$meta" | sed -n '1p')"
    [ "$status" = RUN ] || noop
    conv="$(printf '%s' "$meta" | sed -n '2p')"; [ -n "$conv" ] || conv=default
    tp="$(printf '%s' "$meta" | sed -n '3p')"

    acc="$root/.horos/agy_changed.$conv"
    tf="$(mktemp)"; trap 'rm -f "$tf"' EXIT
    HB_ACC="$acc" HB_ROOT="$root" HB_TP="$tp" python3 - > "$tf" <<'PY' 2>/dev/null || noop
import json, os

root = os.environ["HB_ROOT"].rstrip("/")
# (a) accumulated changed files -> Write tool_use lines (supports JSONL records and plain-path lines)
order = []
added_map = {}
try:
    with open(os.environ["HB_ACC"], encoding="utf-8") as fh:
        for raw in fh:
            s = raw.strip()
            if not s:
                continue
            p = s
            al = None
            if s.startswith("{"):
                try:
                    rec = json.loads(s)
                    if isinstance(rec, dict):
                        p = str(rec.get("path") or "").strip()
                        v = rec.get("added_lines")
                        if isinstance(v, int):
                            al = max(0, v)
                except Exception:
                    p = s
            if not p:
                continue
            if p not in added_map:
                order.append(p)
                added_map[p] = al
            else:
                if added_map[p] is not None and al is not None:
                    added_map[p] += al
                else:
                    added_map[p] = None
except OSError:
    pass

# (b) agy transcript -> last assistant text, tool_seen, ended_on_tool (D26)
NON_TOOL = {
    "PLANNER_RESPONSE", "USER_INPUT", "CONVERSATION_HISTORY", "EPHEMERAL_MESSAGE",
    "SYSTEM_MESSAGE", "ERROR_MESSAGE", "FINISH", "CHECKPOINT", "BRAIN_UPDATE",
}
last_text = ""
tool_seen = False
ended_on_tool = False
try:
    with open(os.environ["HB_TP"], encoding="utf-8") as tfh:
        tlines = [json.loads(l) for l in tfh if l.strip()]
except (OSError, ValueError):
    tlines = []
for o in tlines:
    if not isinstance(o, dict):
        continue
    if o.get("tool_calls"):
        tool_seen = True
    elif o.get("source") == "MODEL" and o.get("type") not in NON_TOOL:
        tool_seen = True
for o in reversed(tlines):
    if isinstance(o, dict) and o.get("type") == "PLANNER_RESPONSE" and isinstance(o.get("content"), str) and o["content"].strip():
        last_text = o["content"]
        break
for o in reversed(tlines):
    if not isinstance(o, dict) or o.get("source") != "MODEL":
        continue
    t = o.get("type")
    ended_on_tool = bool(o.get("tool_calls")) or (t not in NON_TOOL)
    break

out = []
for p in order:
    disk = p if os.path.isabs(p) else os.path.join(root, p)
    try:
        with open(disk, encoding="utf-8", errors="replace") as fh:
            content = fh.read()
    except OSError:
        continue
    tinp = {"file_path": p, "new_string": content}
    if added_map.get(p) is not None:
        tinp["_horos_added_lines"] = added_map[p]
    out.append({"type": "assistant", "message": {"role": "assistant", "content": [
        {"type": "tool_use", "name": "Write", "input": tinp}]}})

if tool_seen and not out:
    out.append({"type": "assistant", "message": {"role": "assistant", "content": [
        {"type": "tool_use", "name": "Read", "input": {}}]}})
if ended_on_tool:
    out.append({"type": "assistant", "message": {"role": "assistant", "content": [
        {"type": "tool_use", "name": "Read", "input": {}}]}})
elif last_text:
    out.append({"type": "assistant", "message": {"role": "assistant", "content": [
        {"type": "text", "text": last_text}]}})
for o in out:
    print(json.dumps(o, ensure_ascii=False))
PY
    if [ ! -s "$tf" ]; then
      rm -f "$acc" 2>/dev/null || true
      noop
    fi
    sin="$(printf '{"session_id":"%s","transcript_path":"%s"}' "$conv" "$tf")"
    vf="$(printf '%s' "$sin" | CLAUDE_PROJECT_DIR="$root" "$HERE/finish-the-work.sh" 2>/dev/null || true)"
    vd="$(printf '%s' "$sin" | CLAUDE_PROJECT_DIR="$root" "$HERE/decision-guard.sh" 2>/dev/null || true)"
    vc="$(printf '%s' "$sin" | CLAUDE_PROJECT_DIR="$root" "$HERE/claim-guard.sh" 2>/dev/null || true)"
    out="$(HB_VF="$vf" HB_VD="$vd" HB_VC="$vc" python3 - <<'PY' 2>/dev/null || true
import json, os, sys
reasons = []
for k in ("HB_VF", "HB_VD", "HB_VC"):
    v = os.environ.get(k) or ""
    try: o = json.loads(v) if v.strip() else {}
    except Exception: o = {}
    if o.get("decision") == "block":
        reasons.append(o.get("reason", ""))
if reasons:
    sys.stdout.buffer.write((json.dumps({"decision": "continue", "reason": " | ".join(r for r in reasons if r)}, ensure_ascii=False) + "\n").encode("utf-8"))
PY
)"
    if [ -n "$out" ]; then
      printf '%s\n' "$out"
    else
      # D31: clean stop -> retire accumulated turn changes so future turns start fresh
      rm -f "$acc" 2>/dev/null || true
    fi
    exit 0 ;;

  *) noop ;;
esac
