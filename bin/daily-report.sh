#!/bin/zsh
# 日報自動生成スクリプト v4
# プロジェクト別・セッションID別に整理

set -e

DAILY_DIR="$HOME/.claude/memory/daily"
HISTORY_FILE="$HOME/.claude/history.jsonl"
PROJECTS_DIR="$HOME/.claude/projects"
TODAY=$(date +%Y-%m-%d)
REPORT_FILE="$DAILY_DIR/$TODAY.md"

mkdir -p "$DAILY_DIR"

if [ ! -f "$HISTORY_FILE" ]; then
    echo "history.jsonl が見つかりません"
    exit 0
fi

TODAY_START=$(date -j -f "%Y-%m-%d %H:%M:%S" "$TODAY 00:00:00" "+%s")000
TODAY_END=$(date -j -f "%Y-%m-%d %H:%M:%S" "$TODAY 23:59:59" "+%s")999

MEMOS_DB="$HOME/.claude/db/memos.sqlite"

python3 - "$HISTORY_FILE" "$PROJECTS_DIR" "$TODAY_START" "$TODAY_END" "$REPORT_FILE" "$TODAY" "$MEMOS_DB" << 'PYTHON_SCRIPT'
import json
import sys
import os
import sqlite3
from datetime import datetime
from collections import defaultdict
from pathlib import Path
from glob import glob

history_file = sys.argv[1]
projects_dir = sys.argv[2]
today_start = int(sys.argv[3])
today_end = int(sys.argv[4])
report_file = sys.argv[5]
today_str = sys.argv[6]
memos_db = sys.argv[7]

def extract_project_name(project_path):
    if not project_path:
        return 'unknown'
    name = Path(project_path).name
    # .claude -> claude に正規化
    if name.startswith('.'):
        name = name[1:]
    return name

def should_include(text):
    if not text:
        return False
    if text.startswith('[Pasted text'):
        return False
    if len(text) > 150:
        return False
    if '\n' in text:
        return False
    if len(text) <= 3:
        return False
    if text.isalpha() and text.islower():
        return False
    return True

# === memos.sqlite から当日の学びメモを読み込み ===
today_memos = []
if os.path.exists(memos_db):
    try:
        conn = sqlite3.connect(memos_db)
        conn.row_factory = sqlite3.Row
        cursor = conn.cursor()
        # 当日のメモを取得（ts が ISO8601 形式なので LIKE で日付マッチ）
        cursor.execute("""
            SELECT id, ts, project, tags, problem, fix, takeaway, context
            FROM memos
            WHERE ts LIKE ?
            ORDER BY ts
        """, (f"{today_str}%",))
        for row in cursor.fetchall():
            today_memos.append(dict(row))
        conn.close()
    except Exception as e:
        pass  # DB エラーは無視

# === history.jsonl からユーザー入力を読み込み ===
user_inputs = []
with open(history_file, 'r', encoding='utf-8') as f:
    for line in f:
        line = line.strip()
        if not line:
            continue
        try:
            entry = json.loads(line)
            ts = entry.get('timestamp', 0)
            if today_start <= ts <= today_end:
                user_inputs.append(entry)
        except json.JSONDecodeError:
            continue

# === projects/*.jsonl からセッション情報を読み込み ===
sessions = {}  # session_id -> session_data

for project_dir in glob(f"{projects_dir}/*"):
    if not os.path.isdir(project_dir):
        continue

    project_encoded = os.path.basename(project_dir)
    # デコード: -Users-taiki-kageyama-Work-project-foo -> /Users/taiki/kageyama/Work/project/foo
    project_path = '/' + project_encoded.replace('-', '/')
    project_name = Path(project_path).name

    for jsonl_file in glob(f"{project_dir}/*.jsonl"):
        try:
            mtime = os.path.getmtime(jsonl_file) * 1000
            if not (today_start <= mtime <= today_end):
                continue

            session_id = Path(jsonl_file).stem  # ファイル名 = セッションID
            session = {
                'id': session_id[:8],  # 短縮ID
                'full_id': session_id,
                'project': project_name,
                'project_path': project_path,
                'edits': [],
                'commands': [],  # {'id': tool_use_id, 'cmd': command, 'result': result}
                'responses': [],  # Claude の返答テキスト
                'first_ts': None,
                'last_ts': None
            }

            # tool_use_id -> command のマッピング
            pending_commands = {}

            with open(jsonl_file, 'r', encoding='utf-8') as f:
                for line in f:
                    line = line.strip()
                    if not line:
                        continue
                    try:
                        entry = json.loads(line)
                        entry_type = entry.get('type', '')
                        ts_str = entry.get('timestamp')

                        # タイムスタンプを記録（UTCからローカル時間に変換）
                        if ts_str:
                            try:
                                from datetime import timezone
                                ts_utc = datetime.fromisoformat(ts_str.replace('Z', '+00:00'))
                                ts_local = ts_utc.astimezone().replace(tzinfo=None)
                                if session['first_ts'] is None or ts_local < session['first_ts']:
                                    session['first_ts'] = ts_local
                                if session['last_ts'] is None or ts_local > session['last_ts']:
                                    session['last_ts'] = ts_local
                            except:
                                pass

                        # assistant タイプからツール使用とテキスト返答を解析
                        if entry_type == 'assistant':
                            message = entry.get('message', {})
                            content = message.get('content', [])
                            if isinstance(content, list):
                                for block in content:
                                    block_type = block.get('type', '')

                                    # テキスト返答を保存
                                    if block_type == 'text':
                                        text = block.get('text', '')
                                        if text and len(text) > 10:  # 短すぎるものは除外
                                            session['responses'].append(text)

                                    # ツール使用を解析
                                    elif block_type == 'tool_use':
                                        tool_name = block.get('name', '')
                                        tool_input = block.get('input', {})
                                        tool_id = block.get('id', '')

                                        if tool_name in ['Edit', 'Write']:
                                            file_path = tool_input.get('file_path', '')
                                            if file_path:
                                                filename = os.path.basename(file_path)
                                                if filename not in session['edits']:
                                                    session['edits'].append(filename)

                                        elif tool_name == 'Bash':
                                            cmd = tool_input.get('command', '')
                                            desc = tool_input.get('description', '')
                                            if cmd:
                                                cmd_info = {
                                                    'id': tool_id,
                                                    'cmd': cmd[:80],
                                                    'desc': desc,
                                                    'result': None
                                                }
                                                session['commands'].append(cmd_info)
                                                if tool_id:
                                                    pending_commands[tool_id] = cmd_info

                        # user タイプから tool_result を解析
                        elif entry_type == 'user':
                            message = entry.get('message', {})
                            content = message.get('content', [])
                            if isinstance(content, list):
                                for block in content:
                                    if block.get('type') == 'tool_result':
                                        tool_id = block.get('tool_use_id', '')
                                        result = block.get('content', '')
                                        if tool_id and tool_id in pending_commands:
                                            # 結果を短縮して保存
                                            if isinstance(result, str):
                                                result_short = result[:150].split('\n')[0]
                                                pending_commands[tool_id]['result'] = result_short

                    except json.JSONDecodeError:
                        continue

            if session['edits'] or session['commands'] or session['first_ts']:
                sessions[session_id] = session

        except Exception as e:
            continue

# === ユーザー入力をセッションに紐付け ===
# history.jsonl のタイムスタンプに最も近いセッションに割り当て
from datetime import timedelta

for entry in user_inputs:
    project_path = entry.get('project', '')
    project_name = extract_project_name(project_path)
    ts_ms = entry.get('timestamp', 0)
    ts = datetime.fromtimestamp(ts_ms / 1000)

    # 同じプロジェクトで時間が最も近いセッションを探す
    best_session = None
    best_distance = timedelta(hours=24)  # 最大距離

    for sid, session in sessions.items():
        if session['project'] != project_name:
            continue
        if not session['first_ts'] or not session['last_ts']:
            continue

        start = session['first_ts']
        end = session['last_ts']

        # 時間範囲内ならその中央からの距離、範囲外なら端からの距離
        if start <= ts <= end:
            # 範囲内：セッション中央からの距離
            mid = start + (end - start) / 2
            distance = abs(ts - mid)
        elif ts < start:
            distance = start - ts
        else:
            distance = ts - end

        # より近いセッションがあれば更新
        if distance < best_distance:
            best_distance = distance
            best_session = session

    # 1時間以内のセッションにのみ紐付け
    if best_session and best_distance < timedelta(hours=1):
        if 'inputs' not in best_session:
            best_session['inputs'] = []
        best_session['inputs'].append(entry)

# === プロジェクト別にセッションをグループ化 ===
projects = defaultdict(list)
for session in sessions.values():
    projects[session['project']].append(session)

# セッションを時間順にソート
for project_name in projects:
    projects[project_name].sort(key=lambda s: s['first_ts'] or datetime.min.replace(tzinfo=None))

# === 日報を生成 ===
output = []
output.append(f"# {today_str} 日報")
output.append("")

# 概要
total_sessions = len(sessions)
total_edits = sum(len(s['edits']) for s in sessions.values())
total_commands = sum(len(s['commands']) for s in sessions.values())
total_inputs = len(user_inputs)

if user_inputs:
    first_ts = min(e['timestamp'] for e in user_inputs)
    last_ts = max(e['timestamp'] for e in user_inputs)
    first_time = datetime.fromtimestamp(first_ts / 1000).strftime('%H:%M')
    last_time = datetime.fromtimestamp(last_ts / 1000).strftime('%H:%M')
    duration_mins = (last_ts - first_ts) // 60000
else:
    first_time = last_time = "00:00"
    duration_mins = 0

output.append("## 概要")
output.append("")
output.append(f"- **プロジェクト数**: {len(projects)}")
output.append(f"- **セッション数**: {total_sessions}")
output.append(f"- **タスク数**: {total_inputs}")
output.append(f"- **編集ファイル**: {total_edits}件")
output.append(f"- **コマンド実行**: {total_commands}件")
output.append(f"- **作業時間**: {first_time} 〜 {last_time} ({duration_mins}分)")
if today_memos:
    output.append(f"- **学びメモ**: {len(today_memos)}件")
output.append("")

# 今日の学び（memos.sqlite から）
if today_memos:
    output.append("## 今日の学び")
    output.append("")
    for memo in today_memos:
        tags = memo.get('tags', '')
        problem = memo.get('problem', '')
        fix = memo.get('fix', '')
        takeaway = memo.get('takeaway', '')
        project = memo.get('project', '')

        output.append(f"### {tags or 'メモ'}")
        if project:
            output.append(f"**プロジェクト**: {project}")
        output.append("")

        if problem:
            output.append("**問題:**")
            output.append(f"> {problem[:300]}")
            output.append("")

        if fix:
            output.append("**解決:**")
            output.append(f"> {fix[:300]}")
            output.append("")

        if takeaway:
            output.append("**次回への教訓:**")
            output.append(f"> {takeaway[:300]}")
            output.append("")

        output.append("---")
        output.append("")

# 成果サマリー
output.append("## 成果サマリー")
output.append("")
for project_name, project_sessions in sorted(projects.items()):
    all_edits = set()
    all_inputs = []
    for s in project_sessions:
        all_edits.update(s['edits'])
        all_inputs.extend(s.get('inputs', []))

    if not all_edits and not all_inputs:
        continue

    output.append(f"### {project_name}")
    output.append(f"セッション: {len(project_sessions)}件")

    if all_edits:
        output.append(f"- 📝 編集: {', '.join(sorted(all_edits))}")

    filtered_inputs = [e for e in all_inputs if should_include(e.get('display', ''))]
    if filtered_inputs:
        shown = filtered_inputs[:3]
        for e in shown:
            display = e.get('display', '')[:80]
            ts = datetime.fromtimestamp(e['timestamp'] / 1000).strftime('%H:%M')
            output.append(f"- [{ts}] {display}")

    output.append("")

# 詳細（プロジェクト別・セッション別）
output.append("## 詳細")
output.append("")

for project_name, project_sessions in sorted(projects.items()):
    output.append(f"## {project_name}")
    output.append("")

    for session in project_sessions:
        # セッション時間
        if session['first_ts']:
            s_start = session['first_ts'].strftime('%H:%M')
            s_end = session['last_ts'].strftime('%H:%M') if session['last_ts'] else s_start
        else:
            s_start = s_end = "??:??"

        output.append(f"### セッション {session['id']} ({s_start}〜{s_end})")
        output.append("")

        # セッション成果サマリー（最後の返答から抽出）
        responses = session.get('responses', [])
        if responses and (session['edits'] or session['commands']):
            # 成果を示すキーワード（優先度付き）
            strong_keywords = ['完了しました', '修正しました', '追加しました', '更新しました', '作成しました',
                              '実装しました', '変更しました', '改善しました', '生成しました', 'を編集', 'を追加',
                              '以下の変更', '以下の修正', 'が完了', '成功']
            # 除外するパターン
            exclude_patterns = ['お手伝い', 'ください', '何を', 'どのような', '例えば', '具体的な']

            summary_text = None
            # 最後から探す
            for resp in reversed(responses[-15:]):
                # 除外パターンを含むものはスキップ
                if any(ex in resp for ex in exclude_patterns):
                    continue
                # 成果キーワードを含む短めの文を探す
                if any(kw in resp for kw in strong_keywords) and 20 < len(resp) < 400:
                    summary_text = resp
                    break

            if summary_text:
                output.append("**成果:**")
                # 最初の2文を抽出
                sentences = summary_text.replace('\n', ' ').split('。')
                summary_lines = '。'.join(sentences[:2])
                if len(summary_lines) > 200:
                    summary_lines = summary_lines[:200] + '...'
                output.append(f"> {summary_lines}")
                output.append("")

        # ユーザー入力
        inputs = session.get('inputs', [])
        filtered = [e for e in inputs if should_include(e.get('display', ''))]
        if filtered:
            output.append("**タスク:**")
            for entry in filtered:
                display = entry.get('display', '')
                ts = datetime.fromtimestamp(entry['timestamp'] / 1000).strftime('%H:%M')
                output.append(f"- [{ts}] {display}")
            output.append("")

        # 編集ファイル
        if session['edits']:
            output.append("**編集したファイル:**")
            for f in session['edits']:
                output.append(f"- `{f}`")
            output.append("")

        # コマンド実行
        if session['commands']:
            output.append("**実行したコマンド:**")
            for cmd_info in session['commands'][:15]:
                cmd = cmd_info['cmd']
                desc = cmd_info.get('desc', '')
                result = cmd_info.get('result', '')

                # 説明があれば説明を優先、なければコマンドを表示
                if desc:
                    output.append(f"- {desc}")
                    output.append(f"  ```{cmd}```")
                else:
                    output.append(f"- `{cmd}`")

                # 結果があれば表示
                if result:
                    output.append(f"  → {result}")

            if len(session['commands']) > 15:
                output.append(f"- ... 他 {len(session['commands']) - 15} 件")
            output.append("")

        output.append("---")
        output.append("")

# ファイルに書き出し
with open(report_file, 'w', encoding='utf-8') as f:
    f.write('\n'.join(output))

print(f"日報を生成しました: {report_file}")
print(f"  プロジェクト: {len(projects)}件")
print(f"  セッション: {total_sessions}件")
print(f"  タスク: {total_inputs}件")
print(f"  編集ファイル: {total_edits}件")
print(f"  コマンド: {total_commands}件")
PYTHON_SCRIPT
