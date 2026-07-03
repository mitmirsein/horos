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
| **2. 결정 외화** | 변경 코드 **주석**의 `D<n>`(결정)·`A<n>`(아포리아) 참조 ∈ ledger 완비? (결정=why·cost·escape / 아포리아=poles·why_unresolved·trigger) | Stop(decision-guard) | ✅ MVP |
| **3. 경계 수렴** | 수정 파일 ∈ 선언된 scope allowlist? | PreToolUse(Edit\|Write\|MultiEdit) | ✅ MVP |
| **4. 가역성** | 명령이 파괴·비가역 패턴 매치? | PreToolUse(Bash) | ✅ MVP |
| **5. 완료 정의** | 약속만 하고 멈춤 / 도구 0회로 완료 선언? | Stop(finish-the-work) | ✅ MVP |
| **1. 불신/계약** | clamp·경계값·재조립 (코드 품질, 기계 판정 난망) | contract-first 스킬 | ✅ 규율층 |
| **감사층 (claim-gate)** | 에이전트가 떨군 claim ⊨ schema·바인딩 신선도·내부 불변식·교차참조? (의미 진리 제외) | Stop(claim-guard) | 🆕 warn |

**훅으로 떨어지는 {2,3,4,5}** 는 결정론적으로 강제하고, 기계 판정이 안 되는 **{1 불신}은 `contract-first` 스킬(규율층)**으로 안내한다 — 5철학 전부 커버한다.

그 위에 **감사층(claim-gate)** 을 둔다 — LLM(에이전트)이 변경에 대한 *주장(claim)* 을 떨구면(`horos claim`), stdlib 훅이 그 주장의 **형식·바인딩 신선도·내부 불변식·교차참조**를 결정론으로 판정한다. **LLM 은 훅에 들어가지 않는다**(번역은 에이전트, 판정은 엔진 — 비결정론은 게이트 밖에 격리). 의미 *진리* 는 판정하지 않으므로(형식이 맞는 거짓도 통과) 기본 `warn` 이다.

## 단계적 강제 (warn → block → strict)

- **warn** (기본): 위반 시 사람에게 `systemMessage` 경고만 하고 **동작은 허용**한다. 오탐을 관찰·수집하는 단계.
- **block**: 견고한 위반(범위 밖 수정, 파괴 명령, broken-ref, 약속-미실행)을 실제로 차단한다 — PreToolUse `permissionDecision:"deny"`, Stop `decision:"block"`.
- **strict** (D18): block + 영구-warn이던 MISSING 경로(결정 미외화·claim 미커버)도 차단하고, 루프가드 문턱을 2→4로 올린다. **하위 모델용** — 권고(warn)를 무신호로 취급하는 모델에게 규약을 완전 강제한다. 알 수 없는 mode 값은 warn으로 clamp(과잉강제 방지).

```
hooks/horos mode show          # 현재 모드
hooks/horos log                # 누적 위반 검토 (오탐 걸러졌는지)
hooks/horos mode block         # 충분히 검증되면 승격
hooks/horos mode strict        # 하위 모델 구동 시(규약 완전 강제)
```

## 판정 메시지 계약 + 코드 레지스트리 (D15)

모든 판정·에러는 한 가지 계약을 따른다 — 하위 모델이 **추론 없이 복붙으로 복구**할 수 있게:

```
[horos:block|warn] <CODE> <한국어 설명>. Action: <영어 명령형 1줄>. 예: <실값 채운 명령 1개>
```

예시는 동적으로 채워진다(실제 깨진 ID, ledger에서 계산한 다음 빈 D-id, 실제 변경 파일). 정본 표는 `hooks/lib.sh` 상단 주석.

| 계열 | 코드 | 뜻 |
|---|---|---|
| 판정 | `HOROS-SCOPE-OUT` · `HOROS-REV-DESTRUCT` · `HOROS-FIN-PROMISE` · `HOROS-FIN-NOEVIDENCE` · `HOROS-DEC-BROKEN` · `HOROS-DEC-MISSING` · `HOROS-CLM-BROKEN` · `HOROS-CLM-MISSING` | 각 가드의 위반 판정 |
| CLI (D14) | `HOROS-CLI-BADID` · `DUPID` · `BADKIND` · `BADFLAG` · `BADREF` · `NOREF` · `NOFILE` · `ROOT` | 적재 시점 검증 — 무증상 죽은 레코드 대신 시끄러운 에러 |
| 텔레메트리 (D16) | `HOROS-TEL-MALFORMED` · `STALE-DROP` · `LOOPGUARD` · `PYFAIL` | 침묵 통과의 흔적 — `horos doctor` health가 집계 |

## 세션 브리프 (D17)

SessionStart 훅(`hooks/session-brief.sh`)이 매 세션 시작에 **규약 카드**(≤15줄)를 컨텍스트로 주입한다 —
현재 mode/scope, 다음 빈 D/A-id로 채운 명령 템플릿, 메시지 계약 안내. 하위 모델이 규약을 문서에서
"당겨오기"를 기대하지 않고 시스템이 "밀어 넣는다"(강제 역전의 해소). `.horos/cli.path`도 함께 기록해
슬래시 커맨드가 플러그인/참조 설치 어느 쪽에서든 중앙 CLI를 찾는다.

## 구조

```
.claude-plugin/
  plugin.json            플러그인 매니페스트 (version = VERSION, D19)
  marketplace.json       이 레포 자체가 1-플러그인 마켓플레이스
.claude/
  settings.json          레포 자체 도그푸딩 배선: PreToolUse + Stop(3훅) + SessionStart
  commands/ · skills/    루트 정본으로의 상대 심링크 (CLAUDE.md 패턴)
commands/                /scope · /horos-mode (정본 — 플러그인 노출용 루트 배치)
skills/contract-first/   SKILL.md — 철학 1 규율층 스킬 (정본)
hooks/
  lib.sh                 공통: JSON 파싱(python3 stdlib) · 모드(warn/block/strict) · 코드 레지스트리 · 로깅/텔레메트리 · emit
  scope-guard.sh         철학 3 (Edit|Write|MultiEdit|NotebookEdit)
  reversibility-guard.sh 철학 4
  finish-the-work.sh     철학 5 (+ session_id 기반 무한루프 가드)
  decision-guard.sh      철학 2 (D-id 결정 · A-id 아포리아 참조무결성)
  claim-guard.sh         감사층 (떨궈진 claim 의 형식·신선도·불변식·교차참조, D9)
  session-brief.sh       SessionStart 규약 카드 주입 (D17)
  parent-bridge.sh       조상 세션 위임 브리지 (D11): horos 하위 작업만 골라 horos 훅에 위임
  plugin-dispatch.sh     플러그인 진입점 (D19/D20): 활성 마커 + 우선순위 게이트 후 실훅 exec
  hooks.json             플러그인 훅 매니페스트 (${CLAUDE_PLUGIN_ROOT} → plugin-dispatch.sh)
  horos                  CLI: scope / mode / decide / aporia / claim / install / init / uninstall / log / doctor
VERSION                  중앙 버전 스탬프 (doctor·plugin.json과 동기)
decisions.jsonl          철학 2 ledger: 결정 {id, why, cost, escape, …} · 아포리아 {id, type:"aporia", poles, why_unresolved, trigger, …} (커밋 대상)
tests/
  run.sh                 합성 JSON × warn/block/strict 단위검증 (격리된 CLAUDE_PROJECT_DIR)
  fixtures/*.jsonl       합성 transcript
.horos/                  런타임 상태 (gitignore, machine-local): mode·scope·violations·claims.jsonl·cli.path
```

## 설치 (다른 프로젝트에 얹기)

horos 는 자족적이다 — 순수 bash + python3 stdlib, 외부 의존 없음. 두 가지 배포 경로가 있다.

### 경로 A — 플러그인 (D19/D20, 권장)

플러그인을 한 번 설치하면, 이후 프로젝트 채택은 `horos init` 한 줄(마커 생성)이다.

```bash
# 1) 한 번만: 이 레포를 마켓플레이스로 등록하고 플러그인 설치
claude plugin marketplace add ~/Desktop/MS_Dev.nosync/horos
claude plugin install horos@horos              # user 전역 (또는 --scope project)

# 2) 프로젝트마다: 옵트인 마커 생성 (settings.json 수술 없음)
hooks/horos init ~/path/to/your-project        # .horos/ + mode=warn + gitignore
hooks/horos doctor ~/path/to/your-project      # plugn/activ/prece 행 확인
```

플러그인이 전역이어도 **`.horos/` 마커가 없는 프로젝트에서는 완전히 잠잠하다**(활성 게이트).
또한 대상의 settings.json에 기존 horos 배선(참조 설치·브리지)이 있으면 **플러그인이 양보**한다
(우선순위 게이트, D20) — 기존 소비자는 무수정 공존하고, 이관은 `horos uninstall <target>` 으로
참조 배선을 걷어낼 때만 일어난다. 조상 워크스페이스의 parent-bridge 도 그대로 유효하다
(조상 루트엔 `.horos` 가 없어 플러그인이 자연 침묵).

### 경로 C — Antigravity CLI (agy, D23)

horos 는 Claude Code 전용이 아니다. **agy(Antigravity CLI)** 는 자체 라이프사이클 훅을 갖고 있고
외부 명령 훅의 **하드 차단**을 지원한다(실측 확인). `hooks/agy-adapter.sh` 가 유일한 agy-결합 파일로,
agy 훅 I/O(`toolCall.name/args`)를 기존 판사가 쓰는 Claude 모양으로 번역한다 — scope-guard·
reversibility-guard·session-brief 는 한 줄도 고치지 않고 그대로 돈다.

```bash
hooks/horos install --harness agy ~/path/to/project   # 대상 .agents/hooks.json 에 어댑터를 참조 등록
hooks/horos init ~/path/to/project                    # .horos 옵트인 마커 (agy도 동일 게이트)
```

- PreToolUse → scope/reversibility(범위 밖 수정·파괴 명령 **차단**), PreInvocation → 규약 카드 주입.
- Stop → finish + decision + claim(D25/D26): pre-tool 이 변경 파일을 누적하고 agy transcript 에서
  마지막 프로즈·tool_seen 을 읽어 합성 transcript 를 만들어 세 게이트를 판정(broken/약속/근거없는완료 →
  멈춤 차단=`{"decision":"continue"}`).
- 판정 포맷 차이(agy `{"decision":"deny"}` · 무의견=무출력, D24)는 어댑터가 흡수한다.
- **agy 에서 5철학 전부 강제된다** — Claude Code 와 동등한 강제층. 유일 agy-결합 파일은 `agy-adapter.sh`,
  판사(scope/reversibility/finish/decision/claim)는 한 줄도 안 고친다.

### 경로 B — 참조 설치 (D12, 플러그인 없이)

horos 한 벌만 두고, 대상 프로젝트는 *복사하지 않고* 그 중앙본을 참조한다 — 복사본은 시간이 지나면 드리프트한다(D12).

```bash
# horos 레포 안에서 (이 레포가 곧 '중앙 소스')
hooks/horos install ~/path/to/your-project    # 대상 .claude/settings.json 에 중앙 훅을 참조 등록
hooks/horos doctor   ~/path/to/your-project    # 대상 배선 점검 (각 훅을 local|ref 로 표시)
```

`install` 은 대상의 `.claude/settings.json` 에 horos 훅을 **중앙 경로(`$HOME/...`)로 참조**하도록 등록하고
(`$HOME` 상대라 머신·사용자명이 달라도 해석됨), `.horos/` 를 대상 `.gitignore` 에 추가한다 — 훅 본체는 복사하지 않는다.
Claude Code 가 훅 실행 시 `CLAUDE_PROJECT_DIR=<대상>` 을 주입하므로 상태(`.horos/`)·결정(`decisions.jsonl`)은
대상 프로젝트에 분리 생성된다(중앙은 로직 1벌). 멱등이라 재실행하면 옛 등록(복사 시절 포함)을 걷어내고 다시 가리킨다.
훅은 세션 시작 시 로드되니 대상을 (다시) 열어야 적용된다. 강도는 기본 `warn`.

대상에서 CLI(`decide`·`scope`·`claim`·`doctor`)를 쓰려면 중앙 CLI 를 그 프로젝트 안에서 부르면 된다 —
CLI 는 `CLAUDE_PROJECT_DIR` 가 없으면 **CWD 의 git 루트**로 ROOT 를 잡는다(D13). 자주 쓰면 PATH 에 심링크하라:

```bash
ln -s ~/Desktop/MS_Dev.nosync/horos/hooks/horos ~/.local/bin/horos   # 선택: 전역 CLI (한 줄)
```

> 레거시(자족 복사): 중앙 소스를 둘 수 없어 한 벌을 떼어내야 하면 `cp -rp hooks .claude .` 후
> `printf '\n.horos/\n' >> .gitignore` + `chmod +x hooks/*.sh hooks/horos`. 드리프트 추적은 사용자 책임 —
> 가능하면 참조 방식을 쓰라.

## 부모(조상) 세션에서 강제하기

Claude Code 는 **프로젝트 루트의** `.claude/settings.json` 에서만 훅을 읽는다. horos 가 멀티프로젝트
워크스페이스의 *하위* 폴더이고 루트를 그 조상으로 열면, horos 자신의 훅은 잠들어 있다 —
horos 를 자체 프로젝트로 열거나, **조상 루트에 `parent-bridge.sh` 를 등록**해야 강제된다.

브리지는 각 이벤트에서 (1) 작업이 horos 하위인지 판정하고, (2) 맞으면 `CLAUDE_PROJECT_DIR` 를
horos 로 고정해 실제 horos 훅에 위임하며, (3) 아니면 즉시 통과한다(다른 프로젝트 무영향).
어떤 오류에도 fail-open. 조상 `.claude/settings.json` 에 세 줄을 등록한다(경로는 환경에 맞게):

```json
{ "hooks": {
  "PreToolUse": [
    { "matcher": "Edit|Write|MultiEdit", "hooks": [{ "type": "command",
      "command": "[ -f \"$HOME/…/horos/hooks/parent-bridge.sh\" ] && bash \"$HOME/…/horos/hooks/parent-bridge.sh\" pre-edit || true" }] },
    { "matcher": "Bash", "hooks": [{ "type": "command",
      "command": "… parent-bridge.sh pre-bash || true" }] }
  ],
  "Stop": [ { "matcher": "*", "hooks": [{ "type": "command",
      "command": "… parent-bridge.sh stop || true" }] } ]
}}
```

- `pre-edit` → scope-guard(편집 파일이 horos 하위일 때) · `pre-bash` → reversibility-guard(cwd 가
  horos 이거나 명령이 horos 경로 참조) · `stop` → finish/decision/claim 을 한 번에(세션이 horos
  파일을 건드렸을 때, 세 판정을 병합해 1회 출력).
- **한계**: `decision`/`claim` 은 horos 하위 파일만 판정한다(D10, `CLAUDE_PROJECT_DIR` 밖 절대경로 무시).
  `finish` 는 세션-전역이라 혼합 세션에선 세션 끝 전체를 평가한다. 정밀 강제가 필요하면 horos 를
  자체 프로젝트로 열어라. settings.json 변경은 **다음 세션부터** 적용된다(훅은 세션 시작 시 로드).

## 사용

```
/scope hooks/** tests/** README.md          # 이번 작업의 편집 경계 선언 (철학 3)
hooks/horos decide D2 "<why>" "<cost>" "<escape>" "a.py,b.py"   # 결정 외화 (철학 2)
hooks/horos aporia A1 "<극1>|<극2>" "<why_unresolved>" "<trigger>" "a.py"   # 긴장(아포리아) 외화 (철학 2)
hooks/horos claim completion "<한 일>" "a.py,tests/test_a.py" "" "tests_added"   # 검증 가능한 주장 떨구기 (감사층)
/horos-mode block                           # 강도 승격 (하위 모델이면 strict)
hooks/horos doctor                          # 설치 점검 (version·plugin·activation·health)
bash tests/run.sh                           # 단위검증
```

CLI 는 적재 시점에 검증한다(D14): 잘못된/중복 ID, 오타 플래그(`test_added` → did-you-mean),
형식이 틀리거나 ledger 에 없는 refs 는 **그 자리에서** `HOROS-CLI-*` 에러와 교정 명령을 돌려준다 —
무증상 죽은 레코드가 되어 나중에 게이트를 조용히 무력화하는 대신. 확장 플래그는 `x_*` 네임스페이스로
검증 없이 허용된다(감사 제안서 §6 확장점).

scope 미선언 시 scope-guard 는 강제하지 않는다(경계 선언은 능동적 행위라는 철학 3의 전제).
코드에 `D<n>`(결정) 또는 `A<n>`(아포리아) 을 주석으로 달면 decision-guard 가 그 참조가 ledger 에 완비됐는지 검사한다. 아포리아는 *해소하지 않고 보류한 긴장*을 1급으로 외화한다 — broken-ref 만 검사하고 미외화(MISSING) 경고는 적용하지 않는다(긴장 표명을 강요하지 않음). 변경에 대해 `horos claim` 으로 주장을 떨구면 claim-guard 가 그 형식·신선도·불변식·교차참조를 결정론으로 판정한다(의미 진리는 에이전트 몫). 유의미 변경에 덮는 주장이 없으면 warn.

## 한계 (정직하게)

- finish-the-work·decision-guard 의 판정은 **휴리스틱**이다. 견고한 쪽(`promise`=약속-미실행, `D-ref broken`=참조무결성)은
  block 가능하지만, 오탐 많은 쪽(`claim`=증거 없는 완료, `missing`=유의미한 코드변경+D참조0)은 warn/block 모드에선 **warn-only** 다
  (strict 에서만 block 으로 승격, D18). `missing` 은 사소 변경(<2파일 & <8줄)을 면제해 한 줄 타이포에는 뜨지 않는다.
- 침묵 통과는 여전히 존재하지만 이제 **보인다**(D16): malformed 드롭·stale 강등·루프가드 침묵·judge 크래시는
  `HOROS-TEL-*` 로 violations.log 에 남고 `horos doctor` health 가 집계한다. 비계측으로 남긴 것: 훅 JSON 파싱 실패와
  transcript 부재(정상적으로 흔해서 소음이 된다).
- TESTISH 경로 면제(D3)·유의미성 문턱(D2)·따옴표 마스킹(D4)은 의도된 오탐/미탐 트레이드다. `tests/` 아래 실코드,
  8줄 미만의 중요 변경, `bash -c "rm -rf …"` 는 여전히 게이트 밖 — strict 후보로 기록만 해 둔다.
- **claim-guard(감사층)** 는 떨궈진 주장의 *형식·바인딩 신선도·내부 불변식·교차참조*만 보장한다. 신선·일관·형식이 맞아도 **의미상 거짓인 주장(coherent lie)은 통과**한다 — 의미 진리는 horos 밖(에이전트 몫)이다. 그래서 구조 위반만 block 가능, 커버리지(주장 누락)는 warn. 바인딩은 풀파일 sha256 이라 stale 주장은 차단이 아니라 *드롭*되어(정당한 재편집 오탐 방지, D9) 커버리지 경고로 떨어진다.
- reversibility-guard 는 명령을 패턴 매치한다. **따옴표 안 내용을 마스킹**해 커밋 메시지 등 인자 속 위험 단어 오탐을 제거했다(D4) — 단 heredoc·백틱·변수 확장은 여전히 미파싱이라 완전하지 않다.
- 한 Stop 이벤트의 finish-the-work·decision-guard 는 **병렬 실행**된다(문서). Stop 은 block(계속)/침묵(멈춤)뿐이라 PreToolUse 같은 allow/deny **충돌이 없다** — 동시 block 이면 두 reason 으로 계속될 뿐이다. 각 훅이 독립적으로 정상 block 을 냄을 테스트로 확인했다(D5).
- transcript JSONL 스키마(`assistant` 줄의 `message.content[]`)에 의존한다. 스키마가 바뀌면 **fail-open**(조용히 통과) —
  훅 버그가 작업을 인질로 잡지 않게 한 의도된 선택.
- 효과는 측정되지 않았다. fablize/prometheus 와 마찬가지로 **방향은 확실하되 수치는 주장하지 않는다.**

## License

MIT — see [LICENSE](LICENSE).
