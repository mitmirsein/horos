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

echo "== D21: production shape — ABSOLUTE transcript path matched against ROOT-relative claim =="
# The 3 live consumers see absolute file_path in the transcript; `horos claim` takes ROOT-relative
# evidence_files. Pre-D21 these never intersected -> audit tier silently inert + strict deadlock.
ABSP="$TMP/abscov"; mkdir -p "$ABSP/.horos"
{ echo "def f():"; for i in 1 2 3 4 5 6 7 8 9 10; do echo "    x$i=$i"; done; echo "    return 1"; } > "$ABSP/mod.py"
CLAUDE_PROJECT_DIR="$ABSP" "$HOOKS/horos" claim completion "mod.py 구현" "mod.py" >/dev/null 2>&1
absbody="def f():$(for i in 1 2 3 4 5 6 7 8 9 10; do printf '\\n    x%d=%d' "$i" "$i"; done)\\n    return 1"
printf '{"type":"assistant","message":{"role":"assistant","content":[{"type":"tool_use","name":"Write","input":{"file_path":"%s/mod.py","new_string":"%s"}}]}}\n' "$ABSP" "$absbody" > "$ABSP/tp.jsonl"
printf 'block\n' > "$ABSP/.horos/mode"
expect_empty "abs transcript: fresh covering claim recognized (block, no false coverage warn)" "$(printf '{"session_id":"ac1","transcript_path":"%s"}' "$ABSP/tp.jsonl" | CLAUDE_PROJECT_DIR="$ABSP" "$HOOKS/claim-guard.sh")"
printf 'strict\n' > "$ABSP/.horos/mode"
expect_empty "abs transcript: covering claim satisfies strict (no unsatisfiable block)" "$(printf '{"session_id":"ac2","transcript_path":"%s"}' "$ABSP/tp.jsonl" | CLAUDE_PROJECT_DIR="$ABSP" "$HOOKS/claim-guard.sh")"
rm -f "$ABSP/.horos/claims.jsonl"; printf 'strict\n' > "$ABSP/.horos/mode"
expect "abs transcript: uncovered significant change still blocks in strict" '"decision": "block"' "$(printf '{"session_id":"ac3","transcript_path":"%s"}' "$ABSP/tp.jsonl" | CLAUDE_PROJECT_DIR="$ABSP" "$HOOKS/claim-guard.sh")"

echo "== D15: message contract — [horos:*] <CODE> <ko>. Action: <en>. 예: <filled command> =="
mode warn
expect "scope OUT: code present" "HOROS-SCOPE-OUT" "$(call scope-guard.sh '{"tool_name":"Write","tool_input":{"file_path":"'"$TMP"'/secret.txt"}}')"
expect "scope OUT: filled /scope widening example" "/scope hooks/** README.md secret.txt" "$(call scope-guard.sh '{"tool_name":"Write","tool_input":{"file_path":"'"$TMP"'/secret.txt"}}')"
"$HOOKS/horos" scope set 'src/**' 'a b.md' >/dev/null   # a glob WITH whitespace
expect "scope OUT: whitespace glob stays one quoted arg in example" "'a b.md'" "$(call scope-guard.sh '{"tool_name":"Write","tool_input":{"file_path":"'"$TMP"'/secret.txt"}}')"
"$HOOKS/horos" scope set 'hooks/**' 'README.md' >/dev/null   # restore for later sections
expect "reversibility: code present" "HOROS-REV-DESTRUCT" "$(call reversibility-guard.sh '{"tool_name":"Bash","tool_input":{"command":"rm -rf build"}}')"
mode warn; reset_guard
expect "finish PROMISE: code present" "HOROS-FIN-PROMISE" "$(fin sm1 "$FIX/promise.jsonl" | "$HOOKS/finish-the-work.sh")"
mode warn; reset_guard
expect "finish CLAIM: code present" "HOROS-FIN-NOEVIDENCE" "$(fin sm2 "$FIX/claim.jsonl" | "$HOOKS/finish-the-work.sh")"
mode warn; rgd
out_broken="$(fin sm3 "$FIX/edit_code_brokenref.jsonl" | "$HOOKS/decision-guard.sh")"
expect "decision BROKEN: code + English twin" "(미정의/undefined)" "$out_broken"
expect "decision BROKEN: example filled with the broken id" "horos decide D9" "$out_broken"
mode warn; rgd
expect "decision MISSING: example uses next free id" "horos decide D2" "$(fin sm4 "$FIX/edit_code_bigchange.jsonl" | "$HOOKS/decision-guard.sh")"
mode warn; cgd
out_lie="$(fin sm5 "$FIX/edit_code_claim_testlie.jsonl" | "$HOOKS/claim-guard.sh")"
expect "claim BROKEN: code + English twin" "false: no test file" "$out_lie"
expect "claim BROKEN: code present" "HOROS-CLM-BROKEN" "$out_lie"
mode warn; cgd
out_uncov="$(fin sm6 "$FIX/edit_code_claim_uncovered.jsonl" | "$HOOKS/claim-guard.sh")"
expect "claim MISSING: example filled with changed files" "cov1.py,cov2.py" "$out_uncov"
expect "violations.log: 5th column carries the code" "HOROS-CLM-MISSING" "$(tail -n1 "$TMP/.horos/violations.log")"

echo "== D14: CLI deposit-time validation (loud errors instead of silent dead records) =="
CLIP="$TMP/cliproj"; mkdir -p "$CLIP"
printf 'x=1\n' > "$CLIP/a.py"
clip(){ CLAUDE_PROJECT_DIR="$CLIP" "$HOOKS/horos" "$@" 2>&1; }
expect "decide: malformed id rejected" "HOROS-CLI-BADID" "$(clip decide foo w c e || true)"
expect "decide: good deposit -> recorded with path" "recorded D1 -> " "$(clip decide D1 w c e)"
expect "decide: duplicate id rejected" "HOROS-CLI-DUPID" "$(clip decide D1 w2 c2 e2 || true)"
expect "decide: rejection suggests next free id" "D2" "$(clip decide D1 w2 c2 e2 || true)"
expect "aporia: single pole rejected at deposit" "HOROS-CLI-BADKIND" "$(clip aporia A1 onlyone u t || true)"
expect "claim: unknown kind rejected" "HOROS-CLI-BADKIND" "$(clip claim wrongkind x a.py || true)"
expect "claim: typo flag rejected with correction" "did you mean 'tests_added'" "$(clip claim completion x a.py "" test_added || true)"
expect "claim: x_ extension flag accepted" "recorded C1" "$(clip claim completion x a.py "" x_custom)"
expect "claim: bad ref format rejected" "HOROS-CLI-BADREF" "$(clip claim completion x a.py D0x || true)"
expect "claim: undefined ref rejected with fix command" "HOROS-CLI-NOREF" "$(clip claim completion x a.py D77 || true)"
expect "claim: bind file missing -> NOFILE" "HOROS-CLI-NOFILE" "$(clip claim completion x nofile.py || true)"
NOGIT="$TMP/nogit"; mkdir -p "$NOGIT"
expect "write cmd, non-git CWD, no env -> ROOT notice" "HOROS-CLI-ROOT" "$(cd "$NOGIT" && env -u CLAUDE_PROJECT_DIR "$HOOKS/horos" decide D1 w c e 2>&1)"

echo "== D16: silent-pass telemetry (every fail-open leaves a trace) =="
VLOG="$TMP/.horos/violations.log"
printf 'not-json\n' >> "$TMP/decisions.jsonl"
mode warn; rgd
fin d16a "$FIX/edit_code_bigchange.jsonl" | "$HOOKS/decision-guard.sh" >/dev/null
expect "malformed ledger line -> TEL trace" "ledger:4" "$(tail -n 5 "$VLOG")"
printf 'not-json-claims\n' >> "$TMP/.horos/claims.jsonl"
mode warn; cgd
fin d16b "$FIX/edit_code_claim_uncovered.jsonl" | "$HOOKS/claim-guard.sh" >/dev/null
expect "malformed claims line -> TEL trace" "claims:4" "$(tail -n 5 "$VLOG")"
mode warn; cgd
fin d16c "$FIX/edit_code_claim_good.jsonl" | "$HOOKS/claim-guard.sh" >/dev/null
expect "stale claim demotion -> TEL trace" "HOROS-TEL-STALE-DROP" "$(tail -n 5 "$VLOG")"
mode warn; reset_guard
fin d16lp "$FIX/promise.jsonl" | "$HOOKS/finish-the-work.sh" >/dev/null
fin d16lp "$FIX/promise.jsonl" | "$HOOKS/finish-the-work.sh" >/dev/null
fin d16lp "$FIX/promise.jsonl" | "$HOOKS/finish-the-work.sh" >/dev/null
expect "loop-guard silence -> TEL exactly once" "1" "$(grep -cF 'finish:d16lp' "$VLOG" || true)"
PYP="$TMP/pyfail"; mkdir -p "$PYP/.horos" "$PYP/decisions.jsonl"   # ledger-as-directory => judge crash
expect_empty "judge crash -> silent pass (fail-open)" "$(printf '{"session_id":"pf1","transcript_path":"%s","hook_event_name":"Stop"}' "$FIX/edit_code_bigchange.jsonl" | CLAUDE_PROJECT_DIR="$PYP" "$HOOKS/decision-guard.sh")"
expect "judge crash -> PYFAIL trace" "HOROS-TEL-PYFAIL" "$(tail -n 2 "$PYP/.horos/violations.log")"
expect "doctor: health section present" "health:" "$("$HOOKS/horos" doctor "$TMP")"
expect "doctor: silent-pass traces surfaced" "silent-pass traces:" "$("$HOOKS/horos" doctor "$TMP")"

echo "== D17: session-brief — protocol self-injection at SessionStart =="
brief="$(printf '{"hook_event_name":"SessionStart"}' | "$HOOKS/session-brief.sh")"
expect "brief: card emitted with version" "[horos v" "$brief"
expect "brief: current mode shown" "mode=warn" "$brief"
expect "brief: decide template uses next free id" "horos decide D2" "$brief"
expect "brief: aporia template uses next free id" "horos aporia A3" "$brief"
expect "brief: declared scope shown" "hooks/**" "$brief"
expect "brief: cli.path points at central CLI" "$HOOKS/horos" "$(cat "$TMP/.horos/cli.path")"
PNEW="$TMP/newproj"; mkdir -p "$PNEW"
expect "brief: empty project starts at D1" "horos decide D1" "$(printf '{}' | CLAUDE_PROJECT_DIR="$PNEW" "$HOOKS/session-brief.sh")"

echo "== D18: strict tier — warn-tier MISSING blocks, loop threshold 4, NotebookEdit =="
expect "mode strict accepted" "mode = strict" "$("$HOOKS/horos" mode strict)"
mode block; rgd
expect "decision MISSING stays warn in block mode" "[horos:warn]" "$(fin d18a "$FIX/edit_code_bigchange.jsonl" | "$HOOKS/decision-guard.sh")"
mode strict; rgd
expect "decision MISSING blocks in strict" '"decision": "block"' "$(fin d18b "$FIX/edit_code_bigchange.jsonl" | "$HOOKS/decision-guard.sh")"
mode strict; cgd
expect "claim coverage-MISSING blocks in strict" '"decision": "block"' "$(fin d18c "$FIX/edit_code_claim_uncovered.jsonl" | "$HOOKS/claim-guard.sh")"
mode strict; reset_guard
fin d18lp "$FIX/promise.jsonl" | "$HOOKS/finish-the-work.sh" >/dev/null
fin d18lp "$FIX/promise.jsonl" | "$HOOKS/finish-the-work.sh" >/dev/null
fin d18lp "$FIX/promise.jsonl" | "$HOOKS/finish-the-work.sh" >/dev/null
expect "strict: 4th nudge still blocks (threshold 4)" '"decision": "block"' "$(fin d18lp "$FIX/promise.jsonl" | "$HOOKS/finish-the-work.sh")"
expect_empty "strict: 5th stop silenced" "$(fin d18lp "$FIX/promise.jsonl" | "$HOOKS/finish-the-work.sh")"
expect "NotebookEdit out-of-scope denied (strict)" '"permissionDecision": "deny"' "$(call scope-guard.sh '{"tool_name":"NotebookEdit","tool_input":{"notebook_path":"'"$TMP"'/nb.ipynb"}}')"
expect_empty "NotebookEdit with no scope declared -> pass" "$(printf '{"tool_name":"NotebookEdit","tool_input":{"notebook_path":"%s/nb.ipynb"}}' "$PNEW" | CLAUDE_PROJECT_DIR="$PNEW" "$HOOKS/scope-guard.sh")"
mode warn

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
expect "install: session brief registered (D17)"     "session-brief.sh" "$S2"
expect "install: NotebookEdit matcher (D18)"          "Edit|Write|MultiEdit|NotebookEdit" "$S2"
expect "install: unrelated hook preserved"           "echo unrelated"  "$S2"
expect_empty "install: old copy-style entry migrated away" "$(printf '%s' "$S2" | grep -F 'CLAUDE_PROJECT_DIR/hooks/scope-guard.sh' || true)"
expect "install: .horos gitignored in target"        ".horos/"         "$(cat "$PROJ/.gitignore")"
"$HOOKS/horos" install "$PROJ" >/dev/null 2>&1        # re-run: must stay idempotent
expect "install: idempotent (scope-guard one line)"  "1" "$(grep -cF 'scope-guard.sh' "$PROJ/.claude/settings.json")"
expect "doctor [target]: referenced hook resolves OK" "[OK] scope-guard" "$("$HOOKS/horos" doctor "$PROJ")"
expect_empty "doctor [target]: no hook reported MISS" "$("$HOOKS/horos" doctor "$PROJ" | grep -F '[MISS]' || true)"
expect "doctor: central version stamp" "vers : $(cat "$HOOKS/../VERSION")" "$("$HOOKS/horos" doctor "$PROJ")"
expect "doctor: missing VERSION -> unknown (copied CLI)" "vers : unknown" "$("$TMP/hooks/horos" doctor "$PROJ")"

echo "== D19/D20: plugin dispatch — activation marker + local-wiring precedence =="
PD="$HOOKS/plugin-dispatch.sh"
RROOT="$(cd "$HOOKS/.." && pwd)"
PLGP="$TMP/plugproj"; mkdir -p "$PLGP"
# D19 gate must be DISCRIMINATING: not just empty output, but the gate exits BEFORE lib.sh's
# .horos auto-mkdir — so a marker-less project stays marker-less after a dispatch call.
"$PD" pre-edit >/dev/null 2>&1 <<EOF || true
{"tool_name":"Write","tool_input":{"file_path":"$PLGP/x.txt"}}
EOF
CLAUDE_PROJECT_DIR="$PLGP" "$PD" pre-edit >/dev/null 2>&1 <<EOF || true
{"tool_name":"Write","tool_input":{"file_path":"$PLGP/x.txt"}}
EOF
expect_empty "plugin: no marker -> gate exits before .horos auto-mkdir (D19)" "$([ -d "$PLGP/.horos" ] && echo "LEAKED .horos" || true)"
expect_empty "plugin: no .horos marker -> inert (D19)" "$(printf '{"tool_name":"Write","tool_input":{"file_path":"%s/x.txt"}}' "$PLGP" | CLAUDE_PROJECT_DIR="$PLGP" "$PD" pre-edit)"
"$HOOKS/horos" init "$PLGP" >/dev/null
expect "init: marker + default mode warn" "warn" "$(cat "$PLGP/.horos/mode")"
expect "init: .horos gitignored" ".horos/" "$(cat "$PLGP/.gitignore")"
"$HOOKS/horos" init "$PLGP" >/dev/null
expect "init: idempotent (gitignore one line)" "1" "$(grep -cxF '.horos/' "$PLGP/.gitignore" || true)"
GIP="$TMP/gitignore-nonl"; mkdir -p "$GIP"; printf 'node_modules' > "$GIP/.gitignore"   # no trailing newline
"$HOOKS/horos" init "$GIP" >/dev/null
expect "init: no line-join onto newline-less .gitignore (D14)" "1" "$(grep -cxF 'node_modules' "$GIP/.gitignore" || true)"
expect "init: .horos on its own line" "1" "$(grep -cxF '.horos/' "$GIP/.gitignore" || true)"
expect "plugin: session-start delegates brief (empty ledger -> D1)" "horos decide D1" "$(printf '{}' | CLAUDE_PROJECT_DIR="$PLGP" "$PD" session-start)"
CLAUDE_PROJECT_DIR="$PLGP" "$HOOKS/horos" scope set 'src/**' >/dev/null
CLAUDE_PROJECT_DIR="$PLGP" "$HOOKS/horos" mode block >/dev/null
expect "plugin: marker present -> delegates scope-guard (deny)" '"permissionDecision": "deny"' "$(printf '{"tool_name":"Write","tool_input":{"file_path":"%s/out.txt"}}' "$PLGP" | CLAUDE_PROJECT_DIR="$PLGP" "$PD" pre-edit)"
expect "plugin: stop-decision delegates (broken ref blocks)" '"decision": "block"' "$(printf '{"session_id":"pg1","transcript_path":"%s"}' "$FIX/edit_code_brokenref.jsonl" | CLAUDE_PROJECT_DIR="$PLGP" "$PD" stop-decision)"
# each dispatch route must reach its REAL target, not just have a case label (behavioral, not static)
expect "plugin: pre-bash delegates reversibility (rm -rf deny)" '"permissionDecision": "deny"' "$(printf '{"tool_name":"Bash","tool_input":{"command":"rm -rf build"},"cwd":"%s"}' "$PLGP" | CLAUDE_PROJECT_DIR="$PLGP" "$PD" pre-bash)"
CLAUDE_PROJECT_DIR="$PLGP" "$HOOKS/horos" mode strict >/dev/null
expect "plugin: stop-finish delegates (promise blocks)" '"decision": "block"' "$(printf '{"session_id":"pg2","transcript_path":"%s"}' "$FIX/promise.jsonl" | CLAUDE_PROJECT_DIR="$PLGP" "$PD" stop-finish)"
expect "plugin: stop-claim delegates (strict coverage blocks)" '"decision": "block"' "$(printf '{"session_id":"pg3","transcript_path":"%s"}' "$FIX/edit_code_claim_uncovered.jsonl" | CLAUDE_PROJECT_DIR="$PLGP" "$PD" stop-claim)"
CLAUDE_PROJECT_DIR="$PLGP" "$HOOKS/horos" mode block >/dev/null
mkdir -p "$PLGP/.claude"
# seed BOTH a horos entry AND an unrelated one, to test D20 defer + uninstall preservation
printf '%s\n' '{"hooks":{"PreToolUse":[{"matcher":"Write","hooks":[{"type":"command","command":"echo keep-me-plugintest"}]},{"matcher":"Edit","hooks":[{"type":"command","command":"x/scope-guard.sh"}]}]}}' > "$PLGP/.claude/settings.json"
expect_empty "plugin: local wiring present -> defers (D20)" "$(printf '{"tool_name":"Write","tool_input":{"file_path":"%s/out.txt"}}' "$PLGP" | CLAUDE_PROJECT_DIR="$PLGP" "$PD" pre-edit)"
"$HOOKS/horos" uninstall "$PLGP" >/dev/null
expect_empty "uninstall: horos wiring stripped" "$(grep -F 'scope-guard.sh' "$PLGP/.claude/settings.json" || true)"
expect "uninstall: non-horos entry preserved" "keep-me-plugintest" "$(cat "$PLGP/.claude/settings.json")"
pchk="$TMP/plugchk.out"
HOOKS_DIR="$HOOKS" python3 - > "$pchk" <<'PYX'
import json, os, re
hd = os.environ["HOOKS_DIR"]; root = os.path.dirname(hd)
pj = json.load(open(os.path.join(root, ".claude-plugin", "plugin.json")))
ver = open(os.path.join(root, "VERSION")).read().strip()
out = ["version:ok" if pj.get("version") == ver
       else "version:MISMATCH(%s!=%s)" % (pj.get("version"), ver)]
cfg = json.load(open(os.path.join(hd, "hooks.json")))
evs = set()
for entries in (cfg.get("hooks") or {}).values():
    for e in entries:
        for h in e.get("hooks", []):
            m = re.search(r'plugin-dispatch\.sh"?\s+(\S+)', h.get("command", ""))
            if m: evs.add(m.group(1))
src = open(os.path.join(hd, "plugin-dispatch.sh")).read()
missing = [e for e in sorted(evs) if (e + ")") not in src]
out.append("events:ok" if evs and not missing else "events:MISSING:" + ",".join(missing))
print(" ".join(out))
PYX
expect "plugin packaging consistent (version + dispatch map)" "version:ok events:ok" "$(cat "$pchk")"
expect_empty "plugin surface parity (.claude symlinks == root canon)" "$( { cmp "$RROOT/.claude/commands/scope.md" "$RROOT/commands/scope.md" 2>&1; cmp "$RROOT/.claude/commands/horos-mode.md" "$RROOT/commands/horos-mode.md" 2>&1; cmp "$RROOT/.claude/skills/contract-first/SKILL.md" "$RROOT/skills/contract-first/SKILL.md" 2>&1; } || true)"

echo "== D23: agy-adapter — translate Antigravity CLI hook I/O to/from horos judges =="
AD="$HOOKS/agy-adapter.sh"
AP="$TMP/agyproj"; mkdir -p "$AP/src" "$AP/.horos"
printf 'block\n' > "$AP/.horos/mode"
CLAUDE_PROJECT_DIR="$AP" "$HOOKS/horos" scope set 'src/**' >/dev/null
agyin(){ printf '{"toolCall":{"name":"%s","args":%s},"workspacePaths":["%s"]}' "$1" "$2" "$AP"; }
# PreToolUse translation: agy write_file -> scope-guard -> agy decision
expect "agy: out-of-scope write -> agy deny" '"decision": "deny"' "$(agyin write_file '{"AbsolutePath":"'"$AP"'/secret.txt"}' | "$AD" pre-tool)"
expect "agy: deny reason carries horos code" "HOROS-SCOPE-OUT" "$(agyin write_file '{"AbsolutePath":"'"$AP"'/secret.txt"}' | "$AD" pre-tool)"
expect_empty "agy: in-scope write -> silent (no opinion)" "$(agyin write_file '{"AbsolutePath":"'"$AP"'/src/a.py"}' | "$AD" pre-tool)"
expect_empty "agy: read tool (view_file) -> not gated, silent" "$(agyin view_file '{"AbsolutePath":"'"$AP"'/x"}' | "$AD" pre-tool)"
# run_command -> reversibility-guard
expect "agy: destructive run_command -> agy deny" '"decision": "deny"' "$(agyin run_command '{"CommandLine":"rm -rf build"}' | "$AD" pre-tool)"
expect "agy: destructive reason code" "HOROS-REV-DESTRUCT" "$(agyin run_command '{"CommandLine":"rm -rf build"}' | "$AD" pre-tool)"
expect_empty "agy: safe run_command -> silent" "$(agyin run_command '{"CommandLine":"ls -la"}' | "$AD" pre-tool)"
# camelCase/alias arg keys tolerated
expect "agy: alias arg key (command) still read" '"decision": "deny"' "$(agyin run_command '{"command":"git reset --hard"}' | "$AD" pre-tool)"
# warn mode -> allow + surfaced reason (not deny)
printf 'warn\n' > "$AP/.horos/mode"
expect "agy: warn mode out-of-scope -> allow+reason" '"decision": "allow"' "$(agyin write_file '{"AbsolutePath":"'"$AP"'/secret.txt"}' | "$AD" pre-tool)"
printf 'block\n' > "$AP/.horos/mode"
# opt-in gate: a project without .horos is never governed
NOAP="$TMP/agynohoros"; mkdir -p "$NOAP"
expect_empty "agy: no .horos -> silent (opt-in)" "$(printf '{"toolCall":{"name":"write_file","args":{"AbsolutePath":"%s/x"}},"workspacePaths":["%s"]}' "$NOAP" "$NOAP" | "$AD" pre-tool)"
# session-start -> PreInvocation injectSteps carrying the protocol card
expect "agy: session-start injects protocol card" "injectSteps" "$(printf '{"workspacePaths":["%s"]}' "$AP" | "$AD" session-start)"
expect "agy: injected card carries mode" "mode=" "$(printf '{"workspacePaths":["%s"]}' "$AP" | "$AD" session-start)"
expect "agy: no .horos session-start -> empty injectSteps" '{"injectSteps":[]}' "$(printf '{"workspacePaths":["%s"]}' "$NOAP" | "$AD" session-start)"
# D25 Stop-tier: pre-tool accumulates changed files; stop judges them via decision + claim gates
{ printf '%s\n' '{"id":"D1","why":"w","cost":"c","escape":"e"}'; } > "$AP/decisions.jsonl"
agystop(){ printf '{"conversationId":"%s","terminationReason":"model_stop","workspacePaths":["%s"]}' "$1" "$AP"; }
# accumulation: an allowed in-scope write is recorded under its conversationId
printf '%s\n' 'def a(): return 1' > "$AP/src/acc.py"
printf '{"toolCall":{"name":"write_file","args":{"AbsolutePath":"%s/src/acc.py"}},"conversationId":"cX","workspacePaths":["%s"]}' "$AP" "$AP" | "$AD" pre-tool >/dev/null
expect "agy stop: allowed write is accumulated" "src/acc.py" "$(cat "$AP/.horos/agy_changed.cX" 2>/dev/null)"
# a DENIED (out-of-scope) write is NOT accumulated
printf '{"toolCall":{"name":"write_file","args":{"AbsolutePath":"%s/nope.py"}},"conversationId":"cX","workspacePaths":["%s"]}' "$AP" "$AP" | "$AD" pre-tool >/dev/null
expect_empty "agy stop: denied write not accumulated" "$(grep -F 'nope.py' "$AP/.horos/agy_changed.cX" 2>/dev/null || true)"
# broken D-ref in an accumulated file -> stop returns agy continue (blocks the stop)
{ echo 'def b():'; echo '    return 1  # D77 undefined'; } > "$AP/src/br.py"
printf '%s\n' "$AP/src/br.py" > "$AP/.horos/agy_changed.cBR"
rm -f "$AP/.horos/stop_guard_decision" "$AP/.horos/stop_guard_claim"
expect "agy stop: broken D-ref -> continue (block stop)" '"decision": "continue"' "$(agystop cBR | "$AD" stop)"
expect "agy stop: continue reason carries code" "HOROS-DEC-BROKEN" "$(agystop cBR | "$AD" stop)"
# a trivial clean change -> no block, stop allowed (silent)
printf '%s\n' 'x=1' > "$AP/src/ok.py"
printf '%s\n' "$AP/src/ok.py" > "$AP/.horos/agy_changed.cOK"
rm -f "$AP/.horos/stop_guard_decision" "$AP/.horos/stop_guard_claim"
expect_empty "agy stop: trivial clean change -> allow stop" "$(agystop cOK | "$AD" stop)"
# no accumulation for a conversation -> stop allowed
expect_empty "agy stop: nothing accumulated -> allow stop" "$(agystop cNONE | "$AD" stop)"
# D26 finish-the-work in agy: read the last assistant prose + tool_seen from agy's transcriptPath
agytp(){ printf '{"conversationId":"%s","terminationReason":"model_stop","workspacePaths":["%s"],"transcriptPath":"%s"}' "$1" "$AP" "$2"; }
python3 -c 'import json;[print(json.dumps(l,ensure_ascii=False)) for l in [{"type":"PLANNER_RESPONSE","source":"MODEL","content":None,"tool_calls":[{"name":"view_file"}]},{"type":"VIEW_FILE","source":"MODEL","content":"x"},{"type":"PLANNER_RESPONSE","source":"MODEL","content":"이제 테스트를 추가하겠습니다."}]]' > "$AP/.horos/tp_promise.jsonl"
rm -f "$AP/.horos/stop_guard" "$AP/.horos/stop_guard_decision" "$AP/.horos/stop_guard_claim"
expect "agy finish: promise-only stop -> continue" '"decision": "continue"' "$(agytp cFP "$AP/.horos/tp_promise.jsonl" | "$AD" stop)"
expect "agy finish: promise code" "HOROS-FIN-PROMISE" "$(agytp cFP "$AP/.horos/tp_promise.jsonl" | "$AD" stop)"
python3 -c 'import json;print(json.dumps({"type":"PLANNER_RESPONSE","source":"MODEL","content":"완료했습니다. 다 됐습니다."},ensure_ascii=False))' > "$AP/.horos/tp_claim.jsonl"
rm -f "$AP/.horos/stop_guard" "$AP/.horos/stop_guard_decision" "$AP/.horos/stop_guard_claim"
expect "agy finish: zero-tool completion claim -> continue" "HOROS-FIN-NOEVIDENCE" "$(agytp cFC "$AP/.horos/tp_claim.jsonl" | "$AD" stop)"
python3 -c 'import json;[print(json.dumps(l,ensure_ascii=False)) for l in [{"type":"PLANNER_RESPONSE","source":"MODEL","content":None,"tool_calls":[{"name":"run_command"}]},{"type":"RUN_COMMAND","source":"MODEL","content":"ok"},{"type":"PLANNER_RESPONSE","source":"MODEL","content":"작업을 마쳤고 테스트도 통과했습니다."}]]' > "$AP/.horos/tp_clean.jsonl"
rm -f "$AP/.horos/stop_guard" "$AP/.horos/stop_guard_decision" "$AP/.horos/stop_guard_claim"
expect_empty "agy finish: tool-used completion -> allow stop" "$(agytp cFOK "$AP/.horos/tp_clean.jsonl" | "$AD" stop)"
# install --harness agy: portable .agents/hooks.json, idempotent
AGYT="$TMP/agyinstall"; mkdir -p "$AGYT"
"$HOOKS/horos" install --harness agy "$AGYT" >/dev/null 2>&1
AGYCFG="$(cat "$AGYT/.agents/hooks.json" 2>/dev/null)"
expect "install --harness agy: writes .agents/hooks.json" "agy-adapter.sh" "$AGYCFG"
expect "install --harness agy: routes pre-tool + session-start" "session-start" "$AGYCFG"
expect "install --harness agy: wires Stop tier (D25)" '" stop"' "$AGYCFG"
expect "install --harness agy: portable \$HOME path" '$HOME/' "$AGYCFG"
expect "install --harness agy: .horos gitignored" ".horos/" "$(cat "$AGYT/.gitignore")"
"$HOOKS/horos" install --harness agy "$AGYT" >/dev/null 2>&1
expect "install --harness agy: idempotent (one horos key)" "1" "$(grep -c '"horos"' "$AGYT/.agents/hooks.json")"

echo
echo "RESULT: $pass passed, $fail failed"
[ "$fail" -eq 0 ]
