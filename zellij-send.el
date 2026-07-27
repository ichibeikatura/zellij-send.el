;;; zellij-send.el --- Send text to zellij sessions from Emacs -*- lexical-binding: t -*-

;; Copyright (C) 2026 桂市兵衛
;; SPDX-License-Identifier: GPL-3.0-or-later
;; Author: 桂市兵衛
;; Version: 0.1.0
;; Package-Requires: ((emacs "28.1") (transient "0.4"))
;; URL: https://github.com/ichibeikatura/zellij-send.el

;;; Commentary:
;; Emacs から zellij セッションに日本語文字列を送る拡張。
;; M-x zellij-send でセッション選択、C-c C-c で送信、C-c C-a でメニュー。

;;; Code:

(require 'transient)

(declare-function markdown-mode "markdown-mode")
(declare-function zellij-send-mode "zellij-send")

(defgroup zellij-send nil
  "Send text to zellij sessions."
  :group 'tools)

(defcustom zellij-send-executable "zellij"
  "Path to the zellij executable."
  :type 'string
  :group 'zellij-send)

(defcustom zellij-send-default-command "claude"
  "新規セッションで起動するコマンド。"
  :type 'string
  :group 'zellij-send)

(defcustom zellij-send-term "xterm-256color"
  "zellij をサブプロセス起動する際に設定する TERM 環境変数。
Emacs はサブプロセスに既定で TERM=dumb を渡すため、これがそのまま
zellij サーバ・ペインに継承され、ペイン内のシェルでも TERM=dumb と
なり starship 等が無効化される。サーバを起動する `attach
--create-background' とペインを生む `run' をこの値で起動して回避する。"
  :type 'string
  :group 'zellij-send)

(defcustom zellij-send-session-size '(320 . 80)
  "新しく作る zellij セッションのサイズ (COLUMNS . LINES)。nil なら zellij 任せ。
zellij は tty が無いとき環境変数 COLUMNS / LINES を見る。Emacs の
サブプロセスには tty も COLUMNS も渡らないため、既定のままだと
`attach --create-background' で作ったセッションが 25 桁 × 24 行になり、
Claude Code が自分でペイン幅に合わせて改行を入れる都合で出力が
細切れに折り返される。広く取っておくと本文が長い行のまま届き、
Emacs 側で好きなように折り返せる。

なおターミナルから attach すると、zellij の仕様で
そのクライアントの大きさまでセッションが縮む。"
  :type '(choice (const :tag "zellij 任せ" nil)
                 (cons (integer :tag "桁") (integer :tag "行")))
  :group 'zellij-send)

(defcustom zellij-send-poll-interval 2.0
  "ポーリング間隔（秒）。0 でポーリング無効。"
  :type 'number
  :group 'zellij-send)

(defcustom zellij-send-history-max 50
  "セッションごとに覚えておく送信履歴の数。"
  :type 'integer
  :group 'zellij-send)

(defcustom zellij-send-log-file ".zellij-send/claude-log.md"
  "Claude の出力ログファイルのパス（セッション作業ディレクトリからの相対）。
実際の追記は Stop フック（stop-zellij-send.sh）が行うため、
変更する場合はフックスクリプト側も合わせること。"
  :type 'string
  :group 'zellij-send)

(defvar-local zellij-send--session nil
  "このバッファに対応する zellij セッション名。")

(defvar-local zellij-send--pane-id nil
  "送信先ペインの ID（例: \"terminal_2\"）。
このパッケージが `zellij run' で起動したペインのみ判明する。
nil の場合は focused pane に送る（attach クライアントが必要）。")

(defvar-local zellij-send--timer nil
  "ポーリングタイマー。")

(defvar-local zellij-send--user-cleared nil
  "ユーザーが意図してクリアした場合 non-nil。ポーリング・Stop フックの上書きを防ぐ。")

(defvar-local zellij-send--reply-main-buffer nil
  "返信バッファを開いた元の zellij-send バッファ。")

(defvar-local zellij-send--reply-window-config nil
  "返信バッファを開く前のウィンドウ構成。")

(defmacro zellij-send--assert-session ()
  "カレントバッファが zellij-send セッションに紐付いていなければエラーを発する。"
  '(unless zellij-send--session
     (user-error "zellij-send バッファ外では使えません")))

;;; セッション一覧の取得

(defun zellij-send--parse-sessions (raw)
  "RAW テキスト（list-sessions 出力）から生存セッション名リストを返す。
zellij の出力は 1 行 1 セッションで
「NAME [Created ...] (current)」の形式（ANSI 付き）。
以下は除外する:
- EXITED セッション（送信しても届かないため）
- セッションが 0 件のときの案内文
  （\"No active zellij sessions found.\" — 従来はこれを
  セッション名 \"No\" として拾ってしまっていた）。"
  (delq nil
        (mapcar (lambda (line)
                  (let ((clean (string-trim (zellij-send--strip-ansi line))))
                    (when (and (string-match "\\`\\([^ \t]+\\)[ \t]+\\[Created" clean)
                               (not (string-match-p "EXITED" clean)))
                      (match-string 1 clean))))
                (split-string raw "\n" t))))

(defun zellij-send--list-sessions-async (callback)
  "list-sessions を非同期で実行し CALLBACK を呼ぶ。
成功時: (callback sessions) — sessions は文字列リスト（空もあり）。
タイムアウト時（5秒）: (callback :timeout)。"
  (let* ((out-buf (generate-new-buffer " *zellij-list-sessions*"))
         (err-buf (generate-new-buffer " *zellij-list-sessions-err*"))
         (done nil)
         timer proc)
    (setq proc
          (make-process
           :name "zellij-list-sessions"
           :buffer out-buf
           :stderr err-buf
           :noquery t
           :command (list zellij-send-executable "list-sessions")
           :sentinel
           (lambda (p _)
             (when (and (not done)
                        (memq (process-status p) '(exit signal)))
               (setq done t)
               (when timer (cancel-timer timer))
               (let ((sessions (zellij-send--parse-sessions
                                (with-current-buffer out-buf (buffer-string)))))
                 (ignore-errors (kill-buffer out-buf))
                 (ignore-errors (kill-buffer err-buf))
                 (funcall callback sessions))))))
    (setq timer
          (run-with-timer 5.0 nil
                          (lambda ()
                            (unless done
                              (setq done t)
                              (ignore-errors (delete-process proc))
                              (ignore-errors (kill-buffer out-buf))
                              (ignore-errors (kill-buffer err-buf))
                              (funcall callback :timeout)))))))

;;; バッファ管理

(defun zellij-send--buffer-name (session)
  "SESSION に対応するバッファ名を返す。"
  (format "*ai-%s*" session))

(defun zellij-send--get-or-create-buffer (session)
  "SESSION 用バッファを返す。なければ作成して zellij-send-mode を有効化。"
  (let* ((name (zellij-send--buffer-name session))
         (buf (get-buffer-create name)))
    (with-current-buffer buf
      (unless (eq major-mode 'zellij-send-mode)
        (zellij-send-mode)
        (setq zellij-send--session session)))
    buf))

;;; 送信

(defun zellij-send--process-environment ()
  "zellij を起動するための `process-environment' を返す。
TERM を `zellij-send-term' に差し替え（Emacs 既定の TERM=dumb が
zellij サーバ・ペインに継承されるのを防ぐ）、`zellij-send-session-size'
が non-nil なら COLUMNS / LINES も渡す（tty が無いとき zellij は
これを見る。未設定だと 25 桁 × 24 行の極端に狭いペインになる）。"
  (let ((env (cons (concat "TERM=" zellij-send-term) process-environment)))
    (when zellij-send-session-size
      (setq env (append (list (format "COLUMNS=%d" (car zellij-send-session-size))
                              (format "LINES=%d" (cdr zellij-send-session-size)))
                        env)))
    env))

(defun zellij-send--zellij-async (args &optional callback)
  "zellij を ARGS で非同期実行する。
終了したら CALLBACK に exit code を渡して呼ぶ（CALLBACK は省略可）。
同期 `call-process' は使わない: Emacs の UI をブロックし、
zellij サーバ側の都合で応答が遅れた場合にフリーズするため。
TERM を上書きして起動する（サーバを起動する `attach
--create-background' が TERM=dumb をペインに伝播させないため）。"
  (let ((process-environment (zellij-send--process-environment)))
    (make-process
     :name "zellij-async"
     :buffer nil
     :noquery t
     :command (cons zellij-send-executable args)
     :sentinel
     (lambda (proc _event)
       (when (memq (process-status proc) '(exit signal))
         (when callback
           (funcall callback (process-exit-status proc))))))))

(defun zellij-send--pane-args ()
  "カレントバッファの `zellij-send--pane-id' から --pane-id 引数リストを返す。
pane-id 不明なら nil（focused pane への送信になる）。"
  (when zellij-send--pane-id
    (list "--pane-id" zellij-send--pane-id)))

(defun zellij-send--send (session text &optional callback)
  "SESSION に TEXT を送り、続けて Enter キー（0x0D）を非同期送信する。
カレントバッファに `zellij-send--pane-id' があればそのペインへ、
なければ focused pane へ送る（後者は attach クライアントが必要）。
完了したら CALLBACK に成功なら t、失敗なら nil を渡して呼ぶ（省略可）。
失敗時はメッセージも表示する。"
  (let ((pane-args (zellij-send--pane-args)))
    (zellij-send--zellij-async
     (append (list "--session" session "action" "write-chars")
             pane-args (list "--" text))
     (lambda (exit1)
       (if (not (zerop exit1))
           (progn
             (message "zellij テキスト送信失敗 (exit: %d)" exit1)
             (when callback (funcall callback nil)))
         (zellij-send--zellij-async
          (append (list "--session" session "action" "write")
                  pane-args (list "--" "13"))
          (lambda (exit2)
            (if (not (zerop exit2))
                (progn
                  (message "zellij Enter 送信失敗 (exit: %d)" exit2)
                  (when callback (funcall callback nil)))
              (when callback (funcall callback t))))))))))

(defun zellij-send--send-keys (session bytes &optional callback)
  "SESSION の対象ペインに BYTES（数値のリスト）をキー入力として送る。
カレントバッファの `zellij-send--pane-id' を使うので、必ず対象バッファを
カレントにして呼ぶこと。テキストではなく制御文字を送るための入口
（例: Esc = 27）。"
  (zellij-send--zellij-async
   (append (list "--session" session "action" "write")
           (zellij-send--pane-args)
           (list "--")
           (mapcar #'number-to-string bytes))
   callback))

;;; スクリーンダンプ

(defun zellij-send--strip-ansi (str)
  "STR から ANSI エスケープシーケンスを除去して返す。"
  (let ((result str))
    (setq result (replace-regexp-in-string "\033\\[[0-9;?]*[A-Za-z]" "" result))
    (setq result (replace-regexp-in-string "\033." "" result))
    result))

(defun zellij-send--process-dump (raw)
  "dump-screen の生テキスト RAW を整形して返す。"
  (replace-regexp-in-string "^─+" ""
   (zellij-send--strip-ansi
    (replace-regexp-in-string "\r" "" raw))))

(defun zellij-send--dump-screen-async (session callback)
  "SESSION のスクリーン内容を非同期で取得する（STDOUT 直読み・zellij 0.44+）。
カレントバッファに `zellij-send--pane-id' があればそのペインをダンプする。
取得できたら整形済み文字列を、失敗時は nil を引数にして CALLBACK を呼ぶ。
CALLBACK は要求元バッファをカレントにした状態で呼ばれる。"
  (let ((req-buffer (current-buffer))
        (out-buf (generate-new-buffer " *zellij-dump*"))
        (err-buf (generate-new-buffer " *zellij-dump-err*")))
    (make-process
     :name "zellij-dump"
     :buffer out-buf
     :stderr err-buf
     :noquery t
     :command (append (list zellij-send-executable
                            "--session" session
                            "action" "dump-screen")
                      (when zellij-send--pane-id
                        (list "--pane-id" zellij-send--pane-id)))
     :sentinel
     (lambda (proc _event)
       (when (memq (process-status proc) '(exit signal))
         (let ((content
                (when (zerop (process-exit-status proc))
                  (zellij-send--process-dump
                   (with-current-buffer out-buf (buffer-string))))))
           (ignore-errors (kill-buffer out-buf))
           (ignore-errors (kill-buffer err-buf))
           (when (buffer-live-p req-buffer)
             (with-current-buffer req-buffer
               (funcall callback content)))))))))

;;; セッション情報の取得（cwd・pane-id）

(defun zellij-send--zellij-output-async (session args callback)
  "SESSION に対して zellij を ARGS で実行し、STDOUT を CALLBACK に渡す。
失敗時は nil を渡す。"
  (let ((out-buf (generate-new-buffer " *zellij-out*"))
        (err-buf (generate-new-buffer " *zellij-out-err*")))
    (make-process
     :name "zellij-output"
     :buffer out-buf
     :stderr err-buf
     :noquery t
     :command (append (list zellij-send-executable "--session" session) args)
     :sentinel
     (lambda (proc _event)
       (when (memq (process-status proc) '(exit signal))
         (let ((out (and (zerop (process-exit-status proc))
                         (with-current-buffer out-buf (buffer-string)))))
           (ignore-errors (kill-buffer out-buf))
           (ignore-errors (kill-buffer err-buf))
           (funcall callback out)))))))

(defun zellij-send--parse-panes (raw)
  "`action list-panes' の出力 RAW から端末ペインの (ID . TITLE) を順に返す。
出力は「PANE_ID  TYPE  TITLE」の表。plugin ペインは除外する。"
  (delq nil
        (mapcar
         (lambda (line)
           (let ((clean (string-trim (zellij-send--strip-ansi line))))
             (when (string-match "\\`\\(terminal_[0-9]+\\)[ \t]+terminal[ \t]*\\(.*\\)\\'"
                                 clean)
               (cons (match-string 1 clean)
                     (string-trim (match-string 2 clean))))))
         (split-string raw "\n" t))))

(defun zellij-send--pick-pane (panes)
  "PANES（(ID . TITLE) のリスト）から送信先として最も妥当なものを選ぶ。
`zellij-send-default-command' と同名のタイトルを優先し、
無ければ最初の端末ペインを使う。"
  (or (car (seq-find (lambda (p)
                       (string= (cdr p) zellij-send-default-command))
                     panes))
      (caar panes)))

(defun zellij-send--detect-pane-async (session callback)
  "SESSION の送信先 pane-id を推定して CALLBACK に渡す（不明なら nil）。"
  (zellij-send--zellij-output-async
   session '("action" "list-panes")
   (lambda (out)
     (funcall callback
              (and out (zellij-send--pick-pane
                        (zellij-send--parse-panes out)))))))

(defun zellij-send--parse-layout-cwd (raw)
  "`action dump-layout' の出力 RAW からセッションの cwd を返す（無ければ nil）。"
  (when (string-match "^[[:space:]]*cwd[[:space:]]+\"\\([^\"]+\\)\"" raw)
    (match-string 1 raw)))

(defun zellij-send--session-cwd-async (session callback)
  "SESSION の作業ディレクトリを CALLBACK に渡す（不明なら nil）。"
  (zellij-send--zellij-output-async
   session '("action" "dump-layout")
   (lambda (out)
     (funcall callback (and out (zellij-send--parse-layout-cwd out))))))

(defun zellij-send-attach-session-async (session &optional callback)
  "既存の SESSION 用バッファを、ユーザーに何も聞かずに用意する。
cwd は `dump-layout'、pane-id は `list-panes' から取得して設定する。
pane-id が取れれば attach クライアント無しでも送信できる。
用意できたら CALLBACK にバッファを渡す。"
  (let ((buf (zellij-send--get-or-create-buffer session)))
    (zellij-send--session-cwd-async
     session
     (lambda (cwd)
       (when (and cwd (buffer-live-p buf) (file-directory-p cwd))
         (with-current-buffer buf
           (setq-local default-directory (file-name-as-directory cwd))))
       (zellij-send--detect-pane-async
        session
        (lambda (pane-id)
          (when (and pane-id (buffer-live-p buf))
            (with-current-buffer buf
              (setq-local zellij-send--pane-id pane-id)))
          (when callback (funcall callback buf))))))))

;;; 送信履歴

;; 履歴はセッション名をキーにしたグローバル表に持つ。黒板バッファと
;; 返信バッファで同じ履歴を共有し、バッファを閉じても残るため。
;; 辿っている位置と下書きの退避はバッファローカル。

(defvar zellij-send--history-table (make-hash-table :test #'equal)
  "セッション名 -> 送信済みテキストのリスト（新しい順）。")

(defvar-local zellij-send--history-index nil
  "履歴を辿っている位置（0 が最新）。nil なら辿っていない。")

(defvar-local zellij-send--history-draft nil
  "履歴を辿り始める前のバッファ内容。")

(defun zellij-send-history (session)
  "SESSION の送信履歴（新しい順）を返す。"
  (gethash session zellij-send--history-table))

(defun zellij-send--history-add (session text)
  "SESSION の履歴に TEXT を追加する。直前と同じ内容なら追加しない。"
  (let ((history (zellij-send-history session)))
    (unless (equal (car history) text)
      (setq history (cons text history))
      (when (> (length history) zellij-send-history-max)
        (setq history (seq-take history zellij-send-history-max)))
      (puthash session history zellij-send--history-table))))

(defun zellij-send--history-replace (text)
  "バッファの内容を TEXT で置き換える。
ポーリングに上書きされないよう、変更済みのままにしておく。"
  (erase-buffer)
  (insert text)
  (goto-char (point-max)))

(defun zellij-send--history-move (delta)
  "履歴を DELTA 分だけ辿ってバッファに出す。DELTA が正なら古い方へ。"
  (zellij-send--assert-session)
  (let* ((history (zellij-send-history zellij-send--session))
         (index (+ (or zellij-send--history-index -1) delta)))
    (unless history
      (user-error "送信履歴がありません"))
    (cond
     ((< index 0)
      ;; 最新より新しい側に戻ったら、辿り始める前の下書きに復帰する
      (setq zellij-send--history-index nil)
      (zellij-send--history-replace (or zellij-send--history-draft ""))
      (setq zellij-send--history-draft nil)
      (message "下書きに戻りました"))
     ((>= index (length history))
      (user-error "これ以上古い履歴はありません"))
     (t
      (when (null zellij-send--history-index)
        (setq zellij-send--history-draft (buffer-string)))
      (setq zellij-send--history-index index)
      (zellij-send--history-replace (nth index history))
      (message "履歴 %d/%d" (1+ index) (length history))))))

(defun zellij-send-history-prev ()
  "1 つ前に送信したテキストを呼び戻す。"
  (interactive)
  (zellij-send--history-move 1))

(defun zellij-send-history-next ()
  "1 つ後に送信したテキストを呼び戻す（最新まで戻ると下書きに復帰）。"
  (interactive)
  (zellij-send--history-move -1))

(defun zellij-send-history-select ()
  "送信履歴から選んでバッファに入れる。"
  (interactive)
  (zellij-send--assert-session)
  (let ((history (zellij-send-history zellij-send--session)))
    (unless history
      (user-error "送信履歴がありません"))
    (let ((choice (completing-read "履歴: " history nil t)))
      (when (null zellij-send--history-index)
        (setq zellij-send--history-draft (buffer-string)))
      (setq zellij-send--history-index (seq-position history choice))
      (zellij-send--history-replace choice))))

;;; プロンプト検出・ハイライト

(defun zellij-send--detect-prompt ()
  "バッファに Claude Code の選択肢プロンプトがあれば non-nil を返す。"
  (save-excursion
    (goto-char (point-min))
    (re-search-forward "❯[[:space:]]*[1-9]\\." nil t)))

(defun zellij-send--clear-prompt-highlight ()
  "選択肢行のハイライトを消す。"
  (remove-overlays (point-min) (point-max) 'zellij-send-prompt t))

(defun zellij-send--highlight-prompt ()
  "選択肢行をハイライトする。"
  (zellij-send--clear-prompt-highlight)
  (save-excursion
    (goto-char (point-min))
    (while (re-search-forward "^.*❯[[:space:]]*[1-9]\\..*$" nil t)
      (let ((ov (make-overlay (line-beginning-position) (line-end-position))))
        (overlay-put ov 'zellij-send-prompt t)
        (overlay-put ov 'face 'highlight)))))

;;; バッファ更新（共通処理）

(defun zellij-send--update-buffer (content)
  "バッファを CONTENT で更新し、プロンプト検出・ハイライトを実行する。
カーソル位置とウィンドウの表示開始位置は可能な範囲で復元する
（ポーリング更新のたびに読んでいる箇所が先頭へ飛ぶのを防ぐため）。"
  (let* ((win (get-buffer-window (current-buffer) t))
         (pos (point))
         (wstart (and (window-live-p win) (window-start win))))
    (with-silent-modifications
      (erase-buffer)
      (insert content))
    (goto-char (min pos (point-max)))
    (when (window-live-p win)
      (set-window-point win (point))
      (when wstart
        (set-window-start win (min wstart (point-max)) t))))
  (set-buffer-modified-p nil)
  (if (zellij-send--detect-prompt)
      (zellij-send--highlight-prompt)
    (zellij-send--clear-prompt-highlight)))

;;; ポーリング

(defun zellij-send--poll ()
  "タイマーコールバック。dump-screen を非同期で要求し、結果が来たらバッファを更新する。"
  (when (and (buffer-live-p (current-buffer))
             zellij-send--session
             (not (buffer-modified-p))
             (not zellij-send--user-cleared))
    (zellij-send--dump-screen-async
     zellij-send--session
     (lambda (content)
       (when (and content
                  (not (buffer-modified-p))
                  (not zellij-send--user-cleared)
                  (not (string= content (buffer-string))))
         (zellij-send--update-buffer content))))))

(defun zellij-send--start-polling ()
  "ポーリングタイマーを開始する。"
  (when (and (> zellij-send-poll-interval 0)
             (null zellij-send--timer))
    (let ((buf (current-buffer)))
      (setq zellij-send--timer
            (run-at-time zellij-send-poll-interval zellij-send-poll-interval
                         (lambda ()
                           (when (buffer-live-p buf)
                             (with-current-buffer buf
                               (zellij-send--poll)))))))))

(defun zellij-send--stop-polling ()
  "ポーリングタイマーを停止する。"
  (when zellij-send--timer
    (cancel-timer zellij-send--timer)
    (setq zellij-send--timer nil)))

;;; Claude Code コマンド

(defun zellij-send-compact ()
  "セッションに /compact を送信してコンテキストを圧縮する。"
  (interactive)
  (zellij-send--assert-session)
  (zellij-send--send zellij-send--session "/compact"
                     (lambda (ok)
                       (when ok (message "圧縮しました")))))

(defun zellij-send-cc-clear ()
  "セッションに /clear を送信してコンテキストをリセットする。"
  (interactive)
  (zellij-send--assert-session)
  (zellij-send--send zellij-send--session "/clear"
                     (lambda (ok)
                       (when ok (message "クリアしました（コンテキスト）")))))

(defun zellij-send-interrupt ()
  "実行中の処理を中断する（対象ペインに Esc を送る）。
状態は問わない。ダッシュボードの状態表示は数秒古いことがあり、
「作業中に見えない」ことを理由に中断を拒むと止められなくなるため。"
  (interactive)
  (zellij-send--assert-session)
  (let ((session zellij-send--session))
    (zellij-send--send-keys
     session '(27)
     (lambda (exit)
       (if (zerop exit)
           (message "中断しました → [%s]" session)
         (message "中断の送信に失敗しました (exit: %d)" exit))))))

(defun zellij-send-save-progress ()
  "現在の作業内容を CLAUDE.md に記録するよう依頼する。"
  (interactive)
  (zellij-send--assert-session)
  (zellij-send--send zellij-send--session
                     "ここまでの作業内容と決定事項を CLAUDE.md に追記して"
                     (lambda (ok)
                       (when ok (message "記録を依頼しました")))))

;;; インタラクティブコマンド

(defun zellij-send-send ()
  "バッファのテキストを zellij セッションに送信し、バッファをクリアする。"
  (interactive)
  (zellij-send--assert-session)
  (let* ((session zellij-send--session)
         (buf (current-buffer))
         (text (string-trim (buffer-string))))
    (when (string-empty-p text)
      (user-error "送信するテキストが空です"))
    ;; 失敗時に入力テキストを失わないよう、クリアは成功後に行う
    (zellij-send--send
     session text
     (lambda (ok)
       (when (and ok (buffer-live-p buf))
         (zellij-send--history-add session text)
         (with-current-buffer buf
           (erase-buffer)
           (set-buffer-modified-p nil)
           (setq zellij-send--user-cleared nil)
           ;; 送信し終えたら履歴を辿る位置はリセットする
           (setq zellij-send--history-index nil)
           (setq zellij-send--history-draft nil))
         (message "送信しました → [%s]" session))))))

(defun zellij-send-show-response ()
  "zellij スクリーンの内容をバッファに取得・表示する。"
  (interactive)
  (zellij-send--assert-session)
  (zellij-send--dump-screen-async
   zellij-send--session
   (lambda (content)
     (if content
         (progn
           (zellij-send--update-buffer content)
           (message "スクリーン内容を取得しました"))
       (message "スクリーン内容の取得に失敗しました")))))

(defun zellij-send-clear-buffer ()
  "バッファの内容をクリアする。"
  (interactive)
  (erase-buffer)
  (set-buffer-modified-p nil)
  (setq zellij-send--user-cleared t)
  (message "クリアしました"))

(defun zellij-send-quit ()
  "Claude Code に /exit を送り、zellij セッションとバッファを削除する。"
  (interactive)
  (zellij-send--assert-session)
  (let ((session zellij-send--session)
        (main-buf (current-buffer)))
    (unless (yes-or-no-p
             (format "セッション [%s] を削除しますか? (zellij セッションも消えます) " session))
      (user-error "キャンセルしました"))
    ;; Claude Code に /exit を送信（失敗しても続行）
    (zellij-send--send session "/exit")
    (message "セッション [%s] を終了中..." session)
    ;; 2秒後にセッションを強制削除してバッファを閉じる
    (run-with-timer
     2.0 nil
     (lambda ()
       (zellij-send--zellij-async
        (list "delete-session" "--force" session)
        (lambda (exit)
          (if (zerop exit)
              (progn
                (when (buffer-live-p main-buf)
                  (kill-buffer main-buf))
                (message "セッション [%s] を削除しました" session))
            ;; 削除に失敗したらバッファは残す（再操作できるようにするため）
            (message "セッション [%s] の削除に失敗しました (exit: %d)"
                     session exit))))))))

(defun zellij-send-open-log ()
  "Claude の出力ログ（markdown）を別ウィンドウで開く。
ログは Stop フックが `zellij-send-log-file' に追記する。"
  (interactive)
  (zellij-send--assert-session)
  (let ((file (expand-file-name zellij-send-log-file default-directory)))
    (unless (file-exists-p file)
      (user-error "ログファイルがまだありません: %s" file))
    (find-file-other-window file)))

;;; 返信バッファ

(defun zellij-send--reply-send ()
  "返信バッファの内容を送信してバッファを閉じ、元のバッファに戻る。"
  (interactive)
  (unless zellij-send--session
    (user-error "セッション情報がありません"))
  (let ((session zellij-send--session)
        (text (string-trim (buffer-string)))
        (reply-buf (current-buffer))
        (main-buf zellij-send--reply-main-buffer)
        (wconf zellij-send--reply-window-config))
    (when (string-empty-p text)
      (user-error "送信するテキストが空です"))
    ;; 失敗時は返信バッファを残してテキストを失わない
    (zellij-send--send
     session text
     (lambda (ok)
       (when ok
         (zellij-send--history-add session text)
         (when (buffer-live-p reply-buf)
           (kill-buffer reply-buf))
         (if (window-configuration-p wconf)
             (set-window-configuration wconf)
           (when (and main-buf (buffer-live-p main-buf))
             (pop-to-buffer main-buf)))
         (message "送信しました → [%s]" session))))))

(defun zellij-send-reply-number ()
  "数字を入力して zellij セッションに送信する。"
  (interactive)
  (zellij-send--assert-session)
  (let ((session zellij-send--session)
        (n (read-number "送る数字: ")))
    (zellij-send--send session (number-to-string n)
                       (lambda (ok)
                         (when ok
                           (message "送信しました: %d → [%s]" n session))))))

(defvar zellij-send-reply-mode-map
  (let ((map (make-sparse-keymap)))
    (set-keymap-parent map text-mode-map)
    (define-key map (kbd "C-c C-c") #'zellij-send--reply-send)
    (define-key map (kbd "C-c C-k") #'zellij-send-interrupt)
    (define-key map (kbd "M-p")     #'zellij-send-history-prev)
    (define-key map (kbd "M-n")     #'zellij-send-history-next)
    map)
  "zellij-send 返信バッファのキーマップ。")

(defun zellij-send-reply ()
  "返信用の空バッファを開く。C-c C-c で送信してバッファを閉じる。"
  (interactive)
  (zellij-send--assert-session)
  (let* ((session zellij-send--session)
         (main-buf (current-buffer))
         (wconf (current-window-configuration))
         (reply-buf (get-buffer-create (format "*zellij-reply-%s*" session))))
    (with-current-buffer reply-buf
      (erase-buffer)
      (text-mode)
      (setq-local zellij-send--session session)
      (setq-local zellij-send--pane-id
                  (buffer-local-value 'zellij-send--pane-id main-buf))
      (setq-local zellij-send--reply-main-buffer main-buf)
      (setq-local zellij-send--reply-window-config wconf)
      (use-local-map zellij-send-reply-mode-map)
      (setq-local header-line-format
                  (format " Reply → [%s]  |  C-c C-c: 送信して閉じる" session)))
    (pop-to-buffer reply-buf)))

;;; Transient メニュー

(defun zellij-send-open-dashboard ()
  "セッション一覧ダッシュボードを開く。
`zellij-send-dashboard' が読み込まれていない場合は require を試みる。
本体はダッシュボードに依存しない（依存は dashboard → 本体の一方向）。"
  (interactive)
  (unless (fboundp 'zellij-send-dashboard)
    (unless (require 'zellij-send-dashboard nil t)
      (user-error "zellij-send-dashboard が読み込まれていません")))
  (call-interactively 'zellij-send-dashboard))

(transient-define-prefix zellij-send-menu ()
  "ZellijSend メニュー"
  [["表示"
    ("d" "ダッシュボード（セッション一覧）" zellij-send-open-dashboard)
    ("a" "Claude Code の回答を表示" zellij-send-show-response)
    ("l" "出力ログを開く (markdown)" zellij-send-open-log)
    ("x" "表示内容をクリア"         zellij-send-clear-buffer)]
   ["送信"
    ("e" "答える（返信バッファを開く）" zellij-send-reply)
    ("n" "答える（数字を送る）"         zellij-send-reply-number)
    ("h" "送信履歴から選ぶ"             zellij-send-history-select)]
   ["命令"
    ("i" "中断 (Esc)"              zellij-send-interrupt)
    ("c" "圧縮 (/compact)"         zellij-send-compact)
    ("C" "リセット (/clear)"       zellij-send-cc-clear)
    ("s" "作業を記録"              zellij-send-save-progress)
    ("q" "終了（セッション削除）"  zellij-send-quit)]])

;;; メジャーモード

(defvar zellij-send-mode-map
  (let ((map (make-sparse-keymap)))
    (define-key map (kbd "C-c C-c") #'zellij-send-send)
    (define-key map (kbd "C-c C-a") #'zellij-send-menu)
    (define-key map (kbd "C-c C-k") #'zellij-send-interrupt)
    (define-key map (kbd "M-p")     #'zellij-send-history-prev)
    (define-key map (kbd "M-n")     #'zellij-send-history-next)
    map)
  "zellij-send-mode のキーマップ。")

(defun zellij-send--mode-setup ()
  "zellij-send-mode の共通セットアップ処理。"
  (setq-local header-line-format
              '(:eval (format " Session: %s  |  C-c C-c: 送信  C-c C-a: メニュー"
                              (or zellij-send--session "?"))))
  (zellij-send--start-polling)
  (add-hook 'kill-buffer-hook #'zellij-send--stop-polling nil t))

(if (require 'markdown-mode nil t)
    (define-derived-mode zellij-send-mode markdown-mode "ZellijSend"
      "zellij セッションにテキストを送るためのモード。
\\{zellij-send-mode-map}"
      (zellij-send--mode-setup))
  (define-derived-mode zellij-send-mode text-mode "ZellijSend"
    "zellij セッションにテキストを送るためのモード。
\\{zellij-send-mode-map}"
    (zellij-send--mode-setup)))

;;; Stop フックハンドラ

;;;###autoload
(defun zellij-send--on-claude-stop ()
  "Claude Code 停止時に全 zellij-send バッファを dump-screen で更新する。
~/.claude/hooks/stop-zellij-send.sh から emacsclient 経由で呼ばれる。
ユーザーが意図してクリアしたバッファは更新しない。"
  (dolist (buf (buffer-list))
    (when (buffer-live-p buf)
      (with-current-buffer buf
        (when (and (eq major-mode 'zellij-send-mode)
                   zellij-send--session
                   (not zellij-send--user-cleared)
                   (not (buffer-modified-p)))
          (zellij-send--dump-screen-async
           zellij-send--session
           (lambda (content)
             (when (and content
                        (not zellij-send--user-cleared)
                        (not (buffer-modified-p)))
               (zellij-send--update-buffer content)))))))))

;;; エントリポイント

(defun zellij-send--prompt-session-dir ()
  "作業ディレクトリをユーザーに選択させ、末尾スラッシュなしの絶対パスを返す。"
  (directory-file-name
   (expand-file-name
    (read-directory-name "作業ディレクトリ: " default-directory))))

(defun zellij-send--assert-session-unique (session known-sessions)
  "SESSION が KNOWN-SESSIONS に含まれる場合 user-error を発する。"
  (when (member session known-sessions)
    (user-error "セッション「%s」はすでに存在します" session)))

(defun zellij-send--setup-session-buffer (session dir)
  "SESSION 用バッファを作成し default-directory を DIR に設定して表示する。
作成したバッファを返す。"
  (let ((buf (zellij-send--get-or-create-buffer session)))
    (with-current-buffer buf
      (setq-local default-directory (file-name-as-directory dir)))
    (switch-to-buffer buf)
    (goto-char (point-max))
    buf))

(defun zellij-send--run-in-session-async (session dir command callback)
  "SESSION に新しいペインを作って COMMAND（文字列）を起動する。
DIR はペインの作業ディレクトリ。成功したら pane-id（例: \"terminal_2\"）を、
失敗したら nil を CALLBACK に渡す。attach クライアントは不要（zellij 0.44+）。"
  (let ((out-buf (generate-new-buffer " *zellij-run*"))
        (err-buf (generate-new-buffer " *zellij-run-err*"))
        (process-environment (zellij-send--process-environment)))
    (make-process
     :name "zellij-run"
     :buffer out-buf
     :stderr err-buf
     :noquery t
     :command (append (list zellij-send-executable "--session" session
                            "run" "--cwd" dir "--name" command "--")
                      (split-string command))
     :sentinel
     (lambda (proc _event)
       (when (memq (process-status proc) '(exit signal))
         (let ((out (with-current-buffer out-buf (buffer-string))))
           (ignore-errors (kill-buffer out-buf))
           (ignore-errors (kill-buffer err-buf))
           (funcall callback
                    (and (zerop (process-exit-status proc))
                         (string-match "terminal_[0-9]+" out)
                         (match-string 0 out)))))))))

(defun zellij-send--create-new-session (known-sessions)
  "新規 detached zellij セッションを作成し claude ペインを起動する。
attach クライアント（eat）は使わない: `zellij attach --create-background' で
セッションを作り、`zellij run' で `zellij-send-default-command' を起動して
返る pane-id を保持し、以後 --pane-id 指定で送受信する。
KNOWN-SESSIONS は重複チェック用のセッション名リスト。"
  (let* ((dir (zellij-send--prompt-session-dir))
         (session (file-name-nondirectory dir)))
    (zellij-send--assert-session-unique session known-sessions)
    (let ((buf (zellij-send--setup-session-buffer session dir)))
      (zellij-send--zellij-async
       (list "attach" "--create-background" session)
       (lambda (exit)
         (if (not (zerop exit))
             (message "zellij セッション作成に失敗しました (exit: %d)" exit)
           ;; セッション初期化を待ってから claude ペインを起動
           (run-with-timer
            0.5 nil
            (lambda ()
              (zellij-send--run-in-session-async
               session dir zellij-send-default-command
               (lambda (pane-id)
                 (if (not pane-id)
                     (message "%s の起動に失敗しました"
                              zellij-send-default-command)
                   (when (buffer-live-p buf)
                     (with-current-buffer buf
                       (setq-local zellij-send--pane-id pane-id)))
                   ;; `attach --create-background' が生むデフォルト shell ペイン
                   ;; （terminal_0）を閉じ、claude ペインだけを残す。失敗しても
                   ;; 致命的ではないので結果は無視する。
                   (zellij-send--zellij-async
                    (list "--session" session "action" "close-pane"
                          "--pane-id" "terminal_0")
                    #'ignore)
                   (message "セッション [%s] を作成しました (%s)"
                            session pane-id))))))))))))

(defun zellij-send--connect-existing-session (session)
  "既存 SESSION 用の黒板バッファを開く。
cwd と pane-id は zellij から取得するので、ディレクトリは尋ねない
\(`zellij-send-attach-session-async' 参照)。pane-id が取れなかった
場合のみ focused pane 送信になり、ターミナルでの attach が要る。"
  (let ((known (get-buffer (zellij-send--buffer-name session))))
    ;; バッファ生成は同期。cwd と pane-id は後から非同期で埋まる。
    (switch-to-buffer (zellij-send--get-or-create-buffer session))
    (goto-char (point-max))
    (unless known
      (zellij-send-attach-session-async
       session
       (lambda (buf)
         (when (buffer-live-p buf)
           (with-current-buffer buf
             (message "セッション [%s] に接続しました%s" session
                      (if zellij-send--pane-id
                          (format " (%s)" zellij-send--pane-id)
                        "（pane-id 不明: ターミナルで attach が必要です）")))))))))

(defun zellij-send--select-session (sessions)
  "SESSIONS からセッションを選ばせ、対応するバッファを開く。
ミニバッファ入力を含むため、プロセス sentinel の中から直接呼ばないこと
\(`zellij-send' 参照)。"
  (let* ((choices (append sessions (list "[New]")))
         (choice (completing-read "Session: " choices nil t)))
    (if (string= choice "[New]")
        (zellij-send--create-new-session sessions)
      (zellij-send--connect-existing-session choice))))

;;;###autoload
(defun zellij-send ()
  "zellij セッションを選択して入力バッファを開く。"
  (interactive)
  (message "セッション一覧を取得中...")
  (zellij-send--list-sessions-async
   (lambda (sessions)
     (if (eq sessions :timeout)
         (message "zellij の応答がタイムアウトしました（5秒）。zellij が正常に動作しているか確認してください。")
       ;; コールバックはプロセス sentinel の中で走る。sentinel 内では
       ;; quit が抑止されるため、そのままミニバッファ入力を行うと C-g が
       ;; 効かない・入力が壊れる。タイマーで sentinel を抜けてから聞く。
       (run-at-time 0 nil #'zellij-send--select-session sessions)))))

(provide 'zellij-send)
;;; zellij-send.el ends here
