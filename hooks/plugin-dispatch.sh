#!/usr/bin/env bash
# plugin-dispatch.sh (D19/D20/D34) — single entrypoint for the horos PLUGIN packaging.
# Two-tier dispatch:
#   Tier 2 (opt-in full suite, D19/D20): when CLAUDE_PROJECT_DIR carries .horos/, defer if local
#     .claude/settings.json already wires horos, else delegate all 5 guards + session-brief.
#   Tier 1 (global baseline, D34): when .horos/ is absent, run stateless reversibility-guard on
#     pre-bash ONLY when global-mode is warn|block. Zero .horos/ auto-mkdir, zero Stop/SessionStart noise.
set -uo pipefail
HERE="$(cd "$(dirname "${BASH_SOURCE[0]}")" 2>/dev/null && pwd)" || exit 0
root="${CLAUDE_PROJECT_DIR:-}"
event="${1:-}"

if [ -n "$root" ] && [ -d "$root/.horos" ]; then
  if grep -qE 'scope-guard\.sh|parent-bridge\.sh' "$root/.claude/settings.json" 2>/dev/null; then
    exit 0                                                                   # D20: local wiring wins
  fi
  case "$event" in
    pre-edit)      exec "$HERE/scope-guard.sh" ;;
    pre-bash)      exec "$HERE/reversibility-guard.sh" ;;
    stop-finish)   exec "$HERE/finish-the-work.sh" ;;
    stop-decision) exec "$HERE/decision-guard.sh" ;;
    stop-claim)    exec "$HERE/claim-guard.sh" ;;
    session-start) exec "$HERE/session-brief.sh" ;;
    *) exit 0 ;;
  esac
fi

# D34: Tier-1 global baseline (stateless pre-bash only; O(1) pure-bash exit when off)
[ "$event" = pre-bash ] || exit 0
gmode="${HOROS_GLOBAL_MODE:-}"
if [ -z "$gmode" ]; then
  hhome="${HOROS_HOME:-${HOME:-}}"
  gcfg="${HOROS_GLOBAL_CONFIG:-${XDG_CONFIG_HOME:-$hhome/.config}/horos/global_mode}"
  [ -f "$gcfg" ] && IFS= read -r gmode < "$gcfg" 2>/dev/null || true
  gmode="${gmode//[[:space:]]/}"
fi
case "$gmode" in warn|block) ;; *) exit 0 ;; esac

defer_tree=""
if [ -n "$root" ]; then
  if grep -qF 'reversibility-guard.sh' "$root/.claude/settings.json" 2>/dev/null; then
    exit 0
  fi
  if grep -qF 'parent-bridge.sh' "$root/.claude/settings.json" 2>/dev/null; then
    defer_tree="$(cd "$HERE/.." 2>/dev/null && pwd || true)"
  fi
fi
HOROS_DEFER_SUBTREE="$defer_tree" exec python3 "$HERE/horos_core.py" global-pre-bash claude "$gmode"
