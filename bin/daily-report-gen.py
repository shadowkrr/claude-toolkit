#!/usr/bin/env python3
"""
日報生成スクリプト (ハイブリッド版 v5)
- history.jsonl → プロジェクトパス解決
- session JSONL → 会話 + 変更 → プロジェクト単位で統合 → Claude haiku で要約
"""

import atexit
import json
import os
import signal
import sys
import subprocess
import datetime
from pathlib import Path
from collections import defaultdict

HOME = Path.home()
HISTORY_FILE = HOME / ".claude" / "history.jsonl"
PROJECTS_DIR = HOME / ".claude" / "projects"
DAILY_DIR = HOME / ".claude" / "memory" / "daily"
LOCK_FILE = HOME / ".claude" / "memory" / "logs" / "daily-report.lock"

CLAUDE_CMD = os.environ.get("CLAUDE_CMD") or "/opt/homebrew/bin/claude"

# ノイズディレクトリのパターン（Go build/cgo 等の自動生成）
NOISE_DIR_PATTERNS = [
    "opt-homebrew-Cellar-go",
    "private-var-folders",
    "private-tmp",
    "go-build",
]


def cleanup_lock():
    """ロックファイルを削除（自分のPIDの場合のみ）"""
    try:
        if LOCK_FILE.exists():
            lock_pid = LOCK_FILE.read_text().strip()
            if lock_pid == str(os.getpid()):
                LOCK_FILE.unlink(missing_ok=True)
    except Exception:
        pass


atexit.register(cleanup_lock)
signal.signal(signal.SIGTERM, lambda *_: sys.exit(0))


# ============================================================
# history.jsonl → プロジェクトパス解決
# ============================================================

def parse_history(target_date):
    project_paths = set()

    if not HISTORY_FILE.exists():
        return project_paths

    with open(HISTORY_FILE, "r", encoding="utf-8") as f:
        for line in f:
            line = line.strip()
            if not line:
                continue
            try:
                entry = json.loads(line)
            except json.JSONDecodeError:
                continue

            ts_ms = entry.get("timestamp", 0)
            ts = datetime.datetime.fromtimestamp(ts_ms / 1000)
            if ts.date() != target_date:
                continue

            project_path = entry.get("project", "")
            if project_path:
                # ノイズパスを除外
                if not any(p in project_path for p in [
                    "/var/folders/", "go-build", "/opt/homebrew/Cellar/go",
                    "/private/tmp",
                ]):
                    project_paths.add(project_path)

    return project_paths


def escape_table(s):
    return s.replace("|", "\\|").replace("\n", " ").replace("\r", "")


# ============================================================
# session JSONL → 素材抽出
# ============================================================

def truncate(s, max_len=80):
    if not s:
        return ""
    first_line = s.split("\n")[0].strip()
    first_line = escape_table(first_line)
    if len(first_line) > max_len:
        return first_line[:max_len] + "..."
    return first_line


def resolve_project_name(dir_name, project_paths):
    """ディレクトリ名 + history.jsonl のパスからプロジェクト名を解決"""
    normalized = "/" + dir_name.lstrip("-").replace("-", "/")

    best_name = ""
    best_len = 0
    for pp in project_paths:
        pp_normalized = pp.replace(".", "/").replace("-", "/")
        dir_normalized = normalized.replace(".", "/")
        if pp_normalized.startswith(dir_normalized) or dir_normalized.startswith(pp_normalized):
            name = os.path.basename(pp)
            if len(pp) > best_len:
                best_len = len(pp)
                best_name = name

    if best_name:
        return best_name

    # フォールバック: ディレクトリ名末尾
    parts = dir_name.lstrip("-").split("-")
    return parts[-1] if parts else dir_name


def parse_entry_timestamp(entry):
    """エントリからタイムスタンプを取得"""
    ts_str = entry.get("timestamp", "")
    if not ts_str:
        snap = entry.get("snapshot", {})
        ts_str = snap.get("timestamp", "")
    if ts_str:
        try:
            return datetime.datetime.fromisoformat(ts_str.replace("Z", "+00:00"))
        except (ValueError, AttributeError):
            pass
    return None


def session_has_today_entries(jsonl_path, target_date):
    """セッションに対象日のエントリがあるか高速チェック（先頭20行）"""
    try:
        with open(jsonl_path, "r", encoding="utf-8") as f:
            for i, line in enumerate(f):
                if i >= 20:
                    break
                line = line.strip()
                if not line:
                    continue
                try:
                    entry = json.loads(line)
                except json.JSONDecodeError:
                    continue
                ts = parse_entry_timestamp(entry)
                if ts and ts.date() == target_date:
                    return True
    except Exception:
        pass
    return False


def parse_session(jsonl_path, target_date):
    """セッションJSONLから対象日の会話・変更を抽出"""
    user_msgs = []
    assistant_msgs = []
    edits = []
    writes = []
    first_time = None
    last_time = None

    with open(jsonl_path, "r", encoding="utf-8") as f:
        for line in f:
            line = line.strip()
            if not line:
                continue
            try:
                entry = json.loads(line)
            except json.JSONDecodeError:
                continue

            # タイムスタンプチェック
            ts = parse_entry_timestamp(entry)
            if ts:
                if ts.date() != target_date:
                    continue
                local_ts = ts.astimezone(tz=None)
                time_str = local_ts.strftime("%H:%M")
                if first_time is None:
                    first_time = time_str
                last_time = time_str

            entry_type = entry.get("type", "")
            content = entry.get("message", {}).get("content", [])
            if not isinstance(content, list):
                content = []

            if entry_type == "user":
                for block in content:
                    if block.get("type") == "text":
                        text = block["text"].strip()
                        if text and not text.startswith("[Pasted") and len(text) > 3:
                            user_msgs.append(text[:200])

            elif entry_type == "assistant":
                for block in content:
                    if block.get("type") == "text":
                        text = block["text"].strip()
                        if len(text) > 20:
                            assistant_msgs.append(text[:300])

                    elif block.get("type") == "tool_use":
                        tool = block.get("name", "")
                        inp = block.get("input", {})

                        if tool == "Edit":
                            fp = inp.get("file_path", "")
                            if fp:
                                old = truncate(inp.get("old_string", ""))
                                new = truncate(inp.get("new_string", "")) or "(削除)"
                                if old != new:
                                    edits.append({
                                        "file": os.path.basename(fp),
                                        "old": old,
                                        "new": new,
                                    })

                        elif tool == "Write":
                            fp = inp.get("file_path", "")
                            if fp:
                                writes.append(os.path.basename(fp))

    return {
        "first_time": first_time or "??:??",
        "user_msgs": user_msgs,
        "assistant_msgs": assistant_msgs,
        "edits": dedupe_edits(edits),
        "writes": list(dict.fromkeys(writes)),
    }


def dedupe_edits(edits):
    seen = set()
    result = []
    for e in edits:
        key = (e["file"], e["old"], e["new"])
        if key not in seen:
            seen.add(key)
            result.append(e)
    return result


def is_noise_directory(dir_name):
    """Go build/cgo 等の自動生成ディレクトリか判定"""
    for pattern in NOISE_DIR_PATTERNS:
        if pattern in dir_name:
            return True
    return False


def is_noise_session(sess):
    """自動生成セッション（実質的な会話なし）を検出"""
    has_edits = bool(sess["edits"])
    has_writes = bool(sess["writes"])
    user_count = len(sess["user_msgs"])

    # ユーザー発言なし & ファイル変更なし → 空セッション
    if user_count == 0 and not has_edits and not has_writes:
        return True

    # ユーザー発言1件以下 & ファイル変更なし → 内容が薄すぎる
    if user_count < 2 and not has_edits and not has_writes:
        # コンパイラフラグ風のメッセージならノイズ確定
        if sess["user_msgs"]:
            msg = sess["user_msgs"][0]
            if msg.startswith("-") and any(flag in msg for flag in [
                "-arch", "-Wall", "-Werror", "-fPIC", "-pthread",
                "-x c", "-dM", "-fno-stack", "gcc",
            ]):
                return True
        return True

    return False


def consolidate_sessions(session_list):
    """同一プロジェクトの複数セッションを1つに統合"""
    if not session_list:
        return None
    if len(session_list) == 1:
        return session_list[0]

    merged = {
        "first_time": min(s["first_time"] for s in session_list),
        "user_msgs": [],
        "assistant_msgs": [],
        "edits": [],
        "writes": [],
    }

    seen_user = set()
    seen_assistant = set()

    for sess in sorted(session_list, key=lambda s: s["first_time"]):
        for m in sess["user_msgs"]:
            key = m[:80]
            if key not in seen_user:
                seen_user.add(key)
                merged["user_msgs"].append(m)
        for m in sess["assistant_msgs"]:
            key = m[:80]
            if key not in seen_assistant:
                seen_assistant.add(key)
                merged["assistant_msgs"].append(m)
        merged["edits"].extend(sess["edits"])
        merged["writes"].extend(sess["writes"])

    merged["edits"] = dedupe_edits(merged["edits"])
    merged["writes"] = list(dict.fromkeys(merged["writes"]))

    # haiku に渡すデータ量をキャップ
    merged["user_msgs"] = merged["user_msgs"][:15]
    merged["assistant_msgs"] = merged["assistant_msgs"][:10]
    merged["edits"] = merged["edits"][:15]
    merged["writes"] = merged["writes"][:10]

    return merged


def get_sessions(target_date, project_paths):
    """今日アクティブだったセッションをプロジェクトごとに取得"""
    sessions = defaultdict(list)

    if not PROJECTS_DIR.exists():
        return sessions

    for project_dir in PROJECTS_DIR.iterdir():
        if not project_dir.is_dir():
            continue

        # ノイズディレクトリをスキップ
        if is_noise_directory(project_dir.name):
            continue

        project_name = resolve_project_name(project_dir.name, project_paths)

        for jsonl_file in project_dir.glob("*.jsonl"):
            if "subagents" in str(jsonl_file):
                continue

            # mtime で大まかにフィルタ（高速化）
            try:
                mtime = datetime.datetime.fromtimestamp(jsonl_file.stat().st_mtime)
                if mtime.date() != target_date:
                    continue
            except OSError:
                continue

            # JSONL 内タイムスタンプで正確にチェック
            if not session_has_today_entries(jsonl_file, target_date):
                continue

            try:
                sess = parse_session(jsonl_file, target_date)
            except Exception:
                continue

            # ノイズセッションをスキップ
            if is_noise_session(sess):
                continue

            sessions[project_name].append(sess)

    return sessions


# ============================================================
# Claude haiku で要約
# ============================================================

def summarize_session(project, sess):
    """セッションの素材を Claude haiku で要約"""
    parts = [f"プロジェクト: {project}"]

    if sess["user_msgs"]:
        parts.append("\nユーザー発言:")
        for m in sess["user_msgs"][:15]:
            parts.append(f"- {m[:150]}")

    if sess["assistant_msgs"]:
        parts.append("\nアシスタント応答:")
        for m in sess["assistant_msgs"][:10]:
            parts.append(f"- {m[:200]}")

    if sess["edits"]:
        parts.append("\nコード変更:")
        for e in sess["edits"][:15]:
            parts.append(f"- {e['file']}: `{e['old']}` → `{e['new']}`")

    if sess["writes"]:
        parts.append("\n新規作成ファイル:")
        for w in sess["writes"][:10]:
            parts.append(f"- {w}")

    input_text = "\n".join(parts)

    prompt = f"""以下のセッション情報を日報用に要約してください。
Markdownのみ出力。前後に説明やコードブロック記号を付けないでください。

重要なルール:
- 提供された情報のみで要約すること。不足があっても質問や追加情報の要求は絶対にしないこと。
- 情報が少ない場合は、わかる範囲で短く要約すること。
- 「情報が不足」「情報が不完全」「情報が必要」などの表現は使用禁止。

フォーマット（厳守）:

**概要:** 何をしたか1-2文で簡潔に

**変更:** （コード変更があれば。なければ省略）

| ファイル | 変更前 | 変更後 |
|---------|--------|--------|
| file.go | `old code` | `new code` |

**新規作成:** （あれば。なければ省略）
- `filename`

入力:
{input_text}"""

    try:
        env = {k: v for k, v in os.environ.items()
               if "CLAUDE" not in k.upper()}

        result = subprocess.run(
            [CLAUDE_CMD, "-p", "--model", "haiku", "--no-session-persistence"],
            input=prompt,
            capture_output=True,
            text=True,
            timeout=30,
            env=env,
        )
        output = result.stdout.strip()
        if output.startswith("```"):
            lines = output.split("\n")
            output = "\n".join(
                l for l in lines if not l.strip().startswith("```")
            )
        return output if output and len(output) > 20 else None
    except Exception as e:
        print(f"haiku要約失敗: {e}", file=sys.stderr)
        return None


def fallback_session(sess):
    """haiku が使えない場合のフォールバック"""
    lines = []

    if sess["user_msgs"]:
        lines.append("**主な作業:**")
        seen = set()
        for m in sess["user_msgs"][:8]:
            t = truncate(m, 120)
            if t not in seen:
                seen.add(t)
                lines.append(f"- {t}")
        lines.append("")

    if sess["edits"]:
        lines.append("**変更:**")
        lines.append("")
        lines.append("| ファイル | 変更前 | 変更後 |")
        lines.append("|---------|--------|--------|")
        for e in sess["edits"][:10]:
            lines.append(f"| {e['file']} | `{e['old']}` | `{e['new']}` |")
        lines.append("")

    if sess["writes"]:
        lines.append("**新規作成:**")
        for w in sess["writes"][:5]:
            lines.append(f"- `{w}`")
        lines.append("")

    return "\n".join(lines)


# ============================================================
# レポート生成
# ============================================================

def generate_report(target_date, use_haiku=True):
    project_paths = parse_history(target_date)
    sessions = get_sessions(target_date, project_paths)

    if not sessions:
        return None

    lines = [f"# {target_date} 日報", ""]

    # --- プロジェクト別セッション詳細 ---
    for project in sorted(sessions.keys()):
        session_list = sessions[project]
        merged = consolidate_sessions(session_list)
        if merged is None:
            continue

        lines.append(f"## [{merged['first_time']}] {project}")
        lines.append("")

        summary = None
        if use_haiku:
            summary = summarize_session(project, merged)

        if summary:
            lines.append(summary)
        else:
            lines.append(fallback_session(merged))

        lines.append("---")
        lines.append("")

    return "\n".join(lines)


def main():
    target_date = datetime.date.today()
    stdout_mode = "--stdout" in sys.argv
    no_haiku = "--no-haiku" in sys.argv
    args = [a for a in sys.argv[1:] if not a.startswith("--")]

    if args:
        try:
            target_date = datetime.date.fromisoformat(args[0])
        except ValueError:
            print(f"無効な日付: {args[0]}", file=sys.stderr)
            sys.exit(1)

    report = generate_report(target_date, use_haiku=not no_haiku)
    if report is None:
        print(f"{target_date}: データなし", file=sys.stderr)
        sys.exit(0)

    if stdout_mode:
        print(report)
    else:
        DAILY_DIR.mkdir(parents=True, exist_ok=True)
        report_file = DAILY_DIR / f"{target_date}.md"
        report_file.write_text(report + "\n", encoding="utf-8")
        print(f"日報生成完了: {report_file}", file=sys.stderr)


if __name__ == "__main__":
    main()
