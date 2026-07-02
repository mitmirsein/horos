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

# NOTE: python output goes to a tempfile, not $(...<<'PY'...) — bash's $() + here-doc scanner
# can prematurely close on parenthesis-heavy bodies (same pattern as claim-guard). # D15
vfile="$(mktemp)"; trap 'rm -f "$vfile"' EXIT
# D16: a judge crash must not kill the Stop silently-with-stderr — trace PYFAIL, then pass.
HOROS_TP="$tp" HOROS_LEDGER="$HOROS_ROOT/decisions.jsonl" HOROS_ROOT="$HOROS_ROOT" python3 - > "$vfile" 2>/dev/null <<'PY' || { log_event HOROS-TEL-PYFAIL decision-guard; printf '%s 0\n' "$sid" > "$GUARD"; pass; }
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
        for lineno, line in enumerate(f, 1):
            line = line.strip()
            if not line: continue
            try: r = json.loads(line)
            except Exception:                  # D16: dropped ledger lines leave a trace
                print("TEL\tHOROS-TEL-MALFORMED\tledger:%d" % lineno); continue
            if r.get("id"): ledger[r["id"]] = r
except FileNotFoundError:
    pass
def next_free(prefix):                         # D15: for filled command examples in messages
    n = 0
    for i in ledger:
        m = re.match("^" + prefix + r"([1-9][0-9]*)$", str(i))
        if m: n = max(n, int(m.group(1)))
    return "%s%d" % (prefix, n + 1)
def complete(r):                               # D8: completeness depends on record kind
    if r.get("type") == "aporia":
        return bool(r.get("poles")) and all(str(r.get(k, "")).strip()
                                             for k in ("why_unresolved", "trigger"))
    return all(str(r.get(k, "")).strip() for k in ("why", "cost", "escape"))
broken = []; broken_ids = []
for d in sorted(refs):
    if d not in ledger:
        broken.append(d + "(미정의/undefined)"); broken_ids.append(d)
    elif not complete(ledger[d]):
        broken.append(d + "(불완전/incomplete)"); broken_ids.append(d)
if broken:
    # fields: detail, first broken bare id, next free D-id (both for filled examples, D15)
    print("BROKEN\t" + ", ".join(broken) + "\t" + broken_ids[0] + "\t" + next_free("D")); raise SystemExit
if not refs:
    significant = len(changed_files) >= 2 or new_lines >= 8
    print(("MISSING\t" + next_free("D")) if significant else "PASS"); raise SystemExit
print("PASS")
PY
verdict="$(drain_tel "$vfile")"

case "${verdict%%	*}" in
  BROKEN)
    detail="$(printf '%s' "$verdict" | cut -f2)"
    bid="$(printf '%s' "$verdict" | cut -f3)"
    case "$bid" in                             # D15: fill the fix command for the actual broken id
      A*) fix="horos aporia $bid \"<극1>|<극2>\" \"<why_unresolved>\" \"<trigger>\"" ;;
      *)  fix="horos decide $bid \"<why>\" \"<cost>\" \"<escape>\"" ;;
    esac
    n=$(( prev_n + 1 )); printf '%s %s\n' "$sid" "$n" > "$GUARD"
    if [ "$n" -eq 2 ]; then log_event HOROS-TEL-LOOPGUARD "decision:$sid"; fi   # D16: silence starts next Stop
    enforce_stop HOROS-DEC-BROKEN "decision/broken-ref" "$detail" \
      "코드 주석이 결정/아포리아 ID를 참조하지만 ledger(decisions.jsonl)에 없거나 불완전합니다: ${detail}. Action: externalize the referenced id into the ledger now, then end the turn. 예: ${fix}" ;;
  MISSING)
    nfd="$(printf '%s' "$verdict" | cut -f2)"; [ -n "$nfd" ] || nfd="D<n>"
    printf '%s 0\n' "$sid" > "$GUARD"
    log_violation "decision/not-externalized" "significant code change, no D-id reference" HOROS-DEC-MISSING
    warn_emit "HOROS-DEC-MISSING 이번 세션에 유의미한 코드 변경이 있었지만 결정(D-id)을 외화한 흔적이 없습니다. 중요한 선택이었다면 기록하고 코드 주석으로 참조하세요. Action: record the key decision, then reference it from a code comment. 예: horos decide ${nfd} \"<why>\" \"<cost>\" \"<escape>\"  후 코드에  # ${nfd}" ;;
  *)
    printf '%s 0\n' "$sid" > "$GUARD"; pass ;;
esac
