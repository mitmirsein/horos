#!/usr/bin/env bash
# Audit tier (D9) — verify the agent's deposited CLAIMS about this session's code changes.
# Stop: judges with python3 stdlib only (NO LLM, NO network) the FORM of claims in .horos/claims.jsonl:
#   - schema + internal invariants + cross-ref integrity  -> enforce per mode (block-able)
#   - SIGNIFICANT code change with no FRESH covering claim -> warn (or block in strict, D18)
# Supports Claude Edit/Write/MultiEdit + Codex apply_patch and realpath normalization (# D27, # D28, # D29).
set -euo pipefail
hook_event=Stop
. "$(dirname "${BASH_SOURCE[0]}")/lib.sh"

sha="$(json_field stop_hook_active)"
if [ "$sha" = true ] || [ "$sha" = True ]; then pass; fi
sid="$(json_field session_id)"
tp="$(json_field transcript_path)"
if [ -z "$tp" ] || [ ! -f "$tp" ]; then pass; fi

GUARD="$HOROS_STATE/stop_guard_claim"
guard_check_or_pass "$GUARD" "$sid"

vfile="$(mktemp)"; trap 'rm -f "$vfile"' EXIT
PYTHONPATH="$HOROS_HERE" HOROS_TP="$tp" HROOT="$HOROS_ROOT" HOROS_CLAIMS="$HOROS_STATE/claims.jsonl" \
  HOROS_LEDGER="$HOROS_ROOT/decisions.jsonl" python3 - > "$vfile" 2>/dev/null <<'PY' || { log_event HOROS-TEL-PYFAIL claim-guard; guard_reset "$GUARD" "$sid"; pass; }
import hashlib, os, horos_core

ROOT = os.environ["HROOT"]
real_root = os.path.realpath(ROOT)

changed, new_lines, _ = horos_core.extract_session_changes(os.environ["HOROS_TP"], ROOT)
if not changed:
    print("PASS"); raise SystemExit

claims, c_tel = horos_core.load_jsonl(os.environ["HOROS_CLAIMS"], "claims")
ledger, l_tel = horos_core.load_ledger(os.environ["HOROS_LEDGER"])
for t in c_tel + l_tel:
    print(t)

def norm_rel(p):
    inside, rel = horos_core.normalize_relpath(str(p), ROOT)
    return rel if inside else str(p)

def filehash(p):
    inside, rel = horos_core.normalize_relpath(str(p), ROOT)
    if not inside:
        return None
    try:
        with open(os.path.join(real_root, rel), "rb") as fh:
            return hashlib.sha256(fh.read()).hexdigest()
    except OSError:
        return None

def fresh(c):
    binds = c.get("binds") or {}
    return isinstance(binds, dict) and bool(binds) and all(filehash(f) == h for f, h in binds.items())

def ev(c):
    raw = c.get("evidence_files")
    if not isinstance(raw, list):
        return set()
    return {norm_rel(x) for x in raw if x}

relevant = []
for c in claims:
    if not (ev(c) & changed):
        continue
    if fresh(c):
        relevant.append(c)
    else:
        print("TEL\tHOROS-TEL-STALE-DROP\t" + str(c.get("id", "?")))

def relcsv(paths):
    return ",".join(sorted(paths)[:3])

errs = []
for c in relevant:
    cid = str(c.get("id", "?"))
    if c.get("kind") not in horos_core.CLAIM_KINDS:
        errs.append(cid + "(kind 불명/unknown-kind)")
    ev_list = c.get("evidence_files")
    if not isinstance(ev_list, list) or not ev_list:
        errs.append(cid + "(evidence_files 없음/empty)")
    if not str(c.get("assert", "")).strip():
        errs.append(cid + "(assert 없음/empty)")
    ct = c.get("claims_true") or {}
    if isinstance(ct, dict) and ct.get("tests_added") and not any(
        horos_core.TESTISH.search(norm_rel(x)) for x in (ev_list or [])
    ):
        errs.append(cid + "(tests_added 허위/false: no test file in evidence)")
    if isinstance(ct, dict) and ct.get("consistent_with_refs") and not (c.get("refs") or []):
        errs.append(cid + "(consistent_with_refs 인데 refs 없음/refs empty)")
    for d in (c.get("refs") or []):
        if d not in ledger:
            errs.append(cid + ":" + str(d) + "(미정의/undefined)")
        elif not horos_core.record_complete(ledger[d]):
            errs.append(cid + ":" + str(d) + "(불완전/incomplete)")
if errs:
    print("BROKEN\t" + ", ".join(errs) + "\t" + relcsv(changed)); raise SystemExit

covered = set()
for c in relevant:
    covered |= (ev(c) & changed)
if changed - covered:
    significant = len(changed) >= 2 or new_lines >= 8
    print(("MISSING\t" + relcsv(changed - covered)) if significant else "PASS"); raise SystemExit
print("PASS")
PY
verdict="$(drain_tel "$vfile")"

case "${verdict%%	*}" in
  BROKEN)
    detail="$(printf '%s' "$verdict" | cut -f2)"
    fcsv="$(printf '%s' "$verdict" | cut -f3)"; [ -n "$fcsv" ] || fcsv="<files,csv>"
    n="$(guard_bump "$GUARD" "$sid")"
    if [ "$n" -eq "$(loop_threshold)" ]; then log_event HOROS-TEL-LOOPGUARD "claim:$sid"; fi
    enforce_stop HOROS-CLM-BROKEN "claim/structural" "$detail" \
      "떨궈진 claim 이 구조 검사를 통과하지 못했습니다: ${detail}. Action: fix the claim (or externalize the missing ref first) and redeposit. 예: horos claim completion \"<한 일>\" \"${fcsv}\"  (테스트를 실제로 추가했을 때만 끝에 tests_added 를 붙여라. 이 게이트는 형식·신선·일관만 보장하며 의미 진리는 보장하지 않습니다.)" ;;
  MISSING)
    fcsv="$(printf '%s' "$verdict" | cut -f2)"; [ -n "$fcsv" ] || fcsv="<files,csv>"
    msg="유의미한 코드 변경에 이를 덮는 claim 이 없습니다. Action: deposit a verifiable claim covering the changed files. 예: horos claim completion \"<한 일>\" \"${fcsv}\"  (테스트 추가 시에만 끝에 tests_added)"
    if [ "$(horos_mode)" = strict ]; then
      n="$(guard_bump "$GUARD" "$sid")"
      if [ "$n" -eq "$(loop_threshold)" ]; then log_event HOROS-TEL-LOOPGUARD "claim:$sid"; fi
      enforce_stop HOROS-CLM-MISSING "claim/uncovered" "significant code change, no fresh covering claim" "$msg"
    else
      guard_reset "$GUARD" "$sid"
      log_violation "claim/uncovered" "significant code change, no fresh covering claim" HOROS-CLM-MISSING
      warn_emit "HOROS-CLM-MISSING $msg (감사층, warn)"
    fi ;;
  *)
    guard_reset "$GUARD" "$sid"; pass ;;
esac
