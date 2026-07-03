#!/usr/bin/env bash
# Audit tier (D9) — verify the agent's deposited CLAIMS about this session's code changes.
# Stop: the agent deposits claims (`horos claim`) into .horos/claims.jsonl. This gate judges,
# with python3 stdlib only (NO LLM, NO network), the FORM of those claims — never semantic truth:
#   - schema + internal invariants + cross-ref integrity  -> enforce per mode (block-able)
#   - SIGNIFICANT code change with no FRESH covering claim -> warn only (trivial edits exempt)
# Freshness = full-file sha256(disk) == claim.binds. A stale claim is DROPPED, not blocked (D9):
# a legitimate re-edit must not false-block, so staleness demotes to the coverage(warn) path.
# Honest boundary: a fresh, schema-valid, invariant-consistent claim that is nonetheless
# semantically FALSE (a coherent lie) passes. horos guarantees the claim's form, not its truth.
set -euo pipefail
hook_event=Stop
. "$(dirname "${BASH_SOURCE[0]}")/lib.sh"

sha="$(json_field stop_hook_active)"
if [ "$sha" = true ] || [ "$sha" = True ]; then pass; fi
sid="$(json_field session_id)"
tp="$(json_field transcript_path)"
if [ -z "$tp" ] || [ ! -f "$tp" ]; then pass; fi

GUARD="$HOROS_STATE/stop_guard_claim"
prev_sid=""; prev_n=0
if [ -f "$GUARD" ]; then read -r prev_sid prev_n < "$GUARD" || true; fi
[ "$prev_sid" = "$sid" ] || prev_n=0
[[ "${prev_n:-0}" =~ ^[0-9]+$ ]] || prev_n=0
if [ "${prev_n:-0}" -ge "$(loop_threshold)" ]; then printf '%s 0\n' "$sid" > "$GUARD"; pass; fi

# NOTE: the python is redirected to a tempfile rather than captured via $(...<<'PY'...).
# bash's $() + here-doc scanner can prematurely close on parenthesis-heavy bodies; this avoids it.
vfile="$(mktemp)"; trap 'rm -f "$vfile"' EXIT
# D16: a judge crash must not kill the Stop silently-with-stderr — trace PYFAIL, then pass.
HOROS_TP="$tp" HROOT="$HOROS_ROOT" HOROS_CLAIMS="$HOROS_STATE/claims.jsonl" HOROS_LEDGER="$HOROS_ROOT/decisions.jsonl" python3 - > "$vfile" 2>/dev/null <<'PY' || { log_event HOROS-TEL-PYFAIL claim-guard; printf '%s 0\n' "$sid" > "$GUARD"; pass; }
import json, os, re, hashlib
CODE_EXT = (".py",".js",".ts",".tsx",".jsx",".sh",".go",".rs",".java",".rb",
            ".c",".cpp",".cc",".h",".hpp",".php",".swift",".kt",".scala",
            ".clj",".ex",".exs",".lua",".pl",".mjs",".cjs",".vue",".dart")
TESTISH = re.compile(r'(?:^|/)(?:tests?|fixtures?|spec|__tests__)(?:/|$)|\.(?:test|spec)\.')
ROOT = os.environ["HROOT"].rstrip('/')
KINDS = ("completion", "consistency")
def in_project(fp):                            # D10: only consider files inside this project (parent-session bridge)
    if not fp.startswith('/'):                 # relative -> assume in-project (fixtures, rel edits)
        return True
    return bool(ROOT) and (fp == ROOT or fp.startswith(ROOT + '/'))

# 1) this session's changed code files (same rule as decision-guard; test/fixture paths skipped)
changed = set(); new_lines = 0
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
            if TESTISH.search(fp): continue
            changed.add(fp)
            blob = " ".join(str(inp.get(k, "")) for k in ("new_string", "content"))
            for e in inp.get("edits", []) or []:
                blob += "\n" + str(e.get("new_string", ""))
            new_lines += blob.count("\n")
# D21: transcript file_path is ABSOLUTE, but claim.evidence_files are ROOT-relative (CLI convention).
# Comparing the two sets directly was always empty in production -> every fresh covering claim was
# invisible: the audit tier's coverage falsely warned AND its structural (BROKEN) checks never ran.
# D18 strict escalated that to an UNSATISFIABLE block. Normalize both sides to ROOT-relative here.
def relpath(fp):
    return fp[len(ROOT) + 1:] if (ROOT and fp.startswith(ROOT + '/')) else fp
changed = {relpath(f) for f in changed}
if not changed:
    print("PASS"); raise SystemExit

# 2) load claims (runtime, machine-local) and the decision ledger (for cross-ref)
def load(path, label):
    out = []
    try:
        with open(path) as f:
            for lineno, line in enumerate(f, 1):
                line = line.strip()
                if not line: continue
                try: out.append(json.loads(line))
                except Exception:              # D16: dropped lines leave a trace
                    print("TEL\tHOROS-TEL-MALFORMED\t%s:%d" % (label, lineno))
    except FileNotFoundError:
        pass
    return out
claims = load(os.environ["HOROS_CLAIMS"], "claims")
ledger = {r["id"]: r for r in load(os.environ["HOROS_LEDGER"], "ledger") if r.get("id")}

def complete(r):                               # D8: kind-aware completeness (shared with decision-guard)
    if r.get("type") == "aporia":
        return bool(r.get("poles")) and all(str(r.get(k, "")).strip()
                                             for k in ("why_unresolved", "trigger"))
    return all(str(r.get(k, "")).strip() for k in ("why", "cost", "escape"))

def filehash(rel):
    try:
        with open(os.path.join(ROOT, rel), "rb") as fh:
            return hashlib.sha256(fh.read()).hexdigest()
    except OSError:
        return None
def fresh(c):                                  # all bound files still match the claimed hash
    binds = c.get("binds") or {}
    return bool(binds) and all(filehash(f) == h for f, h in binds.items())

# 3) only FRESH claims touching this session's changes are judged (stale -> dropped, D9)
def ev(c): return {relpath(x) for x in (c.get("evidence_files") or [])}   # D21: normalize to match `changed`
relevant = []
for c in claims:
    if not (ev(c) & changed): continue
    if fresh(c): relevant.append(c)
    else:                                      # D16: a demoted claim leaves a trace
        print("TEL\tHOROS-TEL-STALE-DROP\t" + str(c.get("id", "?")))

def relcsv(paths):                             # D15: up to 3 ROOT-relative paths for filled examples
    out = []
    for p in sorted(paths)[:3]:
        out.append(p[len(ROOT) + 1:] if ROOT and p.startswith(ROOT + '/') else p)
    return ",".join(out)

errs = []
for c in relevant:
    cid = c.get("id", "?")
    if c.get("kind") not in KINDS: errs.append(cid + "(kind 불명/unknown-kind)")
    if not isinstance(c.get("evidence_files"), list) or not c.get("evidence_files"):
        errs.append(cid + "(evidence_files 없음/empty)")
    if not str(c.get("assert", "")).strip(): errs.append(cid + "(assert 없음/empty)")
    ct = c.get("claims_true") or {}
    if ct.get("tests_added") and not any(TESTISH.search(x) for x in (c.get("evidence_files") or [])):
        errs.append(cid + "(tests_added 허위/false: no test file in evidence)")
    if ct.get("consistent_with_refs") and not (c.get("refs") or []):
        errs.append(cid + "(consistent_with_refs 인데 refs 없음/refs empty)")
    for d in (c.get("refs") or []):
        if d not in ledger: errs.append(cid + ":" + d + "(미정의/undefined)")
        elif not complete(ledger[d]): errs.append(cid + ":" + d + "(불완전/incomplete)")
if errs:
    print("BROKEN\t" + ", ".join(errs) + "\t" + relcsv(changed)); raise SystemExit

# 4) coverage: significant change with no fresh covering claim -> warn
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
    n=$(( prev_n + 1 )); printf '%s %s\n' "$sid" "$n" > "$GUARD"
    if [ "$n" -eq "$(loop_threshold)" ]; then log_event HOROS-TEL-LOOPGUARD "claim:$sid"; fi   # D16: silence starts next Stop
    enforce_stop HOROS-CLM-BROKEN "claim/structural" "$detail" \
      "떨궈진 claim 이 구조 검사를 통과하지 못했습니다: ${detail}. Action: fix the claim (or externalize the missing ref first) and redeposit. 예: horos claim completion \"<한 일>\" \"${fcsv}\"  (테스트를 실제로 추가했을 때만 끝에 tests_added 를 붙여라. 이 게이트는 형식·신선·일관만 보장하며 의미 진리는 보장하지 않습니다.)" ;;
  MISSING)
    fcsv="$(printf '%s' "$verdict" | cut -f2)"; [ -n "$fcsv" ] || fcsv="<files,csv>"
    # 예 omits tests_added on purpose: copying it verbatim must not self-defeat into CLM-BROKEN
    # when no test file is in evidence (add tests_added only when you actually added a test). # D15
    msg="유의미한 코드 변경에 이를 덮는 claim 이 없습니다. Action: deposit a verifiable claim covering the changed files. 예: horos claim completion \"<한 일>\" \"${fcsv}\"  (테스트 추가 시에만 끝에 tests_added)"
    if [ "$(horos_mode)" = strict ]; then          # D18: strict promotes coverage-MISSING to a block
      n=$(( prev_n + 1 )); printf '%s %s\n' "$sid" "$n" > "$GUARD"
      if [ "$n" -eq "$(loop_threshold)" ]; then log_event HOROS-TEL-LOOPGUARD "claim:$sid"; fi
      enforce_stop HOROS-CLM-MISSING "claim/uncovered" "significant code change, no fresh covering claim" "$msg"
    else
      printf '%s 0\n' "$sid" > "$GUARD"
      log_violation "claim/uncovered" "significant code change, no fresh covering claim" HOROS-CLM-MISSING
      warn_emit "HOROS-CLM-MISSING $msg (감사층, warn)"
    fi ;;
  *)
    printf '%s 0\n' "$sid" > "$GUARD"; pass ;;
esac
