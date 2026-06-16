# horos

작업 철학을 **에이전트가 위반할 수 없게 강제**하는 Claude Code 디스크립린 레이어.

이름 `horos`(ὅρος, 그리스어 "경계 · 정의 · 계약조건")는 두 가지를 동시에 함의한다 —
경계를 그어 정의하고(철학 3), 계약으로 묶는다(철학 1). *이름은 placeholder이며 `mv` 로 바꿔도 된다.*

## 왜

[fablize](https://github.com/fivetaku/fablize)(Opus 대상)와 [prometheus](https://github.com/tmdgusya/prometheus)(GLM-5.2 대상)는
모델의 절차적 규율을 외부에서 강제하는 하네스다. 둘의 핵심 교훈은 prometheus 가 `goals.py` 를 버리며 남긴 한 문장이다:

> 의지로 호출하는 게이트는 못 믿는다 → **에이전트가 '완료'를 선언할 수 없고, 시스템이 판정한다.**

5개 작업 철학은 *무엇을 지킬지*는 완비돼 있지만 *어떻게 위반 불가능하게 만들지*는 인간 장인의 자기규율에 맡겨져 있다.
에이전트에 그대로 이식하면 깨진다. **horos 는 그 갭(강제의 부재)을 메운다** — 각 철학을 기계가 판정 가능한 프록시로 환원해 훅에 배선하고,
환원되지 않는 잔여만 규율(스킬)로 내린다.

## 5철학 → 강제 프록시 매핑

| 작업 철학 | 기계 판정 프록시 | 강제 지점 | 상태 |
|---|---|---|---|
| **2. 결정 외화** | 변경 코드 **주석**의 `D<n>` 참조 ∈ ledger(why·cost·escape 완비)? | Stop(decision-guard) | ✅ MVP |
| **3. 경계 수렴** | 수정 파일 ∈ 선언된 scope allowlist? | PreToolUse(Edit\|Write\|MultiEdit) | ✅ MVP |
| **4. 가역성** | 명령이 파괴·비가역 패턴 매치? | PreToolUse(Bash) | ✅ MVP |
| **5. 완료 정의** | 약속만 하고 멈춤 / 도구 0회로 완료 선언? | Stop(finish-the-work) | ✅ MVP |
| **1. 불신/계약** | clamp·경계값·재조립 (코드 품질, 기계 판정 난망) | contract-first 스킬 | ✅ 규율층 |

**훅으로 떨어지는 {2,3,4,5}** 는 결정론적으로 강제하고, 기계 판정이 안 되는 **{1 불신}은 `contract-first` 스킬(규율층)**으로 안내한다 — 5철학 전부 커버한다.

## 단계적 강제 (warn → block)

- **warn** (기본): 위반 시 사람에게 `systemMessage` 경고만 하고 **동작은 허용**한다. 오탐을 관찰·수집하는 단계.
- **block**: 위반을 실제로 차단한다 — PreToolUse `permissionDecision:"deny"`, Stop `decision:"block"`.

```
hooks/horos mode show          # 현재 모드
hooks/horos log                # 누적 위반 검토 (오탐 걸러졌는지)
hooks/horos mode block         # 충분히 검증되면 승격
```

## 구조

```
.claude/
  settings.json          PreToolUse(Edit|Write|MultiEdit, Bash) + Stop(2훅) 등록
  commands/              /scope · /horos-mode
  skills/contract-first/ SKILL.md — 철학 1 규율층 스킬
hooks/
  lib.sh                 공통: JSON 파싱(python3 stdlib) · 모드 · 로깅 · 이벤트별 emit
  scope-guard.sh         철학 3
  reversibility-guard.sh 철학 4
  finish-the-work.sh     철학 5 (+ session_id 기반 무한루프 가드)
  decision-guard.sh      철학 2 (D-id 참조무결성)
  horos                  CLI: scope / mode / decide / log / doctor
decisions.jsonl          철학 2 ledger: {id, why, cost, escape, files, date} (커밋 대상)
tests/
  run.sh                 합성 JSON × warn/block 양모드 단위검증 (격리된 CLAUDE_PROJECT_DIR)
  fixtures/*.jsonl       합성 transcript
.horos/                  런타임 상태 (gitignore, machine-local)
```

## 설치 (다른 프로젝트에 얹기)

horos 는 자족적이다 — 순수 bash + python3 stdlib, 외부 의존·절대경로 참조 없음. 대상 프로젝트 루트에 복사한다:

```bash
git clone https://github.com/mitmirsein/horos /tmp/horos
cd your-project
cp -rp /tmp/horos/hooks .
cp -rp /tmp/horos/.claude .          # 기존 .claude 가 있으면 settings.json 은 덮지 말고 병합
printf '\n.horos/\n' >> .gitignore
chmod +x hooks/*.sh hooks/horos
hooks/horos doctor                   # 설치 점검
```

Claude Code 가 대상 프로젝트를 열면 훅이 자동 활성화된다(첫 실행 시 신뢰 승인). 강도는 기본 `warn`.

## 사용

```
/scope hooks/** tests/** README.md          # 이번 작업의 편집 경계 선언 (철학 3)
hooks/horos decide D2 "<why>" "<cost>" "<escape>" "a.py,b.py"   # 결정 외화 (철학 2)
/horos-mode block                           # 강도 승격
hooks/horos doctor                          # 설치 점검
bash tests/run.sh                           # 단위검증
```

scope 미선언 시 scope-guard 는 강제하지 않는다(경계 선언은 능동적 행위라는 철학 3의 전제).
코드에 `D<n>` 을 주석으로 달면 decision-guard 가 그 참조가 ledger 에 완비됐는지 검사한다.

## 한계 (정직하게)

- finish-the-work·decision-guard 의 판정은 **휴리스틱**이다. 견고한 쪽(`promise`=약속-미실행, `D-ref broken`=참조무결성)은
  block 가능하지만, 오탐 많은 쪽(`claim`=증거 없는 완료, `missing`=유의미한 코드변경+D참조0)은 **warn-only** 로 약화했다.
  `missing` 은 사소 변경(<2파일 & <8줄)을 면제해 한 줄 타이포에는 뜨지 않는다.
- reversibility-guard 는 명령을 패턴 매치한다. **따옴표 안 내용을 마스킹**해 커밋 메시지 등 인자 속 위험 단어 오탐을 제거했다(D4) — 단 heredoc·백틱·변수 확장은 여전히 미파싱이라 완전하지 않다.
- 한 Stop 이벤트의 finish-the-work·decision-guard 는 **병렬 실행**된다(문서). Stop 은 block(계속)/침묵(멈춤)뿐이라 PreToolUse 같은 allow/deny **충돌이 없다** — 동시 block 이면 두 reason 으로 계속될 뿐이다. 각 훅이 독립적으로 정상 block 을 냄을 테스트로 확인했다(D5).
- transcript JSONL 스키마(`assistant` 줄의 `message.content[]`)에 의존한다. 스키마가 바뀌면 **fail-open**(조용히 통과) —
  훅 버그가 작업을 인질로 잡지 않게 한 의도된 선택.
- 효과는 측정되지 않았다. fablize/prometheus 와 마찬가지로 **방향은 확실하되 수치는 주장하지 않는다.**

## License

MIT — see [LICENSE](LICENSE).
