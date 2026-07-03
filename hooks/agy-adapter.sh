#!/usr/bin/env bash
# agy-adapter.sh (D23) — run horos's Claude-shaped judges UNCHANGED under the Antigravity CLI (agy).
#
# agy is a different harness (its own hook I/O), so horos's enforcement can't fire there as-is.
# This adapter is the ONLY agy-coupled file: it translates agy's hook I/O to/from the Claude Code
# shapes the existing guards already speak, so scope-guard/reversibility-guard/session-brief run
# byte-for-byte unchanged (their 130+ tests stay the source of truth). One event arg:
#   pre-tool       (agy PreToolUse)   -> scope-guard (file writes) | reversibility-guard (run_command)
#   session-start  (agy PreInvocation)-> session-brief, injected as an ephemeral message
#   stop           (agy Stop)         -> decision-guard + claim-guard (D25)
#
# Stop-tier design (D25): agy's transcript schema differs from Claude's, so instead of parsing it,
# pre-tool ACCUMULATES each written file into .horos/agy_changed.<convId>; on stop the adapter
# synthesizes a Claude-shaped transcript from those paths (disk content as new_string) and runs the
# decision/claim gates against it. finish-the-work needs the last assistant text, which agy's Stop
# payload does not carry — deferred.
#
# agy contract (builtin skills/agy-customizations/docs/hooks.md, verified live 2026-07-03):
#   INPUT  (stdin, camelCase): { toolCall:{name,args}, conversationId, workspacePaths,
#                               transcriptPath, stepIdx }  (args keys are PascalCase, e.g. CommandLine)
#   OUTPUT (stdout):
#     PreToolUse    -> {"decision":"allow|deny|ask","reason":...}   (deny = hard block)
#     PreInvocation -> {"injectSteps":[{"ephemeralMessage":"..."}]}
# Fail-open throughout: an adapter bug must never wedge the agent (emit allow/empty, exit 0).
set -uo pipefail
HERE="$(cd "$(dirname "${BASH_SOURCE[0]}")" 2>/dev/null && pwd)" || exit 0
event="${1:-}"
input="$(cat 2>/dev/null || true)"

emit() { printf '%s\n' "$1"; exit 0; }   # single JSON verdict to agy, then done
# agy's PreToolUse requires an explicit decision; emitting a decision-less `{}` is read as a BLOCK
# (verified live 2026-07-03: `{}` denied every tool). So "no opinion" = NO stdout at all, exit 0 —
# horos only speaks (deny/allow+reason) when it actually has a verdict, and leaves every other tool
# to agy's normal flow. # D24
noop() { exit 0; }

# project root = agy workspacePaths[0] (fallback cwd); horos state/enforcement bind here
root="$(HB_IN="$input" python3 - <<'PY' 2>/dev/null || true
import os, json
try: d = json.loads(os.environ.get("HB_IN") or "{}")
except Exception: d = {}
wp = d.get("workspacePaths") or []
print(wp[0] if (wp and isinstance(wp[0], str)) else os.getcwd())
PY
)"
[ -n "$root" ] || root="$(pwd)"

# activation gate (same opt-in as the Claude plugin): only govern projects carrying .horos/
if [ ! -d "$root/.horos" ]; then
  case "$event" in session-start) emit '{"injectSteps":[]}' ;; *) noop ;; esac
fi

case "$event" in
  session-start)
    # session-brief prints the plain-text protocol card on stdout; wrap it as an ephemeral step.
    card="$(printf '%s' "$input" | CLAUDE_PROJECT_DIR="$root" "$HERE/session-brief.sh" 2>/dev/null || true)"
    [ -n "$card" ] || emit '{"injectSteps":[]}'
    HB_CARD="$card" python3 - <<'PY' 2>/dev/null || emit '{"injectSteps":[]}'
import os, json
print(json.dumps({"injectSteps": [{"ephemeralMessage": os.environ["HB_CARD"]}]}, ensure_ascii=False))
PY
    exit 0 ;;

  pre-tool)
    # classify agy's toolCall -> which guard, and build the Claude-shaped tool payload it expects.
    # line1: guard basename ("" = not a gated tool); line2: Claude-shaped JSON on stdin for it.
    plan="$(HB_IN="$input" python3 - <<'PY' 2>/dev/null || true
import os, json
try: d = json.loads(os.environ.get("HB_IN") or "{}")
except Exception: d = {}
tc = d.get("toolCall") or {}
name = str(tc.get("name") or "").lower()
args = tc.get("args") or {}
def first(keys):
    for k in keys:
        for kk in (k, k.lower(), k[:1].upper()+k[1:]):
            if kk in args and args[kk]:
                return str(args[kk])
    return ""
SHELL = {"run_command", "run_terminal_command", "command", "bash"}
# agy file-mutation tools (binary/docs; matched broadly so a new alias still gets scoped)
MUTATE = {"write_file", "write_to_file", "create_file", "edit_file", "replace_file_content",
          "multi_replace_file_content", "edit_notebook", "code_action", "file_change", "write_blob"}
if name in SHELL:
    cmd = first(["CommandLine", "Command", "command"])
    print("reversibility-guard.sh")
    print(json.dumps({"tool_name": "Bash", "tool_input": {"command": cmd}}, ensure_ascii=False))
elif name in MUTATE or (name.endswith("_file") and name not in ("view_file", "read_file")):
    fp = first(["AbsolutePath", "TargetFile", "FilePath", "Path", "file_path", "NotebookPath"])
    print("scope-guard.sh")
    print(json.dumps({"tool_name": "Write", "tool_input": {"file_path": fp}}, ensure_ascii=False))
    print(fp)  # line3: the path, for D25 changed-file accumulation
    import re as _re
    print(_re.sub(r"[^A-Za-z0-9._-]", "", str(d.get("conversationId") or "default")))  # line4: safe convId
    raise SystemExit
else:
    print("")  # view_file/list_dir/search_web/etc. — not gated
    print("")
PY
)"
    guard="$(printf '%s' "$plan" | sed -n '1p')"
    cinput="$(printf '%s' "$plan" | sed -n '2p')"
    [ -n "$guard" ] || noop                            # not a gated tool -> no opinion
    verdict="$(printf '%s' "$cinput" | CLAUDE_PROJECT_DIR="$root" "$HERE/$guard" 2>/dev/null || true)"
    # D25: record a written file as "changed this session" unless horos denied it (write won't happen)
    if [ "$guard" = scope-guard.sh ]; then
      fpath="$(printf '%s' "$plan" | sed -n '3p')"
      conv="$(printf '%s' "$plan" | sed -n '4p')"; [ -n "$conv" ] || conv=default
      case "$verdict" in *'"permissionDecision": "deny"'*) : ;;
        *) [ -n "$fpath" ] && printf '%s\n' "$fpath" >> "$root/.horos/agy_changed.$conv" 2>/dev/null || true ;;
      esac
    fi
    # translate the guard's Claude-shaped verdict -> agy PreToolUse decision (silence = no opinion)
    out="$(HB_V="$verdict" python3 - <<'PY' 2>/dev/null || true
import os, json
v = os.environ.get("HB_V") or ""
try: o = json.loads(v) if v.strip() else {}
except Exception: o = {}
hso = o.get("hookSpecificOutput") or {}
if hso.get("permissionDecision") == "deny":            # block mode
    print(json.dumps({"decision": "deny", "reason": hso.get("permissionDecisionReason", "")}, ensure_ascii=False))
elif "systemMessage" in o:                             # warn tier: allow but surface the notice
    print(json.dumps({"decision": "allow", "reason": o["systemMessage"]}, ensure_ascii=False))
# pass -> print nothing
PY
)"
    [ -n "$out" ] && printf '%s\n' "$out"              # silent on pass
    exit 0 ;;

  stop)
    # D25: judge the session's accumulated changes with the decision + claim gates. Synthesize a
    # Claude-shaped transcript from .horos/agy_changed.<convId> (disk content as new_string).
    conv="$(HB_IN="$input" python3 - <<'PY' 2>/dev/null || true
import os, json, re
try: d = json.loads(os.environ.get("HB_IN") or "{}")
except Exception: d = {}
print(re.sub(r"[^A-Za-z0-9._-]", "", str(d.get("conversationId") or "default")))
PY
)"
    [ -n "$conv" ] || conv=default
    acc="$root/.horos/agy_changed.$conv"
    [ -f "$acc" ] || noop                              # nothing recorded -> allow stop
    tf="$(mktemp)"; trap 'rm -f "$tf"' EXIT
    HB_ACC="$acc" HB_ROOT="$root" python3 - > "$tf" <<'PY' 2>/dev/null || noop
import os, json
root = os.environ["HB_ROOT"].rstrip("/")
seen = set()
for line in open(os.environ["HB_ACC"]):
    p = line.strip()
    if not p or p in seen: continue
    seen.add(p)
    disk = p if os.path.isabs(p) else os.path.join(root, p)
    try:
        with open(disk) as fh: content = fh.read()
    except OSError:
        continue                                        # file gone -> not a live change
    print(json.dumps({"type": "assistant", "message": {"role": "assistant", "content": [
        {"type": "tool_use", "name": "Write", "input": {"file_path": p, "new_string": content}}]}},
        ensure_ascii=False))
PY
    [ -s "$tf" ] || noop                               # no live changed files -> allow stop
    sin="$(printf '{"session_id":"%s","transcript_path":"%s"}' "$conv" "$tf")"
    v1="$(printf '%s' "$sin" | CLAUDE_PROJECT_DIR="$root" "$HERE/decision-guard.sh" 2>/dev/null || true)"
    v2="$(printf '%s' "$sin" | CLAUDE_PROJECT_DIR="$root" "$HERE/claim-guard.sh" 2>/dev/null || true)"
    # any block -> agy continue (re-enter loop) with the merged reason; warn is advisory (dropped)
    out="$(HB_V1="$v1" HB_V2="$v2" python3 - <<'PY' 2>/dev/null || true
import os, json
reasons = []
for k in ("HB_V1", "HB_V2"):
    v = os.environ.get(k) or ""
    try: o = json.loads(v) if v.strip() else {}
    except Exception: o = {}
    if o.get("decision") == "block":
        reasons.append(o.get("reason", ""))
if reasons:
    print(json.dumps({"decision": "continue", "reason": " | ".join(r for r in reasons if r)}, ensure_ascii=False))
PY
)"
    [ -n "$out" ] && printf '%s\n' "$out"              # silent = allow stop
    exit 0 ;;

  *) noop ;;
esac
