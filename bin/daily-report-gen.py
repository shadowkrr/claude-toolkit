#!/usr/bin/env python3
"""
日報生成スクリプト (ハイブリッド版)
- history.jsonl → タスク一覧（全セッション漏れなし）
- session JSONL → 変更詳細（Edit/Write の before/after）
"""

import json
import os
import sys
import datetime
from pathlib import Path
from collections import defaultdict

HOME = Path.home()
HISTORY_FILE = HOME / ".claude" / "history.jsonl"
PROJECTS_DIR = HOME / ".claude" / "projects"
DAILY_DIR = HOME / ".claude" / "memory" / "daily"


def parse_history(target_date):
    """history.jsonl から対象日のエントリを抽出"""
    entries = []
    project_paths = set()

    if not HISTORY_FILE.exists():
        return entries, project_paths

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

            display = entry.get("display", "")
            project_path = entry.get("project", "")
            project_name = os.path.basename(project_path) if project_path else ""

            if project_path:
                project_paths.add(project_path)

            entries.append({
                "time": ts.strftime("%H:%M"),
                "display": display,
                "project": project_name,
            })

    return entries, project_paths


def filter_tasks(entries):
    """タスク一覧用にノイズ除去 + 重複排除"""
    noise_words = {"exit", "終了", "commit", "確認", "削除", "mata"}
    seen = set()
    filtered = []
    for e in entries:
        text = e["display"]
        if text.startswith("[Pasted"):
            continue
        if len(text) <= 3:
            continue
        if len(text) > 200:
            continue
        if "\n" in text:
            continue
        text_stripped = text.strip().rstrip("。.!！")
        if text_stripped.lower() in noise_words:
            continue
        # 重複排除（同じプロジェクト・同じ内容）
        dedup_key = (e["project"], text)
        if dedup_key in seen:
            continue
        seen.add(dedup_key)
        filtered.append(e)
    return filtered


def escape_table(s):
    """Markdownテーブル用エスケープ"""
    return s.replace("|", "\\|").replace("\n", " ").replace("\r", "")


def truncate(s, max_len=60):
    """1行にtruncate"""
    if not s:
        return ""
    first_line = s.split("\n")[0].strip()
    first_line = escape_table(first_line)
    if len(first_line) > max_len:
        return first_line[:max_len] + "..."
    return first_line


def match_project(file_path, project_paths):
    """ファイルパスからプロジェクト名を特定（最長一致）"""
    best_match = ""
    best_name = ""
    for pp in project_paths:
        if file_path.startswith(pp) and len(pp) > len(best_match):
            best_match = pp
            best_name = os.path.basename(pp)
    if best_name:
        return best_name
    return os.path.basename(os.path.dirname(file_path))


def get_session_changes(target_date, project_paths):
    """セッションJSONLからEdit/Writeを抽出"""
    changes = defaultdict(list)

    if not PROJECTS_DIR.exists():
        return changes

    for project_dir in PROJECTS_DIR.iterdir():
        if not project_dir.is_dir():
            continue

        for jsonl_file in project_dir.glob("*.jsonl"):
            if "subagents" in str(jsonl_file):
                continue

            try:
                mtime = datetime.datetime.fromtimestamp(jsonl_file.stat().st_mtime)
                if mtime.date() != target_date:
                    continue
            except OSError:
                continue

            try:
                with open(jsonl_file, "r", encoding="utf-8") as f:
                    for line in f:
                        line = line.strip()
                        if not line:
                            continue
                        try:
                            entry = json.loads(line)
                        except json.JSONDecodeError:
                            continue

                        if entry.get("type") != "assistant":
                            continue

                        content = entry.get("message", {}).get("content", [])
                        if not isinstance(content, list):
                            continue

                        for block in content:
                            if block.get("type") != "tool_use":
                                continue

                            tool = block.get("name", "")
                            inp = block.get("input", {})

                            if tool == "Edit":
                                fp = inp.get("file_path", "")
                                if not fp:
                                    continue
                                proj = match_project(fp, project_paths)
                                changes[proj].append({
                                    "type": "edit",
                                    "file": os.path.basename(fp),
                                    "old": truncate(inp.get("old_string", "")),
                                    "new": truncate(inp.get("new_string", "")) or "(削除)",
                                })

                            elif tool == "Write":
                                fp = inp.get("file_path", "")
                                if not fp:
                                    continue
                                proj = match_project(fp, project_paths)
                                changes[proj].append({
                                    "type": "write",
                                    "file": os.path.basename(fp),
                                })
            except Exception:
                continue

    return changes


def dedupe(items):
    """重複除去 + 無意味な差分を除外"""
    seen = set()
    result = []
    for item in items:
        if item["type"] == "edit":
            # 変更前後が同じなら除外
            if item["old"] == item["new"]:
                continue
            key = (item["file"], item["old"], item["new"])
        else:
            key = ("write", item["file"])
        if key not in seen:
            seen.add(key)
            result.append(item)
    return result


def generate_report(target_date):
    entries, project_paths = parse_history(target_date)
    tasks = filter_tasks(entries)
    changes = get_session_changes(target_date, project_paths)

    if not tasks and not changes:
        return None

    lines = [f"# {target_date} 日報", ""]

    # --- タスク一覧 ---
    if tasks:
        lines.append("## タスク一覧")
        lines.append("")
        lines.append("| 時刻 | プロジェクト | 内容 |")
        lines.append("|------|-------------|------|")
        for t in tasks:
            display = escape_table(t["display"])[:100]
            lines.append(f"| {t['time']} | {t['project']} | {display} |")
        lines.append("")

    # --- 変更詳細 ---
    if changes:
        lines.append("## 変更詳細")
        lines.append("")
        for project in sorted(changes.keys()):
            items = dedupe(changes[project])
            edits = [i for i in items if i["type"] == "edit"]
            writes = [i for i in items if i["type"] == "write"]

            lines.append(f"### {project}")
            lines.append("")

            if edits:
                lines.append("| ファイル | 変更前 | 変更後 |")
                lines.append("|---------|--------|--------|")
                for e in edits:
                    old_d = f"`{e['old']}`" if e["old"] else ""
                    new_d = f"`{e['new']}`" if e["new"] != "(削除)" else "(削除)"
                    lines.append(f"| {e['file']} | {old_d} | {new_d} |")
                lines.append("")

            if writes:
                lines.append("**新規作成:**")
                for w in writes:
                    lines.append(f"- `{w['file']}`")
                lines.append("")

    return "\n".join(lines)


def main():
    target_date = datetime.date.today()
    stdout_mode = "--stdout" in sys.argv
    args = [a for a in sys.argv[1:] if not a.startswith("--")]

    if args:
        try:
            target_date = datetime.date.fromisoformat(args[0])
        except ValueError:
            print(f"無効な日付: {args[0]}", file=sys.stderr)
            sys.exit(1)

    report = generate_report(target_date)
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
