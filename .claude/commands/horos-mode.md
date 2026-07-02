---
description: horos 강제 강도를 warn/block 으로 토글한다 (단계적 도입)
argument-hint: warn | block | show
---
CLI 경로는 다음 폴백 체인으로 잡는다 (플러그인/참조 설치 양쪽 대응, D17):
`HOROS_CLI="$(cat "$CLAUDE_PROJECT_DIR/.horos/cli.path" 2>/dev/null || echo "$CLAUDE_PROJECT_DIR/hooks/horos")"`

horos 강제 모드를 변경/조회하라: `"$HOROS_CLI" mode $ARGUMENTS`

- 인자가 없으면 `"$HOROS_CLI" mode show` 로 현재 모드를 보여라.
- `warn` = 위반 시 사람에게 경고만 하고 동작은 허용한다(관찰 단계, 오탐 수집).
- `block` = 위반을 실제로 차단한다(PreToolUse deny / Stop 계속).

전환 전에 `"$HOROS_CLI" log` 로 누적 위반을 검토해 오탐이 충분히 걸러졌는지 확인할 것을 권한다.
