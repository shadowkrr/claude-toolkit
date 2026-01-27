#!/bin/zsh
# 日報自動生成スクリプト v6
# 直前のセッションを Claude (haiku) で要約して日報に追記
# 非同期実行でセッション終了をブロックしない

DAILY_DIR="$HOME/.claude/memory/daily"
PROJECTS_DIR="$HOME/.claude/projects"
LOG_DIR="$HOME/.claude/memory/logs"
TODAY=$(date +%Y-%m-%d)
NOW=$(date +%H:%M)
REPORT_FILE="$DAILY_DIR/$TODAY.md"
CLAUDE_CMD="${CLAUDE_CMD:-claude}"

mkdir -p "$DAILY_DIR" "$LOG_DIR"

# 非同期実行用の関数
generate_summary() {
    local LATEST_JSONL="$1"
    local SESSION_ID="$2"
    local PROJECT_NAME="$3"
    local NOW="$4"
    local REPORT_FILE="$5"
    local LOG_FILE="$LOG_DIR/daily-report-$(date +%Y%m%d_%H%M%S).log"

    exec > "$LOG_FILE" 2>&1

    echo "開始: $(date)"
    echo "セッション: $SESSION_ID ($PROJECT_NAME)"

    # セッションの内容を抽出
    SESSION_SUMMARY=$(python3 - "$LATEST_JSONL" << 'PYTHON_SCRIPT'
import json
import sys
import os

jsonl_file = sys.argv[1]

edits = []
writes = []
user_inputs = []

with open(jsonl_file, 'r', encoding='utf-8') as f:
    for line in f:
        line = line.strip()
        if not line:
            continue
        try:
            entry = json.loads(line)
            entry_type = entry.get('type', '')

            if entry_type == 'user':
                message = entry.get('message', {})
                content = message.get('content', [])
                if isinstance(content, list):
                    for block in content:
                        if block.get('type') == 'text':
                            text = block.get('text', '')
                            # 短い指示のみ（長文やペーストは除外）
                            if text and 3 < len(text) < 300 and '\n' not in text:
                                if not text.startswith('[Pasted'):
                                    user_inputs.append(text)

            elif entry_type == 'assistant':
                message = entry.get('message', {})
                content = message.get('content', [])
                if isinstance(content, list):
                    for block in content:
                        if block.get('type') == 'tool_use':
                            tool_name = block.get('name', '')
                            tool_input = block.get('input', {})

                            if tool_name == 'Edit':
                                file_path = tool_input.get('file_path', '')
                                old_str = tool_input.get('old_string', '')
                                new_str = tool_input.get('new_string', '')
                                if file_path and (old_str or new_str):
                                    edits.append({
                                        'file': os.path.basename(file_path),
                                        'old': old_str[:200] if old_str else '(新規追加)',
                                        'new': new_str[:200] if new_str else '(削除)'
                                    })

                            elif tool_name == 'Write':
                                file_path = tool_input.get('file_path', '')
                                content = tool_input.get('content', '')
                                if file_path:
                                    writes.append({
                                        'file': os.path.basename(file_path),
                                        'preview': content[:150] if content else ''
                                    })
        except json.JSONDecodeError:
            continue

# 出力を構築（コンパクトに）
output = []

if user_inputs:
    output.append("ユーザー指示:")
    for inp in list(dict.fromkeys(user_inputs))[:5]:  # 重複除去、最大5件
        output.append(f"- {inp[:100]}")

if edits:
    output.append("\n編集:")
    for edit in edits[:8]:
        output.append(f"[{edit['file']}] {edit['old'][:80]} → {edit['new'][:80]}")

if writes:
    output.append("\n新規作成:")
    for w in writes[:5]:
        output.append(f"- {w['file']}")

print('\n'.join(output))
PYTHON_SCRIPT
)

    if [ -z "$SESSION_SUMMARY" ]; then
        echo "セッションに有効な変更なし"
        exit 0
    fi

    echo "抽出完了、Claude (haiku) で要約中..."

    # Claude haiku で要約（高速）
    SUMMARY=$(cat << EOF | "$CLAUDE_CMD" -p --model haiku 2>&1
あなたは日報生成ツールです。入力を以下のフォーマットに変換してください。
出力はMarkdownコードブロックのみ。前後に説明や会話を一切付けないでください。

出力フォーマット（これ以外は出力禁止）:
## [$NOW] $PROJECT_NAME

### 変更内容
- **修正前**: (変更前の状態を1文で)
- **修正後**: (変更後の状態を1文で)

### 概要
(何を・なぜ変更したかを1-2文で)

---

入力:
$SESSION_SUMMARY
EOF
)
    # コードブロックのマーカーを除去
    SUMMARY=$(echo "$SUMMARY" | sed '/^```/d')

    if [ -z "$SUMMARY" ]; then
        echo "要約生成失敗"
        exit 1
    fi

    # 日報に追記
    echo "" >> "$REPORT_FILE"
    echo "$SUMMARY" >> "$REPORT_FILE"

    echo "完了: $(date)"
    echo "追記先: $REPORT_FILE"
}

# === メイン処理 ===

# 日報ファイルがなければヘッダーを作成
if [ ! -f "$REPORT_FILE" ]; then
    echo "# $TODAY 日報" > "$REPORT_FILE"
    echo "" >> "$REPORT_FILE"
fi

# 直前のセッション（最新の jsonl）を特定
LATEST_JSONL=$(find "$PROJECTS_DIR" -name "*.jsonl" -type f -mmin -60 2>/dev/null | xargs ls -t 2>/dev/null | head -1)

if [ -z "$LATEST_JSONL" ]; then
    echo "直近60分以内のセッションが見つかりません"
    exit 0
fi

SESSION_ID=$(basename "$LATEST_JSONL" .jsonl)
PROJECT_DIR=$(dirname "$LATEST_JSONL")
PROJECT_NAME=$(basename "$PROJECT_DIR" | sed 's/-/\//g' | xargs basename 2>/dev/null || basename "$PROJECT_DIR")

echo "日報生成を開始: $SESSION_ID ($PROJECT_NAME)"

# 非同期で実行（バックグラウンド）
generate_summary "$LATEST_JSONL" "$SESSION_ID" "$PROJECT_NAME" "$NOW" "$REPORT_FILE" &
disown

echo "バックグラウンドで処理中... ログ: $LOG_DIR/"
