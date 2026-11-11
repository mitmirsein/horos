# horos: 에이전트 작업 헌법 (정본)

> 이 파일(`AGENTS.md`)이 **정본**이다. `CLAUDE.md`와 `GEMINI.md`는 이 파일로 연결된 상대 심링크다.
> 셋 중 어느 파일을 열어 편집하든 실체는 이 파일이며, 여기만 수정하면 Claude, Codex, Gemini 세 에이전트에 동시에 반영된다.
> (절대경로 심링크는 금지한다. 머신마다 사용자명이 달라 링크가 파손될 수 있으므로 같은 폴더 내 상대 심링크만 허용한다.)

이 저장소에서 작업하는 에이전트는 horos가 강제하는 작업 철학을 스스로 적용(dogfooding)한다.
horos는 작업 철학을 결정론적 훅으로 강제하는 규율 계층이며, 이 저장소 자신이 첫 번째 적용 대상이다.

## 작업 철학 (강제 대상)

1. **불신을 기본값으로 삼는 계약 중심 설계**: 외부 입력, 모델 출력, 미래의 자기 자신까지 모두 검증 대상으로 간주한다. 의미값 재조립, 범위 제한(clamp), 경계값 4종(정상, 매핑, 누락, 변조) 테스트를 기본으로 적용한다. 코딩 시 `contract-first` 스킬(`.claude/skills/`)이 절차를 안내하며, 변경을 마치면 `horos claim <completion|consistency> <assert> <files> [refs] [flags]` 명령으로 검증 가능한 주장을 남긴다. 감사층 `claim-guard`가 주장의 형식, 해시 신선도, 내부 불변식, 교차참조를 결정론적으로 판정한다.
2. **결정을 추적 가능한 객체로 외화**: 주요 설계 결정에 ID(`D1` 등)를 부여하고 이유, 비용, 탈출구를 기록한다. 코드 주석(`# D<n>`)으로 결정을 참조하고 `horos decide D<n> <why> <cost> <escape>` 명령으로 원장(`decisions.jsonl`)에 기록하면 `decision-guard`가 참조 무결성을 검사한다 (문자열 리터럴, URL 경로, 테스트 및 픽스처 파일은 검사에서 제외한다, D3, D29). 해소하지 않고 보류한 **긴장**(aporia)은 `horos aporia A<n> "<극1>|<극2>" <why_unresolved> <trigger>` 명령으로 외화하고 코드에 `# A<n>`으로 참조한다 (`decision-guard`는 깨진 참조만 차단하며 미외화는 강제하지 않는다, D8).
3. **문제 해결 전 경계 선언**: 건드리지 않을 영역을 먼저 확정하여 변경 반경을 수렴시킨다. 작업 시작 시 `/scope` 또는 `horos scope set` 명령으로 허용 경계를 선언한다 (`scope-guard`는 `realpath` 정규화와 세그먼트 구분 글로브를 통해 `..` 우회와 심링크 탈출을 차단한다, D29).
4. **가역성 우선**: 기존 구조를 파괴하기보다 안전하게 덧댄다. 비가역 파괴 명령(`rm -rf`, `git reset --hard`, `git checkout .`, `git restore .`, `git push -f`, `git branch -D`, `bash -c`/`python -c` 인라인 삭제 등, D30) 실행 전에 백업이나 별도 커밋으로 복구 지점을 먼저 확보한다.
5. **완료의 넓은 정의**: 구현, 단위 검증, 문서 현행화, 최종 실행 확인까지를 하나의 완료 단위로 본다. 다음 작업을 하겠다는 약속 문장으로 턴을 끝내지 않고 즉시 도구를 호출하여 실행한다 (D30).

## 판정 메시지 계약 (D15)

모든 훅 판정과 CLI 오류는 `[horos:block|warn] <CODE> <한국어 설명>. Action: <영어 명령형 1줄>. 예: <실값 채운 명령 1개>` 형식을 따른다 (`FIN` 계열은 특정 명령 대신 도구 즉시 실행이 목적이므로 예시 생략 가능). 코드 레지스트리 정본은 `hooks/lib.sh` 상단 주석 표다. 새 판정 경로를 추가할 때는 이 계약과 함께 `hooks/lib.sh`, `README.md`, `tests/run.sh`를 동시에 갱신한다.

## 운영 및 개발 규칙

- 코드나 훅을 수정하면 반드시 `bash tests/run.sh`를 실행하여 **전체 통과**(실패 0건)를 확인하고 결과를 보고한다 (철학 5).
- 훅과 코어 모듈(`hooks/horos_core.py`)은 순수 `bash`와 `python3` 표준 라이브러리만 사용한다. 가상환경, `jq`, 절대경로 하드코딩을 일체 금지한다 (멀티머신 이식성 보장).
- `.horos/`는 머신 로컬 런타임 상태이므로 커밋 및 머신 간 동기화를 금지한다 (`.gitignore` 및 워크스페이스 `.stignore` 등록). 반면 `decisions.jsonl`과 `tests/fixtures/*.jsonl`은 공유 정본이므로 버전 관리와 동기화 대상에 포함한다.
- `warn` -> `block` -> `strict` 승격은 단계적으로만 수행한다 (D18). `horos log` 및 `horos doctor`의 상태 지표를 먼저 점검하며, 오래된 런타임 로그는 `horos prune`으로 정리한다 (D32).
- 새 강제 규칙이나 도구 매처를 추가할 때는 훅 본체, `hooks/horos_core.py`, 단위검증(`tests/run.sh`), `README.md`, `.claude/settings.json`, `hooks/hooks.json`, `hooks/horos`의 `install` 방출부 패리티를 함께 갱신한다 (`Edit|Write|MultiEdit|NotebookEdit|apply_patch`, D28).
- 커맨드(`commands/`)와 스킬(`skills/`)의 정본은 저장소 루트에 두며, `.claude/` 하위 항목은 상대 심링크 상태를 유지한다 (D19).
- 다른 프로젝트에 horos를 적용할 때는 `hooks/`를 복사하지 않고 중앙 소스를 참조 연결한다:
  - Claude Code 플러그인: `hooks/horos init <target>` (D19/D20)
  - Claude Code 참조 배선: `hooks/horos install <target>` (D12)
  - Antigravity 2.0 참조 배선: `hooks/horos install --harness agy <target>` (D23/D31)
  - Codex CLI 참조 배선: `hooks/horos install --harness codex <target>` (D28)
- `hooks/lib.sh`는 `HOROS_PROJECT_DIR` -> `CLAUDE_PROJECT_DIR` -> 입력 페이로드(`workspacePaths`/`cwd`) -> 프로세스 CWD의 Git 루트 순으로 프로젝트 루트를 자동 해석하므로 Claude, Antigravity, Codex, 일반 POSIX 하네스(`HOROS_HARNESS=exitcode`)에서 동일하게 동작한다 (D28).

## 검증 명령

```bash
bash tests/run.sh        # 단위 및 경계값 전체 검증 (warn/block/strict × claude/agy/codex/exitcode)
hooks/horos doctor       # 배선, 하네스, 설정 드리프트, 버전, 텔레메트리 종합 점검
```
