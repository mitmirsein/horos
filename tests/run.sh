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
printf '%s\n' '{"id":"D1","why":"w","cost":"c","escape":"e"}' > "$TMP/decisions.jsonl"
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

echo "== M2: dual-violation -> both Stop hooks block independently (no allow/deny conflict) =="
mode block; reset_guard; rgd
expect "finish-the-work blocks on dual-violation" '"decision": "block"' "$(fin m2a "$FIX/dual_violation.jsonl" | "$HOOKS/finish-the-work.sh")"
mode block; reset_guard; rgd
expect "decision-guard blocks on dual-violation"  '"decision": "block"' "$(fin m2b "$FIX/dual_violation.jsonl" | "$HOOKS/decision-guard.sh")"

echo
echo "RESULT: $pass passed, $fail failed"
[ "$fail" -eq 0 ]
