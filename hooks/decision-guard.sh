#!/usr/bin/env bash
# Philosophy 2 — externalize decisions (and held tensions) as trackable objects.
# Stop: if this session changed code, ids REFERENCED IN COMMENTS by that code must exist and be
# complete in the ledger (decisions.jsonl). Supports Claude Edit/Write/MultiEdit + Codex apply_patch,
# realpath normalization, and quote/URL-safe comment extraction (# D3, # D8, # D27, # D28, # D29).
set -euo pipefail
hook_event=Stop
. "$(dirname "${BASH_SOURCE[0]}")/lib.sh"

sha="$(json_field stop_hook_active)"
if [ "$sha" = true ] || [ "$sha" = True ]; then pass; fi
sid="$(json_field session_id)"
tp="$(json_field transcript_path)"
if [ -z "$tp" ] || [ ! -f "$tp" ]; then pass; fi

GUARD="$HOROS_STATE/stop_guard_decision"
guard_check_or_pass "$GUARD" "$sid"

vfile="$(mktemp)"; trap 'rm -f "$vfile"' EXIT
PYTHONPATH="$HOROS_HERE" HOROS_TP="$tp" HOROS_LEDGER="$HOROS_ROOT/decisions.jsonl" HOROS_ROOT="$HOROS_ROOT" \
  python3 - > "$vfile" 2>/dev/null <<'PY' || { log_event HOROS-TEL-PYFAIL decision-guard; guard_reset "$GUARD" "$sid"; pass; }
import os, horos_core

root = os.environ.get("HOROS_ROOT", "")
changed_files, new_lines, refs = horos_core.extract_session_changes(os.environ["HOROS_TP"], root)
if not changed_files:
    print("PASS"); raise SystemExit

ledger, tel = horos_core.load_ledger(os.environ["HOROS_LEDGER"])
for t in tel:
    print(t)

nfd = horos_core.next_free_id(ledger.keys(), "D")
broken = []
broken_ids = []
for d in sorted(refs):
    if d not in ledger:
        broken.append(d + "(미정의/undefined)"); broken_ids.append(d)
    elif not horos_core.record_complete(ledger[d]):
        broken.append(d + "(불완전/incomplete)"); broken_ids.append(d)

if broken:
    print("BROKEN\t" + ", ".join(broken) + "\t" + broken_ids[0] + "\t" + nfd); raise SystemExit
if not refs:
    significant = len(changed_files) >= 2 or new_lines >= 8
    print(("MISSING\t" + nfd) if significant else "PASS"); raise SystemExit
print("PASS")
PY
verdict="$(drain_tel "$vfile")"

case "${verdict%%	*}" in
  BROKEN)
    detail="$(printf '%s' "$verdict" | cut -f2)"
    bid="$(printf '%s' "$verdict" | cut -f3)"
    case "$bid" in
      A*) fix="horos aporia $bid \"<극1>|<극2>\" \"<why_unresolved>\" \"<trigger>\"" ;;
      *)  fix="horos decide $bid \"<why>\" \"<cost>\" \"<escape>\"" ;;
    esac
    n="$(guard_bump "$GUARD" "$sid")"
    if [ "$n" -eq "$(loop_threshold)" ]; then log_event HOROS-TEL-LOOPGUARD "decision:$sid"; fi
    enforce_stop HOROS-DEC-BROKEN "decision/broken-ref" "$detail" \
      "코드 주석이 결정/아포리아 ID를 참조하지만 ledger(decisions.jsonl)에 없거나 불완전합니다: ${detail}. Action: externalize the referenced id into the ledger now, then end the turn. 예: ${fix}" ;;
  MISSING)
    nfd="$(printf '%s' "$verdict" | cut -f2)"; [ -n "$nfd" ] || nfd="D<n>"
    msg="이번 세션에 유의미한 코드 변경이 있었지만 결정(D-id)을 외화한 흔적이 없습니다. 중요한 선택이었다면 기록하고 코드 주석으로 참조하세요. Action: record the key decision, then reference it from a code comment. 예: horos decide ${nfd} \"<why>\" \"<cost>\" \"<escape>\"  후 코드에  # ${nfd}"
    if [ "$(horos_mode)" = strict ]; then
      n="$(guard_bump "$GUARD" "$sid")"
      if [ "$n" -eq "$(loop_threshold)" ]; then log_event HOROS-TEL-LOOPGUARD "decision:$sid"; fi
      enforce_stop HOROS-DEC-MISSING "decision/not-externalized" "significant code change, no D-id reference" "$msg"
    else
      guard_reset "$GUARD" "$sid"
      log_violation "decision/not-externalized" "significant code change, no D-id reference" HOROS-DEC-MISSING
      warn_emit "HOROS-DEC-MISSING $msg"
    fi ;;
  *)
    guard_reset "$GUARD" "$sid"; pass ;;
esac
