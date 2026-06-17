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
if [ "${prev_n:-0}" -ge 2 ]; then printf '%s 0\n' "$sid" > "$GUARD"; pass; fi

# NOTE: the python is redirected to a tempfile rather than captured via $(...<<'PY'...).
# bash's $() + here-doc scanner can prematurely close on parenthesis-heavy bodies; this avoids it.
vfile="$(mktemp)"; trap 'rm -f "$vfile"' EXIT
HOROS_TP="$tp" HROOT="$HOROS_ROOT" HOROS_CLAIMS="$HOROS_STATE/claims.jsonl" HOROS_LEDGER="$HOROS_ROOT/decisions.jsonl" python3 - > "$vfile" <<'PY'
import json, os, re, hashlib
CODE_EXT = (".py",".js",".ts",".tsx",".jsx",".sh",".go",".rs",".java",".rb",
            ".c",".cpp",".cc",".h",".hpp",".php",".swift",".kt",".scala",
            ".clj",".ex",".exs",".lua",".pl",".mjs",".cjs",".vue",".dart")
TESTISH = re.compile(r'(?:^|/)(?:tests?|fixtures?|spec|__tests__)(?:/|$)|\.(?:test|spec)\.')
ROOT = os.environ["HROOT"]
KINDS = ("completion", "consistency")

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
            if TESTISH.search(fp): continue
            changed.add(fp)
            blob = " ".join(str(inp.get(k, "")) for k in ("new_string", "content"))
            for e in inp.get("edits", []) or []:
                blob += "\n" + str(e.get("new_string", ""))
            new_lines += blob.count("\n")
if not changed:
    print("PASS"); raise SystemExit

# 2) load claims (runtime, machine-local) and the decision ledger (for cross-ref)
def load(path):
    out = []
    try:
        with open(path) as f:
            for line in f:
                line = line.strip()
                if not line: continue
                try: out.append(json.loads(line))
                except Exception: continue
    except FileNotFoundError:
        pass
    return out
claims = load(os.environ["HOROS_CLAIMS"])
ledger = {r["id"]: r for r in load(os.environ["HOROS_LEDGER"]) if r.get("id")}

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
def ev(c): return set(c.get("evidence_files") or [])
relevant = [c for c in claims if (ev(c) & changed) and fresh(c)]

errs = []
for c in relevant:
    cid = c.get("id", "?")
    if c.get("kind") not in KINDS: errs.append(cid + "(kind)")
    if not isinstance(c.get("evidence_files"), list) or not c.get("evidence_files"):
        errs.append(cid + "(evidence_files)")
    if not str(c.get("assert", "")).strip(): errs.append(cid + "(assert)")
    ct = c.get("claims_true") or {}
    if ct.get("tests_added") and not any(TESTISH.search(x) for x in (c.get("evidence_files") or [])):
        errs.append(cid + "(tests_added 허위: 증거에 테스트 없음)")
    if ct.get("consistent_with_refs") and not (c.get("refs") or []):
        errs.append(cid + "(consistent_with_refs 인데 refs 없음)")
    for d in (c.get("refs") or []):
        if d not in ledger: errs.append(cid + ":" + d + "(미정의)")
        elif not complete(ledger[d]): errs.append(cid + ":" + d + "(불완전)")
if errs:
    print("BROKEN\t" + ", ".join(errs)); raise SystemExit

# 4) coverage: significant change with no fresh covering claim -> warn
covered = set()
for c in relevant:
    covered |= (ev(c) & changed)
if changed - covered:
    significant = len(changed) >= 2 or new_lines >= 8
    print("MISSING" if significant else "PASS"); raise SystemExit
print("PASS")
PY
verdict="$(cat "$vfile")"

case "${verdict%%	*}" in
  BROKEN)
    detail="$(printf '%s' "$verdict" | cut -f2)"
    printf '%s %s\n' "$sid" "$(( prev_n + 1 ))" > "$GUARD"
    enforce_stop "claim/structural" "$detail" \
      "떨궈진 claim 이 구조 검사를 통과하지 못했습니다: ${detail}. 'horos claim <completion|consistency> <assert> <files,csv> [refs,csv] [true_flags,csv]' 로 떨굽니다. (이 게이트는 claim 의 형식·신선·일관만 보장하며 의미 진리는 보장하지 않습니다.)" ;;
  MISSING)
    printf '%s 0\n' "$sid" > "$GUARD"
    log_violation "claim/uncovered" "significant code change, no fresh covering claim"
    warn_emit "유의미한 코드 변경에 이를 덮는 claim 이 없습니다. 'horos claim completion <한 일> <files,csv> [refs] [tests_added,…]' 로 변경에 대한 검증 가능한 주장을 떨구세요 (감사층, warn)." ;;
  *)
    printf '%s 0\n' "$sid" > "$GUARD"; pass ;;
esac
