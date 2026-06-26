# horos — agent constitution (this repo)

> **이 파일(`AGENTS.md`)이 정본이다.** `CLAUDE.md` 와 `GEMINI.md` 는 이 파일로의 *상대* 심링크다 —
> 셋 중 무엇을 열어 편집하든 실체는 이 파일이며, 여기만 고치면 Claude·Codex·Gemini 세 에이전트에 동시 반영된다.
> (절대경로 심링크 금지: 머신마다 사용자명이 달라 깨질 수 있다. 같은 폴더 상대링크라야 안전.)

이 레포에서 작업하는 에이전트는 horos 가 강제하는 작업 철학을 **dogfooding** 한다.
horos 는 그 철학을 코드로 강제하는 레이어이고, 이 레포 자신이 첫 적용 대상이다.

## 작업 철학 (강제 대상)

1. **불신을 기본값 (계약적)** — 외부 입력·모델 출력·미래의 자기 자신도 의심한다. 의미값 재조립, clamp, 경계값 4종(정상/매핑/None/변조) 테스트. 코딩 시 `contract-first` 스킬(`.claude/skills/`)이 절차를 안내한다 — 기계 강제가 아닌 규율층. 변경을 끝내면 `horos claim <completion|consistency> <assert> <files> [refs] [flags]` 로 검증 가능한 주장을 떨군다 — **감사층** claim-guard 가 그 형식·바인딩 신선도·내부 불변식·교차참조를 결정론으로 판정한다(의미 진리는 보장 안 함; LLM 은 주장만, 판정은 엔진).
2. **결정을 추적 가능한 객체로 외화** — 결정에 ID(D1…)를 붙이고 이유+비용+탈출구를 글로 남긴다. 코드 주석(`# D<n>`)으로 결정을 참조하고 `horos decide D<n> <why> <cost> <escape>` 로 ledger(`decisions.jsonl`)에 외화하라 — decision-guard 가 참조무결성을 검사한다(주석 밖 문자열 리터럴과 `tests/`·`fixtures` 파일은 무시). 해소하지 않고 보류한 **긴장(아포리아)** 은 `horos aporia A<n> "<극1>|<극2>" <why_unresolved> <trigger>` 로 외화하고 코드에 `# A<n>` 으로 참조한다 — decision-guard 가 broken-ref 만 검사하며 미외화는 강요하지 않는다(결정을 억지로 평탄화하지 말 것).
3. **풀기 전에 경계부터 선언** — "건드리지 않을 것"을 먼저 적어 변경 반경을 수렴시킨다. 작업 시작 시 `/scope` 로 경계를 선언하라.
4. **가역성 선호** — 갈아엎지 말고 얹는다. 파괴·비가역 명령(`rm -rf`, `git reset --hard`, `--force`) 전에 dry-run/백업/별도 커밋.
5. **'완료'의 넓은 정의** — 동작+테스트+문서 현행화+검증까지가 한 단위. 약속으로 턴을 끝내지 말고 도구로 실행하라.

## 규칙

- 코드/훅을 수정하면 반드시 `bash tests/run.sh` 를 돌려 **전체 통과**를 확인하고 결과를 보고한다 (철학 5).
- 훅 스크립트는 순수 bash + python3 stdlib 만 사용한다. venv·jq·절대경로 심링크 금지 (멀티머신 이식성).
- `.horos/` 는 런타임 상태다(커밋·동기화 금지). `decisions.jsonl` 은 공유 산출물이라 커밋 대상.
- warn→block 은 단계적으로만 승격한다. `horos log` 로 오탐을 검토하기 전에 block 으로 올리지 않는다.
- 새 강제 규칙을 추가하면: 훅 + 단위검증 fixture + README 매핑표 + 이 파일을 **함께** 갱신한다 (계약 변경의 동반 파일).
- horos 가 조상 루트의 하위 폴더라 자체 세션으로 열리지 않을 땐, 조상 `.claude/settings.json` 에 `hooks/parent-bridge.sh`(pre-edit/pre-bash/stop)를 등록해 강제한다 — horos 하위 작업만 위임하고 타 프로젝트엔 무영향(D11). decision/claim 은 `CLAUDE_PROJECT_DIR` 밖 파일을 판정하지 않는다(D10).
- 다른 프로젝트에 horos 를 얹을 땐 hooks/ 를 **복사하지 말고** `hooks/horos install <target>` 로 중앙 소스를 *참조*시킨다 — 복사본은 드리프트한다(D12). 훅은 Claude Code 가 주입하는 `CLAUDE_PROJECT_DIR` 로 대상에 묶이고, CLI 는 그 값이 없으면 CWD 의 git 루트로 ROOT 를 잡는다(D13). `hooks/horos doctor <target>` 로 참조 배선을 점검한다.

## 검증

```
bash tests/run.sh        # unit checks (scope/reversibility/finish/decision × warn/block)
hooks/horos doctor       # 설치 점검
```
