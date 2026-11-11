# horos (v0.5.1)

[![CI](https://github.com/mitmirsein/horos/actions/workflows/ci.yml/badge.svg)](https://github.com/mitmirsein/horos/actions/workflows/ci.yml)
[![License: MIT](https://img.shields.io/badge/License-MIT-blue.svg)](LICENSE)
[![Zero Dependencies](https://img.shields.io/badge/deps-bash%20%2B%20python3%20stdlib-success.svg)](#platform-compatibility--requirements)

**[English](README.md)** | **[한국어](README.ko.md)**

Deterministic hook-based discipline layer for coding agents across **Claude Code**, **Antigravity 2.0**, **OpenAI Codex CLI**, and generic **POSIX exit-code** harnesses.

Prompts and `AGENTS.md` files decay under long context windows. `horos` (Greek ὅρος: boundary, definition, contractual term) enforces engineering boundaries mechanically at tool-call and turn-stop boundaries using zero external packages and zero extra LLM calls (`bash` + `python3` standard library only).

---

## 30-Second Quickstart (Lite Tier: Zero Ledger Ceremony)

You do **not** need decision ledgers (`decisions.jsonl`) or audit claims (`claim`) to get immediate value. Out of the box, `horos` protects your workspace with **file-scope confinement**, **destructive shell command blocking**, and **premature-stop detection**.

```bash
# 1. Clone once and link the CLI onto PATH (zero pip/npm packages needed)
git clone https://github.com/mitmirsein/horos.git ~/.horos-src
mkdir -p ~/.local/bin && ln -sfn ~/.horos-src/hooks/horos ~/.local/bin/horos

# 2. Wire hooks by reference and opt in (starts in safe 'warn' mode)
horos install ~/path/to/my-project
horos init ~/path/to/my-project

# 3. Confine edits to allowed directories and promote to 'block' mode
cd ~/path/to/my-project
horos scope set "src/**" "tests/**"
horos mode block
horos doctor
```

---

## Progressive Adoption (Lite -> Ledger -> Strict)

Adopt only the enforcement depth your project needs:

| Stage | Mode | What You / Your Agent Do | What `horos` Enforces Deterministically |
|---|---|---|---|
| **1. Observe** | `warn` (default) | Run `horos init` | Logs violations to `.horos/violations.log` and emits non-blocking warnings |
| **2. Lite Guardrails** | `block` | Optionally declare `horos scope set ...` | Blocks out-of-scope file edits (`scope-guard`), destructive shell/subshell commands (`reversibility-guard`), and unexecuted promises or zero-evidence completion claims (`finish-the-work`) |
| **3. Decision Ledger** | `block` | Record key trade-offs via `horos decide D1 ...` and cite `# D1` in code comments | Stage 2 + blocks broken or incomplete `D-id` / `A-id` comment references against `decisions.jsonl` (`decision-guard`) |
| **4. Full Audit** | `strict` | Deposit `sha256`-bound claims via `horos claim completion ...` | Stage 3 + requires ledger references and fresh file-hash claims on non-trivial (`>= 8` added lines) code changes (`claim-guard`) |

---

## Why Deterministic Hooks?

Prior agent harnesses ([fablize](https://github.com/fivetaku/fablize), [prometheus](https://github.com/tmdgusya/prometheus)) established a clear rule:

> Voluntary self-check instructions inside prompts cannot be trusted when context pressure rises. Agents propose; deterministic system hooks judge.

`horos` enforces four mechanical gates plus a `sha256`-bound audit tier through `python3` stdlib hooks, while keeping pure design judgment (input clamping, boundary testing) in the companion `contract-first` skill.

## Philosophy-to-Hook Mapping

| Principle | Deterministic Proxy | Hook Event | Tiers |
|---|---|---|---|
| **Boundary Convergence** | Normalized target path (`realpath`) matches declared `scope` globs; blocks `..` traversal and symlink escapes; distinguishes `*` vs `**` segments (D29) | `PreToolUse` (`Edit\|Write\|MultiEdit\|NotebookEdit\|apply_patch`) | `warn` / `block` / `strict` |
| **Reversibility** | Shell command (including unwrapped `bash -c`, `sh -c`, `eval`, `python -c` payloads) matches destructive patterns (`rm -rf`, `git reset --hard`, `git push --force`, `git checkout .`, D30) | `PreToolUse` (`Bash`) | `warn` / `block` / `strict` |
| **Definition of Done** | Assistant turn ends with an unexecuted promise or claims completion with zero tool invocations (D30) | `Stop` (`finish-the-work`) | `warn` / `block` / `strict` |
| **Decision Externalization** | `D<n>` (decision) and `A<n>` (aporia: unresolved tension) IDs cited in code **comments** exist and are complete in `decisions.jsonl`, ignoring string literals and URLs (D29) | `Stop` (`decision-guard`) | `warn` / `block` / `strict` |
| **Claim Audit Tier** | Deposited `horos claim` passes schema check, `sha256` file-bind freshness, flag invariants (`tests_added`), and ledger cross-reference checks (D9, D21) | `Stop` (`claim-guard`) | `warn` / `block` / `strict` |
| **Contract-First Design** | Untrusted-by-default boundaries, range clamping, 4-category boundary unit tests | `contract-first` skill | Advisory skill |

## Self-Executing Remediation Contract (D15)

Every block, warning, and CLI validation error follows a single machine-actionable format with a concrete recovery command pre-filled for the agent:

```text
[horos:block|warn] <CODE> <Korean summary>. Action: <English imperative>. 예: <pre-filled command>
```

| Family | Codes | Purpose |
|---|---|---|
| Guard Judgments | `HOROS-SCOPE-OUT`, `HOROS-REV-DESTRUCT`, `HOROS-FIN-PROMISE`, `HOROS-FIN-NOEVIDENCE`, `HOROS-DEC-BROKEN`, `HOROS-DEC-MISSING`, `HOROS-CLM-BROKEN`, `HOROS-CLM-MISSING` | Pre-tool denials and stop-turn continuations |
| CLI Validation (D14) | `HOROS-CLI-BADID`, `DUPID`, `BADKIND`, `BADFLAG`, `BADREF`, `NOREF`, `NOFILE`, `ROOT` | Deposit-time schema and hash validation |
| Fail-Open Telemetry (D16) | `HOROS-TEL-MALFORMED`, `STALE-DROP`, `LOOPGUARD`, `PYFAIL` | Silent-pass observability surfaced by `horos doctor` |

---

## Multi-Harness Setup

`horos` wires hooks **by `$HOME`-relative reference** rather than copying scripts into every repository, preventing hook drift across projects and synced machines (D12).

### 1. Claude Code (Plugin or Reference Wiring)

```bash
# Option A: Install global plugin from GitHub, then opt in per project (recommended)
claude plugin marketplace add mitmirsein/horos
claude plugin install horos@horos
horos init ~/path/to/project

# Option B: Reference wiring in target .claude/settings.json without global plugin
horos install ~/path/to/project
horos init ~/path/to/project
horos doctor ~/path/to/project
```

### 2. Antigravity 2.0 (`--harness agy`, D23/D31)

`hooks/agy-adapter.sh` translates Antigravity 2.0 hook payloads bidirectionally (`SessionStart` nested `systemMessage`, `PreToolUse` permission decisions, `Stop` `terminationReason` abort-safety so `USER_CANCELED` / `ERROR` / `MAX_*` never trap the session, and incremental line-delta tracking).

```bash
horos install --harness agy ~/path/to/project   # writes .agents/hooks.json
horos init ~/path/to/project                    # creates .horos opt-in marker
```

### 3. OpenAI Codex CLI (`--harness codex`, D28)

Resolves the target root automatically without `CLAUDE_PROJECT_DIR` (`HOROS_PROJECT_DIR` -> payload `cwd` -> Git/ancestral `.horos` root) and parses multi-file `apply_patch` payloads directly in both `scope-guard` and `Stop` guards.

```bash
horos install --harness codex ~/path/to/project # writes .codex/hooks.json
horos init ~/path/to/project                    # creates .horos opt-in marker
# Note: approve project hooks via `/hooks` on first launch in Codex CLI if prompted.
```

### 4. Generic POSIX Exit-Code Runners (`HOROS_HARNESS=exitcode`, D28)

Any custom agent loop or CI runner that treats `exit 2` + `stderr` as a block and `exit 0` as allow can invoke the guards directly without an adapter:

```bash
HOROS_HARNESS=exitcode HOROS_PROJECT_DIR=/path/to/project ~/.horos-src/hooks/scope-guard.sh < payload.json
```

---

## CLI Cheat Sheet

```bash
horos scope set "src/**" "tests/**"                                       # Declare allowed edit globs
horos scope show | clear                                                  # Inspect or remove scope boundary
horos mode show | warn | block | strict                                   # Inspect or switch enforcement tier
horos decide D1 "<why>" "<cost>" "<escape>" "src/app.py"                  # Record architectural decision
horos aporia A1 "<pole1>|<pole2>" "<why_unresolved>" "<revisit_trigger>"  # Record unresolved design tension
horos claim completion "<summary>" "src/app.py,tests/test_app.py" "D1" "tests_added,consistent_with_refs"
horos doctor [target-dir]                                                 # Audit wiring, drift, and telemetry
horos prune --days 14 [target-dir]                                        # Prune aged runtime logs and claims
horos uninstall [--harness claude|agy|codex] <target-dir>                 # Cleanly remove horos hook entries
bash tests/run.sh                                                         # Run 219-case hermetic test suite
```

## Repository Layout

```text
.claude-plugin/          Claude Code plugin & marketplace manifests (D19)
.github/workflows/ci.yml Ubuntu + macOS CI test matrix (D33)
commands/                /scope and /horos-mode slash command sources
skills/contract-first/   SKILL.md for boundary & contract discipline
hooks/
  horos_core.py          Shared zero-dep Python stdlib core (realpath, globs, flock, parsers)
  lib.sh                 Shared shell bootstrap, root resolution, loop guard, channel emitter
  scope-guard.sh         PreToolUse file-boundary guard
  reversibility-guard.sh PreToolUse destructive-command & subshell guard
  finish-the-work.sh     Stop unexecuted-promise & zero-evidence guard
  decision-guard.sh      Stop D-id / A-id comment reference verifier
  claim-guard.sh         Stop sha256 claim freshness & invariant verifier
  session-brief.sh       SessionStart compact protocol card injector (<= 15 lines)
  agy-adapter.sh         Antigravity 2.0 bidirectional hook adapter
  parent-bridge.sh       Parent workspace selective delegation bridge
  plugin-dispatch.sh     Global plugin opt-in & precedence dispatcher
  horos                  Unified management CLI
tests/                   219 unit/boundary tests + 20 synthetic transcript fixtures
```

## Platform Compatibility & Requirements

- **Supported OS**: macOS, Linux (`x86_64`, `aarch64`), and Windows **WSL2** (uses POSIX `fcntl.flock` for concurrent session-map and ledger locking; native Windows `cmd.exe` / PowerShell is not supported).
- **Runtime**: `bash` and `python3` (>= 3.8), standard library only.

## Honest Boundaries

- **Structural Audit vs. Semantic Truth**: `claim-guard` verifies schema validity, `sha256` file-hash freshness, flag invariants, and ledger cross-references. A structurally valid claim bound to passing hashes cannot prove semantic correctness on its own; unit tests and code review remain essential.
- **Static Shell Scanning Scope**: `reversibility-guard` unwraps `bash -c`, `sh -c`, `eval`, and `python -c` inline payloads and flags destructive Git/filesystem commands, but does not perform full multi-hop variable taint analysis or inspect external scripts invoked by path.
- **Fail-Open Safety with Traceability**: Unexpected transcript schema changes or internal exceptions never deadlock an agent session; hooks fail open and record `HOROS-TEL-*` entries in `.horos/violations.log` surfaced by `horos doctor` (D16).

## License

MIT License. See [LICENSE](LICENSE).
