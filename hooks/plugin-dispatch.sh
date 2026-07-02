#!/usr/bin/env bash
# plugin-dispatch.sh (D19/D20) — single entrypoint for the horos PLUGIN packaging.
# A globally-enabled plugin fires in EVERY project, so the dispatcher gates hard, in order:
#   1) no CLAUDE_PROJECT_DIR            -> exit 0 (nothing to bind per-project state to)
#   2) activation gate (D19)            -> the project must OPT IN by carrying .horos/
#      (created by `horos init`). Checked BEFORE any hook sources lib.sh, so non-opted
#      projects never get a .horos/ auto-mkdir and the marker stays meaningful.
#   3) precedence gate (D20)            -> if the project's own .claude/settings.json already
#      wires horos (reference install) or a workspace bridge, the plugin DEFERS. Local wiring
#      wins; migrating existing consumers is optional and double-fire is impossible.
#   4) exec the real hook, stdin passed through, CLAUDE_PROJECT_DIR untouched.
# Fail-open everywhere: a packaging bug must never hold a session hostage.
# Cost when gated out: one [ -d ] plus at most one grep of a small settings.json — O(1).
set -uo pipefail
HERE="$(cd "$(dirname "${BASH_SOURCE[0]}")" 2>/dev/null && pwd)" || exit 0
root="${CLAUDE_PROJECT_DIR:-}"
[ -n "$root" ] || exit 0
[ -d "$root/.horos" ] || exit 0                                            # D19: opt-in marker
if grep -qE 'scope-guard\.sh|parent-bridge\.sh' "$root/.claude/settings.json" 2>/dev/null; then
  exit 0                                                                   # D20: local wiring wins
fi
case "${1:-}" in
  pre-edit)      exec "$HERE/scope-guard.sh" ;;
  pre-bash)      exec "$HERE/reversibility-guard.sh" ;;
  stop-finish)   exec "$HERE/finish-the-work.sh" ;;
  stop-decision) exec "$HERE/decision-guard.sh" ;;
  stop-claim)    exec "$HERE/claim-guard.sh" ;;
  session-start) exec "$HERE/session-brief.sh" ;;
  *) exit 0 ;;
esac
