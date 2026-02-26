#!/bin/zsh
# 日報自動生成（ハイブリッド版 v8）
# history.jsonl + session JSONL → haiku で要約 → 日報生成

SCRIPT_DIR="${0:A:h}"
LOG_DIR="$HOME/.claude/memory/logs"
mkdir -p "$LOG_DIR"

LOG_FILE="$LOG_DIR/daily-report-$(date +%Y%m%d_%H%M%S).log"

# 多重起動防止（ロックファイル）
LOCK_FILE="$HOME/.claude/memory/logs/daily-report.lock"

if [ -f "$LOCK_FILE" ]; then
    LOCK_PID=$(cat "$LOCK_FILE" 2>/dev/null)
    if [ -n "$LOCK_PID" ] && kill -0 "$LOCK_PID" 2>/dev/null; then
        echo "日報生成は既に実行中です (PID: $LOCK_PID)。スキップします。"
        exit 0
    else
        # プロセスが存在しない → 古いロックファイルを削除
        rm -f "$LOCK_FILE"
    fi
fi

# セッション終了後に実行されるため、ネスト検出の環境変数をクリア
unset CLAUDECODE CLAUDE_CODE_SESSION CLAUDE_CODE_ENTRY_POINT 2>/dev/null

# バックグラウンドで実行（セッション終了をブロックしない）
python3 "$SCRIPT_DIR/daily-report-gen.py" "$@" >> "$LOG_FILE" 2>&1 &
BG_PID=$!
echo "$BG_PID" > "$LOCK_FILE"
disown

echo "日報生成開始 (PID: $BG_PID)... ログ: $LOG_FILE"
