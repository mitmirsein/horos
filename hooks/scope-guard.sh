#!/usr/bin/env bash
# Philosophy 3 — boundary convergence.
# PreToolUse(Edit|Write|MultiEdit|NotebookEdit|apply_patch): file edits must fall inside the
# declared scope allowlist (# D18, # D28, # D29).
# No scope declared => no enforcement (declaring the boundary is an opt-in act, per philosophy 3).
set -euo pipefail
hook_event=PreToolUse
. "$(dirname "${BASH_SOURCE[0]}")/lib.sh"

SCOPE="$HOROS_STATE/scope.json"
if [ ! -f "$SCOPE" ]; then pass; fi

# D16/D28/D29: single python judge handles Claude tools + Codex apply_patch, resolves '..' and
# symlinks via realpath on both root and target, and enforces segment-aware '*' vs '**' globs.
vfile="$(mktemp)"; trap 'rm -f "$vfile"' EXIT
PYTHONPATH="$HOROS_HERE" HOROS_IN="$INPUT" HOROS_ROOT="$HOROS_ROOT" HOROS_SCOPE="$SCOPE" \
  python3 - > "$vfile" 2>/dev/null <<'PY' || { log_event HOROS-TEL-PYFAIL scope-guard; pass; }
import json, os, horos_core

try:
    d = json.loads(os.environ.get("HOROS_IN") or "{}")
except Exception:
    d = {}
if not isinstance(d, dict):
    d = {}

tool = str(d.get("tool_name") or "")
inp = d.get("tool_input")
if tool not in ("Edit", "Write", "MultiEdit", "NotebookEdit", "apply_patch"):
    print("OK"); raise SystemExit

targets = []
if tool == "apply_patch":
    targets = [p for p, _ in horos_core.extract_apply_patch_entries(inp) if p]
elif isinstance(inp, dict):
    fp = str(inp.get("file_path") or inp.get("notebook_path") or "")
    if fp:
        targets = [fp]

if not targets:
    print("OK"); raise SystemExit

root = os.environ["HOROS_ROOT"]
try:
    allow = json.load(open(os.environ["HOROS_SCOPE"], encoding="utf-8")).get("allow", [])
    if not isinstance(allow, list):
        allow = []
    allow = [str(x) for x in allow]
except Exception:
    allow = []

def q(x):
    return "'" + x.replace("'", "'\\''") + "'" if (any(c.isspace() for c in x) or "'" in x) else x

for fp in targets:
    inside, rel = horos_core.normalize_relpath(fp, root)
    # horos's own state + decision ledger inside THIS project are always writable
    if inside and (rel == ".horos" or rel.startswith(".horos/") or rel == "decisions.jsonl"):
        continue
    if inside and any(horos_core.glob_match(rel, p) for p in allow):
        continue
    example = " ".join(q(x) for x in (list(allow) + [rel]))
    print("OUT\t" + rel + "\t" + "; ".join(allow) + "\t" + example)
    raise SystemExit

print("OK")
PY

verdict="$(cat "$vfile")"
if [ -z "$verdict" ]; then log_event HOROS-TEL-PYFAIL scope-guard; pass; fi
if [ "${verdict%%	*}" = OK ]; then pass; fi
rel="$(printf '%s' "$verdict" | cut -f2)"
allow="$(printf '%s' "$verdict" | cut -f3)"
example="$(printf '%s' "$verdict" | cut -f4)"   # shlex-quoted allow globs + rel (D15)
enforce_pretool HOROS-SCOPE-OUT "scope" "$rel" \
  "범위 밖 수정: '$rel' 은 선언된 scope에 없음 (allow: $allow). 의도한 확장이면 경계를 넓힌 뒤 재시도하고, 아니면 범위 안에서 작업하세요. Action: edit only inside the declared scope, or widen it first and retry. 예: /scope $example"
