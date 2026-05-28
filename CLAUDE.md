# CLAUDE.md

このファイルは、このリポジトリでコードを扱う際の Claude Code へのガイダンスです。

## プロジェクト概要

Emacs から zellij セッション上の AI エージェント（主に Claude Code）に日本語テキストを送る Emacs パッケージ。
`M-x zellij-send` でセッションを選択し、専用バッファ（`*ai-セッション名*`）で入力・確認・返信を行う。
このパッケージは 3 つの要素で成り立つ:
- *ai-SESSION* バッファ（黒板）: ユーザーが入力するための主インターフェース
- eat バッファ: zellij attach <session> を実行する。理由は (a) Claude Code の応答を生で確認できる、(b) zellij セッションは attach されたクライアントが存在しないと write-chars が期待通り動かないため、eat による attach が機能上必須
- zellij セッション本体: バックグラウンドで動く実体
zellij-send を呼び出すと、[New] か既存セッションかに関係なく、黒板バッファと eat バッファの両方が開くこと。eat 側で attach が確立してから write-chars 系のコマンドを送ること。

## 開発環境

- Emacs 31、`lexical-binding: t`
- 依存: `transient` 0.4以上（必須）、`markdown-mode`（オプション）
- パッケージ管理: elpaca 想定

## ファイル構造

| ファイル | 役割 |
|---|---|
| `zellij-send.el` | パッケージ本体（全機能） |
| `CLAUDE.md` | 本ドキュメント |
| `README.md` | ユーザー向けドキュメント |
| `LICENSE` | GPL v3 |

## アーキテクチャ

```
Emacs バッファ (*ai-SESSION*)
  ├─ 入力: C-c C-c → zellij-send--send → zellij action write-chars + write 13
  ├─ 表示: zellij action dump-screen → tmpfile 経由 → バッファ更新（非同期 / make-process + sentinel）
  ├─ 自動受信: Stop フック (emacsclient) または ポーリング (run-at-time)
  └─ UI: transient メニュー (C-c C-a)
```

### zellij コマンドの呼び出し方針

- `call-process` または `start-process` を使い、**シェル文字列結合は行わない**
- 引数は個別の文字列として渡す（コマンドインジェクション防止）
- `dump-screen` は **`make-process` + sentinel で非同期化**している（tmpfile 経由）:
  ```elisp
  (zellij-send--dump-screen-async session callback)
  ```
  ポーリングは 2 秒ごとに再帰的に走るため、同期 `call-process` のままだと eat の attach クライアント（同一シングルスレッド内で pty I/O を処理）と相互待ちになり Emacs がフリーズする。これを避けるために非同期化している。コールバックは要求元バッファをカレントにした状態で呼ばれる。

### Enter キー送信の注意点

`write-chars` に `\n` を含めても Enter にならない。必ず 2 ステップに分ける:
```
zellij action write-chars "テキスト"
zellij action write 13    ; 0x0D = CR = Enter
```

### ANSI エスケープの除去

`list-sessions` / `dump-screen` の出力にはカラーコードが含まれる。`zellij-send--strip-ansi` で 2 段階除去:
```elisp
(replace-regexp-in-string "\033\\[[0-9;?]*[A-Za-z]" "" result)  ; CSI
(replace-regexp-in-string "\033." "" result)                      ; その他 ESC
```

## コーディング規約

### 命名規則

| パターン | 用途 |
|---|---|
| `zellij-send-FOO` | ユーザー向け `M-x` コマンド、`defcustom`、`defvar` |
| `zellij-send--FOO` | 内部関数・変数（公開しない） |
| `zellij-send--FOO` (defvar-local) | バッファローカル状態 |

### defcustom の流儀

```elisp
(defcustom zellij-send-FOO default-value
  "日本語の説明。"
  :type 'string   ; または 'number 'boolean など
  :group 'zellij-send)
```

### バッファローカル変数

`defvar-local` で宣言し、`setq-local` で設定する:
```elisp
(defvar-local zellij-send--session nil "...")
;; 設定時:
(setq-local zellij-send--session session)
```

### インタラクティブ関数のガード

バッファ外から呼ばれた場合は `user-error` で即終了:
```elisp
(defun zellij-send-FOO ()
  "説明。"
  (interactive)
  (unless zellij-send--session
    (user-error "zellij-send バッファ外では使えません"))
  ...)
```

### エラーメッセージ・メッセージ

日本語で書く。`user-error` はユーザー操作ミス、`error` はプログラムエラー。

### セクション構成（zellij-send.el の順序）

```
;;; defgroup / defcustom
;;; defvar-local
;;; セッション一覧の取得
;;; バッファ管理
;;; 送信
;;; スクリーンダンプ
;;; プロンプト検出・ハイライト
;;; バッファ更新（共通処理）
;;; 通知
;;; ポーリング
;;; 選択肢の即送信
;;; Claude Code コマンド
;;; インタラクティブコマンド
;;; 返信バッファ
;;; Transient メニュー
;;; メジャーモード
;;; Stop フックハンドラ
;;; エントリポイント
```

## バッファの設計思想

`*ai-SESSION*` バッファは「黒板」として使う:
- 固定ヘッダなし（バッファ全体がコンテンツ）
- セッション情報は `header-line-format` に表示
- ユーザーが編集中（`buffer-modified-p` = t）はポーリングで上書きしない
- `zellij-send--user-cleared` フラグ: ユーザーが意図してクリアした場合に Stop フック・ポーリングの上書きを防ぐ

## 自動受信（Stop フック）

Claude Code 停止時に `~/.claude/hooks/stop-zellij-send.sh` → `emacsclient` → `zellij-send--on-claude-stop` を経由してバッファを更新する。`;;;###autoload` が必須。

## 新規セッション作成

`zellij-send--create-new-session` の起動コマンド:
```
zellij --session NAME options --default-cwd DIR
```
`start-process` で非同期・detached 起動（Emacs をブロックしない）。起動後 `sleep-for 0.5` してからコマンドを送信。
