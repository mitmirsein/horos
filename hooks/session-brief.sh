#!/usr/bin/env bash
# session-brief.sh (D17) — SessionStart: push the horos protocol INTO the session context.
# Plain stdout on exit 0 is the SessionStart injection channel (<=15 lines, filled command
# templates with actual next-free ids). Writes .horos/cli.path so slash commands find the central
# CLI under plugin and reference installs (D13, D27, D28).
set -uo pipefail
hook_event=SessionStart
. "$(dirname "${BASH_SOURCE[0]}")/lib.sh"

HERE="$HOROS_HERE"
CLI="$HERE/horos"
printf '%s\n' "$CLI" > "$HOROS_STATE/cli.path" 2>/dev/null || true
ver="unknown"
[ -f "$HERE/../VERSION" ] && ver="$(tr -d '[:space:]' < "$HERE/../VERSION" 2>/dev/null || echo unknown)"

bf="$(mktemp)"; trap 'rm -f "$bf"' EXIT
PYTHONPATH="$HERE" HOROS_LEDGER="$HOROS_ROOT/decisions.jsonl" HOROS_CLAIMS="$HOROS_STATE/claims.jsonl" \
  HOROS_SCOPE="$HOROS_STATE/scope.json" python3 - > "$bf" 2>/dev/null <<'PY' || true
import json, os, horos_core

ledger_recs, _ = horos_core.load_jsonl(os.environ["HOROS_LEDGER"])
claim_recs, _ = horos_core.load_jsonl(os.environ["HOROS_CLAIMS"])
ids = {str(r["id"]) for r in ledger_recs if r.get("id")}
sc = ""
try:
    sc = " ".join(str(g) for g in json.load(open(os.environ["HOROS_SCOPE"], encoding="utf-8")).get("allow", []))
except Exception:
    sc = ""
print(horos_core.next_free_id(ids, "D"), horos_core.next_free_id(ids, "A"), len(ledger_recs), len(claim_recs))
print(sc)
PY
nfd=""; nfa=""; ndec=""; ncl=""; scope_globs=""
{ read -r nfd nfa ndec ncl || true; IFS= read -r scope_globs || true; } < "$bf"
[ -n "$nfd" ] || nfd=D1; [ -n "$nfa" ] || nfa=A1; [ -n "$ndec" ] || ndec=0; [ -n "$ncl" ] || ncl=0
scope_disp="${scope_globs:-"(미선언 — /scope 로 선언하라)"}"

cat <<CARD
[horos v${ver}] 규율층 활성 (discipline hooks active) — mode=$(horos_mode) | scope: ${scope_disp}
5작업철학이 훅으로 강제된다. 아래 규약을 따르면 차단은 없다 (follow these conventions):
1) 경계(철학3) — 작업 시작 시 편집 경계 선언:  /scope <glob> ...   예: /scope src/** tests/** README.md
2) 결정 외화(철학2) — 중요한 설계 선택마다:  horos decide ${nfd} "<why>" "<cost>" "<escape>"   후 코드 주석에  # ${nfd}
   해소하지 않고 보류한 긴장(아포리아):  horos aporia ${nfa} "<극1>|<극2>" "<why_unresolved>" "<trigger>"   후  # ${nfa}
3) 감사 주장 — 변경을 마치면:  horos claim completion "<한 일>" "<files,csv>" "" tests_added
4) 가역성(철학4) — rm -rf, git reset --hard 류 실행 전에 백업/별도 커밋 (훅이 감지)
5) 완료(철학5) — 약속으로 턴을 끝내지 말 것: 도구로 실행하고, 검증 출력과 함께 완료를 선언
훅 메시지 계약: "[horos:warn|block] HOROS-<CODE> <설명>. Action: <영어 지시>. 예: <명령>" — Action 과 예시를 그대로 따르라 (follow the Action line verbatim).
CLI: ${CLI}  (ledger ${ndec}건 · claims ${ncl}건; 'horos' 가 PATH에 없으면 위 절대경로로 실행하라 — use this absolute path if 'horos' is not on PATH)
CARD
exit 0
