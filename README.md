# Claude Code Toolkit

Claude Code の日報自動生成とセッション管理ツール。

## ディレクトリ構成

```
~/.claude/
├── bin/
│   ├── cc                      # セッション選択ランチャー
│   ├── daily-report.sh         # 日報生成（SessionEnd hook）
│   └── daily-report-gen.py     # 日報生成ロジック
├── memory/
│   ├── daily/                  # 日報（YYYY-MM-DD.md）
│   └── logs/                   # 日報生成ログ
├── settings.json               # Claude Code 設定（hooks等）
└── .gitignore
```

## cc - セッション選択ランチャー

```bash
cc              # セッション選択メニュー（新規 or 継続）
cc "タスク"     # タスクを指定して起動
cc -f task.md   # ファイルからタスクを読み込み
echo "x" | cc   # パイプ入力
```

## 日報自動生成

### 仕組み（ハイブリッド v8）

1. `history.jsonl` から対象日のプロジェクトパスを解決
2. `projects/*/*.jsonl` からセッションの会話・変更を抽出
3. プロジェクト単位で統合し、Claude haiku で要約
4. Markdown 日報として `memory/daily/YYYY-MM-DD.md` に出力

| ソース | 用途 |
|--------|------|
| `history.jsonl` | プロジェクトパス解決 |
| `projects/*/*.jsonl` | 会話 + 変更詳細 |

### 特徴

- **多重起動防止**: ロックファイル（PIDベース）で排他制御
- **ノイズ除外**: go-build, /var/folders 等の自動生成パスをフィルタ
- **環境変数クリア**: SessionEnd hook 実行時のネスト検出を回避

### 自動実行

SessionEnd hook でセッション終了時にバックグラウンド実行。

```json
{
  "hooks": {
    "SessionEnd": [{
      "hooks": [{
        "type": "command",
        "command": "$HOME/.claude/bin/daily-report.sh"
      }]
    }]
  }
}
```

手動実行: `~/.claude/bin/daily-report.sh [YYYY-MM-DD]`

## 依存関係

- `python3`
- `claude` (Claude Code CLI / haiku で要約に使用)

## ライセンス

Private
