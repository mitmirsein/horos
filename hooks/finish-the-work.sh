#!/usr/bin/env bash
# Philosophy 5 — a broad definition of "done".
# Stop: refuse a turn that ends by promising work instead of doing it, or that claims completion
# without having used a single tool to verify (# D27, # D30).
set -euo pipefail
hook_event=Stop
. "$(dirname "${BASH_SOURCE[0]}")/lib.sh"

sha="$(json_field stop_hook_active)"
if [ "$sha" = true ] || [ "$sha" = True ]; then pass; fi

sid="$(json_field session_id)"
tp="$(json_field transcript_path)"
if [ -z "$tp" ] || [ ! -f "$tp" ]; then pass; fi

GUARD="$HOROS_STATE/stop_guard"
guard_check_or_pass "$GUARD" "$sid"

# D16/D30: judge via shared stdlib core; trace PYFAIL and fail-open on unexpected exception.
verdict="$(PYTHONPATH="$HOROS_HERE" HOROS_TP="$tp" python3 -c \
  'import os, horos_core; print(horos_core.judge_finish_transcript(os.environ["HOROS_TP"]))' \
  2>/dev/null)" || { log_event HOROS-TEL-PYFAIL finish-the-work; guard_reset "$GUARD" "$sid"; pass; }

case "$verdict" in
  PROMISE)
    n="$(guard_bump "$GUARD" "$sid")"
    if [ "$n" -eq "$(loop_threshold)" ]; then log_event HOROS-TEL-LOOPGUARD "finish:$sid"; fi
    enforce_stop HOROS-FIN-PROMISE "finish/promise" "promise-without-action" \
      "직전 응답이 작업을 '하겠다'고 말만 하고 도구 호출 없이 끝났습니다. Action: perform the promised work NOW with tool calls, then end the turn. (약속한 그 작업을 지금 도구로 실행하세요.)" ;;
  CLAIM)
    n="$(guard_bump "$GUARD" "$sid")"
    if [ "$n" -eq "$(loop_threshold)" ]; then log_event HOROS-TEL-LOOPGUARD "finish:$sid"; fi
    enforce_stop HOROS-FIN-NOEVIDENCE "finish/claim" "completion-without-evidence" \
      "완료를 선언했지만 이번 세션에 검증 도구 호출이 한 번도 없습니다. Action: run THIS project's verification (its tests / build / typecheck) with tools and report the output before claiming done." ;;
  *)
    guard_reset "$GUARD" "$sid"
    pass ;;
esac
