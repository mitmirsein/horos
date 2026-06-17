#!/usr/bin/env bash
# Philosophy 2 — externalize decisions (and held tensions) as trackable objects.
# Stop: if this session changed code, ids REFERENCED IN COMMENTS by that code must exist and be
# complete in the ledger (decisions.jsonl). Two id kinds (D8):
#   - D<n> decision : complete = why + cost + escape
#   - A<n> aporia   : complete = poles + why_unresolved + trigger (a tension deliberately left open)
#   - broken/incomplete reference (either kind) -> enforce per mode (block-able; clean machine verdict)
#   - SIGNIFICANT code change with zero D/A-ref -> warn only (trivial edits exempt; aporia never required)
# Refs are read ONLY from comments (#, //), and test/fixture files are skipped, so string
# literals like {"id":"D1"} in code are not mistaken for references (D3).
set -euo pipefail
hook_event=Stop
. "$(dirname "${BASH_SOURCE[0]}")/lib.sh"

sha="$(json_field stop_hook_active)"
if [ "$sha" = true ] || [ "$sha" = True ]; then pass; fi
sid="$(json_field session_id)"
tp="$(json_field transcript_path)"
if [ -z "$tp" ] || [ ! -f "$tp" ]; then pass; fi

GUARD="$HOROS_STATE/stop_guard_decision"
prev_sid=""; prev_n=0
if [ -f "$GUARD" ]; then read -r prev_sid prev_n < "$GUARD" || true; fi
[ "$prev_sid" = "$sid" ] || prev_n=0
[[ "${prev_n:-0}" =~ ^[0-9]+$ ]] || prev_n=0
if [ "${prev_n:-0}" -ge 2 ]; then printf '%s 0\n' "$sid" > "$GUARD"; pass; fi

verdict="$(HOROS_TP="$tp" HOROS_LEDGER="$HOROS_ROOT/decisions.jsonl" HOROS_ROOT="$HOROS_ROOT" python3 - <<'PY'
import json, os, re
CODE_EXT = (".py",".js",".ts",".tsx",".jsx",".sh",".go",".rs",".java",".rb",
            ".c",".cpp",".cc",".h",".hpp",".php",".swift",".kt",".scala",
            ".clj",".ex",".exs",".lua",".pl",".mjs",".cjs",".vue",".dart")
TESTISH = re.compile(r'(?:^|/)(?:tests?|fixtures?|spec|__tests__)(?:/|$)|\.(?:test|spec)\.')
COMMENT = re.compile(r'(?:#|//)\s*(.*)')
DREF = re.compile(r'\b[DA]\d+\b')              # D8: decisions (D) and aporias (A)
ROOT = os.environ.get("HOROS_ROOT", "").rstrip('/')   # D10: only judge files inside this project
def in_project(fp):                            # D10: drop edits outside CLAUDE_PROJECT_DIR (parent-session bridge)
    if not fp.startswith('/'):                 # relative path -> assume in-project (fixtures, rel edits)
        return True
    return bool(ROOT) and (fp == ROOT or fp.startswith(ROOT + '/'))
changed_files = set(); new_lines = 0; refs = set()
with open(os.environ["HOROS_TP"]) as f:
    for line in f:
        line = line.strip()
        if not line: continue
        try: o = json.loads(line)
        except Exception: continue
        if o.get("type") != "assistant": continue
        for b in (o.get("message", {}) or {}).get("content", []) or []:
            if not (isinstance(b, dict) and b.get("type") == "tool_use"): continue
            if b.get("name") not in ("Edit", "Write", "MultiEdit"): continue
            inp = b.get("input", {}) or {}
            fp = inp.get("file_path", "") or ""
            if not fp.endswith(CODE_EXT): continue
            if not in_project(fp): continue            # D10: skip files outside this project
            if TESTISH.search(fp): continue            # D3: skip test / fixture files
            changed_files.add(fp)
            blob = " ".join(str(inp.get(k, "")) for k in ("new_string", "content"))
            for e in inp.get("edits", []) or []:
                blob += "\n" + str(e.get("new_string", ""))
            new_lines += blob.count("\n")
            for ln in blob.splitlines():               # D3: D-refs from comments only
                m = COMMENT.search(ln)
                if m:
                    refs.update(DREF.findall(m.group(1)))
if not changed_files:
    print("PASS"); raise SystemExit
ledger = {}
try:
    with open(os.environ["HOROS_LEDGER"]) as f:
        for line in f:
            line = line.strip()
            if not line: continue
            try: r = json.loads(line)
            except Exception: continue
            if r.get("id"): ledger[r["id"]] = r
except FileNotFoundError:
    pass
def complete(r):                               # D8: completeness depends on record kind
    if r.get("type") == "aporia":
        return bool(r.get("poles")) and all(str(r.get(k, "")).strip()
                                             for k in ("why_unresolved", "trigger"))
    return all(str(r.get(k, "")).strip() for k in ("why", "cost", "escape"))
broken = []
for d in sorted(refs):
    if d not in ledger: broken.append(d + "(미정의)")
    elif not complete(ledger[d]): broken.append(d + "(불완전)")
if broken:
    print("BROKEN\t" + ", ".join(broken)); raise SystemExit
if not refs:
    significant = len(changed_files) >= 2 or new_lines >= 8
    print("MISSING" if significant else "PASS"); raise SystemExit
print("PASS")
PY
)"

case "${verdict%%	*}" in
  BROKEN)
    detail="$(printf '%s' "$verdict" | cut -f2)"
    printf '%s %s\n' "$sid" "$(( prev_n + 1 ))" > "$GUARD"
    enforce_stop "decision/broken-ref" "$detail" \
      "코드 주석이 결정/아포리아 ID를 참조하지만 ledger(decisions.jsonl)에 없거나 불완전합니다: ${detail}. 결정은 'horos decide D<n> <why> <cost> <escape>', 아포리아는 'horos aporia A<n> \"<극1>|<극2>\" <why_unresolved> <trigger>' 로 외화하세요." ;;
  MISSING)
    printf '%s 0\n' "$sid" > "$GUARD"
    log_violation "decision/not-externalized" "significant code change, no D-id reference"
    warn_emit "이번 세션에 유의미한 코드 변경이 있었지만 결정(D-id)을 외화한 흔적이 없습니다. 중요한 선택이라면 'horos decide D<n> <why> <cost> <escape>' 로 기록하고 코드 주석에 # D<n> 으로 참조하세요." ;;
  *)
    printf '%s 0\n' "$sid" > "$GUARD"; pass ;;
esac
