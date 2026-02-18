#!/bin/zsh
# 日報自動生成（ハイブリッド版 v7）
# history.jsonl + session JSONL から日報を生成
# haiku 不要・セッション漏れなし

SCRIPT_DIR="${0:A:h}"
LOG_DIR="$HOME/.claude/memory/logs"
mkdir -p "$LOG_DIR"

LOG_FILE="$LOG_DIR/daily-report-$(date +%Y%m%d_%H%M%S).log"

# バックグラウンドで実行（セッション終了をブロックしない）
python3 "$SCRIPT_DIR/daily-report-gen.py" "$@" >> "$LOG_FILE" 2>&1 &
disown

echo "日報生成開始... ログ: $LOG_FILE"
