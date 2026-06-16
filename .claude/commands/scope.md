---
description: 이번 작업의 편집 허용 경계(allowlist)를 선언한다 (작업철학 3 · 경계 수렴)
argument-hint: <glob> [glob ...]   예) hooks/** tests/** README.md
---
이번 작업에서 편집을 허용할 경로 글로브: $ARGUMENTS

작업 철학 3(풀기 전에 경계부터 선언, 발산이 아니라 수렴)에 따라 변경 반경을 먼저 좁힌다.

- 인자가 있으면: `$CLAUDE_PROJECT_DIR/hooks/horos scope set $ARGUMENTS` 를 실행한다.
- 인자가 비어 있으면: 먼저 이번 작업에서 "건드릴 경로"와 "건드리지 않을 것"을 한 줄씩 적은 뒤, 그에 맞는 글로브로 `horos scope set` 을 실행한다.

실행 후 `$CLAUDE_PROJECT_DIR/hooks/horos scope show` 로 확정된 경계를 사용자에게 보여라.
이후 scope 밖 파일을 Edit/Write 하려 하면 scope-guard 훅이 (warn 또는 block) 개입한다.
