#!/usr/bin/env bash
# Philosophy 3 — boundary convergence.
# PreToolUse(Edit|Write|MultiEdit): a file edit must fall inside the declared scope allowlist.
# No scope declared => no enforcement (declaring the boundary is an opt-in act, per philosophy 3).
set -euo pipefail
hook_event=PreToolUse
. "$(dirname "${BASH_SOURCE[0]}")/lib.sh"

tool="$(json_field tool_name)"
case "$tool" in Edit|Write|MultiEdit) ;; *) pass ;; esac

fp="$(json_field tool_input.file_path)"
if [ -z "$fp" ]; then pass; fi

# horos's own state + the decision ledger are always writable, else /scope would deadlock
# and decision-guard (philosophy 2) could never be satisfied.
case "$fp" in *"/.horos/"*|*"/.horos"|*"/decisions.jsonl") pass ;; esac

SCOPE="$HOROS_STATE/scope.json"
if [ ! -f "$SCOPE" ]; then pass; fi

verdict="$(HOROS_ROOT="$HOROS_ROOT" HOROS_FP="$fp" HOROS_SCOPE="$SCOPE" python3 - <<'PY'
import json, os, fnmatch
root = os.environ["HOROS_ROOT"].rstrip('/')
fp = os.environ["HOROS_FP"]
if fp.startswith(root + '/'):
    rel = fp[len(root) + 1:]
elif fp.startswith('/'):
    rel = fp            # absolute path outside the project => out of scope by definition
else:
    rel = fp
try:
    allow = json.load(open(os.environ["HOROS_SCOPE"])).get("allow", [])
except Exception:
    allow = []
def match(rel, pat):
    if fnmatch.fnmatch(rel, pat):
        return True
    base = pat.rstrip('*').rstrip('/')      # treat "dir/" or "dir/**" as a prefix
    return bool(base) and (rel == base or rel.startswith(base + '/'))
ok = any(match(rel, p) for p in allow)
print("OK" if ok else "OUT\t" + rel + "\t" + "; ".join(allow))
PY
)"

if [ "${verdict%%	*}" = OK ]; then pass; fi
rel="$(printf '%s' "$verdict" | cut -f2)"
allow="$(printf '%s' "$verdict" | cut -f3)"
enforce_pretool "scope" "$rel" \
  "범위 밖 수정: '$rel' 은 선언된 scope에 없음 (allow: $allow). 의도한 확장이면 /scope 로 경계를 넓히고, 아니면 범위 안에서 작업하세요."
