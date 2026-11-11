---
description: horos 강제 강도를 warn/block/strict 로 전환한다 (단계적 도입)
argument-hint: warn | block | strict | show
---
CLI 경로는 다음 폴백 체인으로 확인한다 (`cli.path` 실행 가능 여부를 검증하여 타 머신 경로 오염을 차단한다, D17, D32):
`HOROS_CLI="$(cat "${CLAUDE_PROJECT_DIR:-.}/.horos/cli.path" 2>/dev/null || true)"; [ -n "$HOROS_CLI" ] && [ -x "$HOROS_CLI" ] || HOROS_CLI="${CLAUDE_PLUGIN_ROOT:+$CLAUDE_PLUGIN_ROOT/hooks/horos}"; [ -n "$HOROS_CLI" ] && [ -x "$HOROS_CLI" ] || HOROS_CLI="$(command -v horos 2>/dev/null || echo "${CLAUDE_PROJECT_DIR:-.}/hooks/horos")"`

horos 강제 모드를 변경하거나 조회한다: `"$HOROS_CLI" mode $ARGUMENTS`

- 인자가 없으면 `"$HOROS_CLI" mode show` 명령으로 현재 모드를 출력한다.
- `warn`: 위반 시 사람에게 경고만 전달하고 동작은 허용한다 (관찰 단계, 오탐 수집).
- `block`: 명확한 규율 위반을 실제로 차단한다 (`PreToolUse` 거부 및 `Stop` 연장).
- `strict`: `block` 규칙에 더해 권고 등급 경로(결정 미외화 및 claim 미커버)까지 차단하고 루프 가드 문턱을 4회로 높인다. 하위 모델 구동 등 규약 완전 강제가 필요할 때 사용한다 (D18).

전환 전에 `"$HOROS_CLI" log` 명령으로 누적 위반 기록을 검토하여 오탐이 충분히 걸러졌는지 확인한다.
