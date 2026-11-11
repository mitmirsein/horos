# horos (v0.5.1)

[![CI](https://github.com/mitmirsein/horos/actions/workflows/ci.yml/badge.svg)](https://github.com/mitmirsein/horos/actions/workflows/ci.yml)
[![License: MIT](https://img.shields.io/badge/License-MIT-blue.svg)](LICENSE)
[![Zero Dependencies](https://img.shields.io/badge/deps-bash%20%2B%20python3%20stdlib-success.svg)](#지원-환경-및-요구사항)

**[English](README.md)** | **[한국어](README.ko.md)**

작업 철학을 에이전트가 우회할 수 없도록 결정론적 훅으로 강제하는 멀티 하네스(Claude Code, Antigravity 2.0, Codex CLI, 범용 POSIX 러너) 규율 계층이다.

이름 `horos`(ὅρος, 그리스어 경계, 정의, 계약 조건)는 두 가지 원리를 함께 담고 있다: 작업 반경의 경계를 먼저 수렴시키고(철학 3), 입출력과 의사결정을 명시적 계약으로 묶는다(철학 1, 철학 2).

---

## 30초 빠른 시작 (Lite 모드: 원장 없이 바로 쓰기)

처음부터 의사결정 원장(`decisions.jsonl`)이나 감사 주장(`claim`)을 모두 배울 필요는 없다. 클론 직후 기본 가드 3종(**경계 밖 파일 수정 차단**, **파괴적 셸 명령 차단**, **실행 없는 말뿐인 완료 선언 방지**)만으로도 즉시 실무 보호 효과를 얻을 수 있다.

```bash
# 1. 원하는 경로에 클론 후 PATH 연결 (외부 패키지 설치 불필요)
git clone https://github.com/mitmirsein/horos.git ~/.horos-src
mkdir -p ~/.local/bin && ln -sfn ~/.horos-src/hooks/horos ~/.local/bin/horos

# 2. 내 프로젝트에 훅 연결 및 활성화 (기본값: 안전한 warn 관찰 모드)
horos install ~/path/to/my-project
horos init ~/path/to/my-project

# 3. 편집 허용 범위만 선언하고 차단 모드로 전환 (Lite 운영)
cd ~/path/to/my-project
horos scope set "src/**" "tests/**"
horos mode block
horos doctor
```

---

## 단계적 도입 가이드 (Lite -> Ledger -> Strict)

프로젝트 규모와 팀 숙련도에 맞춰 필요한 깊이만큼만 점진적으로 활성화할 수 있다.

| 도입 단계 | 설정 모드 | 에이전트나 사용자가 할 일 | 자동 강제 범위 |
|---|---|---|---|
| **1단계: 관찰** | `warn` (기본) | `horos init` 실행만 수행 | 차단 없이 모든 위반을 경고 메시지와 `.horos/violations.log`로 기록 |
| **2단계: Lite 방어** | `block` | 필요 시 `horos scope set`으로 작업 폴더만 지정 | 범위 밖 파일 편집 차단(`scope-guard`), `rm -rf`/`git reset --hard` 등 파괴 명령 차단(`reversibility-guard`), 미실행 완료 선언 차단(`finish-the-work`) |
| **3단계: 아키텍처 원장** | `block` | 주요 설계 선택을 `horos decide D1 ...`로 기록하고 코드 주석에 `# D1` 병기 | 2단계 방어 + 존재하지 않거나 불완전한 `D-id`/`A-id` 주석 참조 차단(`decision-guard`) |
| **4단계: 무결성 감사** | `strict` | 작업 완료 전 `horos claim completion ...`으로 변경 파일 해시와 근거 제출 | 3단계 방어 + 8줄 이상 유의미 변경 시 원장 기록 및 `sha256` 해시 바인딩 주장 필수화(`claim-guard`) |

---

## 배경과 설계 목적

[fablize](https://github.com/fivetaku/fablize)와 [prometheus](https://github.com/tmdgusya/prometheus)가 입증한 핵심 교훈은 명확하다:

> 에이전트의 자발적 의지로 호출하는 게이트는 신뢰할 수 없다. 에이전트가 스스로 완료를 선언하는 대신 시스템이 결정론적으로 판정해야 한다.

5가지 작업 철학 중 기계 판정이 가능한 4가지(철학 2, 3, 4, 5)와 감사층(`claim-guard`)은 네트워크나 추가 LLM 호출 없이 순수 `python3` 표준 라이브러리 훅으로 강제하고, 구문 검사로 환원되지 않는 설계 규율(철학 1)만 `contract-first` 스킬로 안내한다.

## 5대 철학 및 강제 프록시 매핑

| 작업 철학 | 기계 판정 프록시 | 강제 지점 | 상태 |
|---|---|---|---|
| **2. 결정 외화** | 변경 코드 **주석**의 `D<n>`(결정) 및 `A<n>`(아포리아) 참조가 `decisions.jsonl`에 완비되었는가 (문자열 리터럴 및 URL 제외, D29) | `Stop` (`decision-guard`) | 활성 (`warn`/`block`/`strict`) |
| **3. 경계 수렴** | 수정 대상 파일(`realpath` 정규화)이 선언된 `scope` 허용 목록 안에 속하는가 (`..` 우회 및 심링크 탈출 차단, `*` 대 `**` 세그먼트 구분, D29) | `PreToolUse` (`Edit\|Write\|MultiEdit\|NotebookEdit\|apply_patch`) | 활성 (`warn`/`block`/`strict`) |
| **4. 가역성** | 셸 명령(인라인 `bash -c`, `eval`, `python -c` 포함)이 비가역 파괴 패턴과 일치하는가 (D30) | `PreToolUse` (`Bash`) | 활성 (`warn`/`block`/`strict`) |
| **5. 완료 정의** | 응답 말미가 실행 없는 작업 약속으로 끝나거나, 도구 호출 0회 상태에서 완료를 선언했는가 (D30) | `Stop` (`finish-the-work`) | 활성 (`warn`/`block`/`strict`) |
| **1. 불신 및 계약** | 의미값 재조립, 범위 제한(clamp), 경계값 4종 테스트 작성 | `contract-first` 스킬 | 규율층 안내 |
| **감사층** (`claim-gate`) | 에이전트가 제출한 `claim`이 스키마, `sha256` 해시 신선도, 내부 불변식, 원장 교차참조를 충족하는가 (D9, D21) | `Stop` (`claim-guard`) | 활성 (`warn`/`block`/`strict`) |

감사층(`claim-guard`)은 **번역기와 판사의 분리** 원칙을 따른다. 에이전트(LLM)가 작업 결과를 구조화된 주장(`horos claim`)으로 기록하면, 훅은 오직 표준 라이브러리만으로 형식, 파일 해시 일치 여부, 교차참조 무결성을 판정한다. 의미적 진리 자체는 판정 대상이 아니므로(형식을 갖춘 거짓 주장은 통과함), 커버리지 누락은 기본 `warn` 등급으로 동작하며 `strict` 모드에서만 차단으로 승격된다.

## 판정 메시지 계약 및 코드 레지스트리 (D15)

모든 판정과 CLI 오류는 모델이 추론 없이 즉시 복구 명령을 실행할 수 있도록 단일 출력 계약을 준수한다:

```text
[horos:block|warn] <CODE> <한국어 설명>. Action: <영어 명령형 1줄>. 예: <실값이 채워진 복구 명령>
```

| 계열 | 코드 | 설명 |
|---|---|---|
| 판정 | `HOROS-SCOPE-OUT`, `HOROS-REV-DESTRUCT`, `HOROS-FIN-PROMISE`, `HOROS-FIN-NOEVIDENCE`, `HOROS-DEC-BROKEN`, `HOROS-DEC-MISSING`, `HOROS-CLM-BROKEN`, `HOROS-CLM-MISSING` | 각 가드의 규율 위반 판정 |
| CLI (D14) | `HOROS-CLI-BADID`, `DUPID`, `BADKIND`, `BADFLAG`, `BADREF`, `NOREF`, `NOFILE`, `ROOT` | 적재 시점 즉시 검증 오류 |
| 텔레메트리 (D16) | `HOROS-TEL-MALFORMED`, `STALE-DROP`, `LOOPGUARD`, `PYFAIL` | fail-open 침묵 통과 기록 (`horos doctor` 집계) |

## 디렉터리 구조

```text
.claude-plugin/
  plugin.json            플러그인 매니페스트 (version = VERSION 동기화, D19)
  marketplace.json       단일 플러그인 마켓플레이스 정의
.github/workflows/
  ci.yml                 Ubuntu 및 macOS 매트릭스 자동 검증 파이프라인 (D33)
commands/                /scope, /horos-mode 슬래시 커맨드 정본 (D32 실행 검증 폴백 포함)
skills/contract-first/   SKILL.md (철학 1 규율층 스킬 정본)
hooks/
  horos_core.py          공유 표준 라이브러리 코어: 루트 해석, realpath 정규화, 세그먼트 글로브, flock 잠금, 패치/주석 파서 (D27~D32)
  lib.sh                 공통 셸 래퍼: 하네스 중립 루트 해석, claude/exitcode 방출 채널, 루프 가드, 로깅
  scope-guard.sh         철학 3: 경계 수렴 (Edit|Write|MultiEdit|NotebookEdit|apply_patch)
  reversibility-guard.sh 철학 4: 비가역 파괴 명령 차단 (서브셸 언래핑 포함)
  finish-the-work.sh     철학 5: 약속 미실행 및 무증거 완료 선언 차단
  decision-guard.sh      철학 2: 결정(D-id) 및 아포리아(A-id) 주석 참조 무결성 검증
  claim-guard.sh         감사층: 제출된 claim의 구조, 해시 신선도, 불변식, 교차참조 검증
  session-brief.sh       SessionStart 시점 규약 카드(15줄 이하) 자동 주입 (D17)
  agy-adapter.sh         Antigravity 2.0 양방향 입출력 어댑터 (SessionStart, terminationReason 안전 게이트, 증분 줄 수 계산, D23~D31)
  parent-bridge.sh       상위 워크스페이스 브리지 (하위 horos 작업만 선별 위임, D11)
  plugin-dispatch.sh     글로벌 플러그인 진입점 (.horos 옵트인 및 로컬 배선 우선순위 게이트, D19/D20)
  hooks.json             플러그인 훅 매니페스트
  horos                  통합 CLI (scope, mode, decide, aporia, claim, install, init, uninstall, prune, log, doctor)
VERSION                  중앙 버전 스탬프 (0.5.1)
decisions.jsonl          철학 2 공유 원장 (커밋 및 동기화 대상)
tests/
  run.sh                 전 계층 단위 및 경계값 검증 스위트 (219개 케이스)
  fixtures/*.jsonl       합성 트랜스크립트 픽스처 20종
```

## 멀티 하네스 설치 안내

`horos`는 대상 프로젝트에 훅 스크립트를 복제하지 않고 중앙 저장소를 `$HOME` 상대 경로로 참조 연결하여 프로젝트 간 버전 드리프트를 원천 차단한다 (D12).

### 1. Claude Code (플러그인 또는 참조 배선)

```bash
# 방법 A: GitHub 마켓플레이스에서 글로벌 플러그인 설치 후 프로젝트별 옵트인 (권장)
claude plugin marketplace add mitmirsein/horos
claude plugin install horos@horos
horos init ~/path/to/project

# 방법 B: 플러그인 없이 대상 .claude/settings.json 에 참조 배선 등록
horos install ~/path/to/project
horos init ~/path/to/project
horos doctor ~/path/to/project
```

### 2. Antigravity 2.0 (`--harness agy`, D23/D31)

`hooks/agy-adapter.sh`가 Antigravity 2.0의 훅 입출력(`SessionStart` 중첩 `systemMessage`, `PreToolUse`, `Stop`의 `terminationReason` 종료 사유 분기 및 실제 추가 줄 수 계산)을 양방향 번역한다.

```bash
horos install --harness agy ~/path/to/project   # 대상 .agents/hooks.json 생성 및 갱신
horos init ~/path/to/project                    # .horos 옵트인 마커 생성
```

### 3. Codex CLI (`--harness codex`, D28)

`CLAUDE_PROJECT_DIR`이 없는 환경에서도 `HOROS_PROJECT_DIR`, 훅 입력 JSON의 `cwd`, 프로세스 작업 디렉터리의 Git 루트 순으로 대상 프로젝트를 자동 식별하며, Codex 고유 편집 도구인 `apply_patch` 패치 본문을 직접 파싱한다.

```bash
horos install --harness codex ~/path/to/project # 대상 .codex/hooks.json 생성 및 갱신
horos init ~/path/to/project                    # .horos 옵트인 마커 생성
# 참고: Codex CLI 최초 실행 시 `/hooks` 메뉴에서 프로젝트 훅 신뢰 승인이 필요할 수 있다.
```

### 4. 일반 POSIX 종료 코드 하네스 (`HOROS_HARNESS=exitcode`, D28)

표준 에러(`stderr`) 메시지와 종료 코드(`block` 시 `exit 2`, `warn` 시 `exit 0`) 규약을 따르는 외부 에이전트 러너에서는 환경변수 `HOROS_HARNESS=exitcode`와 `HOROS_PROJECT_DIR=<경로>`만 지정하면 별도 어댑터 없이 모든 가드를 그대로 사용할 수 있다.

## 일상 명령어 요약

```bash
horos scope set "src/**" "tests/**"                                       # 1. 편집 허용 경계 선언
horos mode show | warn | block | strict                                   # 2. 강제 수위 조회 및 전환
horos decide D1 "<이유>" "<비용>" "<탈출구>" "src/app.py"                   # 3. 설계 결정 외화 (# D1 주석 병기)
horos aporia A1 "<극1>|<극2>" "<보류 이유>" "<재검토 조건>"                 # 4. 보류된 설계 긴장(아포리아) 기록
horos claim completion "<수행 요약>" "src/app.py,tests/test_app.py" "D1" "tests_added,consistent_with_refs"
horos doctor                                                              # 5. 배선, 드리프트, 텔레메트리 점검
horos prune --days 14                                                     # 6. 오래된 런타임 기록 정리
bash tests/run.sh                                                         # 7. 전체 단위 테스트 실행 (219건)
```

## 지원 환경 및 요구사항

- **지원 운영체제**: macOS, Linux(`x86_64`, `aarch64`), Windows **WSL2** (파일 잠금에 POSIX `fcntl.flock`을 사용하므로 네이티브 Windows `cmd.exe` 및 PowerShell은 지원하지 않는다).
- **런타임 요구사항**: `bash` 및 `python3` 3.8 이상 (외부 `pip`/`npm` 패키지 의존성 0개).

## 한계와 설계 경계

- **감사층의 정직한 경계**: `claim-guard`는 주장의 구조, 파일 해시 신선도, 내부 불변식, 원장 교차참조만 결정론적으로 보증한다. 형식과 해시가 일치하는 의미상의 거짓 주장(coherent lie)은 기계가 가려낼 수 없으며, 실제 의미 검증은 단위 테스트와 코드 리뷰가 담당한다.
- **정적 명령 스캐닝의 범위**: `reversibility-guard`는 `bash -c`, `sh -c`, `eval`, `python -c` 인라인 삭제와 주요 Git 작업트리 폐기 명령을 잡아내지만, 다단 변수 치환이나 외부 스크립트 파일 내부의 파괴 동작까지 정적으로 완전 분석하지는 않는다.
- **장애 시 개방 원칙**(Fail-Open): 예상치 못한 트랜스크립트 스키마 변경이나 내부 예외 발생 시 세션을 인질로 잡지 않고 통과시키되, 반드시 `.horos/violations.log`에 `HOROS-TEL-*` 추적을 남겨 `horos doctor`에서 관측할 수 있게 한다 (D16).

## 라이선스

MIT License ([LICENSE](LICENSE) 참조).

