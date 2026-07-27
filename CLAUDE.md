# CLAUDE.md

このファイルは、このリポジトリでコードを扱う際の Claude Code へのガイダンスです。

## プロジェクト概要

Emacs から zellij セッション上の AI エージェント（主に Claude Code）に日本語テキストを送る Emacs パッケージ。
`M-x zellij-send` でセッションを選択し、専用バッファ（`*ai-セッション名*`）で入力・確認・返信を行う。
このパッケージは 2 つの要素で成り立つ:
- *ai-SESSION* バッファ（黒板）: ユーザーが入力するための主インターフェース
- zellij セッション本体: detached（attach クライアントなし）でバックグラウンドで動く実体

**attach クライアントは不要**（zellij 0.44+ で実機検証済み）。新規セッションは
`zellij attach --create-background` で detached のまま作り、`zellij run` で claude を
起動して返る pane-id（`terminal_N`）を保持し、以後すべての送受信を `--pane-id` 指定で行う。
focused pane への送信（pane-id 指定なし）はクライアントがいないと届かないため、
pane-id 不明の既存セッションに送る場合のみ使う（ターミナル側で attach していれば動く）。
かつては eat による attach を必須としていたが、eat 連携が原因のフリーズが解消できず全廃した。

## 開発環境

- Emacs 31、`lexical-binding: t`
- 依存: `transient` 0.4以上（必須）、`markdown-mode`（オプション）
- zellij **0.44 以上**（dump-screen の STDOUT 出力・`--pane-id` 指定に依存）
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
Emacs バッファ (*ai-SESSION*)  [zellij-send--pane-id を保持]
  ├─ 入力: C-c C-c → zellij-send--send → zellij action write-chars/write 13（--pane-id 指定）
  ├─ 表示: zellij action dump-screen → STDOUT 直読み → バッファ更新（非同期 / make-process + sentinel）
  ├─ 自動受信: Stop フック (emacsclient) または ポーリング (run-at-time)
  ├─ ログ: Stop フックが transcript から assistant 出力を .zellij-send/claude-log.md に追記
  └─ UI: transient メニュー (C-c C-a)
```

### zellij コマンドの呼び出し方針

- **すべての zellij 呼び出しは非同期**（`make-process` + sentinel）。同期 `call-process` は禁止（Emacs の UI をブロックしフリーズの温床になる）
- 引数は個別の文字列として渡し、**シェル文字列結合は行わない**（コマンドインジェクション防止）。ユーザーテキストの直前に `--` を置き、`-` 始まりのテキストがオプション扱いされるのを防ぐ
- 汎用ヘルパー: `(zellij-send--zellij-async args &optional callback)` — callback に exit code を渡す
- 送信: `(zellij-send--send session text &optional callback)` — write-chars → 成功後に write 13 を sentinel で連鎖。callback には成功 t / 失敗 nil。カレントバッファの `zellij-send--pane-id` を呼び出し時に取り込むため、**必ず対象バッファをカレントにして呼ぶ**（返信バッファには pane-id をコピーしてある）
- スクリーン取得: `(zellij-send--dump-screen-async session callback)` — STDOUT 直読み（zellij 0.44+、tmpfile 不使用）。コールバックは要求元バッファをカレントにした状態で呼ばれる
- ペイン起動: `(zellij-send--run-in-session-async session dir command callback)` — `zellij run` の STDOUT から pane-id を抽出して callback に渡す

**送信後の後処理は成功コールバック内で行う**: バッファクリア（`zellij-send-send`）や返信バッファのクローズ（`zellij-send--reply-send`）は送信成功後に実行し、失敗時に入力テキストを失わないようにする。

**sentinel の中でミニバッファ入力をしない**: sentinel / プロセスフィルタは quit が抑止された状態で走ることがあり、その中で `completing-read` や `read-directory-name` を呼ぶと C-g が効かない・入力が壊れる。非同期結果を受けてユーザーに質問する場合は `(run-at-time 0 nil #'FUNC ARGS)` で sentinel を抜けてから行う（`zellij-send` → `zellij-send--select-session` がこの形）。

**セッション一覧のパース**: `zellij-send--parse-sessions` は `NAME [Created ...]` 形式の行だけを採用し、EXITED セッションと「セッション 0 件」の案内文（`No active zellij sessions found.`）を除外する。先頭トークンを無条件に拾うと案内文から `No` というセッション名が生まれる。

### Enter キー送信の注意点

`write-chars` に `\n` を含めても Enter にならない。必ず 2 ステップに分ける:
```
zellij action write-chars --pane-id terminal_N -- "テキスト"
zellij action write --pane-id terminal_N -- 13    ; 0x0D = CR = Enter
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
;;; ポーリング
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
- 更新時は point と `window-start` を復元する（`zellij-send--update-buffer`）。毎回 `point-min` に飛ばすと 2 秒ごとに読んでいる位置が失われる
- **モードライン通知は持たない**（2026-07-27 撤去）。`global-mode-string` への `:eval` 登録は再描画のたびに全バッファを走査するうえ、状態表示は別途 `zellij-send-dashboard.el` で扱う。作業中/完了の検知（`zellij-send-ready-regexp` / `--is-ready` / `--notifying` / `--was-busy`）も併せて削除済み
- 数字キー（`1`/`2`/`3`）の即送信も撤去。プロンプト表示後にバッファへ本文を書くと数字が誤送信されるため。選択肢の送信は `C-c C-a` → `n`（`zellij-send-reply-number`）。プロンプト行のハイライトは維持

## 自動受信・出力ログ（Stop フック）

Claude Code 停止時に `~/.claude/hooks/stop-zellij-send.sh` が 2 つの処理を行う:
1. フック stdin の JSON から `transcript_path` と `cwd` を取り、最新の assistant 出力を
   `CWD/.zellij-send/claude-log.md`（`zellij-send-log-file` と対応）に時刻付きで追記（python3 使用）
2. `emacsclient` → `zellij-send--on-claude-stop` でバッファを更新。`;;;###autoload` が必須

ログは `C-c C-a` → `l`（`zellij-send-open-log`）で開く。

## 新規セッション作成

`zellij-send--create-new-session` のフロー（すべて非同期）:
1. `zellij attach --create-background NAME` — detached セッション作成（tty 不要）
2. 0.5 秒待って `zellij --session NAME run --cwd DIR --name CMD -- CMD` — claude ペインを起動
3. `zellij run` の STDOUT から pane-id（`terminal_N`）を抽出し、黒板バッファの
   `zellij-send--pane-id` に保存

pane-id はバッファローカルのため Emacs 再起動で失われる。その場合は既存セッション扱い
（focused pane 送信）になるので、ターミナルで attach すれば送信できる。
