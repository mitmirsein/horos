#!/usr/bin/env bash
# Unit-checks each hook against synthetic JSON in both warn and block modes,
# inside an isolated CLAUDE_PROJECT_DIR so real .horos state is never touched.
# NOTE: actual output is captured into a variable (not piped into expect), because on
# macOS /bin/bash 3.2 a pipe's right side is a subshell and would lose the counters.
set -uo pipefail
HOOKS="$(cd "$(dirname "${BASH_SOURCE[0]}")/../hooks" && pwd)"
FIX="$(cd "$(dirname "${BASH_SOURCE[0]}")/fixtures" && pwd)"
TMP="$(mktemp -d)"; trap 'rm -rf "$TMP"' EXIT
export CLAUDE_PROJECT_DIR="$TMP"
mkdir -p "$TMP/.horos" "$TMP/hooks"

pass=0; fail=0
mode(){ printf '%s\n' "$1" > "$TMP/.horos/mode"; }
reset_guard(){ rm -f "$TMP/.horos/stop_guard"; }
call(){ printf '%s' "$2" | "$HOOKS/$1"; }            # call <script> <json> -> stdout
fin(){ printf '{"session_id":"%s","transcript_path":"%s","hook_event_name":"Stop"}' "$1" "$2"; }
expect(){ # label expected actual
  if printf '%s' "$3" | grep -qF -- "$2"; then pass=$((pass+1)); printf '  ok   %s\n' "$1"
  else fail=$((fail+1)); printf '  FAIL %s\n        want: %s\n        got : %s\n' "$1" "$2" "$3"; fi; }
expect_empty(){ # label actual
  if [ -z "$2" ]; then pass=$((pass+1)); printf '  ok   %s (silent pass)\n' "$1"
  else fail=$((fail+1)); printf '  FAIL %s want empty got: %s\n' "$1" "$2"; fi; }

echo "== scope-guard (philosophy 3) =="
"$HOOKS/horos" scope clear >/dev/null
expect_empty "no scope -> no enforcement" "$(call scope-guard.sh '{"tool_name":"Write","tool_input":{"file_path":"'"$TMP"'/anything.txt"}}')"
"$HOOKS/horos" scope set 'hooks/**' 'README.md' >/dev/null
mode warn
expect "out-of-scope (warn)" "[horos:warn]" "$(call scope-guard.sh '{"tool_name":"Write","tool_input":{"file_path":"'"$TMP"'/secret.txt"}}')"
mode block
expect "out-of-scope (block deny)" '"permissionDecision": "deny"' "$(call scope-guard.sh '{"tool_name":"Write","tool_input":{"file_path":"'"$TMP"'/secret.txt"}}')"
expect_empty "in-scope edit allowed" "$(call scope-guard.sh '{"tool_name":"Edit","tool_input":{"file_path":"'"$TMP"'/hooks/x.sh"}}')"
expect_empty ".horos always writable" "$(call scope-guard.sh '{"tool_name":"Write","tool_input":{"file_path":"'"$TMP"'/.horos/scope.json"}}')"
expect_empty "non-edit tool ignored" "$(call scope-guard.sh '{"tool_name":"Read","tool_input":{"file_path":"'"$TMP"'/secret.txt"}}')"
rm -f "$TMP/.horos/mode"
expect "absent mode file -> clean warn default (D7)" "[horos:warn]" "$(call scope-guard.sh '{"tool_name":"Write","tool_input":{"file_path":"'"$TMP"'/secret.txt"}}' 2>&1)"
mode warn

echo "== reversibility-guard (philosophy 4) =="
mode warn
expect "rm -rf (warn)" "[horos:warn]" "$(call reversibility-guard.sh '{"tool_name":"Bash","tool_input":{"command":"rm -rf build"}}')"
mode block
expect "rm -rf (block deny)" '"permissionDecision": "deny"' "$(call reversibility-guard.sh '{"tool_name":"Bash","tool_input":{"command":"rm -rf build"}}')"
expect "git reset --hard detected" "[horos:block]" "$(call reversibility-guard.sh '{"tool_name":"Bash","tool_input":{"command":"git reset --hard HEAD~1"}}')"
expect "git push --force detected" "[horos:block]" "$(call reversibility-guard.sh '{"tool_name":"Bash","tool_input":{"command":"git push --force origin main"}}')"
expect_empty "force-with-lease allowed" "$(call reversibility-guard.sh '{"tool_name":"Bash","tool_input":{"command":"git push --force-with-lease origin main"}}')"
expect_empty "safe command allowed" "$(call reversibility-guard.sh '{"tool_name":"Bash","tool_input":{"command":"ls -la"}}')"
expect_empty "non-bash ignored" "$(call reversibility-guard.sh '{"tool_name":"Read","tool_input":{"file_path":"x"}}')"
mode warn
expect_empty "rm -rf inside commit message -> not flagged (M1)" "$(call reversibility-guard.sh '{"tool_name":"Bash","tool_input":{"command":"git commit -m \"fix rm -rf bug\""}}')"
expect_empty "reset --hard inside message -> not flagged (M1)" "$(call reversibility-guard.sh '{"tool_name":"Bash","tool_input":{"command":"git commit -m \"do reset --hard later\""}}')"
mode block
expect "rm -rf with quoted arg still flagged (M1)" '"permissionDecision": "deny"' "$(call reversibility-guard.sh '{"tool_name":"Bash","tool_input":{"command":"rm -rf \"$BUILD\""}}')"

echo "== finish-the-work (philosophy 5) =="
mode block; reset_guard
expect "promise -> block continue" '"decision": "block"' "$(fin s1 "$FIX/promise.jsonl" | "$HOOKS/finish-the-work.sh")"
mode warn; reset_guard
expect "promise -> warn notice" "[horos:warn]" "$(fin s2 "$FIX/promise.jsonl" | "$HOOKS/finish-the-work.sh")"
mode block; reset_guard
expect_empty "ended on tool_use -> pass" "$(fin s3 "$FIX/tool_end.jsonl" | "$HOOKS/finish-the-work.sh")"
mode block; reset_guard
expect_empty "ended on question -> pass" "$(fin s4 "$FIX/question.jsonl" | "$HOOKS/finish-the-work.sh")"
mode block; reset_guard
expect "claim w/o tool use -> gate" "[horos:block]" "$(fin s5 "$FIX/claim.jsonl" | "$HOOKS/finish-the-work.sh")"
mode block; reset_guard
expect_empty "stop_hook_active -> loop-guard pass" "$(printf '{"session_id":"s6","transcript_path":"%s","stop_hook_active":true,"hook_event_name":"Stop"}' "$FIX/promise.jsonl" | "$HOOKS/finish-the-work.sh")"

echo "== decision-guard (philosophy 2) =="
rgd(){ rm -f "$TMP/.horos/stop_guard_decision"; }
{ printf '%s\n' '{"id":"D1","why":"w","cost":"c","escape":"e"}'
  printf '%s\n' '{"id":"A1","type":"aporia","poles":["sync","async"],"why_unresolved":"u","trigger":"t"}'
  printf '%s\n' '{"id":"A2","type":"aporia","poles":["x"],"why_unresolved":"u"}'
} > "$TMP/decisions.jsonl"
mode warn; rgd
expect_empty "trivial code change (1 line), no D-ref -> exempt" "$(fin sd1 "$FIX/edit_code_noref.jsonl" | "$HOOKS/decision-guard.sh")"
mode warn; rgd
expect "significant change (>=8 lines), no D-ref -> warn" "[horos:warn]" "$(fin sd1b "$FIX/edit_code_bigchange.jsonl" | "$HOOKS/decision-guard.sh")"
mode block; rgd
expect "broken D-ref -> block" '"decision": "block"' "$(fin sd2 "$FIX/edit_code_brokenref.jsonl" | "$HOOKS/decision-guard.sh")"
mode warn; rgd
expect "broken D-ref (warn) -> notice" "[horos:warn]" "$(fin sd3 "$FIX/edit_code_brokenref.jsonl" | "$HOOKS/decision-guard.sh")"
mode block; rgd
expect_empty "good D-ref in ledger -> pass" "$(fin sd4 "$FIX/edit_code_goodref.jsonl" | "$HOOKS/decision-guard.sh")"
mode block; rgd
expect_empty "doc-only change -> pass" "$(fin sd5 "$FIX/edit_doc.jsonl" | "$HOOKS/decision-guard.sh")"
mode block; rgd
expect_empty "D-ref in test-path file -> ignored (D3)" "$(fin sd6 "$FIX/edit_test_path.jsonl" | "$HOOKS/decision-guard.sh")"
mode block; rgd
expect "literal (non-comment) D-ref -> not broken, missing warn (D3)" "[horos:warn]" "$(fin sd7 "$FIX/edit_literal.jsonl" | "$HOOKS/decision-guard.sh")"

echo "== decision-guard: aporia (A-id) refs (philosophy 2, D8) =="
mode block; rgd
expect_empty "good A-ref (aporia complete) -> pass" "$(fin sd8 "$FIX/edit_code_aporia_goodref.jsonl" | "$HOOKS/decision-guard.sh")"
mode block; rgd
expect "incomplete A-ref (missing trigger) -> block" '"decision": "block"' "$(fin sd9 "$FIX/edit_code_aporia_incomplete.jsonl" | "$HOOKS/decision-guard.sh")"
mode block; rgd
expect "undefined A-ref -> block" '"decision": "block"' "$(fin sd10 "$FIX/edit_code_aporia_brokenref.jsonl" | "$HOOKS/decision-guard.sh")"
mode warn; rgd
expect "incomplete A-ref (warn) -> notice" "[horos:warn]" "$(fin sd11 "$FIX/edit_code_aporia_incomplete.jsonl" | "$HOOKS/decision-guard.sh")"

echo "== claim-guard (audit tier, philosophy 1·5, D9) =="
cgd(){ rm -f "$TMP/.horos/stop_guard_claim"; }
mkdir -p "$TMP/tests"
printf 'def g(): return 1\n'           > "$TMP/good.py"
printf 'def test_g(): assert g()==1\n' > "$TMP/tests/test_good.py"
printf 'def l(): return 2\n'           > "$TMP/lie.py"
printf 'def b(): return 3\n'           > "$TMP/badref.py"
HOROS_S="$TMP/.horos" python3 - "$TMP" <<'PY'
import json, os, sys, hashlib
root = sys.argv[1]
def h(p):
    with open(os.path.join(root, p), "rb") as f: return hashlib.sha256(f.read()).hexdigest()
claims = [
  {"id":"C1","kind":"completion","assert":"add g + test","evidence_files":["good.py","tests/test_good.py"],
   "binds":{"good.py":h("good.py"),"tests/test_good.py":h("tests/test_good.py")},
   "refs":["D1"],"claims_true":{"tests_added":True,"consistent_with_refs":True}},
  {"id":"C2","kind":"completion","assert":"claims tested but no test","evidence_files":["lie.py"],
   "binds":{"lie.py":h("lie.py")},"claims_true":{"tests_added":True}},
  {"id":"C3","kind":"consistency","assert":"cites missing decision","evidence_files":["badref.py"],
   "binds":{"badref.py":h("badref.py")},"refs":["D77"],"claims_true":{"consistent_with_refs":True}},
]
with open(os.path.join(os.environ["HOROS_S"], "claims.jsonl"), "w") as f:
    for c in claims: f.write(json.dumps(c, ensure_ascii=False) + "\n")
PY
mode block; cgd
expect_empty "fresh claim, invariants hold, ref ok -> pass" "$(fin sc1 "$FIX/edit_code_claim_good.jsonl" | "$HOOKS/claim-guard.sh")"
mode block; cgd
expect "claims tests_added but no test file -> block" '"decision": "block"' "$(fin sc2 "$FIX/edit_code_claim_testlie.jsonl" | "$HOOKS/claim-guard.sh")"
mode block; cgd
expect "claim cites undefined decision -> block" '"decision": "block"' "$(fin sc3 "$FIX/edit_code_claim_badref.jsonl" | "$HOOKS/claim-guard.sh")"
mode warn; cgd
expect "significant change, no covering claim -> warn" "[horos:warn]" "$(fin sc4 "$FIX/edit_code_claim_uncovered.jsonl" | "$HOOKS/claim-guard.sh")"
mode block; cgd
expect_empty "trivial uncovered change -> exempt" "$(fin sc5 "$FIX/edit_code_noref.jsonl" | "$HOOKS/claim-guard.sh")"
printf 'def g(): return 999\n' > "$TMP/good.py"   # mutate bound file -> claim goes stale
mode block; cgd
expect_empty "stale claim dropped (re-edit not false-blocked) -> pass" "$(fin sc6 "$FIX/edit_code_claim_good.jsonl" | "$HOOKS/claim-guard.sh")"

echo "== M2: dual-violation -> both Stop hooks block independently (no allow/deny conflict) =="
mode block; reset_guard; rgd
expect "finish-the-work blocks on dual-violation" '"decision": "block"' "$(fin m2a "$FIX/dual_violation.jsonl" | "$HOOKS/finish-the-work.sh")"
mode block; reset_guard; rgd
expect "decision-guard blocks on dual-violation"  '"decision": "block"' "$(fin m2b "$FIX/dual_violation.jsonl" | "$HOOKS/decision-guard.sh")"

echo "== D10: edits outside CLAUDE_PROJECT_DIR are ignored (parent-session scoping) =="
mode block; rgd
expect_empty "decision-guard: out-of-project file dropped -> pass" "$(fin sx1 "$FIX/edit_code_outside_project.jsonl" | "$HOOKS/decision-guard.sh")"
mode warn; cgd
expect_empty "claim-guard: out-of-project file dropped -> pass" "$(fin sx2 "$FIX/edit_code_outside_project.jsonl" | "$HOOKS/claim-guard.sh")"

echo "== D11: parent-bridge -> gate to horos subtree, delegate, leave other projects alone =="
cp "$HOOKS"/*.sh "$HOOKS/horos" "$TMP/hooks/" 2>/dev/null || true
chmod +x "$TMP/hooks"/*.sh "$TMP/hooks/horos" 2>/dev/null || true
BR="$TMP/hooks/parent-bridge.sh"
"$TMP/hooks/horos" scope set 'hooks/**' 'README.md' >/dev/null 2>&1 || true
mode block
expect "pre-edit horos file (out of scope) -> delegate scope deny" '"permissionDecision": "deny"' "$(printf '{"tool_name":"Write","tool_input":{"file_path":"%s/secret.txt"}}' "$TMP" | "$BR" pre-edit)"
expect_empty "pre-edit NON-horos file -> bridge passes (other project untouched)" "$(printf '{"tool_name":"Write","tool_input":{"file_path":"/elsewhere/secret.txt"}}' | "$BR" pre-edit)"
expect "pre-bash horos cwd + rm -rf -> delegate reversibility deny" '"permissionDecision": "deny"' "$(printf '{"tool_name":"Bash","tool_input":{"command":"rm -rf build"},"cwd":"%s"}' "$TMP" | "$BR" pre-bash)"
expect_empty "pre-bash NON-horos cwd + rm -rf -> bridge passes" "$(printf '{"tool_name":"Bash","tool_input":{"command":"rm -rf build"},"cwd":"/elsewhere"}' | "$BR" pre-bash)"
printf '{"type":"assistant","message":{"role":"assistant","content":[{"type":"tool_use","name":"Edit","input":{"file_path":"%s/app.py","new_string":"a\\nb\\nc\\nd\\ne\\nf\\ng\\nh\\ni\\n"}}]}}\n' "$TMP" > "$TMP/bridge_tp.jsonl"
mode warn; reset_guard; rgd; cgd
expect "stop: horos edit -> bridged guards warn" "[horos:warn]" "$(printf '{"session_id":"bz1","transcript_path":"%s","hook_event_name":"Stop"}' "$TMP/bridge_tp.jsonl" | "$BR" stop)"
expect_empty "stop: non-horos session -> bridge passes" "$(fin bz2 "$FIX/promise.jsonl" | "$BR" stop)"

echo "== install: wire a target to central horos by reference; idempotent + migrating (D12) =="
PROJ="$TMP/proj"; mkdir -p "$PROJ/.claude"
# pre-seed: one unrelated hook + an old copy-style horos entry (prove migrate-away + preserve)
printf '%s\n' '{ "hooks": { "PreToolUse": [' \
  '  { "matcher": "Write", "hooks": [ { "type": "command", "command": "echo unrelated" } ] },' \
  '  { "matcher": "Edit|Write|MultiEdit", "hooks": [ { "type": "command", "command": "\"$CLAUDE_PROJECT_DIR/hooks/scope-guard.sh\"" } ] }' \
  '] } }' > "$PROJ/.claude/settings.json"
"$HOOKS/horos" install "$PROJ" >/dev/null 2>&1
S2="$(cat "$PROJ/.claude/settings.json")"
expect "install: scope-guard referenced"             "scope-guard.sh"  "$S2"
expect "install: full set incl claim-guard"          "claim-guard.sh"  "$S2"
expect "install: unrelated hook preserved"           "echo unrelated"  "$S2"
expect_empty "install: old copy-style entry migrated away" "$(printf '%s' "$S2" | grep -F 'CLAUDE_PROJECT_DIR/hooks/scope-guard.sh' || true)"
expect "install: .horos gitignored in target"        ".horos/"         "$(cat "$PROJ/.gitignore")"
"$HOOKS/horos" install "$PROJ" >/dev/null 2>&1        # re-run: must stay idempotent
expect "install: idempotent (scope-guard one line)"  "1" "$(grep -cF 'scope-guard.sh' "$PROJ/.claude/settings.json")"
expect "doctor [target]: referenced hook resolves OK" "scope-guard" "$("$HOOKS/horos" doctor "$PROJ")"

echo
echo "RESULT: $pass passed, $fail failed"
[ "$fail" -eq 0 ]
