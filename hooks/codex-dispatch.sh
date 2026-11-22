#!/usr/bin/env bash
# codex-dispatch.sh (D34) — single entrypoint for global ~/.codex/hooks.json wiring.
# Mirrors plugin-dispatch.sh (D19/D20/D34) for Codex CLI without CLAUDE_PROJECT_DIR:
#   1) resolve workspace root via workspacePaths / payload cwd / git toplevel (never central horos/)
#   2) precedence gate (D20): if <root>/.codex/hooks.json already wires horos, defer (no double-fire)
#   3) activation gate (D19): if <root>/.horos exists, delegate full 5-guard suite + session-brief
#   4) Tier-1 baseline (D34): if marker absent, run stateless reversibility-guard on pre-bash only
#      when global-mode is warn|block (zero .horos/ auto-mkdir, zero Stop/SessionStart noise)
set -uo pipefail
HERE="$(cd "$(dirname "${BASH_SOURCE[0]}")" 2>/dev/null && pwd)" || exit 0
event="${1:-}"
input="$(cat 2>/dev/null || true)"

root="$(printf '%s' "$input" | PYTHONPATH="$HERE" python3 "$HERE/horos_core.py" dispatch-root 0 2>/dev/null || true)"

if [ -n "$root" ] && [ -d "$root/.horos" ]; then
  if grep -qE 'scope-guard\.sh|reversibility-guard\.sh|parent-bridge\.sh' "$root/.codex/hooks.json" 2>/dev/null; then
    exit 0                                                                   # D20: local .codex wiring wins
  fi
  case "$event" in
    pre-edit)      printf '%s' "$input" | HOROS_PROJECT_DIR="$root" "$HERE/scope-guard.sh"; exit $? ;;
    pre-bash)      printf '%s' "$input" | HOROS_PROJECT_DIR="$root" "$HERE/reversibility-guard.sh"; exit $? ;;
    session-start) printf '%s' "$input" | HOROS_PROJECT_DIR="$root" "$HERE/session-brief.sh"; exit $? ;;
    stop)
      {
        printf '%s' "$input" | HOROS_PROJECT_DIR="$root" "$HERE/finish-the-work.sh" 2>/dev/null || true
        printf '%s' "$input" | HOROS_PROJECT_DIR="$root" "$HERE/decision-guard.sh" 2>/dev/null || true
        printf '%s' "$input" | HOROS_PROJECT_DIR="$root" "$HERE/claim-guard.sh" 2>/dev/null || true
      } | python3 -c 'import sys, json
blocks = []; warns = []
for line in sys.stdin:
    line = line.strip()
    if not line: continue
    try: o = json.loads(line)
    except Exception: continue
    if o.get("decision") == "block": blocks.append(o.get("reason", ""))
    elif "systemMessage" in o: warns.append(o["systemMessage"])
if blocks:
    sys.stdout.buffer.write((json.dumps({"decision": "block", "reason": " | ".join(b for b in blocks if b)}, ensure_ascii=False) + "\n").encode("utf-8"))
elif warns:
    sys.stdout.buffer.write((json.dumps({"systemMessage": " | ".join(w for w in warns if w)}, ensure_ascii=False) + "\n").encode("utf-8"))' 2>/dev/null || true
      exit 0 ;;
    *) exit 0 ;;
  esac
fi

# D34: Tier-1 global baseline (stateless pre-bash only)
[ "$event" = pre-bash ] || exit 0
gmode="${HOROS_GLOBAL_MODE:-}"
if [ -z "$gmode" ]; then
  hhome="${HOROS_HOME:-${HOME:-}}"
  gcfg="${HOROS_GLOBAL_CONFIG:-${XDG_CONFIG_HOME:-$hhome/.config}/horos/global_mode}"
  [ -f "$gcfg" ] && IFS= read -r gmode < "$gcfg" 2>/dev/null || true
  gmode="${gmode//[[:space:]]/}"
fi
case "$gmode" in warn|block) ;; *) exit 0 ;; esac

if [ -n "$root" ] && grep -qF 'reversibility-guard.sh' "$root/.codex/hooks.json" 2>/dev/null; then
  exit 0
fi
printf '%s' "$input" | python3 "$HERE/horos_core.py" global-pre-bash codex "$gmode"
exit $?
