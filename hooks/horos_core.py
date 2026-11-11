#!/usr/bin/env python3
"""horos_core.py — zero-dependency stdlib core shared by horos hooks and CLI. # D27

Input contracts (philosophy 1, contract-first):
- Every external input (hook JSON, transcript lines, ledger/claim JSONL, paths, globs,
  shell command strings) is untrusted: malformed JSON degrades to empty/telemetry, never
  uncaught exceptions in hook paths.
- File paths are normalized via os.path.realpath on both root and target so '..' segments
  and symlinks cannot escape the project or declared scope (# D29).
- Shared state writes (ledger, claims, violations.log, loop-guard maps) use fcntl.flock
  so concurrent subagents/workers cannot corrupt JSONL lines or clobber session counters (# D27).
"""

import datetime
import fcntl
import hashlib
import json
import os
import re
import subprocess
import sys

CODE_EXT = (
    ".py", ".js", ".ts", ".tsx", ".jsx", ".sh", ".bash", ".zsh", ".go", ".rs",
    ".java", ".rb", ".c", ".cpp", ".cc", ".h", ".hpp", ".php", ".swift", ".kt",
    ".scala", ".clj", ".ex", ".exs", ".lua", ".pl", ".mjs", ".cjs", ".vue",
    ".dart", ".sql",
)

TESTISH = re.compile(
    r"(?:^|/)(?:tests?|fixtures?|spec|__tests__)(?:/|$)|\.(?:test|spec)\."
)
DREF = re.compile(r"\b[DA][1-9][0-9]*\b")
VALID_MODES = ("warn", "block", "strict")
CLAIM_KINDS = ("completion", "consistency")
KNOWN_CLAIM_FLAGS = ("tests_added", "consistent_with_refs")

def _comment_tail(ln):
    """Return unquoted comment text from a single code line, or '' if none. # D3, # D29"""
    stripped = ln.lstrip()
    if stripped.startswith("* ") or stripped.startswith("*\t") or stripped.startswith("*/"):
        return stripped
    in_q = None
    esc = False
    n = len(ln)
    i = 0
    while i < n:
        ch = ln[i]
        if in_q:
            if esc:
                esc = False
            elif ch == "\\":
                esc = True
            elif ch == in_q:
                in_q = None
            i += 1
            continue
        if ch in ('"', "'"):
            in_q = ch
            i += 1
            continue
        if ch == "#":
            return ln[i + 1:]
        if ln[i:i + 2] == "//" and (i == 0 or ln[i - 1] != ":"):
            return ln[i + 2:]
        if ln[i:i + 2] == "/*":
            return ln[i + 2:]
        if ln[i:i + 4] == "<!--":
            return ln[i + 4:]
        if ln[i:i + 3] == "-- " and (i == 0 or ln[i - 1].isspace()):
            return ln[i + 3:]
        i += 1
    return ""


def extract_comment_refs(blob):
    """Extract D<n>/A<n> references strictly from code comments, ignoring string literals
    and URL schemes like https://.../D1. # D3, # D29
    """
    refs = set()
    for ln in (blob or "").splitlines():
        tail = _comment_tail(ln)
        if tail:
            refs.update(DREF.findall(tail))
    return refs


def git_toplevel(cwd):
    """Return git worktree root for cwd, or '' if not inside a git repo."""
    if not cwd or not os.path.isdir(cwd):
        return ""
    try:
        proc = subprocess.run(
            ["git", "-C", cwd, "rev-parse", "--show-toplevel"],
            capture_output=True,
            text=True,
            timeout=2,
        )
        if proc.returncode == 0 and proc.stdout.strip():
            return proc.stdout.strip()
    except Exception:
        pass
    return ""


def resolve_root(input_json="", env=None, fallback_dir=""):
    """Resolve HOROS_ROOT across Claude Code, Antigravity, Codex CLI, and generic harnesses. # D28

    Order:
      1. HOROS_PROJECT_DIR (explicit universal override)
      2. CLAUDE_PROJECT_DIR (Claude Code hook runtime)
      3. Hook payload workspacePaths[0] or cwd/project_dir -> git toplevel if git repo, else dir
      4. Process CWD git toplevel (only when fallback_dir is not itself CWD without markers)
      5. fallback_dir (central horos repo fallback)
    """
    env = env if env is not None else os.environ
    for key in ("HOROS_PROJECT_DIR", "CLAUDE_PROJECT_DIR"):
        val = (env.get(key) or "").strip()
        if val:
            return val.rstrip("/") or "/"

    payload = {}
    if input_json:
        try:
            obj = json.loads(input_json)
            if isinstance(obj, dict):
                payload = obj
        except Exception:
            payload = {}

    cand = ""
    wp = payload.get("workspacePaths")
    if isinstance(wp, list) and wp and isinstance(wp[0], str) and wp[0].strip():
        cand = wp[0].strip()
    else:
        for k in ("cwd", "project_dir", "projectDir", "workdir"):
            v = payload.get(k)
            if isinstance(v, str) and v.strip():
                cand = v.strip()
                break

    if cand:
        gt = git_toplevel(cand)
        return (gt or cand).rstrip("/") or "/"

    cwd_gt = git_toplevel(os.getcwd())
    if cwd_gt:
        return cwd_gt.rstrip("/") or "/"

    return (fallback_dir or os.getcwd()).rstrip("/") or "/"


def normalize_relpath(fp, root):
    """Resolve symlinks and '..' on both root and fp; return (inside_root, rel_or_real_fp). # D29"""
    if not fp:
        return False, ""
    real_root = os.path.realpath(root or os.getcwd()).rstrip("/")
    raw_abs = fp if os.path.isabs(fp) else os.path.join(real_root, fp)
    real_fp = os.path.realpath(raw_abs)
    if real_fp == real_root:
        return True, "."
    prefix = real_root + os.sep
    if real_fp.startswith(prefix):
        rel = real_fp[len(prefix):].replace(os.sep, "/")
        return True, rel
    return False, real_fp


def glob_to_regex(pat):
    """Compile a scope allowlist glob into an anchored regex where '*' stays within one segment
    and '**' (or trailing '/') matches across directory boundaries. # D29
    """
    p = pat.strip().replace("\\", "/")
    while p.startswith("./"):
        p = p[2:]
    if not p:
        return re.compile(r"$^")
    if p.endswith("/"):
        p = p.rstrip("/") + "/**"

    # Special suffix: "dir/**" matches "dir" itself or anything under "dir/".
    if p.endswith("/**") and "**" not in p[:-3] and "*" not in p[:-3] and "?" not in p[:-3]:
        base = re.escape(p[:-3])
        return re.compile(r"^" + base + r"(?:/.*)?$")

    i = 0
    n = len(p)
    out = ["^"]
    while i < n:
        if p[i:i + 3] == "**/":
            out.append(r"(?:.+/)?")
            i += 3
        elif p[i:i + 3] == "/**":
            if i + 3 == n:
                out.append(r"(?:/.*)?")
                i += 3
            else:
                out.append(r"(?:/|/.+)")
                i += 3
        elif p[i:i + 2] == "**":
            out.append(r".*")
            i += 2
        elif p[i] == "*":
            out.append(r"[^/]*")
            i += 1
        elif p[i] == "?":
            out.append(r"[^/]")
            i += 1
        else:
            out.append(re.escape(p[i]))
            i += 1
    out.append("$")
    return re.compile("".join(out))


def glob_match(rel, pat):
    """Return True iff normalized ROOT-relative path `rel` matches scope pattern `pat`. # D29"""
    return bool(glob_to_regex(pat).match(rel))


def locked_append(path, line):
    """Append a single UTF-8 line atomically under an exclusive flock. # D27"""
    parent = os.path.dirname(path)
    if parent:
        os.makedirs(parent, exist_ok=True)
    if not line.endswith("\n"):
        line += "\n"
    with open(path, "a", encoding="utf-8") as fh:
        try:
            fcntl.flock(fh.fileno(), fcntl.LOCK_EX)
        except OSError:
            pass
        fh.write(line)
        fh.flush()


def _parse_guard_content(raw):
    """Parse either a JSON session->count map or legacy 'sid count' plain text. # D27"""
    s = (raw or "").strip()
    if not s:
        return {}
    if s.startswith("{"):
        try:
            obj = json.loads(s)
            if isinstance(obj, dict):
                return {
                    str(k): int(v)
                    for k, v in obj.items()
                    if isinstance(v, (int, float, str)) and str(v).isdigit()
                }
        except Exception:
            return {}
    parts = s.split()
    if len(parts) >= 2 and parts[1].isdigit():
        return {parts[0]: int(parts[1])}
    return {}


def guard_op(guard_path, sid, action="get", threshold=2):
    """Session-keyed Stop loop guard stored in guard_path with flock concurrency safety. # D27

    Actions:
      - 'check': if count >= threshold, reset session counter to 0 and return 'SILENCE';
                 else return 'RUN:<count>'.
      - 'bump' : increment session counter by 1, persist, and return new count as str.
      - 'reset': set session counter to 0 (remove key) and return '0'.
    """
    sid = str(sid or "default")
    parent = os.path.dirname(guard_path)
    if parent:
        os.makedirs(parent, exist_ok=True)
    with open(guard_path, "a+", encoding="utf-8") as fh:
        try:
            fcntl.flock(fh.fileno(), fcntl.LOCK_EX)
        except OSError:
            pass
        fh.seek(0)
        data = _parse_guard_content(fh.read())
        cur = int(data.get(sid, 0))
        if cur < 0:
            cur = 0

        if action == "check":
            if cur >= threshold:
                data.pop(sid, None)
                _write_guard_map(fh, data)
                return "SILENCE"
            return "RUN:%d" % cur
        elif action == "bump":
            nxt = cur + 1
            data[sid] = nxt
            if len(data) > 64:
                # Bound map size to 64 active sessions (clamp).
                for k in list(data.keys())[:-64]:
                    if k != sid:
                        data.pop(k, None)
            _write_guard_map(fh, data)
            return str(nxt)
        elif action == "reset":
            if sid in data:
                data.pop(sid, None)
                _write_guard_map(fh, data)
            return "0"
        return str(cur)


def _write_guard_map(fh, data):
    fh.seek(0)
    fh.truncate()
    if data:
        fh.write(json.dumps(data, ensure_ascii=False) + "\n")
    fh.flush()


def load_jsonl(path, label=""):
    """Load JSONL records; return (records, tel_lines) without failing on bad lines. # D16"""
    records = []
    tel = []
    try:
        with open(path, encoding="utf-8") as fh:
            for lineno, line in enumerate(fh, 1):
                line = line.strip()
                if not line:
                    continue
                try:
                    obj = json.loads(line)
                    if isinstance(obj, dict):
                        records.append(obj)
                    else:
                        if label:
                            tel.append("TEL\tHOROS-TEL-MALFORMED\t%s:%d" % (label, lineno))
                except Exception:
                    if label:
                        tel.append("TEL\tHOROS-TEL-MALFORMED\t%s:%d" % (label, lineno))
    except FileNotFoundError:
        pass
    return records, tel


def load_ledger(path):
    """Load decisions.jsonl into (id_map, tel_lines). Last-wins on duplicate IDs."""
    recs, tel = load_jsonl(path, "ledger")
    ledger = {}
    for r in recs:
        rid = r.get("id")
        if rid:
            ledger[str(rid)] = r
    return ledger, tel


def record_complete(r):
    """Kind-aware completeness check for D<n> decisions and A<n> aporias. # D8"""
    if not isinstance(r, dict):
        return False
    if r.get("type") == "aporia":
        poles = r.get("poles")
        return (
            isinstance(poles, list)
            and len([p for p in poles if str(p).strip()]) >= 2
            and all(str(r.get(k, "")).strip() for k in ("why_unresolved", "trigger"))
        )
    return all(str(r.get(k, "")).strip() for k in ("why", "cost", "escape"))


def next_free_id(ids, prefix):
    """Compute next free sequential ID (e.g. D1, A1, C1) from existing IDs."""
    mx = 0
    rx = re.compile(r"^" + re.escape(prefix) + r"([1-9][0-9]*)$")
    for raw in ids:
        m = rx.match(str(raw))
        if m:
            mx = max(mx, int(m.group(1)))
    return "%s%d" % (prefix, mx + 1)


_PATCH_HEADER = re.compile(r"^\*\*\*\s+(?:Add|Update|Delete)\s+File:\s+(.+?)\s*$")
_PATCH_MOVE = re.compile(r"^\*\*\*\s+Move\s+to:\s+(.+?)\s*$")
_UNIFIED_HEADER = re.compile(r"^\+\+\+\s+b/(.+?)\s*$")


def extract_apply_patch_entries(tool_input):
    """Parse Codex/unified apply_patch tool_input -> list of (file_path, added_lines_blob). # D28"""
    raw = ""
    if isinstance(tool_input, str):
        raw = tool_input
    elif isinstance(tool_input, dict):
        for k in ("patch", "input", "cmd", "command", "content", "diff"):
            v = tool_input.get(k)
            if isinstance(v, str) and v.strip():
                raw = v
                break
    if not raw:
        return []

    entries = []
    cur_fp = None
    cur_lines = []

    def flush():
        if cur_fp:
            entries.append((cur_fp, "\n".join(cur_lines) + ("\n" if cur_lines else "")))

    for line in raw.splitlines():
        m = _PATCH_HEADER.match(line) or _PATCH_MOVE.match(line) or _UNIFIED_HEADER.match(line)
        if m:
            flush()
            cur_fp = m.group(1).strip()
            cur_lines = []
            continue
        if cur_fp is not None and line.startswith("+") and not line.startswith("+++"):
            cur_lines.append(line[1:])
    flush()
    return entries


def extract_session_changes(transcript_path, root):
    """Extract (changed_rel_files, new_lines, comment_refs) for code edits inside `root`
    across Claude Edit/Write/MultiEdit and Codex apply_patch tool calls. # D10, # D21, # D28, # D29
    """
    changed = set()
    new_lines = 0
    refs = set()

    def record_edit(fp, blob, added_lines_override=None):
        nonlocal new_lines
        if not fp or not fp.endswith(CODE_EXT):
            return False
        inside, rel = normalize_relpath(fp, root)
        if not inside:
            return False
        if TESTISH.search(rel):
            return False
        changed.add(rel)
        if isinstance(added_lines_override, int):
            new_lines += max(0, added_lines_override)
        else:
            new_lines += blob.count("\n")
        refs.update(extract_comment_refs(blob))
        return True

    try:
        fh = open(transcript_path, encoding="utf-8")
    except OSError:
        return changed, new_lines, refs

    with fh:
        for line in fh:
            line = line.strip()
            if not line:
                continue
            try:
                o = json.loads(line)
            except Exception:
                continue
            if not isinstance(o, dict) or o.get("type") != "assistant":
                continue
            msg = o.get("message")
            content = msg.get("content") if isinstance(msg, dict) else None
            if not isinstance(content, list):
                continue
            for b in content:
                if not (isinstance(b, dict) and b.get("type") == "tool_use"):
                    continue
                tname = b.get("name")
                inp = b.get("input")
                if tname in ("Edit", "Write", "MultiEdit") and isinstance(inp, dict):
                    fp = str(inp.get("file_path") or "")
                    blob = " ".join(str(inp.get(k, "")) for k in ("new_string", "content"))
                    for e in inp.get("edits") or []:
                        if isinstance(e, dict):
                            blob += "\n" + str(e.get("new_string", ""))
                    override = inp.get("_horos_added_lines")
                    record_edit(fp, blob, override if isinstance(override, int) else None)
                elif tname == "apply_patch":
                    for p_fp, p_blob in extract_apply_patch_entries(inp):
                        record_edit(p_fp, p_blob)

    return changed, new_lines, refs


# Subshell unwrap patterns (# D30): inspect payloads passed to sh/bash/zsh -c or eval.
_SUBSHELL_PAYLOAD = re.compile(
    r"""(?:\b(?:bash|sh|zsh|dash|ksh)\b(?:\s+-[a-zA-Z]+)*\s+-c|\beval)\s+(?:"((?:\\.|[^"\\])*)"|'([^']*)')"""
)
_PY_INLINE_PAYLOAD = re.compile(
    r"""\bpython3?(?:\.[0-9]+)?\b(?:\s+-[a-zA-Z]+)*\s+-c\s+(?:"((?:\\.|[^"\\])*)"|'([^']*)')"""
)

DESTRUCTIVE_PATTERNS = [
    (r"\brm\s+(?:-[a-zA-Z]+\s+|--[a-z-]+\s+)*(?:-[a-zA-Z]*[rRfF]|--recursive\b|--force\b)", "rm 강제/재귀 삭제"),
    (r"\bgit\s+reset\s+--hard\b", "git reset --hard (작업트리 폐기)"),
    (r"\bgit\s+checkout\s+(?:--\s|\.(?:\s|$|;|\||&))", "git checkout --/. (변경 폐기)"),
    (r"\bgit\s+restore\s+(?:(?:[^\n;|&]*\s)?(?:--worktree\b|-[a-zA-Z]*W\b)|\.(?:\s|$|;|\||&))", "git restore (작업트리 변경 폐기)"),
    (r"\bgit\s+clean\s+-[a-zA-Z]*f", "git clean -f (미추적 파일 삭제)"),
    (
        r"\bgit\s+push\b[^\n;|&]*\s(?:--force(?!-)|-[a-zA-Z]*f(?![a-zA-Z-]))",
        "git push --force/-f (원격 히스토리 덮어쓰기)",
    ),
    (r"\bgit\s+branch\s+(?:[^\n;|&]*\s)?-D(?:\s|$|;|\||&)", "git branch -D (미병합 브랜치 강제 삭제)"),
    (r"\bfind\b[^\n;|&]*\s-delete\b", "find -delete"),
    (r"\b(?:dd|mkfs|shred)\b", "저수준 파괴 명령(dd/mkfs/shred)"),
    (r">\s*/dev/(?:sd|nvme|disk)", "디스크 디바이스 직접 쓰기"),
    (r"\btruncate\s+-s\s*0\b", "truncate -s0 (내용 절단)"),
]


def scan_destructive_command(cmd):
    """Return matched destructive command label or '' if safe. # D4, # D30

    Masks quoted arguments (so commit messages like `git commit -m 'fix rm -rf'` pass),
    AFTER unwrapping inline subshell payloads (`bash -c '...'`, `eval '...'`, `python -c '...'`).
    """
    if not cmd:
        return ""

    candidates = []
    for m in _SUBSHELL_PAYLOAD.finditer(cmd):
        inner = m.group(1) if m.group(1) is not None else m.group(2)
        if inner:
            inner_unq = inner.replace('\\"', '"').replace("\\\\", "\\")
            candidates.append(inner_unq)

    for m in _PY_INLINE_PAYLOAD.finditer(cmd):
        py_code = m.group(1) if m.group(1) is not None else m.group(2)
        if py_code and re.search(r"\bshutil\.rmtree\s*\(", py_code):
            return "python -c shutil.rmtree (재귀 디렉터리 삭제)"

    masked = re.sub(r'"(?:\\.|[^"\\])*"', " ", cmd)
    masked = re.sub(r"'[^']*'", " ", masked)
    candidates.insert(0, masked)

    for cand in candidates:
        # Also mask nested quotes inside unwrapped subshells so `bash -c 'git commit -m "rm -rf"'` passes
        c_norm = re.sub(r'"(?:\\.|[^"\\])*"', " ", cand) if cand is not masked else cand
        c_norm = re.sub(r"'[^']*'", " ", c_norm) if cand is not masked else c_norm
        for rx, label in DESTRUCTIVE_PATTERNS:
            if re.search(rx, c_norm):
                return label
    return ""


def judge_finish_transcript(transcript_path):
    """Judge Stop transcript for finish-the-work: return PASS | PROMISE | CLAIM. # D30"""
    last = None
    tool_seen = False
    try:
        fh = open(transcript_path, encoding="utf-8")
    except OSError:
        return "PASS"

    with fh:
        for line in fh:
            line = line.strip()
            if not line:
                continue
            try:
                o = json.loads(line)
            except Exception:
                continue
            if not isinstance(o, dict):
                continue
            if o.get("type") == "assistant":
                last = o
                msg = o.get("message") or {}
                for b in (msg.get("content") if isinstance(msg, dict) else None) or []:
                    if isinstance(b, dict) and b.get("type") == "tool_use":
                        tool_seen = True

    if not last:
        return "PASS"
    msg = last.get("message") or {}
    content = (msg.get("content") if isinstance(msg, dict) else None) or []
    has_tool = any(isinstance(b, dict) and b.get("type") == "tool_use" for b in content)
    text = " ".join(
        str(b.get("text", ""))
        for b in content
        if isinstance(b, dict) and b.get("type") == "text"
    ).strip()
    if not text:
        return "PASS"

    low = text.lower()
    tail = low[-500:]
    # Legitimate stop: turn ends by asking / offering options to the user
    if re.search(r"(\?|shall i|would you like|할까요|드릴까요|하시겠|여쭤|알려\s*주세요|선택해\s*주|결정해\s*주)", tail):
        return "PASS"
    if has_tool:
        return "PASS"

    # D30: check promise patterns on the trailing 500 chars (not mid-report body) and require
    # volitional/future endings in Korean so nouns like "다음으로 테스트 결과를 요약합니다" pass.
    en_promise = re.search(
        r"\b(i'?ll|i will|let me|next,? i|now i'?ll|now let me)\b.{0,45}\b"
        r"(implement|create|write|add|run|fix|build|test|update|modify)\b",
        tail,
    )
    ko_promise = re.search(
        r"(?:이제|다음으로|곧|바로)\s*.{0,30}(?:구현|작성|추가|실행|수정|만들|돌려|돌리|테스트|진행)"
        r"\s*(?:하겠|할게|해\s*보겠|해보겠|해\s*볼게|해볼게|하러|합시다|드리겠)",
        tail,
    ) or re.search(
        r"(?:구현|작성|추가|실행|수정|테스트|진행)(?:하겠습니다|할게요|해\s*보겠습니다|해보겠습니다)\s*[.!]*\s*$",
        tail,
    )
    if en_promise or ko_promise:
        return "PROMISE"

    if (not tool_seen) and re.search(
        r"(완료(?:했|됐|됩|입니다|하였)|finished|all set|\bdone\b|✅|끝났|마쳤)", low
    ):
        return "CLAIM"
    return "PASS"


def prune_runtime(state_dir, keep_days=14, prune_all=False):
    """Prune transient .horos runtime artifacts; return summary dict. # D32"""
    summary = {"violations_kept": 0, "violations_dropped": 0, "claims_dropped": 0, "agy_temp_removed": 0, "guards_reset": 0}
    if not os.path.isdir(state_dir):
        return summary

    cutoff = datetime.datetime.now(datetime.timezone.utc) - datetime.timedelta(days=max(0, int(keep_days)))
    cutoff_iso = cutoff.strftime("%Y-%m-%dT%H:%M:%SZ")

    vlog = os.path.join(state_dir, "violations.log")
    if os.path.isfile(vlog):
        if prune_all:
            with open(vlog, encoding="utf-8") as fh:
                summary["violations_dropped"] = sum(1 for _ in fh)
            os.remove(vlog)
        else:
            kept = []
            dropped = 0
            with open(vlog, encoding="utf-8") as fh:
                for line in fh:
                    ts = line.split("\t", 1)[0].strip()
                    if ts and ts < cutoff_iso:
                        dropped += 1
                    else:
                        kept.append(line)
            with open(vlog, "w", encoding="utf-8") as fh:
                fh.writelines(kept)
            summary["violations_kept"] = len(kept)
            summary["violations_dropped"] = dropped

    cpath = os.path.join(state_dir, "claims.jsonl")
    if os.path.isfile(cpath):
        if prune_all:
            with open(cpath, encoding="utf-8") as fh:
                summary["claims_dropped"] = sum(1 for l in fh if l.strip())
            os.remove(cpath)
        else:
            kept = []
            dropped = 0
            with open(cpath, encoding="utf-8") as fh:
                for line in fh:
                    s = line.strip()
                    if not s:
                        continue
                    try:
                        obj = json.loads(s)
                        dt = str(obj.get("date") or "")
                        if dt and dt[:19] + "Z" < cutoff_iso:
                            dropped += 1
                        else:
                            kept.append(line if line.endswith("\n") else line + "\n")
                    except Exception:
                        dropped += 1
            with open(cpath, "w", encoding="utf-8") as fh:
                fh.writelines(kept)
            summary["claims_dropped"] = dropped

    for name in os.listdir(state_dir):
        fp = os.path.join(state_dir, name)
        if name.startswith("agy_changed.") and os.path.isfile(fp):
            try:
                mtime = datetime.datetime.fromtimestamp(os.path.getmtime(fp), datetime.timezone.utc)
                if prune_all or mtime < cutoff:
                    os.remove(fp)
                    summary["agy_temp_removed"] += 1
            except OSError:
                pass
        elif name in ("stop_guard", "stop_guard_decision", "stop_guard_claim") and prune_all and os.path.isfile(fp):
            try:
                os.remove(fp)
                summary["guards_reset"] += 1
            except OSError:
                pass

    return summary
