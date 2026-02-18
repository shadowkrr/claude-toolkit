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

### データソース（ハイブリッド）

| ソース | 用途 |
|--------|------|
| `history.jsonl` | タスク一覧（全セッション漏れなし） |
| `projects/*/*.jsonl` | 変更詳細（Edit/Write の before/after） |

### 出力形式

```markdown
# 2026-02-18 日報

## タスク一覧

| 時刻 | プロジェクト | 内容 |
|------|-------------|------|
| 09:15 | my-project | 認証バグを修正 |
| 14:00 | my-app | APIエンドポイント追加 |

## 変更詳細

### my-project

| ファイル | 変更前 | 変更後 |
|---------|--------|--------|
| auth.go | `if token == ""` | `if token == "" \|\| isExpired(token)` |

**新規作成:**
- `middleware.go`
```

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
- `claude` (Claude Code CLI)

## ライセンス

Private
