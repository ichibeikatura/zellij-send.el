# zellij-send.el

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

`C-c C-a` でメニューを開き、`a` を押すと zellij のスクリーン内容をバッファに取得します。

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

## カスタマイズ

`zellij` の実行ファイルのパスを変更する場合：

```elisp
(setq zellij-send-executable "/usr/local/bin/zellij")
```

## 仕組み

- テキスト送信: `zellij action write-chars` でテキストを送り、`zellij action write 13`（CR）で Enter を送信
- 回答取得: `zellij action dump-screen` でペインの内容を一時ファイルに書き出し、ANSI エスケープを除去してバッファに表示

## ライセンス

GPL v3 以降。詳細は [LICENSE](LICENSE) を参照してください。
