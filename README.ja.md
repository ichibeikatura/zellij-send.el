# zellij-send.el

[English](README.md) | 日本語

Emacs から [zellij](https://zellij.dev/) セッションの AI エージェント（Claude Code など）にテキストを送る Emacs 拡張です。

## 概要

`*ai-セッション名*` バッファを黒板として使い、テキストを書いて送信・AI の回答を取得・クリアを繰り返すシンプルなワークフローを提供します。

![Screen](Screen.png)

```
┌──────────────────────────────────────┐
│  Emacs: *ai-mysession*                │
│  ──────────────────────────────────  │
│  このコードの意図を説明して          │
│                                      │
│  C-c C-c → 送信 → バッファクリア     │
│  C-c C-a → メニュー                  │
└──────────────────────────────────────┘
         │ zellij action write-chars
         ▼
┌──────────────────────────────────────┐
│  zellij: mysession                   │
│  Claude Code が回答中...             │
└──────────────────────────────────────┘
```

## 必要環境

- Emacs 28 以上（`transient` 内蔵）
- [zellij](https://zellij.dev/) がインストール済みで `$PATH` に通っていること
- [`markdown-mode`](https://github.com/jrblevin/markdown-mode)（オプション）：インストール済みの場合、マークダウン装飾が有効になります

## インストール

### 手動

`zellij-send.el` をロードパスに置き、`init.el` に追加します：

```elisp
(add-to-list 'load-path "/path/to/zellij-send")
(require 'zellij-send)
```

### use-package + elpaca（推奨）

```elisp
(use-package zellij-send
  :ensure (zellij-send
           :url "https://github.com/ichibeikatura/zellij-send.el"))
```

### 手動 use-package

```elisp
(use-package zellij-send
  :load-path "/path/to/zellij-send")
```

## 使い方

### 1. セッションを開く

```
M-x zellij-send
```

起動中の zellij セッション一覧が表示されます。選択すると `*ai-セッション名*` バッファが開きます。

### 2. テキストを送信

バッファにテキストを書いて `C-c C-c` で送信します。送信後バッファは自動的にクリアされます。

### 3. AI の回答を確認

Claude Code が回答を終えると、`*ai-セッション名*` バッファが**自動的に更新**されます。

手動で取得する場合は `C-c C-a` でメニューを開き、`a` を押します。

## キーバインド

`*ai-セッション名*` バッファ内で使えるキーバインドです。

| キー      | 動作                                   |
|-----------|----------------------------------------|
| `C-c C-c` | テキストを送信（バッファはクリア）     |
| `C-c C-a` | メニューを開く                         |

### メニュー（`C-c C-a`）

| キー | 動作                                               |
|------|----------------------------------------------------|
| `a`  | AI の回答を表示（zellij スクリーンをダンプ）       |
| `c`  | バッファの内容をクリア                             |
| `q`  | `/exit` を送信してセッションを終了・バッファを閉じる |
| `e`  | 返信バッファを開く（AI の回答を読みながら返信）    |

### 返信バッファ（`C-c C-a` → `e`）

`*zellij-reply-セッション名*` バッファが開きます。AI の回答を `*ai-セッション名*` バッファで読みながら、返信を別バッファで書けます。

| キー      | 動作                                    |
|-----------|-----------------------------------------|
| `C-c C-c` | テキストを送信してバッファを閉じる      |

送信後は元のウィンドウ構成に自動的に戻ります。

### 選択肢プロンプトへの即応答

Claude Code が番号付き選択肢（`❯ 1.` 形式）を表示すると、`*ai-セッション名*` バッファが自動更新されて選択肢がハイライトされます。

| キー | 動作                  |
|------|-----------------------|
| `1`  | 選択肢 1 を即送信     |
| `2`  | 選択肢 2 を即送信     |
| `3`  | 選択肢 3 を即送信     |

プロンプトが表示されていない場合は通常の数字入力として機能します。

## カスタマイズ

`zellij` の実行ファイルのパスを変更する場合：

```elisp
(setq zellij-send-executable "/usr/local/bin/zellij")
```

## 自動受信のセットアップ（Claude Code Stop フック）

Claude Code の回答完了を Emacs に自動通知する設定です。

この機能を使うには Emacs server が起動している必要があります（`(server-start)` または `emacs --daemon`）。

### 1. フックスクリプトを作成

```sh
mkdir -p ~/.claude/hooks
cat > ~/.claude/hooks/stop-zellij-send.sh << 'EOF'
#!/bin/sh
emacsclient -e "(zellij-send--on-claude-stop)" 2>/dev/null || true
EOF
chmod +x ~/.claude/hooks/stop-zellij-send.sh
```

### 2. Claude Code の設定ファイルを作成

`~/.claude/settings.json`（Claude Code のバージョンによってパスや形式が異なる場合があります）:

```json
{
  "hooks": {
    "Stop": [
      {
        "hooks": [
          {
            "type": "command",
            "command": "~/.claude/hooks/stop-zellij-send.sh"
          }
        ]
      }
    ]
  }
}
```

これで Claude Code が回答を終えるたびに `*ai-セッション名*` バッファが自動更新されます。

## トラブルシューティング

**「zellij セッションが見つかりません」と表示される**
- zellij が起動していることを確認してください。
- `zellij list-sessions` をターミナルで実行して出力があるか確認してください。
- `zellij-send-executable` に正しいパスが設定されているか確認してください（`M-x describe-variable RET zellij-send-executable`）。

**自動受信が動かない（バッファが更新されない）**
- Emacs server が起動しているか確認してください（`M-x server-start` または `emacs --daemon`）。
- `emacsclient -e t` をターミナルで実行して接続できるか確認してください。
- `~/.claude/hooks/stop-zellij-send.sh` に実行権限があるか確認してください（`chmod +x`）。

**日本語が文字化けする / 送信できない**
- `zellij action write-chars` は UTF-8 を前提としています。ターミナルのエンコーディングが UTF-8 になっているか確認してください。

## 仕組み

- テキスト送信: `zellij action write-chars` でテキストを送り、`zellij action write 13`（CR）で Enter を送信
- 回答取得: `zellij action dump-screen` でペインの内容を一時ファイルに書き出し、ANSI エスケープを除去してバッファに表示
- 自動受信（Stop フック）: Claude Code の Stop フック → `emacsclient` → `zellij-send--on-claude-stop` → 全 zellij-send バッファを更新
- ポーリング: `zellij-send-poll-interval`（デフォルト 2 秒）間隔でスクリーン内容を取得・差分更新。ユーザーが入力中（`buffer-modified-p`）は更新しない
- 返信バッファ: `pop-to-buffer` で別ウィンドウに開き、送信後は `set-window-configuration` でウィンドウ構成を復元

## ライセンス

GPL v3 以降。詳細は [LICENSE](LICENSE) を参照してください。
