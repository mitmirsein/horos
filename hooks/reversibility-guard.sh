#!/usr/bin/env bash
# Philosophy 4 — prefer reversibility.
# PreToolUse(Bash): put friction in front of destructive / irreversible commands.
set -euo pipefail
hook_event=PreToolUse
. "$(dirname "${BASH_SOURCE[0]}")/lib.sh"

tool="$(json_field tool_name)"
if [ "$tool" != Bash ]; then pass; fi

cmd="$(json_field tool_input.command)"
if [ -z "$cmd" ]; then pass; fi

match="$(HOROS_CMD="$cmd" python3 - <<'PY'
import os, re
c = os.environ["HOROS_CMD"]
# M1: mask quoted strings so words inside messages/args are not read as commands (D4).
# Use \x22/\x27 (no literal quotes) — literal quotes here break bash quote-pairing
# inside the $()-wrapped heredoc.
c = re.sub(r"\x22[^\x22]*\x22", " ", c)
c = re.sub(r"\x27[^\x27]*\x27", " ", c)
pats = [
    (r'\brm\s+(?:-[a-zA-Z]*\s+)*-?[a-zA-Z]*[rRfF]', 'rm 강제/재귀 삭제'),
    (r'git\s+reset\s+--hard', 'git reset --hard (작업트리 폐기)'),
    (r'git\s+checkout\s+--\s', 'git checkout -- (변경 폐기)'),
    (r'git\s+clean\s+-[a-zA-Z]*f', 'git clean -f (미추적 파일 삭제)'),
    (r'git\s+push\s+(?:.*\s)?--force(?!-with-lease)', 'git push --force (원격 히스토리 덮어쓰기)'),
    (r'\bfind\b.*-delete\b', 'find -delete'),
    (r'\b(?:dd|mkfs|shred)\b', '저수준 파괴 명령(dd/mkfs/shred)'),
    (r'>\s*/dev/sd', '디스크 디바이스 직접 쓰기'),
    (r'\btruncate\s+-s\s*0', 'truncate -s0 (내용 절단)'),
]
for rx, label in pats:
    if re.search(rx, c):
        print(label)
        break
PY
)"

if [ -z "$match" ]; then pass; fi

short="$(printf '%s' "$cmd" | cut -c1-120)"
enforce_pretool "reversibility" "$cmd" \
  "비가역·파괴 작업 감지: ${match}. 갈아엎기 전에 dry-run / 백업 / 별도 커밋으로 가역성을 확보하거나, 의도한 작업이면 확인 후 진행하세요. (명령: ${short})"
