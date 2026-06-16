#!/usr/bin/env bash
# Philosophy 5 — a broad definition of "done".
# Stop: refuse a turn that ends by *promising* work instead of doing it (fablize-style),
# or that *claims completion* without having used a single tool to verify (conservative).
# Loop guard: prefer stop_hook_active if the runtime supplies it; else a session-keyed counter.
set -euo pipefail
hook_event=Stop
. "$(dirname "${BASH_SOURCE[0]}")/lib.sh"

sha="$(json_field stop_hook_active)"
if [ "$sha" = true ] || [ "$sha" = True ]; then pass; fi

sid="$(json_field session_id)"
tp="$(json_field transcript_path)"
if [ -z "$tp" ] || [ ! -f "$tp" ]; then pass; fi

GUARD="$HOROS_STATE/stop_guard"
prev_sid=""; prev_n=0
if [ -f "$GUARD" ]; then read -r prev_sid prev_n < "$GUARD" || true; fi
[ "$prev_sid" = "$sid" ] || prev_n=0
[[ "${prev_n:-0}" =~ ^[0-9]+$ ]] || prev_n=0
if [ "${prev_n:-0}" -ge 2 ]; then
  printf '%s 0\n' "$sid" > "$GUARD"   # already nudged twice this session: stop nagging
  pass
fi

verdict="$(HOROS_TP="$tp" python3 - <<'PY'
import json, os, re
tp = os.environ["HOROS_TP"]
last = None
tool_seen = False
with open(tp) as f:
    for line in f:
        line = line.strip()
        if not line:
            continue
        try:
            o = json.loads(line)
        except Exception:
            continue
        if o.get("type") == "assistant":
            last = o
            for b in (o.get("message", {}) or {}).get("content", []) or []:
                if isinstance(b, dict) and b.get("type") == "tool_use":
                    tool_seen = True
if not last:
    print("PASS"); raise SystemExit
content = (last.get("message", {}) or {}).get("content", []) or []
has_tool = any(isinstance(b, dict) and b.get("type") == "tool_use" for b in content)
text = " ".join(b.get("text", "") for b in content
                if isinstance(b, dict) and b.get("type") == "text").strip()
low = text.lower()
tail = low[-400:]
# legitimate stop: the turn ends by asking / offering — leave it alone
if re.search(r"(\?|shall i|would you like|할까요|드릴까요|하시겠|여쭤|알려\s*주세요)", tail):
    print("PASS"); raise SystemExit
if has_tool:
    print("PASS"); raise SystemExit          # ended on a tool call, not a bare promise
# promise-without-action
if re.search(r"\b(i'?ll|i will|let me|next,? i|now i'?ll)\b.{0,40}\b"
             r"(implement|create|write|add|run|fix|build|test)\b", low) \
   or re.search(r"(이제|다음으로|곧|바로)\s*.{0,20}(구현|작성|추가|실행|수정|만들|돌려|테스트)", low):
    print("PROMISE"); raise SystemExit
# completion claim with zero tool use in the whole session (near-zero false positive)
if (not tool_seen) and re.search(r"(완료(?:했|됐|됩|입니다)|finished|all set|\bdone\b|✅|끝났|마쳤)", low):
    print("CLAIM"); raise SystemExit
print("PASS")
PY
)"

case "$verdict" in
  PROMISE)
    printf '%s %s\n' "$sid" "$(( prev_n + 1 ))" > "$GUARD"
    enforce_stop "finish/promise" "promise-without-action" \
      "직전 응답이 작업을 '하겠다'고 말만 하고 도구 호출 없이 끝났습니다. 지금 도구로 그 작업을 실제로 수행하세요." ;;
  CLAIM)
    printf '%s %s\n' "$sid" "$(( prev_n + 1 ))" > "$GUARD"
    enforce_stop "finish/claim" "completion-without-evidence" \
      "완료를 선언했지만 이번 세션에 검증 도구 호출이 한 번도 없습니다. 완료 정의(동작+테스트+검증)를 증거와 함께 충족했는지 확인하세요." ;;
  *)
    printf '%s 0\n' "$sid" > "$GUARD"
    pass ;;
esac
