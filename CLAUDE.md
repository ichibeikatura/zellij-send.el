# CLAUDE.md

このファイルは、このリポジトリでコードを扱う際のClaude Code (claude.ai/code)へのガイダンスを提供します。

## プロジェクト概要

これは、zellij で動作する AI コーディングエージェントに Emacs から日本語文字列を送る Emacs 拡張です。

## 開発セットアップ

これはEmacs拡張プロジェクトのため、開発には以下が含まれます：
- Emacs Lispコード（`.el`ファイル）の作成
- Emacs内でのテスト
- zellij統合のためのシェルスクリプトやPythonの実装（可能性あり）

## 開発環境
emacs-version :31
lexical-binding: t 

## アーキテクチャ考慮事項

このブリッジを実装する際は、以下を考慮してください：
1. **Emacs側の実装**: Emacsユーザー向けのコマンド、モード、UI要素
2. **zellij通信**: zellijセッションへのコマンド送信(主に日本語、 zellij action write-chars)
3. **非同期処理**: AIエージェントとの通信中もEmacs操作を応答性を保つ

## こういうものを作る
- "emacs-send" でセッションの一覧を表示/選択(zellij list-sessions の出力をパース)
- "ai-セッション名"バッファを作成
- 文字入力、C-c C-c で文字列を送信


## ファイル構造

- zellij-send.el` - 全ての核心機能を含むメインパッケージファイル
- `CLAUDE.md` - このドキュメントファイル
- `README.md` - ユーザー向けドキュメント
- `LICENSE` - GPL v3ライセンス

## 追加機能
- C-c C-c の後は "ai-セッション名"の入力内容をクリアする。
- AI の回答を表示するモードも欲しい
- 終了したい。Claude Code に /exit を送りバッファを消す。
- C-c C-a で transient

(transient-define-prefix my/zellij-send ()
    "Custom Menu"
    [["表示"
      ("a" "Claude Code の回答を表示"    適当に命名して)
      ("c" "表示内容をクリア"     適当に命名して)
      ("q" "終了"      適当に命名して)]
     ]))

## 回答表示の実装方針
- `zellij action dump-screen` でターゲットペインの内容を取得する
- transient の "Claude Code の回答を表示" 実行時に取得・表示する
- "ai-セッション名"に表示する。
- "ai-セッション名"は二人で使う黒板のようなイメージ。消したり書いたいする。本格的に読みたい時にはターミナルに戻る

## 新しい方針
- C-c C-c の後で"ai-セッション名"の入力内容はクリアされる。(これまでと同じ)
- zellij pipe でAIの回答を"ai-セッション名"に表示させる。
- ユーザーはそれを読み、"表示内容をクリア" あるいは編集し、AI に回答する

## 参考実装
- 送信: `tmux send-keys` → `zellij action write-chars`
- 受信: `tmux capture-pane` のポーリング → `zellij pipe` によるプッシュ型受信
- セッション管理: `tmux list-sessions` → `zellij list-sessions`

